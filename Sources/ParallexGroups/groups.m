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
#import <objc/runtime.h>
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

// Returns a C string that lives as long as the process (the mapped names are
// few and fixed); NULL when the name isn't rewritten.
static const char *rewrittenCName(const char *name) {
    // Some of these run during process start-up, before Objective-C is
    // ready: touch nothing until there's a map (set by our constructor).
    if (name == NULL || groupMap == nil) {
        return NULL;
    }
    NSString *rewritten = rewrittenName([NSString stringWithUTF8String:name]);
    return rewritten != nil ? strdup(rewritten.UTF8String) : NULL;
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

__attribute__((constructor)) static void parallex_groups_init(void) {
    serviceMap = parseMap(getenv("PARALLEX_SERVICE_MAP"));
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
