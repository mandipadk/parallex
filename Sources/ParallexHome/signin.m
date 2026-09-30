// Notes which copy started a sign-in.
//
// Apps sign in by opening a web page (an OAuth request with a `state`) and
// get a link in their own scheme back, carrying that state. With several
// copies of an app running, Parallex Links sends that link to the copy
// whose library noted the state here, in <instance>/signin.log (see
// SignInRequests in ParallexCore). Apps open web pages through NSWorkspace
// (Electron's shell.openExternal does too); the page itself opens as usual.
//
// PARALLEX_OPEN_URL_DRY_RUN=1 (tests): note it, but don't open anything.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

#import "ParallexHome.h"

static bool isSignInRequest(NSURL *url, NSString **state) {
    NSString *scheme = url.scheme.lowercaseString;
    if (!([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])) {
        return false;
    }
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *found = nil;
    bool marker = false;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"state"] && item.value.length > 0 && found == nil) {
            found = item.value;
        } else if ([item.name isEqualToString:@"client_id"] || [item.name isEqualToString:@"redirect_uri"]
                   || [item.name isEqualToString:@"response_type"]) {
            marker = true;
        }
    }
    if (found == nil || !marker) {
        return false;
    }
    *state = found;
    return true;
}

static void noteSignIn(NSURL *url) {
    @autoreleasepool {
        NSString *state = nil;
        const char *home = parallex_home_redirect();
        if (home == NULL || url == nil || !isSignInRequest(url, &state)) {
            return;
        }
        NSString *folder = [[NSString stringWithUTF8String:home] stringByDeletingLastPathComponent];
        NSString *path = [folder stringByAppendingPathComponent:@"signin.log"];
        NSFileManager *files = NSFileManager.defaultManager;
        NSNumber *size = [files attributesOfItemAtPath:path error:nil][NSFileSize];
        if (size.longLongValue > 16384) {
            [files removeItemAtPath:path error:nil];
        }
        if (![files fileExistsAtPath:path]) {
            [files createFileAtPath:path contents:nil attributes:@{NSFilePosixPermissions: @0600}];
        }
        // Plain write(2): nothing here may raise inside the app's openURL
        // (a full disk just means no note).
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CLOEXEC);
        if (fd < 0) {
            return;
        }
        NSString *line = [NSString stringWithFormat:@"%ld\t%@\n", (long)NSDate.date.timeIntervalSince1970, state];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        (void)write(fd, data.bytes, data.length);
        close(fd);
    }
}

static bool dryRun(void) {
    const char *value = getenv("PARALLEX_OPEN_URL_DRY_RUN");
    return value != NULL && strcmp(value, "1") == 0;
}

static IMP originalOpenURL, originalOpenURLConfiguration, originalOpenURLsWithApplication;

static BOOL parallex_openURL(id self, SEL _cmd, NSURL *url) {
    noteSignIn(url);
    if (dryRun()) return YES;
    return ((BOOL (*)(id, SEL, NSURL *))originalOpenURL)(self, _cmd, url);
}

static void parallex_openURLConfiguration(id self, SEL _cmd, NSURL *url, id configuration, id completion) {
    noteSignIn(url);
    if (dryRun()) return;
    ((void (*)(id, SEL, NSURL *, id, id))originalOpenURLConfiguration)(self, _cmd, url, configuration, completion);
}

static void parallex_openURLsWithApplication(id self, SEL _cmd, NSArray<NSURL *> *urls, NSURL *application,
                                             id configuration, id completion) {
    for (NSURL *url in urls) {
        noteSignIn(url);
    }
    if (dryRun()) return;
    ((void (*)(id, SEL, NSArray *, NSURL *, id, id))originalOpenURLsWithApplication)(
        self, _cmd, urls, application, configuration, completion);
}

static IMP replaceMethod(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    return method != NULL ? method_setImplementation(method, replacement) : NULL;
}

static bool hooked = false;

static void hookWorkspace(void) {
    if (hooked) return;
    Class workspace = objc_getClass("NSWorkspace");
    if (workspace == Nil) return;
    hooked = true;
    originalOpenURL = replaceMethod(workspace, NSSelectorFromString(@"openURL:"), (IMP)parallex_openURL);
    originalOpenURLConfiguration = replaceMethod(
        workspace, NSSelectorFromString(@"openURL:configuration:completionHandler:"), (IMP)parallex_openURLConfiguration);
    originalOpenURLsWithApplication = replaceMethod(
        workspace, NSSelectorFromString(@"openURLs:withApplicationAtURL:configuration:completionHandler:"),
        (IMP)parallex_openURLsWithApplication);
}

// AppKit loaded after launch: hook once the process is running.
static void imageAdded(const struct mach_header *header, intptr_t slide) {
    if (hooked) return;
    Dl_info info;
    if (dladdr(header, &info) != 0 && info.dli_fname != NULL && strstr(info.dli_fname, "/AppKit.framework/") != NULL) {
        dispatch_async(dispatch_get_main_queue(), ^{ hookWorkspace(); });
    }
}

__attribute__((constructor)) static void parallex_signin_init(void) {
    if (!parallex_home_active()) {
        return;
    }
    hookWorkspace();
    if (!hooked) {
        _dyld_register_func_for_add_image(imageAdded);
    }
}
