#ifndef C_LOOPBACK_SOCKET_H
#define C_LOOPBACK_SOCKET_H

#include <stdint.h>

/// Binds a TCP socket to 127.0.0.1 on a kernel-assigned port and starts listening.
///
/// The address handling lives here rather than in Swift because it is what C is for:
/// composing a `sockaddr_in` and handing its address to `bind` requires pointer casts that
/// are unremarkable in C and, in Swift, are indistinguishable from a pointer outliving its
/// buffer.
///
/// @return A listening descriptor, or -1. The caller owns it and must close it.
int clb_listen_on_loopback(void);

/// The port a descriptor is bound to.
///
/// @return The port in host byte order, or 0 if it could not be read.
uint16_t clb_bound_port(int descriptor);

#endif /* C_LOOPBACK_SOCKET_H */
