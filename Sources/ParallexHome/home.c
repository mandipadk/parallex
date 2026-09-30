// Parallex home redirect.
//
// macOS resolves the home folder (and so ~/Library, Application Support,
// Caches, …) from the user's account record, not from $HOME. An instance's
// own copy of an app loads this library, which answers the account lookups
// for the current user with the instance's home instead — so everything the
// app writes under "~" lands in the instance.
//
// The Parallex launcher sets:
//   PARALLEX_HOME_REDIRECT  the instance's home folder
//   PARALLEX_HOME_SCOPE     the copy's bundle path
//   PARALLEX_KEYCHAIN_SUFFIX appended to the names of the copy's "<App>
//                           Safe Storage" keychain items (the key Electron
//                           and Chromium apps encrypt their data with), so a
//                           copy has its own instead of prompting for, and
//                           sharing, the original's
//   PARALLEX_INSTANCE_KEYCHAIN the copy's own keychain file (made and
//                           unlocked by the launcher): every other password
//                           item the copy stores or looks up goes there
//   PARALLEX_HOME_ENV       "1": also answer getenv("HOME") with the
//                           instance's home (apps built on Node, Chromium
//                           or Rust find "~" through $HOME, not the account)
//   PARALLEX_GUARD          "\n"-separated paths of the original's data,
//                           which the copy may not touch (recorder.c)
//   PARALLEX_LOOPBACK_PORTS ","-separated ports the app finds itself on,
//                           which are the copy's own (ports.c)
// Only processes whose executable lives inside the scope are redirected
// (the app, its helpers and services). Any other process that inherits this
// library — a shell or tool the app started — takes it and the variables
// out of its environment, so its own children never see them. Without both
// variables the library does nothing.

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <fts.h>
#include <sys/stat.h>
#include <Security/Security.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pwd.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "ParallexHome.h"

#define INTERPOSE(replacement, original)                                          \
    __attribute__((used)) static const struct {                                   \
        const void *replacement_function;                                         \
        const void *original_function;                                            \
    } interpose_##original __attribute__((section("__DATA,__interpose"))) = {     \
        (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original \
    }

static const char library_name[] = "/libparallexhome.dylib";
static char redirect_home[PATH_MAX];
static bool active = false;
static bool redirect_env = false;
// For handing your real $HOME back to what the app starts (see below).
static char real_home_entry[PATH_MAX + 8];
static char scope_path[PATH_MAX];
static char keychain_suffix[128];
// "\n"-separated "… Safe Storage" names left alone (other browsers' keys).
static char keychain_keep[1024];
static char instance_keychain_path[PATH_MAX];
// Guard's list, as given (see recorder.c).
static char *guarded_paths = NULL;
static char loopback_ports[128];
// "Safe Storage" keys go to the copy's own keychain as well (copies made
// with it), instead of being renamed in the login keychain.
static bool safe_storage_own = false;

static bool has_suffix(const char *text, size_t length, const char *suffix) {
    size_t suffix_length = strlen(suffix);
    return length >= suffix_length && memcmp(text + length - suffix_length, suffix, suffix_length) == 0;
}

// Take this library and its variables out of the environment, so processes
// started from here don't load it.
static void leave_environment(void) {
    const char *inserted = getenv("DYLD_INSERT_LIBRARIES");
    if (inserted != NULL) {
        size_t size = strlen(inserted) + 1;
        char *kept = malloc(size);
        if (kept != NULL) {
            kept[0] = '\0';
            const char *entry = inserted;
            while (*entry != '\0') {
                const char *end = strchr(entry, ':');
                size_t length = end ? (size_t)(end - entry) : strlen(entry);
                if (length > 0 && !has_suffix(entry, length, library_name)) {
                    if (kept[0] != '\0') {
                        strlcat(kept, ":", size);
                    }
                    strncat(kept, entry, length);
                }
                if (end == NULL) {
                    break;
                }
                entry = end + 1;
            }
            if (kept[0] == '\0') {
                unsetenv("DYLD_INSERT_LIBRARIES");
            } else {
                setenv("DYLD_INSERT_LIBRARIES", kept, 1);
            }
            free(kept);
        }
    }
    unsetenv("PARALLEX_HOME_REDIRECT");
    unsetenv("PARALLEX_HOME_SCOPE");
    unsetenv("PARALLEX_HOME_ENV");
    unsetenv("PARALLEX_KEYCHAIN_SUFFIX");
    unsetenv("PARALLEX_KEYCHAIN_KEEP");
    unsetenv("PARALLEX_INSTANCE_KEYCHAIN");
    unsetenv("PARALLEX_SAFE_STORAGE_OWN");
    unsetenv("PARALLEX_GUARD");
    unsetenv("PARALLEX_LOOPBACK_PORTS");
}

// Runs once, from the constructor (or earlier, if another part of the
// library asks first; see parallex_home_active).
static void set_up_now(void);

// 0: not yet, 1: under way (on some thread; a call from inside it, or from
// another thread meanwhile, sees the library as not active), 2: done.
static _Atomic int setup_state = 0;

static void set_up(void) {
    int expected = 0;
    if (atomic_compare_exchange_strong(&setup_state, &expected, 1)) {
        set_up_now();
        atomic_store(&setup_state, 2);
    }
}

bool parallex_home_settled(void) {
    set_up();
    return atomic_load(&setup_state) == 2;
}

static void set_up_now(void) {
    const char *home = getenv("PARALLEX_HOME_REDIRECT");
    const char *scope = getenv("PARALLEX_HOME_SCOPE");
    if (home == NULL || home[0] != '/' || strlen(home) >= sizeof(redirect_home)
        || scope == NULL || scope[0] != '/') {
        leave_environment();
        return;
    }
    char executable[PATH_MAX];
    uint32_t size = sizeof(executable);
    char resolved[PATH_MAX];
    char resolved_scope[PATH_MAX];
    if (_NSGetExecutablePath(executable, &size) != 0 || realpath(executable, resolved) == NULL
        || realpath(scope, resolved_scope) == NULL) {
        leave_environment();
        return;
    }
    size_t length = strlen(resolved_scope);
    if (strncmp(resolved, resolved_scope, length) != 0 || resolved[length] != '/') {
        leave_environment();
        return;
    }
    // The copy's launcher (the copy being reopened) sets everything up
    // again itself and must see the real home while it does.
    if (has_suffix(resolved, strlen(resolved), "/Contents/MacOS/parallex-launcher")) {
        return;
    }
    strlcpy(redirect_home, home, sizeof(redirect_home));
    strlcpy(scope_path, resolved_scope, sizeof(scope_path));
    const char *env = getenv("PARALLEX_HOME_ENV");
    redirect_env = env != NULL && strcmp(env, "1") == 0;
    const char *suffix = getenv("PARALLEX_KEYCHAIN_SUFFIX");
    if (suffix != NULL && suffix[0] != '\0' && strlen(suffix) < sizeof(keychain_suffix)) {
        strlcpy(keychain_suffix, suffix, sizeof(keychain_suffix));
        const char *keep = getenv("PARALLEX_KEYCHAIN_KEEP");
        if (keep != NULL && strlen(keep) + 2 < sizeof(keychain_keep)) {
            snprintf(keychain_keep, sizeof(keychain_keep), "\n%s\n", keep);
        }
    }
    const char *instance_keychain = getenv("PARALLEX_INSTANCE_KEYCHAIN");
    if (instance_keychain != NULL && instance_keychain[0] == '/') {
        strlcpy(instance_keychain_path, instance_keychain, sizeof(instance_keychain_path));
        const char *own = getenv("PARALLEX_SAFE_STORAGE_OWN");
        safe_storage_own = own != NULL && strcmp(own, "1") == 0;
    }
    const char *guarded = getenv("PARALLEX_GUARD");
    if (guarded != NULL && guarded[0] == '/') {
        guarded_paths = strdup(guarded);
    }
    const char *ports = getenv("PARALLEX_LOOPBACK_PORTS");
    if (ports != NULL && strlen(ports) < sizeof(loopback_ports)) {
        strlcpy(loopback_ports, ports, sizeof(loopback_ports));
    }
    // Calls from this library aren't interposed: this is the real account.
    struct passwd *account = getpwuid(getuid());
    if (account != NULL && account->pw_dir != NULL) {
        snprintf(real_home_entry, sizeof(real_home_entry), "HOME=%s", account->pw_dir);
    }
    active = true;
}

__attribute__((constructor)) static void parallex_home_init(void) {
    set_up();
}

bool parallex_home_active(void) {
    set_up();
    return active;
}

const char *parallex_home_redirect(void) {
    return parallex_home_active() ? redirect_home : NULL;
}

const char *parallex_home_real(void) {
    return parallex_home_active() && real_home_entry[0] != '\0' ? real_home_entry + 5 : NULL;
}

const char *parallex_home_scope(void) {
    return parallex_home_active() ? scope_path : NULL;
}

const char *parallex_home_guarded(void) {
    return parallex_home_active() ? guarded_paths : NULL;
}

const char *parallex_home_ports(void) {
    return parallex_home_active() && loopback_ports[0] != '\0' ? loopback_ports : NULL;
}

static void redirect(struct passwd *entry) {
    if (active && entry != NULL && entry->pw_uid == getuid()) {
        entry->pw_dir = redirect_home;
    }
}

static struct passwd *parallex_getpwuid(uid_t uid) {
    struct passwd *entry = getpwuid(uid);
    redirect(entry);
    return entry;
}

static struct passwd *parallex_getpwnam(const char *name) {
    struct passwd *entry = getpwnam(name);
    redirect(entry);
    return entry;
}

static int parallex_getpwuid_r(uid_t uid, struct passwd *storage, char *buffer, size_t size, struct passwd **result) {
    int status = getpwuid_r(uid, storage, buffer, size, result);
    if (status == 0 && result != NULL) {
        redirect(*result);
    }
    return status;
}

static int parallex_getpwnam_r(const char *name, struct passwd *storage, char *buffer, size_t size, struct passwd **result) {
    int status = getpwnam_r(name, storage, buffer, size, result);
    if (status == 0 && result != NULL) {
        redirect(*result);
    }
    return status;
}

// The environment itself is left alone, so what the app starts inherits
// your real $HOME. Apps that pass on what they read instead (Node builds a
// child's environment from getenv) get it put back below, for anything they
// start from outside the copy: your shell and tools see your own home.
static char *parallex_getenv(const char *name) {
    if (active && redirect_env && name != NULL && strcmp(name, "HOME") == 0) {
        return redirect_home;
    }
    return getenv(name);
}

static bool is_in_scope(const char *path) {
    if (path == NULL || strchr(path, '/') == NULL) {
        return false;
    }
    char resolved[PATH_MAX];
    if (realpath(path, resolved) == NULL) {
        return false;
    }
    size_t length = strlen(scope_path);
    return strncmp(resolved, scope_path, length) == 0 && resolved[length] == '/';
}

// A copy of `envp` with HOME=<instance home> replaced by your real one, or
// NULL when there's nothing to change. The caller frees it.
static char **with_real_home(char *const envp[]) {
    if (!active || !redirect_env || envp == NULL || real_home_entry[0] == '\0') {
        return NULL;
    }
    size_t count = 0;
    size_t home_index = (size_t)-1;
    for (; envp[count] != NULL; count++) {
        if (strncmp(envp[count], "HOME=", 5) == 0 && strcmp(envp[count] + 5, redirect_home) == 0) {
            home_index = count;
        }
    }
    if (home_index == (size_t)-1) {
        return NULL;
    }
    char **copy = malloc((count + 1) * sizeof(char *));
    if (copy == NULL) {
        return NULL;
    }
    for (size_t index = 0; index < count; index++) {
        copy[index] = index == home_index ? real_home_entry : envp[index];
    }
    copy[count] = NULL;
    return copy;
}

static int parallex_execve(const char *path, char *const argv[], char *const envp[]) {
    char **fixed = is_in_scope(path) ? NULL : with_real_home(envp);
    int result = execve(path, argv, fixed != NULL ? fixed : envp);
    free(fixed);
    return result;
}

static int parallex_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                                const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]) {
    char **fixed = is_in_scope(path) ? NULL : with_real_home(envp);
    int result = posix_spawn(pid, path, actions, attributes, argv, fixed != NULL ? fixed : envp);
    free(fixed);
    return result;
}

static int parallex_posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *actions,
                                 const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]) {
    char **fixed = is_in_scope(file) ? NULL : with_real_home(envp);
    int result = posix_spawnp(pid, file, actions, attributes, argv, fixed != NULL ? fixed : envp);
    free(fixed);
    return result;
}

// MARK: Keychain
//
// Two things happen to what a copy keeps in the keychain:
// - "<App> Safe Storage" (the key Electron and Chromium apps encrypt their
//   data with) stays in your login keychain under a name of the copy's own
//   (PARALLEX_KEYCHAIN_SUFFIX), as it has since 0.13, so existing copies
//   keep reading their data.
// - Every other password item goes to the copy's own keychain file
//   (PARALLEX_INSTANCE_KEYCHAIN), so the copy never finds, or overwrites, the
//   original's sign-ins. Requests for the data protection keychain, which a
//   re-signed copy isn't entitled to, go there too. New items trust every
//   executable in the copy, as the app's access group would have.
// Certificates, identities and keys pass through untouched.

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static const char safe_storage[] = " Safe Storage";

static bool renames_keychain(void) {
    return active && keychain_suffix[0] != '\0';
}

// Whether `name` (length bytes) is on the list of names left alone.
static bool is_kept(const char *name, size_t length) {
    if (keychain_keep[0] == '\0' || length + 3 > sizeof(keychain_keep)) {
        return false;
    }
    char needle[sizeof(keychain_keep)];
    needle[0] = '\n';
    memcpy(needle + 1, name, length);
    needle[length + 1] = '\n';
    needle[length + 2] = '\0';
    return strstr(keychain_keep, needle) != NULL;
}

static bool is_safe_storage(UInt32 length, const char *name) {
    size_t tail = sizeof(safe_storage) - 1;
    return name != NULL && length >= tail && memcmp(name + length - tail, safe_storage, tail) == 0;
}

// "<App> Safe Storage" → "<App> Safe Storage<suffix>", for the legacy API
// (the name isn't NUL-terminated there). NULL when it stays as it is; the
// caller frees it. A copy whose key lives in its own keychain renames it
// only where the app names a keychain itself (it may name yours).
static char *renamed_service(UInt32 length, const char *name, bool names_keychain) {
    if ((safe_storage_own && !names_keychain) || !renames_keychain() || !is_safe_storage(length, name)
        || is_kept(name, length)) {
        return NULL;
    }
    size_t size = length + strlen(keychain_suffix) + 1;
    char *renamed = malloc(size);
    if (renamed != NULL) {
        memcpy(renamed, name, length);
        strlcpy(renamed + length, keychain_suffix, size - length);
    }
    return renamed;
}

// The copy's own keychain, opened on first use (Security can't be used from
// the library's constructor), with the access new items get.
static SecKeychainRef instance_keychain;
static SecAccessRef instance_access;

static bool expects_own_keychain(void) {
    return active && instance_keychain_path[0] != '\0';
}

static void open_instance_keychain(void) {
    SecKeychainRef keychain = NULL;
    if (SecKeychainOpen(instance_keychain_path, &keychain) != errSecSuccess) {
        return;
    }
    // Every executable in the copy (the app, its helpers and services).
    CFMutableArrayRef trusted = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    char *roots[] = { scope_path, NULL };
    FTS *walk = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    for (FTSENT *entry; walk != NULL && (entry = fts_read(walk)) != NULL;) {
        if (entry->fts_info == FTS_F && (entry->fts_statp->st_mode & S_IXUSR) && strstr(entry->fts_path, "/MacOS/") != NULL) {
            SecTrustedApplicationRef application = NULL;
            if (SecTrustedApplicationCreateFromPath(entry->fts_path, &application) == errSecSuccess) {
                CFArrayAppendValue(trusted, application);
                CFRelease(application);
            }
        }
    }
    if (walk != NULL) fts_close(walk);
    SecAccessRef access = NULL;
    if (CFArrayGetCount(trusted) > 0) {
        SecAccessCreate(CFSTR("Parallex instance item"), trusted, &access);
    }
    CFRelease(trusted);
    instance_access = access;
    instance_keychain = keychain;
}

// The copy's own keychain when it's open (unlocked); NULL when the copy has
// none, or it isn't open right now (see `expects_own_keychain`: then the
// copy's items are refused rather than looked for in your keychain).
static SecKeychainRef own_keychain(void) {
    if (!expects_own_keychain()) {
        return NULL;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{ open_instance_keychain(); });
    SecKeychainStatus status = 0;
    if (instance_keychain == NULL || SecKeychainGetStatus(instance_keychain, &status) != errSecSuccess
        || !(status & kSecUnlockStateStatus)) {
        return NULL;
    }
    return instance_keychain;
}

static void copy_entry(const void *key, const void *value, void *into) {
    CFDictionarySetValue((CFMutableDictionaryRef)into, key, value);
}

// A SecItem query or attribute dictionary, as the copy should send it. NULL
// when it stays as it is; the caller releases it. (A fresh dictionary with
// CF's retaining callbacks, whatever the caller built theirs with.)
// `refuse` is set when the item belongs in the copy's own keychain and that
// isn't open: better an error than the original's item.
static CFDictionaryRef translated(CFDictionaryRef query, bool adding, bool *refuse) {
    if (!active || query == NULL) {
        return NULL;
    }
    // (A request without a class goes through as it is: macOS refuses it
    // with errSecParam before it reaches any keychain.)
    CFTypeRef kind = CFDictionaryGetValue(query, kSecClass);
    CFTypeRef service = CFDictionaryGetValue(query, kSecAttrService);
    bool generic = kind == NULL || CFEqual(kind, kSecClassGenericPassword);
    bool password = generic || CFEqual(kind, kSecClassInternetPassword);
    if (!password) {
        return NULL;
    }
    // Proxy passwords are the Mac's, not the app's (the system's network
    // code looks them up in-process): they stay where they are.
    if (!generic) {
        CFTypeRef protocol = CFDictionaryGetValue(query, kSecAttrProtocol);
        if (protocol != NULL && (CFEqual(protocol, kSecAttrProtocolHTTPProxy) || CFEqual(protocol, kSecAttrProtocolHTTPSProxy)
                                 || CFEqual(protocol, kSecAttrProtocolSOCKS) || CFEqual(protocol, kSecAttrProtocolFTPProxy))) {
            return NULL;
        }
    }
    bool safe_storage_item = generic && service != NULL && CFGetTypeID(service) == CFStringGetTypeID()
        && CFStringHasSuffix((CFStringRef)service, CFSTR(" Safe Storage"));
    bool names_keychain = CFDictionaryContainsKey(query, kSecUseKeychain) || CFDictionaryContainsKey(query, kSecMatchSearchList);
    if (safe_storage_item && safe_storage_own && !names_keychain) {
        // Its own key in its own keychain, unless it's another app's (a
        // browser copy importing from Chrome reads Chrome's).
        char current[512];
        if (CFStringGetCString((CFStringRef)service, current, sizeof(current), kCFStringEncodingUTF8)
            && is_kept(current, strlen(current))) {
            return NULL;
        }
    } else if (safe_storage_item) {
        char current[512];
        if (!renames_keychain() || !CFStringGetCString((CFStringRef)service, current, sizeof(current), kCFStringEncodingUTF8)
            || is_kept(current, strlen(current))) {
            return NULL;
        }
        CFMutableDictionaryRef renamed = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                   &kCFTypeDictionaryValueCallBacks);
        CFStringRef name = CFStringCreateWithFormat(NULL, NULL, CFSTR("%s%s"), current, keychain_suffix);
        if (renamed == NULL || name == NULL) {
            if (renamed != NULL) CFRelease(renamed);
            if (name != NULL) CFRelease(name);
            return NULL;
        }
        CFDictionaryApplyFunction(query, copy_entry, renamed);
        CFDictionarySetValue(renamed, kSecAttrService, name);
        CFRelease(name);
        return renamed;
    }
    // An app that names its keychain (one of its own, say) means it.
    if (CFDictionaryContainsKey(query, kSecUseKeychain) || CFDictionaryContainsKey(query, kSecMatchSearchList)) {
        return NULL;
    }
    SecKeychainRef own = kind != NULL ? own_keychain() : NULL;
    if (own == NULL) {
        if (kind != NULL && expects_own_keychain() && refuse != NULL) {
            *refuse = true;
        }
        return NULL;
    }
    CFMutableDictionaryRef moved = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                             &kCFTypeDictionaryValueCallBacks);
    if (moved == NULL) {
        return NULL;
    }
    CFDictionaryApplyFunction(query, copy_entry, moved);
    CFDictionaryRemoveValue(moved, kSecUseDataProtectionKeychain);
    CFDictionaryRemoveValue(moved, kSecAttrAccessGroup);
    CFDictionaryRemoveValue(moved, kSecAttrSynchronizable);
    if (adding) {
        CFDictionarySetValue(moved, kSecUseKeychain, own);
        if (instance_access != NULL && !CFDictionaryContainsKey(query, kSecAttrAccess)) {
            CFDictionarySetValue(moved, kSecAttrAccess, instance_access);
        }
    } else {
        CFArrayRef list = CFArrayCreate(NULL, (const void **)&own, 1, &kCFTypeArrayCallBacks);
        CFDictionarySetValue(moved, kSecMatchSearchList, list);
        CFRelease(list);
    }
    return moved;
}

// Only attributes change in an update: never where the item lives.
static CFDictionaryRef translated_changes(CFDictionaryRef changes) {
    if (!renames_keychain() || changes == NULL) {
        return NULL;
    }
    CFTypeRef service = CFDictionaryGetValue(changes, kSecAttrService);
    if (service == NULL || CFGetTypeID(service) != CFStringGetTypeID()
        || !CFStringHasSuffix((CFStringRef)service, CFSTR(" Safe Storage"))) {
        return NULL;
    }
    return translated(changes, true, NULL);
}

// The legacy API: "no keychain" means the default ones. For the copy's
// password items that's its own keychain. Returns false (refuse) when that
// keychain is expected but isn't open.
static bool legacy_where(CFTypeRef requested, UInt32 service_length, const char *service, CFTypeRef *where) {
    *where = requested;
    if (requested != NULL || !active) {
        return true;
    }
    if (is_safe_storage(service_length, service) && (!safe_storage_own || is_kept(service, service_length))) {
        return true;
    }
    SecKeychainRef own = own_keychain();
    if (own == NULL) {
        return !expects_own_keychain();
    }
    *where = own;
    return true;
}

// Items made through the legacy API trust the whole copy too.
static void share_with_copy(SecKeychainItemRef item) {
    if (item != NULL && instance_access != NULL) {
        SecKeychainItemSetAccess(item, instance_access);
    }
}

static OSStatus parallex_find_generic(CFTypeRef keychains, UInt32 service_length, const char *service,
                                      UInt32 account_length, const char *account, UInt32 *password_length,
                                      void **password, SecKeychainItemRef *item) {
    CFTypeRef where = NULL;
    if (!legacy_where(keychains, service_length, service, &where)) {
        return errSecNotAvailable;
    }
    char *renamed = renamed_service(service_length, service, keychains != NULL);
    OSStatus status = renamed != NULL
        ? SecKeychainFindGenericPassword(where, (UInt32)strlen(renamed), renamed, account_length, account,
                                         password_length, password, item)
        : SecKeychainFindGenericPassword(where, service_length, service, account_length, account,
                                         password_length, password, item);
    free(renamed);
    return status;
}

static OSStatus parallex_add_generic(SecKeychainRef keychain, UInt32 service_length, const char *service,
                                     UInt32 account_length, const char *account, UInt32 password_length,
                                     const void *password, SecKeychainItemRef *item) {
    CFTypeRef found = NULL;
    if (!legacy_where(keychain, service_length, service, &found)) {
        return errSecNotAvailable;
    }
    SecKeychainRef where = (SecKeychainRef)found;
    char *renamed = renamed_service(service_length, service, keychain != NULL);
    SecKeychainItemRef made = NULL;
    OSStatus status = renamed != NULL
        ? SecKeychainAddGenericPassword(where, (UInt32)strlen(renamed), renamed, account_length, account,
                                        password_length, password, &made)
        : SecKeychainAddGenericPassword(where, service_length, service, account_length, account,
                                        password_length, password, &made);
    free(renamed);
    if (status == errSecSuccess && where != keychain) {
        share_with_copy(made);
    }
    if (item != NULL) {
        *item = made;
    } else if (made != NULL) {
        CFRelease(made);
    }
    return status;
}

static bool is_proxy(SecProtocolType protocol) {
    return protocol == kSecProtocolTypeHTTPProxy || protocol == kSecProtocolTypeHTTPSProxy
        || protocol == kSecProtocolTypeSOCKS || protocol == kSecProtocolTypeFTPProxy;
}

static OSStatus parallex_find_internet(CFTypeRef keychains, UInt32 server_length, const char *server,
                                       UInt32 domain_length, const char *domain, UInt32 account_length,
                                       const char *account, UInt32 path_length, const char *path, UInt16 port,
                                       SecProtocolType protocol, SecAuthenticationType authentication,
                                       UInt32 *password_length, void **password, SecKeychainItemRef *item) {
    CFTypeRef where = keychains;
    if (!is_proxy(protocol) && !legacy_where(keychains, 0, NULL, &where)) {
        return errSecNotAvailable;
    }
    return SecKeychainFindInternetPassword(where, server_length, server, domain_length,
                                           domain, account_length, account, path_length, path, port, protocol,
                                           authentication, password_length, password, item);
}

static OSStatus parallex_add_internet(SecKeychainRef keychain, UInt32 server_length, const char *server,
                                      UInt32 domain_length, const char *domain, UInt32 account_length,
                                      const char *account, UInt32 path_length, const char *path, UInt16 port,
                                      SecProtocolType protocol, SecAuthenticationType authentication,
                                      UInt32 password_length, const void *password, SecKeychainItemRef *item) {
    CFTypeRef found = keychain;
    if (!is_proxy(protocol) && !legacy_where(keychain, 0, NULL, &found)) {
        return errSecNotAvailable;
    }
    SecKeychainRef where = (SecKeychainRef)found;
    SecKeychainItemRef made = NULL;
    OSStatus status = SecKeychainAddInternetPassword(where, server_length, server, domain_length, domain,
                                                     account_length, account, path_length, path, port, protocol,
                                                     authentication, password_length, password, &made);
    if (status == errSecSuccess && where != keychain) {
        share_with_copy(made);
    }
    if (item != NULL) {
        *item = made;
    } else if (made != NULL) {
        CFRelease(made);
    }
    return status;
}
#pragma clang diagnostic pop

static OSStatus parallex_item_copy(CFDictionaryRef query, CFTypeRef *result) {
    bool refuse = false;
    CFDictionaryRef moved = translated(query, false, &refuse);
    if (refuse) return errSecNotAvailable;
    OSStatus status = SecItemCopyMatching(moved != NULL ? moved : query, result);
    if (moved != NULL) CFRelease(moved);
    return status;
}

static OSStatus parallex_item_add(CFDictionaryRef attributes, CFTypeRef *result) {
    bool refuse = false;
    CFDictionaryRef moved = translated(attributes, true, &refuse);
    if (refuse) return errSecNotAvailable;
    OSStatus status = SecItemAdd(moved != NULL ? moved : attributes, result);
    if (moved != NULL) CFRelease(moved);
    return status;
}

static OSStatus parallex_item_update(CFDictionaryRef query, CFDictionaryRef changes) {
    bool refuse = false;
    CFDictionaryRef moved = translated(query, false, &refuse);
    if (refuse) return errSecNotAvailable;
    CFDictionaryRef moved_changes = translated_changes(changes);
    OSStatus status = SecItemUpdate(moved != NULL ? moved : query, moved_changes != NULL ? moved_changes : changes);
    if (moved != NULL) CFRelease(moved);
    if (moved_changes != NULL) CFRelease(moved_changes);
    return status;
}

static OSStatus parallex_item_delete(CFDictionaryRef query) {
    bool refuse = false;
    CFDictionaryRef moved = translated(query, false, &refuse);
    if (refuse) return errSecNotAvailable;
    OSStatus status = SecItemDelete(moved != NULL ? moved : query);
    if (moved != NULL) CFRelease(moved);
    return status;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
INTERPOSE(parallex_find_generic, SecKeychainFindGenericPassword);
INTERPOSE(parallex_add_generic, SecKeychainAddGenericPassword);
INTERPOSE(parallex_find_internet, SecKeychainFindInternetPassword);
INTERPOSE(parallex_add_internet, SecKeychainAddInternetPassword);
#pragma clang diagnostic pop
INTERPOSE(parallex_item_copy, SecItemCopyMatching);
INTERPOSE(parallex_item_add, SecItemAdd);
INTERPOSE(parallex_item_update, SecItemUpdate);
INTERPOSE(parallex_item_delete, SecItemDelete);

INTERPOSE(parallex_getenv, getenv);
INTERPOSE(parallex_execve, execve);
INTERPOSE(parallex_posix_spawn, posix_spawn);
INTERPOSE(parallex_posix_spawnp, posix_spawnp);
INTERPOSE(parallex_getpwuid, getpwuid);
INTERPOSE(parallex_getpwnam, getpwnam);
INTERPOSE(parallex_getpwuid_r, getpwuid_r);
INTERPOSE(parallex_getpwnam_r, getpwnam_r);
