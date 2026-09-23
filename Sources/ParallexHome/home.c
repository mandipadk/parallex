// Parallex home redirect.
//
// macOS resolves the home folder (and so ~/Library, Application Support,
// Caches, …) from the user's account record, not from $HOME. An instance's
// own copy of an app loads this library, which answers the account lookups
// for the current user with the instance's home instead — so everything the
// app writes under "~" lands in the instance.
//
// It's inert unless both of these are set by the Parallex launcher:
//   PARALLEX_HOME_REDIRECT  the instance's home folder
//   PARALLEX_HOME_SCOPE     the copy's bundle path; only processes whose
//                           executable lives inside it are redirected, so
//                           tools the app starts (shells, git, …) are not.

#include <limits.h>
#include <mach-o/dyld.h>
#include <pwd.h>
#include <stdbool.h>
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

static char redirect_home[PATH_MAX];
static bool active = false;

__attribute__((constructor)) static void parallex_home_init(void) {
    const char *home = getenv("PARALLEX_HOME_REDIRECT");
    const char *scope = getenv("PARALLEX_HOME_SCOPE");
    if (home == NULL || home[0] != '/' || strlen(home) >= sizeof(redirect_home)) {
        return;
    }
    if (scope != NULL && scope[0] != '\0') {
        char executable[PATH_MAX];
        uint32_t size = sizeof(executable);
        char resolved[PATH_MAX];
        char resolved_scope[PATH_MAX];
        if (_NSGetExecutablePath(executable, &size) != 0 || realpath(executable, resolved) == NULL
            || realpath(scope, resolved_scope) == NULL) {
            return;
        }
        size_t length = strlen(resolved_scope);
        if (strncmp(resolved, resolved_scope, length) != 0 || resolved[length] != '/') {
            return;
        }
    }
    strlcpy(redirect_home, home, sizeof(redirect_home));
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

INTERPOSE(parallex_getpwuid, getpwuid);
INTERPOSE(parallex_getpwnam, getpwnam);
INTERPOSE(parallex_getpwuid_r, getpwuid_r);
INTERPOSE(parallex_getpwnam_r, getpwnam_r);
