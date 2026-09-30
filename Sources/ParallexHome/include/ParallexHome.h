// Parallex home redirect: a library loaded into an instance's own copy of an
// app that makes the copy see the instance's home folder as the user's home.
// It works by interposing the account-lookup functions. It also keeps the
// app's own updater from replacing the copy (updates.m).

#include <stdbool.h>

/// Whether this process is part of the copy the library serves (its
/// executable lives inside the copy) and the redirect is on.
bool parallex_home_active(void);

/// Whether the library has finished setting up. Until then (a call made
/// while it sets up), `parallex_home_active` says no without meaning it:
/// don't draw lasting conclusions from it.
bool parallex_home_settled(void);

/// The instance's home, your real home, and the copy's bundle (NULL when
/// the library isn't active in this process).
const char *parallex_home_redirect(void);
const char *parallex_home_real(void);
const char *parallex_home_scope(void);

/// Guard's list: "\n"-separated absolute paths of the original's data (a
/// folder ends in "/"), or NULL when Guard is off.
const char *parallex_home_guarded(void);

/// The ports the app finds a running copy of itself on, ","-separated,
/// which are the copy's own (ports.c), or NULL.
const char *parallex_home_ports(void);
