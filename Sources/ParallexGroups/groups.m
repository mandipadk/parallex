// Parallex app-group mapping.
//
// Sandboxed apps keep shared data — often their sign-in and database — in
// app-group containers (~/Library/Group Containers/<group>), keyed by group
// identifier rather than by app. An own-identity copy is entitled to renamed
// groups of its own; this library, loaded into the copy, translates the
// app's requests for its original groups to those, so the copy never opens
// the original's containers.
//
//   PARALLEX_GROUP_MAP    "original=renamed;original=renamed;…"
//   PARALLEX_SERVICE_MAP  the same for the copy's nested XPC services,
//                         which carry identifiers of their own, so the app's
//                         connections to them reach the copy's services
//
// The sandbox only allows Mach service, semaphore, shared-memory and message
// port names that start with one of the app's groups, so names built from an
// original group are rewritten to the copy's group too.
//
// Without them the library does nothing.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <spawn.h>
#import <os/lock.h>
#import <servers/bootstrap.h>
#import <semaphore.h>
#import <stdarg.h>
#import <sys/mman.h>
#import <xpc/xpc.h>

#import "ParallexGroups.h"

static NSDictionary<NSString *, NSString *> *groupMap;
static NSDictionary<NSString *, NSString *> *serviceMap;

static NSDictionary *parseMap(const char *value) {
    if (value == NULL || value[0] == '\0') {
        return nil;
    }
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSString *pair in [[NSString stringWithUTF8String:value] componentsSeparatedByString:@";"]) {
        NSArray<NSString *> *parts = [pair componentsSeparatedByString:@"="];
        if (parts.count == 2 && parts[0].length > 0 && parts[1].length > 0) {
            map[parts[0]] = parts[1];
        }
    }
    return map.count > 0 ? [map copy] : nil;
}

// Connections to embedded XPC services (NSXPCConnection's service name
// ends up here too). Returns a retained connection, like the original —
// without the annotation ARC would balance it with an extra release.
static xpc_connection_t parallex_xpc_connection_create(const char *name, dispatch_queue_t queue)
    __attribute__((ns_returns_retained));

static xpc_connection_t parallex_xpc_connection_create(const char *name, dispatch_queue_t queue) {
    if (name != NULL && serviceMap != nil) {
        NSString *renamed = serviceMap[[NSString stringWithUTF8String:name]];
        if (renamed != nil) {
            return xpc_connection_create(renamed.UTF8String, queue);
        }
    }
    return xpc_connection_create(name, queue);
}

__attribute__((used)) static const struct {
    const void *replacement;
    const void *original;
} interpose_xpc_connection_create __attribute__((section("__DATA,__interpose"))) = {
    (const void *)(unsigned long)&parallex_xpc_connection_create,
    (const void *)(unsigned long)&xpc_connection_create,
};

static NSString *mapped(NSString *identifier) {
    if (identifier == nil) {
        return nil;
    }
    NSString *renamed = groupMap[identifier];
    return renamed ?: identifier;
}

static IMP originalContainerURL;
static IMP originalInitWithSuiteName;

static NSURL *parallex_containerURL(id self, SEL _cmd, NSString *identifier) {
    return ((NSURL * (*)(id, SEL, NSString *))originalContainerURL)(self, _cmd, mapped(identifier));
}

static id parallex_initWithSuiteName(id self, SEL _cmd, NSString *suite) {
    return ((id (*)(id, SEL, NSString *))originalInitWithSuiteName)(self, _cmd, mapped(suite));
}

#define PARALLEX_INTERPOSE(replacement, original)                                       \
    __attribute__((used)) static const struct {                                        \
        const void *replacement_function;                                              \
        const void *original_function;                                                 \
    } interpose_##original __attribute__((section("__DATA,__interpose"))) = {          \
        (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original \
    }

/// A name that starts with one of the original groups, rewritten to start
/// with the copy's group instead; nil when there's nothing to rewrite.
static NSString *rewrittenName(NSString *name) {
    if (name == nil || groupMap == nil) {
        return nil;
    }
    for (NSString *original in groupMap) {
        if ([name hasPrefix:original]) {
            return [groupMap[original] stringByAppendingString:[name substringFromIndex:original.length]];
        }
    }
    return nil;
}

// Rewritten names, made once each: the result must outlive the call (the
// caller keeps the pointer), and these lookups run often (every connection,
// semaphore and port), so they're kept for the life of the process. The
// names an app uses are few; past a sane number they're made per call.
static os_unfair_lock cacheLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, id> *cache;
static const NSUInteger cacheLimit = 512;

// NULL when the name isn't rewritten.
static const char *rewrittenCName(const char *name) {
    // Some of these run during process start-up, before Objective-C is
    // ready: touch nothing until there's a map (set by our constructor).
    if (name == NULL || groupMap == nil) {
        return NULL;
    }
    NSString *key = [NSString stringWithUTF8String:name];
    if (key == nil) {
        return NULL;
    }
    os_unfair_lock_lock(&cacheLock);
    id cached = cache[key];
    os_unfair_lock_unlock(&cacheLock);
    if (cached != nil) {
        return cached == [NSNull null] ? NULL : (const char *)[(NSValue *)cached pointerValue];
    }
    NSString *rewritten = rewrittenName(key);
    const char *result = rewritten != nil ? strdup(rewritten.UTF8String) : NULL;
    os_unfair_lock_lock(&cacheLock);
    id existing = cache[key];
    if (existing == nil && cache.count < cacheLimit) {
        cache[key] = result != NULL ? [NSValue valueWithPointer:result] : [NSNull null];
    }
    os_unfair_lock_unlock(&cacheLock);
    if (existing != nil) {
        // Another thread made it first; use that one.
        free((void *)result);
        return existing == [NSNull null] ? NULL : (const char *)[(NSValue *)existing pointerValue];
    }
    return result;
}

static xpc_connection_t parallex_xpc_connection_create_mach_service(const char *name, dispatch_queue_t queue, uint64_t flags)
    __attribute__((ns_returns_retained));

static xpc_connection_t parallex_xpc_connection_create_mach_service(const char *name, dispatch_queue_t queue, uint64_t flags) {
    const char *rewritten = rewrittenCName(name);
    return xpc_connection_create_mach_service(rewritten ?: name, queue, flags);
}
PARALLEX_INTERPOSE(parallex_xpc_connection_create_mach_service, xpc_connection_create_mach_service);

static kern_return_t parallex_bootstrap_look_up(mach_port_t port, const name_t name, mach_port_t *service) {
    const char *rewritten = rewrittenCName(name);
    return bootstrap_look_up(port, rewritten ?: name, service);
}
PARALLEX_INTERPOSE(parallex_bootstrap_look_up, bootstrap_look_up);

static kern_return_t parallex_bootstrap_check_in(mach_port_t port, const name_t name, mach_port_t *service) {
    const char *rewritten = rewrittenCName(name);
    return bootstrap_check_in(port, rewritten ?: name, service);
}
PARALLEX_INTERPOSE(parallex_bootstrap_check_in, bootstrap_check_in);

static sem_t *parallex_sem_open(const char *name, int flags, ...) {
    const char *rewritten = rewrittenCName(name);
    if (flags & O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        int mode = va_arg(arguments, int);
        unsigned int value = va_arg(arguments, unsigned int);
        va_end(arguments);
        return sem_open(rewritten ?: name, flags, mode, value);
    }
    return sem_open(rewritten ?: name, flags);
}
PARALLEX_INTERPOSE(parallex_sem_open, sem_open);

static int parallex_shm_open(const char *name, int flags, ...) {
    const char *rewritten = rewrittenCName(name);
    if (flags & O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        int mode = va_arg(arguments, int);
        va_end(arguments);
        return shm_open(rewritten ?: name, flags, mode);
    }
    return shm_open(rewritten ?: name, flags);
}
PARALLEX_INTERPOSE(parallex_shm_open, shm_open);

static CFMessagePortRef parallex_CFMessagePortCreateLocal(CFAllocatorRef allocator, CFStringRef name,
                                                          CFMessagePortCallBack callout, CFMessagePortContext *context,
                                                          Boolean *shouldFree) {
    NSString *rewritten = groupMap != nil ? rewrittenName((__bridge NSString *)name) : nil;
    return CFMessagePortCreateLocal(allocator, rewritten ? (__bridge CFStringRef)rewritten : name, callout, context, shouldFree);
}
PARALLEX_INTERPOSE(parallex_CFMessagePortCreateLocal, CFMessagePortCreateLocal);

static CFMessagePortRef parallex_CFMessagePortCreateRemote(CFAllocatorRef allocator, CFStringRef name) {
    NSString *rewritten = groupMap != nil ? rewrittenName((__bridge NSString *)name) : nil;
    return CFMessagePortCreateRemote(allocator, rewritten ? (__bridge CFStringRef)rewritten : name);
}
PARALLEX_INTERPOSE(parallex_CFMessagePortCreateRemote, CFMessagePortCreateRemote);

// MARK: Processes the copy starts
//
// Tools it starts from outside the copy (/usr/bin/profiles, a shell) start
// without this library: most of macOS's own ignore inserted libraries
// anyway, but one that doesn't fails to load it (built for arm64; theirs
// are arm64e) and aborts. Its maps are left as they are (without the
// library they do nothing). The copy's own helpers, inside its bundle, keep
// everything.

// "<copy>.app/", from where this library was loaded; empty when that isn't
// a copy's Frameworks folder, and then nothing is changed.
static char bundlePrefix[PATH_MAX];

static void findBundle(void) {
    Dl_info info;
    char resolved[PATH_MAX];
    if (dladdr((const void *)&findBundle, &info) == 0 || info.dli_fname == NULL
        || realpath(info.dli_fname, resolved) == NULL) {
        return;
    }
    const char *suffix = "Contents/Frameworks/libparallexgroups.dylib";
    size_t length = strlen(resolved), suffixLength = strlen(suffix);
    if (length <= suffixLength || strcmp(resolved + length - suffixLength, suffix) != 0
        || resolved[length - suffixLength - 1] != '/') {
        return;
    }
    resolved[length - suffixLength] = '\0';
    strlcpy(bundlePrefix, resolved, sizeof(bundlePrefix));
}

// Whether `file` (a path, relative ones too, or with `search` a bare name
// looked up in PATH as posix_spawnp does) is inside the copy.
static bool insideCopy(const char *file, bool search) {
    if (bundlePrefix[0] == '\0') {
        return true;
    }
    if (file == NULL || file[0] == '\0') {
        return false;
    }
    char resolved[PATH_MAX];
    bool found = false;
    if (strchr(file, '/') != NULL || !search) {
        found = realpath(file, resolved) != NULL;
    } else {
        const char *path = getenv("PATH") ?: "/usr/bin:/bin";
        char candidate[PATH_MAX];
        while (!found && *path != '\0') {
            const char *end = strchr(path, ':');
            size_t length = end ? (size_t)(end - path) : strlen(path);
            if (length > 0 && length + 1 + strlen(file) < sizeof(candidate)) {
                memcpy(candidate, path, length);
                candidate[length] = '/';
                strlcpy(candidate + length + 1, file, sizeof(candidate) - length - 1);
                found = access(candidate, X_OK) == 0 && realpath(candidate, resolved) != NULL;
            }
            if (end == NULL) {
                break;
            }
            path = end + 1;
        }
    }
    return found && strncmp(resolved, bundlePrefix, strlen(bundlePrefix)) == 0;
}

static bool isThisLibrary(const char *entry, size_t length) {
    const char *name = "/libparallexgroups.dylib";
    size_t nameLength = strlen(name);
    return length >= nameLength && memcmp(entry + length - nameLength, name, nameLength) == 0;
}

// A copy of `envp` without this library in DYLD_INSERT_LIBRARIES, or NULL
// when it isn't there. `inserted` gets the rebuilt DYLD_INSERT_LIBRARIES
// (if any); the caller frees both.
static char **withoutLibrary(char *const envp[], char **inserted) {
    *inserted = NULL;
    if (envp == NULL) {
        return NULL;
    }
    size_t count = 0;
    bool found = false;
    for (; envp[count] != NULL; count++) {
        if (strncmp(envp[count], "DYLD_INSERT_LIBRARIES=", 22) == 0 && strstr(envp[count], "/libparallexgroups.dylib") != NULL) {
            found = true;
        }
    }
    if (!found) {
        return NULL;
    }
    char **copy = malloc((count + 1) * sizeof(char *));
    if (copy == NULL) {
        return NULL;
    }
    size_t kept = 0;
    for (size_t index = 0; index < count; index++) {
        const char *entry = envp[index];
        if (strncmp(entry, "DYLD_INSERT_LIBRARIES=", 22) == 0 && *inserted == NULL) {
            const char *list = entry + 22;
            size_t size = strlen(entry) + 1;
            char *rebuilt = malloc(size);
            if (rebuilt == NULL) {
                free(copy);
                return NULL;
            }
            strlcpy(rebuilt, "DYLD_INSERT_LIBRARIES=", size);
            bool any = false;
            while (*list != '\0') {
                const char *end = strchr(list, ':');
                size_t length = end ? (size_t)(end - list) : strlen(list);
                if (length > 0 && !isThisLibrary(list, length)) {
                    if (any) {
                        strlcat(rebuilt, ":", size);
                    }
                    strncat(rebuilt, list, length);
                    any = true;
                }
                if (end == NULL) {
                    break;
                }
                list = end + 1;
            }
            if (!any) {
                free(rebuilt);
                continue;
            }
            *inserted = rebuilt;
            copy[kept++] = rebuilt;
            continue;
        }
        copy[kept++] = (char *)entry;
    }
    copy[kept] = NULL;
    return copy;
}

static int parallex_execve(const char *path, char *const argv[], char *const envp[]) {
    char *inserted = NULL;
    char **fixed = insideCopy(path, false) ? NULL : withoutLibrary(envp, &inserted);
    int result = execve(path, argv, fixed != NULL ? fixed : envp);
    free(fixed);
    free(inserted);
    return result;
}
PARALLEX_INTERPOSE(parallex_execve, execve);

static int parallex_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                                const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]) {
    char *inserted = NULL;
    char **fixed = insideCopy(path, false) ? NULL : withoutLibrary(envp, &inserted);
    int result = posix_spawn(pid, path, actions, attributes, argv, fixed != NULL ? fixed : envp);
    free(fixed);
    free(inserted);
    return result;
}
PARALLEX_INTERPOSE(parallex_posix_spawn, posix_spawn);

static int parallex_posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *actions,
                                 const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]) {
    char *inserted = NULL;
    char **fixed = insideCopy(file, true) ? NULL : withoutLibrary(envp, &inserted);
    int result = posix_spawnp(pid, file, actions, attributes, argv, fixed != NULL ? fixed : envp);
    free(fixed);
    free(inserted);
    return result;
}
PARALLEX_INTERPOSE(parallex_posix_spawnp, posix_spawnp);

__attribute__((constructor)) static void parallex_groups_init(void) {
    findBundle();
    serviceMap = parseMap(getenv("PARALLEX_SERVICE_MAP"));
    cache = [NSMutableDictionary dictionary];
    groupMap = parseMap(getenv("PARALLEX_GROUP_MAP"));
    if (groupMap == nil) {
        return;
    }
    Method container = class_getInstanceMethod([NSFileManager class],
                                                @selector(containerURLForSecurityApplicationGroupIdentifier:));
    if (container != NULL) {
        originalContainerURL = method_setImplementation(container, (IMP)parallex_containerURL);
    }
    Method suite = class_getInstanceMethod([NSUserDefaults class], @selector(initWithSuiteName:));
    if (suite != NULL) {
        originalInitWithSuiteName = method_setImplementation(suite, (IMP)parallex_initWithSuiteName);
    }
}
