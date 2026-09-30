// Ports of the copy's own.
//
// Some apps make sure only one of them runs by listening on a fixed port on
// this Mac (Zed: 43737 + 200 + your user ID): a second one that finds the
// port answering hands over to it and quits. A copy would find the
// original, or another copy, and never open. So in a copy, the app's known
// ports are a different port of the copy's own, on the way in (bind) and
// out (connect): the copy finds itself, if it's running, and nothing else.
// PARALLEX_LOOPBACK_PORTS: "<app's port>:<copy's port>,…", chosen when the
// copy was built so no two instances share one (LoopbackPorts in
// ParallexCore).
//
// Only for this Mac's own addresses (127.0.0.0/8, ::1) and listening on
// every address; anything going elsewhere keeps its port.

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

#include "ParallexHome.h"

#define INTERPOSE(replacement, original)                                          \
    __attribute__((used)) static const struct {                                   \
        const void *replacement_function;                                         \
        const void *original_function;                                            \
    } interpose_##replacement __attribute__((section("__DATA,__interpose"))) = {   \
        (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original \
    }

#define PORT_SLOTS 16
static uint16_t ports[PORT_SLOTS];
static uint16_t own_ports[PORT_SLOTS];
static unsigned port_count = 0;
static pthread_mutex_t setup = PTHREAD_MUTEX_INITIALIZER;
static _Atomic bool ready = false;

static void prepare(void) {
    const char *c = parallex_home_ports();
    while (c != NULL && *c != '\0' && port_count < PORT_SLOTS) {
        char *end = NULL;
        long port = strtol(c, &end, 10);
        if (end == c || *end != ':') {
            break;
        }
        const char *own_text = end + 1;
        long own = strtol(own_text, &end, 10);
        if (end == own_text) {
            break;
        }
        if (port > 0 && port < 65536 && own > 0 && own < 65536) {
            ports[port_count] = (uint16_t)port;
            own_ports[port_count] = (uint16_t)own;
            port_count++;
        }
        c = *end == ',' ? end + 1 : end;
    }
}

static bool is_local(const struct sockaddr *address, bool listening) {
    if (address->sa_family == AF_INET) {
        in_addr_t host = ntohl(((const struct sockaddr_in *)address)->sin_addr.s_addr);
        return (host >> 24) == 127 || (listening && host == INADDR_ANY);
    }
    const struct in6_addr *host = &((const struct sockaddr_in6 *)address)->sin6_addr;
    return IN6_IS_ADDR_LOOPBACK(host) || (listening && IN6_IS_ADDR_UNSPECIFIED(host))
        || (IN6_IS_ADDR_V4MAPPED(host) && host->s6_addr[12] == 127);
}

// `address` with the copy's own port, in `copy`, when it's one of the app's
// known ports on this Mac; NULL otherwise.
static const struct sockaddr *remapped(const struct sockaddr *address, socklen_t length,
                                       struct sockaddr_storage *copy, bool listening) {
    // Only once the library is set up (a call made while it sets up finds
    // nothing to remap, and doesn't settle that for good).
    if (!atomic_load(&ready)) {
        if (!parallex_home_settled()) {
            return NULL;
        }
        pthread_mutex_lock(&setup);
        if (!atomic_load(&ready)) {
            prepare();
            atomic_store(&ready, true);
        }
        pthread_mutex_unlock(&setup);
    }
    if (port_count == 0 || address == NULL) {
        return NULL;
    }
    uint16_t port;
    if (address->sa_family == AF_INET && length >= (socklen_t)sizeof(struct sockaddr_in)) {
        port = ntohs(((const struct sockaddr_in *)address)->sin_port);
    } else if (address->sa_family == AF_INET6 && length >= (socklen_t)sizeof(struct sockaddr_in6)) {
        port = ntohs(((const struct sockaddr_in6 *)address)->sin6_port);
    } else {
        return NULL;
    }
    int found = -1;
    for (unsigned index = 0; index < port_count && found < 0; index++) {
        if (ports[index] == port) {
            found = (int)index;
        }
    }
    if (found < 0 || !is_local(address, listening) || (size_t)length > sizeof(*copy)) {
        return NULL;
    }
    memcpy(copy, address, (size_t)length);
    uint16_t own = htons(own_ports[found]);
    if (address->sa_family == AF_INET) {
        ((struct sockaddr_in *)copy)->sin_port = own;
    } else {
        ((struct sockaddr_in6 *)copy)->sin6_port = own;
    }
    return (const struct sockaddr *)copy;
}

static int parallex_bind(int socket, const struct sockaddr *address, socklen_t length) {
    struct sockaddr_storage copy;
    const struct sockaddr *own = remapped(address, length, &copy, true);
    return bind(socket, own != NULL ? own : address, length);
}

static int parallex_connect(int socket, const struct sockaddr *address, socklen_t length) {
    struct sockaddr_storage copy;
    const struct sockaddr *own = remapped(address, length, &copy, false);
    return connect(socket, own != NULL ? own : address, length);
}

extern int connect_nocancel(int socket, const struct sockaddr *address, socklen_t length) __asm("_connect$NOCANCEL");

static int parallex_connect_nocancel(int socket, const struct sockaddr *address, socklen_t length) {
    struct sockaddr_storage copy;
    const struct sockaddr *own = remapped(address, length, &copy, false);
    return connect_nocancel(socket, own != NULL ? own : address, length);
}

INTERPOSE(parallex_bind, bind);
INTERPOSE(parallex_connect, connect);
INTERPOSE(parallex_connect_nocancel, connect_nocancel);
