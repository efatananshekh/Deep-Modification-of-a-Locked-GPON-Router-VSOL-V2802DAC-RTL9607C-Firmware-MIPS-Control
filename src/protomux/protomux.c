#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <errno.h>
#include <signal.h>

#define BUFFER_SIZE 4096

int connect_local(int port) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return -1;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect");
        close(sock);
        return -1;
    }
    return sock;
}

void forward_loop(int client_fd, int target_fd) {
    char buffer[BUFFER_SIZE];
    fd_set fds;
    int max_fd = (client_fd > target_fd) ? client_fd : target_fd;

    while (1) {
        FD_ZERO(&fds);
        FD_SET(client_fd, &fds);
        FD_SET(target_fd, &fds);

        if (select(max_fd + 1, &fds, NULL, NULL, NULL) < 0) {
            if (errno == EINTR) continue;
            break;
        }

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

int main(int argc, char *argv[]) {
    if (argc < 4) {
        fprintf(stderr, "Usage: %s <listen_port> <ssh_port> <socks_port>\n", argv[0]);
        return 1;
    }

    signal(SIGCHLD, SIG_IGN);

    int listen_port = atoi(argv[1]);
    int ssh_port = atoi(argv[2]);
    int socks_port = atoi(argv[3]);

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
    addr.sin_port = htons(listen_port);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }

    if (listen(server_fd, 10) < 0) {
        perror("listen");
        return 1;
    }

    printf("Protomux (C) on 0.0.0.0:%d -> SSH:%d / SOCKS:%d\n", listen_port, ssh_port, socks_port);

    while (1) {
        struct sockaddr_in client_addr;
        socklen_t len = sizeof(client_addr);
        int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &len);
        
        if (client_fd < 0) continue;

        pid_t pid = fork();
        if (pid == 0) {
            // Child
            close(server_fd);
            
            // Wait for data with timeout
            fd_set rfds;
            struct timeval tv;
            FD_ZERO(&rfds);
            FD_SET(client_fd, &rfds);
            
            // 200ms timeout. If client doesn't speak, assume SSH (server-first).
            // SOCKS5 clients MUST speak first.
            tv.tv_sec = 0;
            tv.tv_usec = 200000; 

            int target_port = ssh_port; // Default to SSH if timeout
            int retval = select(client_fd + 1, &rfds, NULL, NULL, &tv);

            if (retval > 0) {
                // Data available - peek it
                char header[4];
                ssize_t n = recv(client_fd, header, sizeof(header), MSG_PEEK);
                
                // Check for SOCKS5 (version 5)
                if (n >= 2 && header[0] == 0x05) {
                    target_port = socks_port;
                }
                // If it explicitly says SSH-, keep SSH port. 
                // Any other data -> SSH (safe default for this use case?)
            }
            // else if retval == 0 (timeout), default to SSH

            int target_fd = connect_local(target_port);
            if (target_fd >= 0) {
                forward_loop(client_fd, target_fd);
                close(target_fd);
            }
            
            close(client_fd);
            exit(0);
        }
        
        // Parent
        close(client_fd);
        // Wait for children to avoid zombie accumulation? No, SIG_IGN handles it.
    }
    
    return 0;
}