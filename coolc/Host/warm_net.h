// Host socket services for Warm's scalar OS boundary (IPv4).
#include <arpa/inet.h>
#include <netdb.h>
#include <poll.h>
#include <fcntl.h>
#include <sys/socket.h>

typedef struct {int fd; int64_t source, port;} WarmHostSocket;
static int64_t warm_net_error(void) {
    switch (errno) {
    case ETIMEDOUT: case EAGAIN: return -17; case ECONNREFUSED: return -18;
    case ECONNRESET: case EPIPE: return -19;
    case EHOSTUNREACH: case ENETUNREACH: return -20;
    case EINTR: return -21; case EADDRINUSE: return -11;
    case EACCES: case EPERM: return -13; default: return -1;
    }
}
static int warm_net_fd(int type) {
    int fd = socket(AF_INET, type, 0);
    if (fd < 0) return fd;
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
    return fd;
}
static int64_t warm_net_wait(int fd, short events, int64_t timeout) {
    struct pollfd p = {.fd=fd, .events=events};
    int r = poll(&p, 1, timeout < 0 ? -1 : timeout > INT_MAX ? INT_MAX : (int)timeout);
    if (r < 0) return warm_net_error();
    if (!r) return -17;
    return 0;
}
static int64_t warm_net_handle(int fd) {
    WarmHostSocket *s = host_calloc(sizeof(*s), NULL);
    s->fd = fd; return (intptr_t)s;
}
static struct sockaddr_in warm_net_addr(int64_t ip, int64_t port) {
    struct sockaddr_in a = {.sin_family=AF_INET, .sin_port=htons((uint16_t)port)};
    a.sin_addr.s_addr = htonl((uint32_t)ip); return a;
}
static int64_t warm_net_resolve(const char *host) {
    struct addrinfo hints = {.ai_family=AF_INET, .ai_socktype=SOCK_STREAM}, *result;
    if (getaddrinfo(host, NULL, &hints, &result)) return -20;
    int64_t ip = ntohl(((struct sockaddr_in *)result->ai_addr)->sin_addr.s_addr);
    freeaddrinfo(result); return ip;
}
static int64_t warm_net_connect(int64_t ip, int64_t port, int64_t timeout) {
    int fd = warm_net_fd(SOCK_STREAM);
    if (fd < 0) return warm_net_error();
    fcntl(fd, F_SETFL, O_NONBLOCK);
    struct sockaddr_in a = warm_net_addr(ip, port);
    int r = connect(fd, (struct sockaddr *)&a, sizeof(a));
    if (r && errno != EINPROGRESS) {int64_t e=warm_net_error();close(fd);return e;}
    if (r) {
        int64_t e=warm_net_wait(fd, POLLOUT, timeout);
        if (e) {close(fd);return e;}
        int error=0; socklen_t len=sizeof(error);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len) || error) {
            if(error)errno=error;
            e=warm_net_error();close(fd);return e;
        }
    }
    return warm_net_handle(fd);
}
static int64_t warm_net_listen(int64_t port) {
    int fd=warm_net_fd(SOCK_STREAM);
    if(fd<0)return warm_net_error();
    struct sockaddr_in a=warm_net_addr(0,port);
    if(bind(fd,(struct sockaddr *)&a,sizeof(a)) || listen(fd,16)) {
        int64_t e=warm_net_error();close(fd);return e;
    }
    fcntl(fd,F_SETFL,O_NONBLOCK);
    return warm_net_handle(fd);
}
static int64_t warm_net_accept(WarmHostSocket *s,int64_t timeout) {
    int64_t e=warm_net_wait(s->fd,POLLIN,timeout);if(e)return e;
    int fd=accept(s->fd,NULL,NULL);if(fd<0)return warm_net_error();
    fcntl(fd,F_SETFL,O_NONBLOCK);
#ifdef SO_NOSIGPIPE
    int one=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
#endif
    return warm_net_handle(fd);
}
static int64_t warm_net_send(WarmHostSocket *s,const void *data,int64_t len) {
    if(!len)return 0;
    int64_t e=warm_net_wait(s->fd,POLLOUT,30000);if(e)return e;
    ssize_t n=send(s->fd,data,(size_t)len,0);
    return n<0?warm_net_error():n;
}
static int64_t warm_net_receive(WarmHostSocket *s,void *data,int64_t len,int64_t timeout) {
    if(!len)return 0;
    int64_t e=warm_net_wait(s->fd,POLLIN,timeout);if(e)return e;
    ssize_t n=recv(s->fd,data,(size_t)len,0);
    return n<0?warm_net_error():n;
}
static int64_t warm_net_udp_open(int64_t port) {
    int fd=warm_net_fd(SOCK_DGRAM);if(fd<0)return warm_net_error();
    struct sockaddr_in a=warm_net_addr(0,port);
    if(bind(fd,(struct sockaddr *)&a,sizeof(a))) {int64_t e=warm_net_error();close(fd);return e;}
    fcntl(fd,F_SETFL,O_NONBLOCK);return warm_net_handle(fd);
}
static int64_t warm_net_udp_send(WarmHostSocket *s,int64_t ip,int64_t port,const void *data,int64_t len) {
    struct sockaddr_in a=warm_net_addr(ip,port);
    ssize_t n=sendto(s->fd,data,(size_t)len,0,(struct sockaddr *)&a,sizeof(a));
    return n<0?warm_net_error():n;
}
static int64_t warm_net_udp_receive(WarmHostSocket *s,void *data,int64_t len,int64_t timeout) {
    int64_t e=warm_net_wait(s->fd,POLLIN,timeout);if(e)return e;
    struct sockaddr_in a;socklen_t count=sizeof(a);
    ssize_t n=recvfrom(s->fd,data,(size_t)len,0,(struct sockaddr *)&a,&count);
    if(n<0)return warm_net_error();
    s->source=ntohl(a.sin_addr.s_addr);s->port=ntohs(a.sin_port);return n;
}
static int64_t warm_net_source(WarmHostSocket *s) {return s->source;}
static int64_t warm_net_port(WarmHostSocket *s) {
    struct sockaddr_in a;socklen_t count=sizeof(a);
    if(getsockname(s->fd,(struct sockaddr *)&a,&count))return warm_net_error();
    return ntohs(a.sin_port);
}
static int64_t warm_net_source_port(WarmHostSocket *s) {return s->port;}
static int64_t warm_net_close(WarmHostSocket *s) {
    int r=close(s->fd);int64_t e=r?warm_net_error():0;host_free(s);return e;
}
