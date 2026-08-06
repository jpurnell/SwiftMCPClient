#include "include/CLoopbackSocket.h"

#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <string.h>

int clb_listen_on_loopback(void) {
    int descriptor = socket(AF_INET, SOCK_STREAM, 0);
    if (descriptor < 0) {
        return -1;
    }

    int reuse = 1;
    setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    /* Port 0: the kernel assigns a free one. RFC 8252 §7.3 requires the authorization
       server to accept any port on the loopback address, so it need not be fixed. */
    address.sin_port = 0;
    /* INADDR_LOOPBACK, never INADDR_ANY. Nothing off this machine can reach it. */
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_len = sizeof(address);

    if (bind(descriptor, (const struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(descriptor, 1) != 0) {
        close(descriptor);
        return -1;
    }
    return descriptor;
}

uint16_t clb_bound_port(int descriptor) {
    struct sockaddr_in address;
    socklen_t length = sizeof(address);
    if (getsockname(descriptor, (struct sockaddr *)&address, &length) != 0) {
        return 0;
    }
    return ntohs(address.sin_port);
}
