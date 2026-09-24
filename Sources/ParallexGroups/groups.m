// Parallex app-group mapping.
//
// Sandboxed apps keep shared data — often their sign-in and database — in
// app-group containers (~/Library/Group Containers/<group>), keyed by group
// identifier rather than by app. An own-identity copy is entitled to renamed
// groups of its own; this library, loaded into the copy, translates the
// app's requests for its original groups to those, so the copy never opens
// the original's containers.
//
//   PARALLEX_GROUP_MAP  "original=renamed;original=renamed;…"
//
// Without it the library does nothing.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "ParallexGroups.h"

static NSDictionary<NSString *, NSString *> *groupMap;

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

__attribute__((constructor)) static void parallex_groups_init(void) {
    const char *value = getenv("PARALLEX_GROUP_MAP");
    if (value == NULL || value[0] == '\0') {
        return;
    }
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSString *pair in [[NSString stringWithUTF8String:value] componentsSeparatedByString:@";"]) {
        NSArray<NSString *> *parts = [pair componentsSeparatedByString:@"="];
        if (parts.count == 2 && parts[0].length > 0 && parts[1].length > 0) {
            map[parts[0]] = parts[1];
        }
    }
    if (map.count == 0) {
        return;
    }
    groupMap = [map copy];

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
