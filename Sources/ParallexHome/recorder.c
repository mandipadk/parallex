// The copy's flight recorder.
//
// A copy with its own Library should never open anything of yours outside
// it: not your ~/Library (where the original app keeps its data), and not
// the app's folders in your home, which the copy's mirrored home reaches
// through links. Checking the files a running copy has open catches only
// what's open at that moment. So the copy's library notes, as it happens,
// every file the copy opens, creates or renames that resolves into your
// home outside the instance, once per path per process, in
// <instance>/access.log. Parallex reads it and sorts it (the original's
// data, what's shared on purpose, everything else).
//
// Every way apps open files goes through one of the functions below:
// Foundation and CoreFoundation (open, openat, open_dprotected_np, mkdir,
// mkdirat, rename, renameat), SQLite (guarded_open_np,
// guarded_open_dprotected_np) and the C library (the $NOCANCEL variants).
// Checks are prefix tests on the path given; only a path that leads out of
// the instance through its home's links is resolved.

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <os/lock.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "ParallexHome.h"

#define INTERPOSE(replacement, original)                                          \
    __attribute__((used)) static const struct {                                   \
        const void *replacement_function;                                         \
        const void *original_function;                                            \
    } interpose_##replacement __attribute__((section("__DATA,__interpose"))) = {   \
        (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original \
    }

typedef uint64_t guardid_t;
extern int open_nocancel(const char *path, int flags, ...) __asm("_open$NOCANCEL");
extern int openat_nocancel(int fd, const char *path, int flags, ...) __asm("_openat$NOCANCEL");
extern int __open_nocancel(const char *path, int flags, ...);
extern int open_dprotected_np(const char *path, int flags, int dpclass, int dpflags, ...);
extern int guarded_open_np(const char *path, const guardid_t *guard, unsigned int guardflags, int flags, ...);
extern int guarded_open_dprotected_np(const char *path, const guardid_t *guard, unsigned int guardflags, int flags,
                                      int dpclass, int dpflags, ...);

static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
static bool ready = false;
static bool off = false;
static char instance_dir[PATH_MAX];
static size_t instance_length;
static char home_prefix[PATH_MAX];     // the instance's home, with "/"
static size_t home_length;
static char library_prefix[PATH_MAX];  // the instance's home's Library, with "/"
static size_t library_length;
static char real_prefix[PATH_MAX];     // your home, with "/"
static size_t real_length;
static char scope_prefix[PATH_MAX];    // the copy, with "/"
static size_t scope_length;
static char program[64];
static int log_fd = -1;
// Paths noted by this process (hashes), so each is written once.
#define SEEN_SLOTS 2048
static uint64_t seen[SEEN_SLOTS];
static unsigned seen_count = 0;
static const off_t log_limit = 2 * 1024 * 1024;
// Set while this thread is noting something: what the recorder itself
// opens (realpath, its log) goes straight through.
static __thread bool noting = false;

static bool starts_with(const char *text, const char *prefix, size_t length) {
    return strncmp(text, prefix, length) == 0;
}

static void prepare(void) {
    ready = true;
    const char *home = parallex_home_redirect();
    const char *real = parallex_home_real();
    const char *scope = parallex_home_scope();
    if (home == NULL || real == NULL || scope == NULL) {
        off = true;
        return;
    }
    snprintf(home_prefix, sizeof(home_prefix), "%s/", home);
    home_length = strlen(home_prefix);
    snprintf(library_prefix, sizeof(library_prefix), "%sLibrary/", home_prefix);
    library_length = strlen(library_prefix);
    snprintf(real_prefix, sizeof(real_prefix), "%s/", real);
    real_length = strlen(real_prefix);
    snprintf(scope_prefix, sizeof(scope_prefix), "%s/", scope);
    scope_length = strlen(scope_prefix);
    // The instance folder holds the home.
    strlcpy(instance_dir, home, sizeof(instance_dir));
    char *slash = strrchr(instance_dir, '/');
    if (slash == NULL) {
        off = true;
        return;
    }
    slash[1] = '\0';
    instance_length = strlen(instance_dir);
    char executable[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) == 0) {
        const char *name = strrchr(executable, '/');
        strlcpy(program, name != NULL ? name + 1 : executable, sizeof(program));
    }
}

static uint64_t hash(const char *text) {
    uint64_t value = 0xcbf29ce484222325ULL;
    for (; *text != '\0'; text++) {
        value = (value ^ (uint8_t)*text) * 0x100000001b3ULL;
    }
    return value == 0 ? 1 : value;
}

// True the first time this process notes `path`.
static bool first_time(const char *path) {
    if (seen_count >= SEEN_SLOTS * 3 / 4) {
        return false;
    }
    uint64_t value = hash(path);
    for (unsigned probe = 0; probe < SEEN_SLOTS; probe++) {
        unsigned slot = (unsigned)((value + probe) % SEEN_SLOTS);
        if (seen[slot] == value) {
            return false;
        }
        if (seen[slot] == 0) {
            seen[slot] = value;
            seen_count++;
            return true;
        }
    }
    return false;
}

static void write_line(const char *operation, const char *path) {
    if (log_fd < 0) {
        char log_path[PATH_MAX];
        snprintf(log_path, sizeof(log_path), "%saccess.log", instance_dir);
        struct stat info;
        if (stat(log_path, &info) == 0 && info.st_size > log_limit) {
            char older[PATH_MAX];
            snprintf(older, sizeof(older), "%s.1", log_path);
            rename(log_path, older);
        }
        log_fd = open(log_path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
        if (log_fd < 0) {
            off = true;
            return;
        }
    }
    char line[PATH_MAX + 160];
    int length = snprintf(line, sizeof(line), "%ld\t%d\t%s\t%s\t%s\n", (long)time(NULL), (int)getpid(), program,
                          operation, path);
    if (length > 0 && length < (int)sizeof(line)) {
        write(log_fd, line, (size_t)length);
    }
}

// Note `path` if it leads to your home outside the instance.
static void note(const char *operation, const char *path) {
    if (off || noting || path == NULL || path[0] != '/') {
        return;
    }
    int saved = errno;
    noting = true;
    os_unfair_lock_lock(&lock);
    if (!ready) {
        prepare();
    }
    if (!off) {
        const char *noted = NULL;
        char resolved[PATH_MAX];
        if (starts_with(path, instance_dir, instance_length)) {
            // Inside the instance, except through its home's links to yours
            // (everything in the home but its Library is one).
            if (starts_with(path, home_prefix, home_length) && !starts_with(path, library_prefix, library_length)
                && realpath(path, resolved) != NULL && !starts_with(resolved, instance_dir, instance_length)
                && starts_with(resolved, real_prefix, real_length)) {
                noted = resolved;
            }
        } else if (starts_with(path, real_prefix, real_length) && !starts_with(path, scope_prefix, scope_length)
                   && !(strncmp(path, scope_prefix, scope_length - 1) == 0 && path[scope_length - 1] == '\0')) {
            // (Not the copy itself, nor anything in it.)
            noted = path;
        }
        if (noted != NULL && first_time(noted)) {
            write_line(operation, noted);
        }
    }
    os_unfair_lock_unlock(&lock);
    noting = false;
    errno = saved;
}

// The mode follows the flags only when a file may be created.
#define MODE_ARGUMENT(flags, last)             \
    mode_t mode = 0;                           \
    if ((flags) & O_CREAT) {                   \
        va_list arguments;                     \
        va_start(arguments, last);             \
        mode = (mode_t)va_arg(arguments, int); \
        va_end(arguments);                     \
    }

static const char *kind(int flags) {
    return (flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? "write" : "read";
}

static int parallex_open(const char *path, int flags, ...) {
    MODE_ARGUMENT(flags, flags);
    int result = open(path, flags, mode);
    if (result >= 0) note(kind(flags), path);
    return result;
}

static int parallex_open_nocancel(const char *path, int flags, ...) {
    MODE_ARGUMENT(flags, flags);
    int result = open_nocancel(path, flags, mode);
    if (result >= 0) note(kind(flags), path);
    return result;
}

static int parallex___open_nocancel(const char *path, int flags, ...) {
    MODE_ARGUMENT(flags, flags);
    int result = __open_nocancel(path, flags, mode);
    if (result >= 0) note(kind(flags), path);
    return result;
}

static int parallex_openat(int fd, const char *path, int flags, ...) {
    MODE_ARGUMENT(flags, flags);
    int result = openat(fd, path, flags, mode);
    if (result >= 0) note(kind(flags), path);
    return result;
}

static int parallex_openat_nocancel(int fd, const char *path, int flags, ...) {
    MODE_ARGUMENT(flags, flags);
    int result = openat_nocancel(fd, path, flags, mode);
    if (result >= 0) note(kind(flags), path);
    return result;
}

static int parallex_open_dprotected_np(const char *path, int flags, int dpclass, int dpflags, ...) {
    MODE_ARGUMENT(flags, dpflags);
    int result = open_dprotected_np(path, flags, dpclass, dpflags, mode);
    if (result >= 0) note(kind(flags), path);
    return result;
}

static int parallex_guarded_open_np(const char *path, const guardid_t *guard, unsigned int guardflags, int flags, ...) {
    MODE_ARGUMENT(flags, flags);
    int result = guarded_open_np(path, guard, guardflags, flags, mode);
    if (result >= 0) note(kind(flags), path);
    return result;
}

static int parallex_guarded_open_dprotected_np(const char *path, const guardid_t *guard, unsigned int guardflags,
                                               int flags, int dpclass, int dpflags, ...) {
    MODE_ARGUMENT(flags, dpflags);
    int result = guarded_open_dprotected_np(path, guard, guardflags, flags, dpclass, dpflags, mode);
    if (result >= 0) note(kind(flags), path);
    return result;
}

static int parallex_mkdir(const char *path, mode_t mode) {
    int result = mkdir(path, mode);
    if (result == 0) note("create", path);
    return result;
}

static int parallex_mkdirat(int fd, const char *path, mode_t mode) {
    int result = mkdirat(fd, path, mode);
    if (result == 0) note("create", path);
    return result;
}

static int parallex_rename(const char *from, const char *to) {
    int result = rename(from, to);
    if (result == 0) note("write", to);
    return result;
}

static int parallex_renameat(int from_fd, const char *from, int to_fd, const char *to) {
    int result = renameat(from_fd, from, to_fd, to);
    if (result == 0) note("write", to);
    return result;
}

INTERPOSE(parallex_open, open);
INTERPOSE(parallex_open_nocancel, open_nocancel);
INTERPOSE(parallex___open_nocancel, __open_nocancel);
INTERPOSE(parallex_openat, openat);
INTERPOSE(parallex_openat_nocancel, openat_nocancel);
INTERPOSE(parallex_open_dprotected_np, open_dprotected_np);
INTERPOSE(parallex_guarded_open_np, guarded_open_np);
INTERPOSE(parallex_guarded_open_dprotected_np, guarded_open_dprotected_np);
INTERPOSE(parallex_mkdir, mkdir);
INTERPOSE(parallex_mkdirat, mkdirat);
INTERPOSE(parallex_rename, rename);
INTERPOSE(parallex_renameat, renameat);
