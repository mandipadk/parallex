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
//
// Guard: the same functions (and renamex_np, clonefile, link, symlink,
// truncate, unlink, rmdir and their *at forms) refuse the original app's
// data outright (PARALLEX_GUARD, see Guard in ParallexCore), failing with
// EPERM as a sandbox would and noting "blocked". It works on the path as
// given, spelled out in full (the way saved paths and paths built from a
// home folder are), not on one relative to an open folder, one that leads
// there through a link, or what tools the copy starts do. It's a safety net
// for an app's own code, not a sandbox against code set on getting around it.

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <os/lock.h>
#include <pthread.h>
#include <sys/clonefile.h>
#include <stdatomic.h>
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
static atomic_bool ready = false;
// Recording stopped (no instance, or its log can't be written).
static bool off = false;
// Guard's list, split in place: `guarded_count` paths, folders ending "/".
#define GUARD_SLOTS 128
static char *guard_text = NULL;
static const char *guarded[GUARD_SLOTS];
static size_t guarded_length[GUARD_SLOTS];
static unsigned guarded_count = 0;
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

static void prepare_guard(void) {
    const char *list = parallex_home_guarded();
    if (list == NULL || (guard_text = strdup(list)) == NULL) {
        return;
    }
    for (char *entry = guard_text; entry != NULL && *entry != '\0' && guarded_count < GUARD_SLOTS;) {
        char *end = strchr(entry, '\n');
        if (end != NULL) {
            *end = '\0';
        }
        size_t length = strlen(entry);
        if (entry[0] == '/' && length > 1) {
            guarded[guarded_count] = entry;
            guarded_length[guarded_count] = length;
            guarded_count++;
        }
        entry = end != NULL ? end + 1 : NULL;
    }
}

static void prepare_all(void);

// A child made by fork() (without exec) starts with one thread: the lock
// must not stay held by a thread that isn't there.
static void before_fork(void) { os_unfair_lock_lock(&lock); }
static void after_fork_parent(void) { os_unfair_lock_unlock(&lock); }
static void after_fork_child(void) { lock = OS_UNFAIR_LOCK_INIT; }

// Everything below is set once, under the lock, before `ready` is. False
// while the library is still setting up: then nothing is noted or refused
// for now, and nothing is concluded for later.
static bool ensure_ready(void) {
    if (atomic_load_explicit(&ready, memory_order_acquire)) {
        return true;
    }
    if (!parallex_home_settled()) {
        return false;
    }
    os_unfair_lock_lock(&lock);
    if (!atomic_load_explicit(&ready, memory_order_relaxed)) {
        prepare_all();
        atomic_store_explicit(&ready, true, memory_order_release);
    }
    os_unfair_lock_unlock(&lock);
    return true;
}

static void prepare_all(void) {
    pthread_atfork(before_fork, after_fork_parent, after_fork_child);
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
    prepare_guard();
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

// True the first time this process notes `path` (for `salt`: a blocked
// attempt is noted apart from a read of the same path).
static bool first_time(const char *path, uint64_t salt) {
    // Full: start over (some paths get noted twice) rather than stop.
    if (seen_count >= SEEN_SLOTS * 3 / 4) {
        memset(seen, 0, sizeof(seen));
        seen_count = 0;
    }
    uint64_t value = hash(path) ^ salt;
    value = value == 0 ? 1 : value;
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
    if (ensure_ready() && !off) {
        // Sorted first; only noting it takes the lock.
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
        if (noted != NULL) {
            os_unfair_lock_lock(&lock);
            if (!off && first_time(noted, 0)) {
                write_line(operation, noted);
            }
            os_unfair_lock_unlock(&lock);
        }
    }
    noting = false;
    errno = saved;
}

// `path` with "//", "." and ".." taken out (by name: nothing is resolved),
// into `out`. False when it doesn't fit.
static bool tidy(const char *path, char *out, size_t size) {
    size_t length = 0;
    const char *part = path;
    while (*part != '\0') {
        while (*part == '/') part++;
        if (*part == '\0') break;
        const char *end = strchr(part, '/');
        size_t part_length = end != NULL ? (size_t)(end - part) : strlen(part);
        if (part_length == 1 && part[0] == '.') {
            // nothing
        } else if (part_length == 2 && part[0] == '.' && part[1] == '.') {
            while (length > 0 && out[length - 1] != '/') length--;
            if (length > 0) length--;
        } else {
            if (length + 1 + part_length + 1 > size) return false;
            out[length++] = '/';
            memcpy(out + length, part, part_length);
            length += part_length;
        }
        part += part_length;
    }
    if (length == 0) {
        if (size < 2) return false;
        out[length++] = '/';
    }
    out[length] = '\0';
    return true;
}

static bool guarded_path(const char *path) {
    for (unsigned index = 0; index < guarded_count; index++) {
        const char *entry = guarded[index];
        size_t length = guarded_length[index];
        if (entry[length - 1] == '/') {
            // A folder: it, or anything in it.
            if (strncasecmp(path, entry, length) == 0
                || (strncasecmp(path, entry, length - 1) == 0 && path[length - 1] == '\0')) {
                return true;
            }
        } else if (strncasecmp(path, entry, length) == 0 && (path[length] == '\0' || path[length] == '/')) {
            return true;
        }
    }
    return false;
}

// Whether Guard refuses `path` (then errno is EPERM and it's noted).
static bool refused(const char *path) {
    if (noting || path == NULL || path[0] != '/') {
        return false;
    }
    // Getting ready looks up the account, which opens files: those go
    // straight through.
    int saved = errno;
    noting = true;
    bool usable = ensure_ready();
    noting = false;
    errno = saved;
    // The same folder by the data volume's own path.
    static const char data_volume[] = "/System/Volumes/Data/";
    if (strncmp(path, data_volume, sizeof(data_volume) - 1) == 0) {
        path += sizeof(data_volume) - 2;
    }
    if (!usable || guarded_count == 0 || strncasecmp(path, real_prefix, real_length) != 0) {
        return false;
    }
    const char *checked = path;
    char tidied[PATH_MAX];
    // (Cheap to test for; hidden folders make it tidy some for nothing.)
    if (strstr(path, "//") != NULL || strstr(path, "/.") != NULL) {
        if (!tidy(path, tidied, sizeof(tidied))) {
            return false;
        }
        checked = tidied;
    }
    if (!guarded_path(checked)) {
        return false;
    }
    noting = true;
    os_unfair_lock_lock(&lock);
    if (!off && first_time(checked, 0x9e3779b97f4a7c15ULL)) {
        write_line("blocked", checked);
    }
    os_unfair_lock_unlock(&lock);
    noting = false;
    errno = EPERM;
    return true;
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
    if (refused(path)) return -1;
    MODE_ARGUMENT(flags, flags);
    int result = open(path, flags, mode);
    if (result >= 0) note(kind(flags), path);
    return result;
}

static int parallex_open_nocancel(const char *path, int flags, ...) {
    if (refused(path)) return -1;
    MODE_ARGUMENT(flags, flags);
    int result = open_nocancel(path, flags, mode);
    if (result >= 0) note(kind(flags), path);
    return result;
}

static int parallex___open_nocancel(const char *path, int flags, ...) {
    if (refused(path)) return -1;
    MODE_ARGUMENT(flags, flags);
    int result = __open_nocancel(path, flags, mode);
    if (result >= 0) note(kind(flags), path);
    return result;
}

static int parallex_openat(int fd, const char *path, int flags, ...) {
    if (refused(path)) return -1;
    MODE_ARGUMENT(flags, flags);
    int result = openat(fd, path, flags, mode);
    if (result >= 0) note(kind(flags), path);
    return result;
}

static int parallex_openat_nocancel(int fd, const char *path, int flags, ...) {
    if (refused(path)) return -1;
    MODE_ARGUMENT(flags, flags);
    int result = openat_nocancel(fd, path, flags, mode);
    if (result >= 0) note(kind(flags), path);
    return result;
}

static int parallex_open_dprotected_np(const char *path, int flags, int dpclass, int dpflags, ...) {
    if (refused(path)) return -1;
    MODE_ARGUMENT(flags, dpflags);
    int result = open_dprotected_np(path, flags, dpclass, dpflags, mode);
    if (result >= 0) note(kind(flags), path);
    return result;
}

static int parallex_guarded_open_np(const char *path, const guardid_t *guard, unsigned int guardflags, int flags, ...) {
    if (refused(path)) return -1;
    MODE_ARGUMENT(flags, flags);
    int result = guarded_open_np(path, guard, guardflags, flags, mode);
    if (result >= 0) note(kind(flags), path);
    return result;
}

static int parallex_guarded_open_dprotected_np(const char *path, const guardid_t *guard, unsigned int guardflags,
                                               int flags, int dpclass, int dpflags, ...) {
    if (refused(path)) return -1;
    MODE_ARGUMENT(flags, dpflags);
    int result = guarded_open_dprotected_np(path, guard, guardflags, flags, dpclass, dpflags, mode);
    if (result >= 0) note(kind(flags), path);
    return result;
}

static int parallex_mkdir(const char *path, mode_t mode) {
    if (refused(path)) return -1;
    int result = mkdir(path, mode);
    if (result == 0) note("create", path);
    return result;
}

static int parallex_mkdirat(int fd, const char *path, mode_t mode) {
    if (refused(path)) return -1;
    int result = mkdirat(fd, path, mode);
    if (result == 0) note("create", path);
    return result;
}

static int parallex_rename(const char *from, const char *to) {
    if (refused(from) || refused(to)) return -1;
    int result = rename(from, to);
    if (result == 0) note("write", to);
    return result;
}

static int parallex_renameat(int from_fd, const char *from, int to_fd, const char *to) {
    if (refused(from) || refused(to)) return -1;
    int result = renameat(from_fd, from, to_fd, to);
    if (result == 0) note("write", to);
    return result;
}

static int parallex_renamex_np(const char *from, const char *to, unsigned int flags) {
    if (refused(from) || refused(to)) return -1;
    int result = renamex_np(from, to, flags);
    if (result == 0) note("write", to);
    return result;
}

static int parallex_renameatx_np(int from_fd, const char *from, int to_fd, const char *to, unsigned int flags) {
    if (refused(from) || refused(to)) return -1;
    int result = renameatx_np(from_fd, from, to_fd, to, flags);
    if (result == 0) note("write", to);
    return result;
}

static int parallex_clonefile(const char *from, const char *to, uint32_t flags) {
    if (refused(from) || refused(to)) return -1;
    int result = clonefile(from, to, flags);
    if (result == 0) {
        note("read", from);
        note("create", to);
    }
    return result;
}

static int parallex_clonefileat(int from_fd, const char *from, int to_fd, const char *to, uint32_t flags) {
    if (refused(from) || refused(to)) return -1;
    int result = clonefileat(from_fd, from, to_fd, to, flags);
    if (result == 0) {
        note("read", from);
        note("create", to);
    }
    return result;
}

static int parallex_link(const char *from, const char *to) {
    if (refused(from) || refused(to)) return -1;
    return link(from, to);
}

static int parallex_linkat(int from_fd, const char *from, int to_fd, const char *to, int flags) {
    if (refused(from) || refused(to)) return -1;
    return linkat(from_fd, from, to_fd, to, flags);
}

// A link made to the original's data would lead there by another name.
static int parallex_symlink(const char *target, const char *path) {
    if (refused(target) || refused(path)) return -1;
    return symlink(target, path);
}

static int parallex_symlinkat(const char *target, int fd, const char *path) {
    if (refused(target) || refused(path)) return -1;
    return symlinkat(target, fd, path);
}

static int parallex_truncate(const char *path, off_t length) {
    if (refused(path)) return -1;
    return truncate(path, length);
}

static int parallex_unlink(const char *path) {
    if (refused(path)) return -1;
    return unlink(path);
}

static int parallex_unlinkat(int fd, const char *path, int flags) {
    if (refused(path)) return -1;
    return unlinkat(fd, path, flags);
}

static int parallex_rmdir(const char *path) {
    if (refused(path)) return -1;
    return rmdir(path);
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
INTERPOSE(parallex_unlink, unlink);
INTERPOSE(parallex_unlinkat, unlinkat);
INTERPOSE(parallex_rmdir, rmdir);
INTERPOSE(parallex_renamex_np, renamex_np);
INTERPOSE(parallex_renameatx_np, renameatx_np);
INTERPOSE(parallex_clonefile, clonefile);
INTERPOSE(parallex_clonefileat, clonefileat);
INTERPOSE(parallex_link, link);
INTERPOSE(parallex_linkat, linkat);
INTERPOSE(parallex_symlink, symlink);
INTERPOSE(parallex_symlinkat, symlinkat);
INTERPOSE(parallex_truncate, truncate);
