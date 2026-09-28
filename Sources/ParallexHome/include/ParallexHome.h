// Parallex home redirect: a library loaded into an instance's own copy of an
// app that makes the copy see the instance's home folder as the user's home.
// It works by interposing the account-lookup functions. It also keeps the
// app's own updater from replacing the copy (updates.m).

#include <stdbool.h>

/// Whether this process is part of the copy the library serves (its
/// executable lives inside the copy) and the redirect is on.
bool parallex_home_active(void);
