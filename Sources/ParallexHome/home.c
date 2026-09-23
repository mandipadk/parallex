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
// Only processes whose executable lives inside the scope are redirected
// (the app, its helpers and services). Any other process that inherits this
// library — a shell or tool the app started — takes it and the variables
// out of its environment, so its own children never see them. Without both
// variables the library does nothing.

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

static const char library_name[] = "/libparallexhome.dylib";
static char redirect_home[PATH_MAX];
static bool active = false;

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
