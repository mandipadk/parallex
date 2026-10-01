// The app's allocator, set up before it forks.
//
// Some apps bring their own memory allocator, made the default when the
// app's own library loads, which sets itself up on its first allocation
// (Firefox and Thunderbird: mozglue's, which registers fork handlers as it
// does). Normally the system frameworks the app links allocate through it
// as they load, so it's set up long before anything forks. This library
// loads those frameworks itself, before the app's own libraries: they've
// already loaded, with the system's allocator, by the time the app's is
// installed. A helper that forks before allocating anything (Firefox's
// crashhelper does, to leave its parent) then has an allocator that was
// never used, and its first allocation comes from the system's own
// fork-child steps (dirhelper, notify), while fork still holds the lock
// for fork handlers: registering one there aborts the child ("os_unfair_lock
// is corrupt").
//
// So the app's forks allocate once first, the way the app would have by
// then without this library.

#include <stdlib.h>
#include <unistd.h>

#define INTERPOSE(replacement, original)                                          \
    __attribute__((used)) static const struct {                                   \
        const void *replacement_function;                                         \
        const void *original_function;                                            \
    } interpose_##replacement __attribute__((section("__DATA,__interpose"))) = {   \
        (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original \
    }

static pid_t parallex_fork(void) {
    void *volatile block = malloc(1);
    free(block);
    return fork();
}

INTERPOSE(parallex_fork, fork);
