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
//   PARALLEX_HOME_ENV       "1": also answer getenv("HOME") with the
//                           instance's home (apps built on Node, Chromium
//                           or Rust find "~" through $HOME, not the account)
// Only processes whose executable lives inside the scope are redirected
// (the app, its helpers and services). Any other process that inherits this
// library — a shell or tool the app started — takes it and the variables
// out of its environment, so its own children never see them. Without both
// variables the library does nothing.

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pwd.h>
#include <spawn.h>
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
}

__attribute__((constructor)) static void parallex_home_init(void) {
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
    // Calls from this library aren't interposed: this is the real account.
    struct passwd *account = getpwuid(getuid());
    if (account != NULL && account->pw_dir != NULL) {
        snprintf(real_home_entry, sizeof(real_home_entry), "HOME=%s", account->pw_dir);
    }
    active = true;
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

// "<App> Safe Storage" → "<App> Safe Storage<suffix>", for the legacy API
// (the name isn't NUL-terminated there). NULL when it stays as it is; the
// caller frees it.
static char *renamed_service(UInt32 length, const char *name) {
    size_t tail = sizeof(safe_storage) - 1;
    if (!renames_keychain() || name == NULL || length < tail || memcmp(name + length - tail, safe_storage, tail) != 0
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

static void copy_entry(const void *key, const void *value, void *into) {
    CFDictionarySetValue((CFMutableDictionaryRef)into, key, value);
}

// The same for a SecItem query or attribute dictionary. NULL when it stays
// as it is; the caller releases it. (A fresh dictionary with CF's retaining
// callbacks, whatever the caller built theirs with.)
static CFDictionaryRef renamed_query(CFDictionaryRef query) {
    if (!renames_keychain() || query == NULL) {
        return NULL;
    }
    CFTypeRef kind = CFDictionaryGetValue(query, kSecClass);
    CFTypeRef service = CFDictionaryGetValue(query, kSecAttrService);
    if ((kind != NULL && !CFEqual(kind, kSecClassGenericPassword)) || service == NULL
        || CFGetTypeID(service) != CFStringGetTypeID()
        || !CFStringHasSuffix((CFStringRef)service, CFSTR(" Safe Storage"))) {
        return NULL;
    }
    char current[512];
    if (!CFStringGetCString((CFStringRef)service, current, sizeof(current), kCFStringEncodingUTF8)
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

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static OSStatus parallex_find_generic(CFTypeRef keychains, UInt32 service_length, const char *service,
                                      UInt32 account_length, const char *account, UInt32 *password_length,
                                      void **password, SecKeychainItemRef *item) {
    char *renamed = renamed_service(service_length, service);
    OSStatus status = renamed != NULL
        ? SecKeychainFindGenericPassword(keychains, (UInt32)strlen(renamed), renamed, account_length, account,
                                         password_length, password, item)
        : SecKeychainFindGenericPassword(keychains, service_length, service, account_length, account,
                                         password_length, password, item);
    free(renamed);
    return status;
}

static OSStatus parallex_add_generic(SecKeychainRef keychain, UInt32 service_length, const char *service,
                                     UInt32 account_length, const char *account, UInt32 password_length,
                                     const void *password, SecKeychainItemRef *item) {
    char *renamed = renamed_service(service_length, service);
    OSStatus status = renamed != NULL
        ? SecKeychainAddGenericPassword(keychain, (UInt32)strlen(renamed), renamed, account_length, account,
                                        password_length, password, item)
        : SecKeychainAddGenericPassword(keychain, service_length, service, account_length, account,
                                        password_length, password, item);
    free(renamed);
    return status;
}
#pragma clang diagnostic pop

static OSStatus parallex_item_copy(CFDictionaryRef query, CFTypeRef *result) {
    CFDictionaryRef renamed = renamed_query(query);
    OSStatus status = SecItemCopyMatching(renamed != NULL ? renamed : query, result);
    if (renamed != NULL) CFRelease(renamed);
    return status;
}

static OSStatus parallex_item_add(CFDictionaryRef attributes, CFTypeRef *result) {
    CFDictionaryRef renamed = renamed_query(attributes);
    OSStatus status = SecItemAdd(renamed != NULL ? renamed : attributes, result);
    if (renamed != NULL) CFRelease(renamed);
    return status;
}

static OSStatus parallex_item_update(CFDictionaryRef query, CFDictionaryRef changes) {
    CFDictionaryRef renamed = renamed_query(query);
    CFDictionaryRef renamed_changes = renamed_query(changes);
    OSStatus status = SecItemUpdate(renamed != NULL ? renamed : query,
                                    renamed_changes != NULL ? renamed_changes : changes);
    if (renamed != NULL) CFRelease(renamed);
    if (renamed_changes != NULL) CFRelease(renamed_changes);
    return status;
}

static OSStatus parallex_item_delete(CFDictionaryRef query) {
    CFDictionaryRef renamed = renamed_query(query);
    OSStatus status = SecItemDelete(renamed != NULL ? renamed : query);
    if (renamed != NULL) CFRelease(renamed);
    return status;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
INTERPOSE(parallex_find_generic, SecKeychainFindGenericPassword);
INTERPOSE(parallex_add_generic, SecKeychainAddGenericPassword);
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
