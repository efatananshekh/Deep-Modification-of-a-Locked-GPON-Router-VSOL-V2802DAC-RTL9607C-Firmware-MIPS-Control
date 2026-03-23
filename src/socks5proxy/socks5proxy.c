/* socks5proxy.c - Lightweight SOCKS5 proxy with username/password auth
 * For MIPS routers with limited resources
 * Compile: zig cc -target mips-linux-musl -O2 -o socks5proxy socks5proxy.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <signal.h>
#include <errno.h>

#define BUFFER_SIZE 8192

static char g_user[64] = "admin";
static char g_pass[64] = "stdONU101";

/* Relay data bidirectionally */
void relay(int client_fd, int target_fd) {
    char buffer[BUFFER_SIZE];
    fd_set fds;
    int max_fd = (client_fd > target_fd) ? client_fd : target_fd;
    
    while (1) {
        FD_ZERO(&fds);
        FD_SET(client_fd, &fds);
        FD_SET(target_fd, &fds);
        
        struct timeval tv = {300, 0}; /* 5 min timeout */
        int ret = select(max_fd + 1, &fds, NULL, NULL, &tv);
        if (ret <= 0) break;
        
        if (FD_ISSET(client_fd, &fds)) {
            ssize_t n = read(client_fd, buffer, sizeof(buffer));
            if (n <= 0) break;
            if (write(target_fd, buffer, n) != n) break;
        }
        
        if (FD_ISSET(target_fd, &fds)) {
            ssize_t n = read(target_fd, buffer, sizeof(buffer));
            if (n <= 0) break;
            if (write(client_fd, buffer, n) != n) break;
        }
    }
}

/* Read exactly n bytes */
int read_full(int fd, void *buf, size_t n) {
    size_t total = 0;
    while (total < n) {
        ssize_t r = read(fd, (char*)buf + total, n - total);
        if (r <= 0) return -1;
        total += r;
    }
    return 0;
}

/* Send SOCKS5 reply */
void send_reply(int fd, unsigned char status) {
    unsigned char reply[10] = {0x05, status, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
    write(fd, reply, 10);
}

/* Handle one client connection */
void handle_client(int client_fd) {
    unsigned char buf[512];
    
    /* Set socket timeout */
    struct timeval tv = {30, 0};
    setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    
    /* SOCKS5 greeting: VER + NMETHODS + METHODS */
    if (read_full(client_fd, buf, 2) < 0 || buf[0] != 0x05) {
        close(client_fd);
        return;
    }
    
    int nmethods = buf[1];
    if (nmethods == 0 || nmethods > 255) {
        close(client_fd);
        return;
    }
    
    if (read_full(client_fd, buf + 2, nmethods) < 0) {
        close(client_fd);
        return;
    }
    
    /* Check for username/password auth (0x02) */
    int has_auth = 0;
    for (int i = 0; i < nmethods; i++) {
        if (buf[2 + i] == 0x02) {
            has_auth = 1;
            break;
        }
    }
    
    if (!has_auth) {
        unsigned char no_auth[2] = {0x05, 0xFF};
        write(client_fd, no_auth, 2);
        close(client_fd);
        return;
    }
    
    /* Request username/password auth */
    unsigned char req_auth[2] = {0x05, 0x02};
    write(client_fd, req_auth, 2);
    
    /* Read auth: VER(1) ULEN(1) USER(ULEN) PLEN(1) PASS(PLEN) */
    if (read_full(client_fd, buf, 2) < 0 || buf[0] != 0x01) {
        close(client_fd);
        return;
    }
    
    int ulen = buf[1];
    if (ulen == 0 || ulen > 255) {
        close(client_fd);
        return;
    }
    
    if (read_full(client_fd, buf + 2, ulen + 1) < 0) {
        close(client_fd);
        return;
    }
    
    char user[256];
    memcpy(user, buf + 2, ulen);
    user[ulen] = '\0';
    
    int plen = buf[2 + ulen];
    if (plen == 0 || plen > 255) {
        close(client_fd);
        return;
    }
    
    if (read_full(client_fd, buf + 3 + ulen, plen) < 0) {
        close(client_fd);
        return;
    }
    
    char pass[256];
    memcpy(pass, buf + 3 + ulen, plen);
    pass[plen] = '\0';
    
    /* Verify credentials */
    if (strcmp(user, g_user) != 0 || strcmp(pass, g_pass) != 0) {
        unsigned char auth_fail[2] = {0x01, 0x01};
        write(client_fd, auth_fail, 2);
        close(client_fd);
        return;
    }
    
    /* Auth success */
    unsigned char auth_ok[2] = {0x01, 0x00};
    write(client_fd, auth_ok, 2);
    
    /* Read SOCKS5 request: VER(1) CMD(1) RSV(1) ATYP(1) */
    if (read_full(client_fd, buf, 4) < 0 || buf[0] != 0x05) {
        close(client_fd);
        return;
    }
    
    unsigned char cmd = buf[1];
    unsigned char atyp = buf[3];
    
    if (cmd != 0x01) { /* Only CONNECT supported */
        send_reply(client_fd, 0x07); /* Command not supported */
        close(client_fd);
        return;
    }
    
    /* Parse destination address */
    char host[256];
    uint16_t port;
    
    if (atyp == 0x01) { /* IPv4 */
        if (read_full(client_fd, buf, 6) < 0) {
            close(client_fd);
            return;
        }
        snprintf(host, sizeof(host), "%d.%d.%d.%d", buf[0], buf[1], buf[2], buf[3]);
        port = (buf[4] << 8) | buf[5];
        
    } else if (atyp == 0x03) { /* Domain */
        if (read_full(client_fd, buf, 1) < 0) {
            close(client_fd);
            return;
        }
        int dlen = buf[0];
        if (dlen == 0 || dlen > 253) {
            close(client_fd);
            return;
        }
        if (read_full(client_fd, buf + 1, dlen + 2) < 0) {
            close(client_fd);
            return;
        }
        memcpy(host, buf + 1, dlen);
        host[dlen] = '\0';
        port = (buf[1 + dlen] << 8) | buf[2 + dlen];
        
    } else if (atyp == 0x04) { /* IPv6 */
        if (read_full(client_fd, buf, 18) < 0) {
            close(client_fd);
            return;
        }
        /* Format IPv6 address */
        struct in6_addr addr6;
        memcpy(&addr6, buf, 16);
        inet_ntop(AF_INET6, &addr6, host, sizeof(host));
        port = (buf[16] << 8) | buf[17];
        
    } else {
        send_reply(client_fd, 0x08); /* Address type not supported */
        close(client_fd);
        return;
    }
    
    /* Resolve and connect */
    struct addrinfo hints, *res, *rp;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;  /* Force IPv4 for adblock compatibility */
    hints.ai_socktype = SOCK_STREAM;
    
    char port_str[6];
    snprintf(port_str, sizeof(port_str), "%d", port);
    
    int gai_ret = getaddrinfo(host, port_str, &hints, &res);
    if (gai_ret != 0) {
        send_reply(client_fd, 0x04); /* Host unreachable */
        close(client_fd);
        return;
    }
    
    /* Adblock check: if DNS returns 0.0.0.0, reject (blocked domain) */
    struct sockaddr_in *addr4 = (struct sockaddr_in *)res->ai_addr;
    if (res->ai_family == AF_INET && addr4->sin_addr.s_addr == 0) {
        freeaddrinfo(res);
        send_reply(client_fd, 0x05); /* Connection refused (blocked) */
        close(client_fd);
        return;
    }
    
    int target_fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (target_fd < 0) {
        freeaddrinfo(res);
        send_reply(client_fd, 0x01); /* General failure */
        close(client_fd);
        return;
    }
    
    /* Set connect timeout */
    struct timeval conn_tv = {10, 0};
    setsockopt(target_fd, SOL_SOCKET, SO_SNDTIMEO, &conn_tv, sizeof(conn_tv));
    
    if (connect(target_fd, res->ai_addr, res->ai_addrlen) < 0) {
        freeaddrinfo(res);
        close(target_fd);
        if (errno == ECONNREFUSED) {
            send_reply(client_fd, 0x05); /* Connection refused */
        } else if (errno == ENETUNREACH) {
            send_reply(client_fd, 0x03); /* Network unreachable */
        } else if (errno == EHOSTUNREACH) {
            send_reply(client_fd, 0x04); /* Host unreachable */
        } else {
            send_reply(client_fd, 0x01); /* General failure */
        }
        close(client_fd);
        return;
    }
    
    freeaddrinfo(res);
    
    /* Connection successful */
    send_reply(client_fd, 0x00);
    
    /* Clear timeouts for relay */
    struct timeval no_tv = {0, 0};
    setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &no_tv, sizeof(no_tv));
    setsockopt(target_fd, SOL_SOCKET, SO_RCVTIMEO, &no_tv, sizeof(no_tv));
    setsockopt(target_fd, SOL_SOCKET, SO_SNDTIMEO, &no_tv, sizeof(no_tv));
    
    /* Relay data */
    relay(client_fd, target_fd);
    
    close(target_fd);
    close(client_fd);
}

int main(int argc, char *argv[]) {
    int port = 1080;
    
    /* Parse arguments: socks5proxy [port] [user:pass] */
    for (int i = 1; i < argc; i++) {
        char *arg = argv[i];
        char *colon = strchr(arg, ':');
        if (colon) {
            *colon = '\0';
            strncpy(g_user, arg, sizeof(g_user) - 1);
            strncpy(g_pass, colon + 1, sizeof(g_pass) - 1);
        } else {
            port = atoi(arg);
        }
    }
    
    signal(SIGCHLD, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);
    
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        return 1;
    }
    
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = INADDR_ANY;
    
    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }
    
    if (listen(server_fd, 32) < 0) {
        perror("listen");
        return 1;
    }
    
    printf("SOCKS5 proxy on :%d (auth: %s:***)\n", port, g_user);
    fflush(stdout);
    
    while (1) {
        struct sockaddr_in client_addr;
        socklen_t len = sizeof(client_addr);
        int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &len);
        
        if (client_fd < 0) continue;
        
        pid_t pid = fork();
        if (pid == 0) {
            /* Child process */
            close(server_fd);
            handle_client(client_fd);
            exit(0);
        }
        
        /* Parent */
        close(client_fd);
    }
    
    return 0;
}
