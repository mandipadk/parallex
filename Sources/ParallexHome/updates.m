// Keeps an app's own updater from replacing its copy.
//
// A copy is a snapshot of the app that Parallex refreshes when the original
// updates. The app's updater doesn't know that: left alone, Sparkle installs
// the vendor's build over the copy whenever the update's signature checks out
// (the copy then has the original's identity again, and the original's
// data), and Squirrel, under Electron's autoUpdater, downloads every update
// in full before refusing it. So inside a copy:
//
// - Sparkle (1 and 2): checks do nothing, there is no feed, and "Check for
//   Updates…" reports it can't check, so its menu item is greyed out.
// - Squirrel: the update server always answers "no update" (HTTP 204), so
//   the app hears it's up to date and nothing is downloaded.
//
// Only active where the home redirect is (processes inside the copy).

#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <dlfcn.h>

#import "ParallexHome.h"

// MARK: - Squirrel

@interface ParallexNoUpdate : NSURLProtocol
@end

@implementation ParallexNoUpdate
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return [request.URL.scheme isEqualToString:@"parallex-no-update"];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}
- (void)startLoading {
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:204
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {
}
@end

static NSURLRequest *noUpdateRequest(void) {
    return [NSURLRequest requestWithURL:[NSURL URLWithString:@"parallex-no-update://updates"]];
}

// Every SQRLUpdater initializer takes the update request first.
static IMP squirrelInit1, squirrelInit2Version, squirrelInit2Download, squirrelInit4;

static id quietInit1(id self, SEL _cmd, NSURLRequest *request) {
    return ((id (*)(id, SEL, id))squirrelInit1)(self, _cmd, noUpdateRequest());
}
static id quietInit2Version(id self, SEL _cmd, NSURLRequest *request, id version) {
    return ((id (*)(id, SEL, id, id))squirrelInit2Version)(self, _cmd, noUpdateRequest(), version);
}
static id quietInit2Download(id self, SEL _cmd, NSURLRequest *request, id download) {
    return ((id (*)(id, SEL, id, id))squirrelInit2Download)(self, _cmd, noUpdateRequest(), download);
}
static id quietInit4(id self, SEL _cmd, NSURLRequest *request, id download, id version, NSUInteger mode) {
    return ((id (*)(id, SEL, id, id, id, NSUInteger))squirrelInit4)(self, _cmd, noUpdateRequest(), download, version, mode);
}

/// Replace a method the class itself (or an ancestor other than NSObject)
/// implements; returns the previous implementation, or NULL if it has none.
static IMP replace(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) {
        return NULL;
    }
    return class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method))
        ?: method_getImplementation(method);
}

static bool quietSquirrel(void) {
    Class updater = objc_getClass("SQRLUpdater");
    if (updater == Nil) {
        return false;
    }
    [NSURLProtocol registerClass:[ParallexNoUpdate class]];
    squirrelInit1 = replace(updater, @selector(initWithUpdateRequest:), (IMP)quietInit1);
    squirrelInit2Version = replace(updater, NSSelectorFromString(@"initWithUpdateRequest:forVersion:"), (IMP)quietInit2Version);
    squirrelInit2Download = replace(updater, NSSelectorFromString(@"initWithUpdateRequest:requestForDownload:"), (IMP)quietInit2Download);
    squirrelInit4 = replace(updater, NSSelectorFromString(@"initWithUpdateRequest:requestForDownload:forVersion:useMode:"), (IMP)quietInit4);
    return true;
}

// MARK: - Sparkle

static void doNothing(id self, SEL _cmd) {
}
static void doNothingWith(id self, SEL _cmd, id argument) {
}
static BOOL answerNo(id self, SEL _cmd) {
    return NO;
}
static id noFeed(id self, SEL _cmd) {
    return nil;
}

static IMP legacyValidateMenuItem;
static BOOL validateMenuItem(id self, SEL _cmd, id item) {
    // (No AppKit here: the menu item's action through the runtime.)
    SEL action = NSSelectorFromString(@"action");
    if ([item respondsToSelector:action]
        && ((SEL (*)(id, SEL))objc_msgSend)(item, action) == NSSelectorFromString(@"checkForUpdates:")) {
        return NO;
    }
    return legacyValidateMenuItem ? ((BOOL (*)(id, SEL, id))legacyValidateMenuItem)(self, _cmd, item) : YES;
}

static void quietSparkleClass(Class cls) {
    for (NSString *name in @[ @"checkForUpdates", @"checkForUpdatesInBackground", @"checkForUpdateInformation",
                              @"resetUpdateCycle", @"resetUpdateCycleAfterShortDelay" ]) {
        replace(cls, NSSelectorFromString(name), (IMP)doNothing);
    }
    replace(cls, NSSelectorFromString(@"checkForUpdates:"), (IMP)doNothingWith);
    for (NSString *name in @[ @"canCheckForUpdates", @"automaticallyChecksForUpdates", @"automaticallyDownloadsUpdates" ]) {
        replace(cls, NSSelectorFromString(name), (IMP)answerNo);
    }
    replace(cls, NSSelectorFromString(@"feedURL"), (IMP)noFeed);
}

static bool quietSparkle(void) {
    bool found = false;
    Class updater = objc_getClass("SPUUpdater"); // Sparkle 2
    if (updater != Nil) {
        quietSparkleClass(updater);
        found = true;
    }
    Class settings = objc_getClass("SPUUpdaterSettings");
    if (settings != Nil) {
        replace(settings, NSSelectorFromString(@"automaticallyChecksForUpdates"), (IMP)answerNo);
        replace(settings, NSSelectorFromString(@"automaticallyDownloadsUpdates"), (IMP)answerNo);
    }
    Class legacy = objc_getClass("SUUpdater"); // Sparkle 1, and Sparkle 2's compatibility class
    if (legacy != Nil) {
        quietSparkleClass(legacy);
        legacyValidateMenuItem = replace(legacy, NSSelectorFromString(@"validateMenuItem:"), (IMP)validateMenuItem);
        found = true;
    }
    return found;
}

// MARK: - Setup

static bool squirrelDone, sparkleDone;

static void quietUpdaters(void) {
    @autoreleasepool {
        if (!squirrelDone && quietSquirrel()) {
            squirrelDone = true;
            os_log(OS_LOG_DEFAULT, "parallex: this copy's Squirrel updater always hears there is no update");
        }
        if (!sparkleDone && quietSparkle()) {
            sparkleDone = true;
            os_log(OS_LOG_DEFAULT, "parallex: this copy's Sparkle updater is turned off");
        }
    }
}

static bool isUpdaterFramework(const char *path) {
    return path != NULL && (strstr(path, "/Squirrel.framework/") != NULL || strstr(path, "/Sparkle.framework/") != NULL);
}

// A framework loaded after launch: hook it once the process is running
// (touching the Objective-C runtime from inside dyld's callback isn't safe).
static void imageAdded(const struct mach_header *header, intptr_t slide) {
    if (squirrelDone && sparkleDone) {
        return;
    }
    Dl_info info;
    if (dladdr(header, &info) != 0 && isUpdaterFramework(info.dli_fname)) {
        dispatch_async(dispatch_get_main_queue(), ^{ quietUpdaters(); });
    }
}

__attribute__((constructor)) static void parallex_updates_init(void) {
    if (!parallex_home_active()) {
        return;
    }
    // Frameworks the app links are loaded (and their classes known) by now.
    quietUpdaters();
    _dyld_register_func_for_add_image(imageAdded);
}
