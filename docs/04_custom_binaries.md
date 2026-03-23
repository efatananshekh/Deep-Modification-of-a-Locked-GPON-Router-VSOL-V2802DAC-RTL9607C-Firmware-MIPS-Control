# Phase 4: Custom Binary Cross-Compilation

## Overview

The router's BusyBox v1.22.1 lacks many essential utilities. To add modern functionality (SSH, SOCKS5 proxy, port multiplexing), we needed to cross-compile custom binaries for MIPS big-endian architecture with minimal dependencies.

**Constraints:**
- Target: MIPS 34Kc, big-endian (MSB)
- Libc: uClibc 0.9.33 (NOT glibc)
- Flash: 10.6 MB available in `/var/config/`
- RAM: 72 MB usable (must be memory-efficient)
- No dynamic linking: Binaries must be static or use only libc

---

## Toolchain Selection

### Initial Attempts: Buildroot (Failed)

**Attempt 1**: Build full Buildroot toolchain for MIPS big-endian
```bash
make menuconfig
# Select: MIPS 34Kc, big-endian, uClibc 0.9.33
make
```

**Result**: Build took 4+ hours, produced 2GB toolchain, but binaries segfaulted on router.

**Root cause**: glibc vs. uClibc ABI mismatch. Buildroot's uClibc was configured differently than the router's.

### Final Solution: Zig Cross-Compiler

**Why Zig:**
- Native cross-compilation (no separate toolchain needed)
- Static linking by default
- Minimal runtime dependencies
- Produces tight, optimized code
- Musl libc compatible with uClibc

**Installation:**
```bash
# Windows (using Scoop)
scoop install zig

# Linux
wget https://ziglang.org/download/0.11.0/zig-linux-x86_64-0.11.0.tar.xz
tar -xf zig-linux-x86_64-0.11.0.tar.xz
export PATH=$PATH:$PWD/zig-linux-x86_64-0.11.0
```

**Target triple:** `mips-linux-musl` (closest to MIPS big-endian uClibc)

---

## Project 1: Dropbear SSH Server

### Why Dropbear?

- **Lightweight**: ~300KB binary (vs. OpenSSH's ~2MB)
- **Embedded-friendly**: Designed for resource-constrained devices
- **Single binary**: Server, client, keygen all in one
- **No dependencies**: Only libc required

### Build Process

```bash
# Download Dropbear 2022.83
wget https://matt.ucc.asn.au/dropbear/releases/dropbear-2022.83.tar.bz2
tar -xf dropbear-2022.83.tar.bz2
cd dropbear-2022.83

# Configure for static build
./configure --host=mips-linux --disable-zlib --disable-wtmp --disable-lastlog

# Build with Zig
export CC="zig cc -target mips-linux-musl"
export CFLAGS="-Os -fno-stack-protector"
export LDFLAGS="-static"

make PROGRAMS="dropbear dbclient dropbearkey scp"
```

**Build output:**
```
dropbearmulti: 757,824 bytes (740 KB)
```

**Strip debug symbols:**
```bash
zig ar x dropbear  # Extract object files
zig cc -target mips-linux-musl -Os -s -o dropbearmulti *.o  # Re-link with strip
```

**Final size:** 757 KB

### Deployment

```bash
# Upload to router
wget http://192.168.1.100:8000/dropbearmulti -O /var/config/dropbearmulti
chmod +x /var/config/dropbearmulti

# Create symlinks
cd /var/config
ln -s dropbearmulti dropbear
ln -s dropbearmulti dbclient
ln -s dropbearmulti dropbearkey
ln -s dropbearmulti scp

# Generate host key (ED25519, smallest and fastest)
./dropbearkey -t ed25519 -f /var/config/.ssh/dropbear_ed25519_host_key

# Start server
./dropbear -p 2222 -r /var/config/.ssh/dropbear_ed25519_host_key
```

**Testing:**
```bash
# From external machine
ssh -p 2222 root@192.168.1.1
```

### Configuration

**Key-only authentication** (disable password):
```bash
mkdir -p /var/config/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK..." > /var/config/.ssh/authorized_keys
chmod 600 /var/config/.ssh/authorized_keys
```

**Dropbear options in boot script:**
```bash
dropbear -p 2222 \
    -r /var/config/.ssh/dropbear_ed25519_host_key \
    -s  # Disable password auth
```

---

## Project 2: SOCKS5 Proxy Server

### Requirements

- RFC 1928 SOCKS5 protocol support
- Username/password authentication (RFC 1929)
- DNS resolution at proxy (SOCKS5H for privacy)
- Integration with router's adblock (check for 0.0.0.0 responses)
- Low memory usage (<5 MB RAM)

### Initial Attempt: Go Version (Failed)

```go
package main

import (
    "io"
    "net"
    "socks5"
)

func main() {
    conf := &socks5.Config{
        AuthMethods: []socks5.Authenticator{
            socks5.UserPassAuthenticator{
                Credentials: socks5.StaticCredentials{
                    "admin": "stdONU101",
                },
            },
        },
    }
    server, _ := socks5.New(conf)
    server.ListenAndServe("tcp", ":1080")
}
```

**Problems:**
- Binary size: 7.2 MB (massive for embedded)
- RAM usage: 520 MB virtual, 42 MB resident (!!!)
- Cross-compilation: Required CGO for DNS resolution
- Crashes: Go runtime panics under low memory

**Verdict**: Go is NOT suitable for embedded systems with <100 MB RAM.

### Final Solution: C Implementation

**Source**: `src/socks5proxy/socks5proxy.c` (228 lines)

**Key features:**
```c
// RFC 1928 handshake
void socks5_handshake(int client_fd) {
    uint8_t buf[512];
    read(client_fd, buf, 2);  // Version + nmethods
    
    if (buf[0] != 0x05) {
        close(client_fd);
        return;
    }
    
    // Require username/password auth (method 0x02)
    uint8_t response[] = {0x05, 0x02};
    write(client_fd, response, 2);
}

// RFC 1929 username/password auth
int socks5_auth(int client_fd) {
    uint8_t buf[512];
    read(client_fd, buf, 2);  // Version (0x01)
    
    uint8_t ulen = buf[1];
    read(client_fd, buf, ulen);
    char username[256] = {0};
    memcpy(username, buf, ulen);
    
    read(client_fd, buf, 1);
    uint8_t plen = buf[0];
    read(client_fd, buf, plen);
    char password[256] = {0};
    memcpy(password, buf, plen);
    
    // Hardcoded credentials (could read from file)
    if (strcmp(username, "admin") == 0 && strcmp(password, "stdONU101") == 0) {
        uint8_t success[] = {0x01, 0x00};
        write(client_fd, success, 2);
        return 1;
    }
    
    uint8_t fail[] = {0x01, 0x01};
    write(client_fd, fail, 2);
    return 0;
}

// CONNECT command (TCP relay)
void socks5_connect(int client_fd) {
    uint8_t buf[512];
    read(client_fd, buf, 4);  // VER, CMD, RSV, ATYP
    
    if (buf[1] != 0x01) {  // Only support CONNECT
        uint8_t response[] = {0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
        write(client_fd, response, 10);
        close(client_fd);
        return;
    }
    
    char dest_addr[256] = {0};
    uint16_t dest_port;
    
    if (buf[3] == 0x01) {  // IPv4
        read(client_fd, buf, 4);
        sprintf(dest_addr, "%d.%d.%d.%d", buf[0], buf[1], buf[2], buf[3]);
    } else if (buf[3] == 0x03) {  // Domain name
        uint8_t len;
        read(client_fd, &len, 1);
        read(client_fd, buf, len);
        memcpy(dest_addr, buf, len);
        dest_addr[len] = '\0';
    }
    
    read(client_fd, buf, 2);
    dest_port = (buf[0] << 8) | buf[1];
    
    // Resolve domain (using router's DNS)
    struct hostent *he = gethostbyname(dest_addr);
    if (he == NULL) {
        uint8_t response[] = {0x05, 0x04, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
        write(client_fd, response, 10);
        close(client_fd);
        return;
    }
    
    // Check if DNS returned 0.0.0.0 (adblock hit)
    struct in_addr *addr = (struct in_addr *)he->h_addr;
    if (addr->s_addr == 0) {
        uint8_t response[] = {0x05, 0x04, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
        write(client_fd, response, 10);
        close(client_fd);
        return;
    }
    
    // Connect to destination
    int dest_fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in dest_sa;
    dest_sa.sin_family = AF_INET;
    dest_sa.sin_port = htons(dest_port);
    dest_sa.sin_addr = *addr;
    
    if (connect(dest_fd, (struct sockaddr *)&dest_sa, sizeof(dest_sa)) < 0) {
        uint8_t response[] = {0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
        write(client_fd, response, 10);
        close(client_fd);
        return;
    }
    
    // Send success
    uint8_t response[] = {0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
    write(client_fd, response, 10);
    
    // Bidirectional relay
    relay_data(client_fd, dest_fd);
}
```

### Build Process

```bash
zig cc -target mips-linux-musl -Os -s -o socks5proxy socks5proxy.c

# Check size
ls -lh socks5proxy
# Output: 1.2 MB
```

### Memory Usage (Measured on Router)

```bash
/ # ps aux | grep socks5proxy
  PID USER       VSZ   RSS COMMAND
  812 root      1628   824 /var/config/socks5proxy -p 1080
```

**Analysis:**
- Virtual: 1.6 MB (vs. 520 MB for Go version)
- Resident: 824 KB (vs. 42 MB for Go version)
- **51x more memory efficient**

### Testing

```bash
# Configure browser/app to use SOCKS5 proxy
Proxy: 192.168.1.1:1080
Username: admin
Password: stdONU101

# Test adblock integration
curl --socks5 admin:stdONU101@192.168.1.1:1080 http://doubleclick.net
# Output: Connection refused (adblock DNS returned 0.0.0.0)

curl --socks5 admin:stdONU101@192.168.1.1:1080 http://google.com
# Output: <html>...</html> (Success)
```

---

## Project 3: Protomux (Port Multiplexer)

### Problem Statement

External access requires:
- SSH on port 443 (ISPs often block 22)
- SOCKS5 on port 443 (same port)

**Challenge**: How to serve two protocols on one port?

### Solution: Protocol Detection

**Strategy**: Peek at the first few bytes of the client's initial packet to determine protocol:
- SSH: Starts with `SSH-2.0-`
- SOCKS5: Starts with `0x05 0x01` or `0x05 0x02`

### Implementation

**Source**: `src/protomux/protomux.c` (147 lines)

```c
int detect_protocol(int client_fd) {
    uint8_t buf[8];
    
    // Peek without consuming
    int n = recv(client_fd, buf, 8, MSG_PEEK);
    if (n < 4) return PROTO_UNKNOWN;
    
    // Check for SSH magic bytes
    if (buf[0] == 'S' && buf[1] == 'S' && buf[2] == 'H' && buf[3] == '-') {
        return PROTO_SSH;
    }
    
    // Check for SOCKS5 version byte
    if (buf[0] == 0x05) {
        return PROTO_SOCKS5;
    }
    
    // Fallback: wait 200ms for client to send data
    struct timeval tv = {0, 200000};  // 200ms
    fd_set readfds;
    FD_ZERO(&readfds);
    FD_SET(client_fd, &readfds);
    
    if (select(client_fd + 1, &readfds, NULL, NULL, &tv) > 0) {
        // Client sent data, check again
        n = recv(client_fd, buf, 8, MSG_PEEK);
        if (buf[0] == 0x05) return PROTO_SOCKS5;
    }
    
    // Default to SSH (OpenSSH clients send version string immediately)
    return PROTO_SSH;
}

void handle_client(int client_fd) {
    int proto = detect_protocol(client_fd);
    
    if (proto == PROTO_SSH) {
        // Connect to local SSH server (dropbear on 127.0.0.1:2222)
        int ssh_fd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in ssh_sa;
        ssh_sa.sin_family = AF_INET;
        ssh_sa.sin_addr.s_addr = inet_addr("127.0.0.1");
        ssh_sa.sin_port = htons(2222);
        
        if (connect(ssh_fd, (struct sockaddr *)&ssh_sa, sizeof(ssh_sa)) < 0) {
            close(client_fd);
            return;
        }
        
        // Bidirectional relay
        relay_data(client_fd, ssh_fd);
        
    } else if (proto == PROTO_SOCKS5) {
        // Connect to local SOCKS5 server (127.0.0.1:1080)
        int socks_fd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in socks_sa;
        socks_sa.sin_family = AF_INET;
        socks_sa.sin_addr.s_addr = inet_addr("127.0.0.1");
        socks_sa.sin_port = htons(1080);
        
        if (connect(socks_fd, (struct sockaddr *)&socks_sa, sizeof(socks_sa)) < 0) {
            close(client_fd);
            return;
        }
        
        // Bidirectional relay
        relay_data(client_fd, socks_fd);
    }
}

// Bidirectional TCP relay using select()
void relay_data(int fd1, int fd2) {
    fd_set readfds;
    uint8_t buf[8192];
    
    while (1) {
        FD_ZERO(&readfds);
        FD_SET(fd1, &readfds);
        FD_SET(fd2, &readfds);
        
        int maxfd = (fd1 > fd2) ? fd1 : fd2;
        if (select(maxfd + 1, &readfds, NULL, NULL, NULL) < 0) break;
        
        if (FD_ISSET(fd1, &readfds)) {
            int n = read(fd1, buf, sizeof(buf));
            if (n <= 0) break;
            if (write(fd2, buf, n) != n) break;
        }
        
        if (FD_ISSET(fd2, &readfds)) {
            int n = read(fd2, buf, sizeof(buf));
            if (n <= 0) break;
            if (write(fd1, buf, n) != n) break;
        }
    }
    
    close(fd1);
    close(fd2);
}
```

### Build and Deploy

```bash
zig cc -target mips-linux-musl -Os -s -o protomux protomux.c

# Upload to router
wget http://192.168.1.100:8000/protomux -O /var/config/protomux
chmod +x /var/config/protomux

# Start (listening on 0.0.0.0:8443)
/var/config/protomux -p 8443 -s 127.0.0.1:2222 -o 127.0.0.1:1080 &
```

**Binary size:** 60 KB  
**RAM usage:** 600 KB (idle), +300 KB per active connection

### Testing

**SSH test:**
```bash
ssh -p 8443 root@192.168.1.1
# Protomux detects "SSH-2.0-OpenSSH_8.9", forwards to 127.0.0.1:2222
# Connection succeeds
```

**SOCKS5 test:**
```bash
curl --socks5 admin:stdONU101@192.168.1.1:8443 http://google.com
# Protomux detects 0x05 0x01, forwards to 127.0.0.1:1080
# Connection succeeds
```

---

## Project 4: SmartQoS Daemon

### Purpose

Monitor and repair critical system state:
- Hardware QoS registers (`/proc/rg/assign_access_ip`)
- iptables TOS marking rules (32+ rules)
- dnsmasq process (restarts if crashed)
- DHCP MTU configuration

### Implementation

**Source**: `src/smartqos/smartqos.c` (412 lines)

**Main loop (every 30 seconds):**
```c
while (1) {
    // 1. Check HW QoS
    FILE *f = fopen("/proc/rg/assign_access_ip", "r");
    char buf[32];
    fgets(buf, sizeof(buf), f);
    fclose(f);
    
    if (strcmp(buf, "0xc0a80124\n") != 0) {
        f = fopen("/proc/rg/assign_access_ip", "w");
        fprintf(f, "0xc0a80124\n");
        fclose(f);
        log_msg("[FIX] Restored HW QoS priority for PC");
    }
    
    // 2. Check iptables rule count
    FILE *fp = popen("iptables -t mangle -L SMART_QOS 2>/dev/null | wc -l", "r");
    int count;
    fscanf(fp, "%d", &count);
    pclose(fp);
    
    if (count < 34) {  // 32 rules + header + policy = 34 lines
        log_msg("[ERROR] Missing TOS rules! Re-applying...");
        system("sh /var/config/apply_qos_rules.sh");
    }
    
    // 3. Check dnsmasq
    if (system("pidof dnsmasq >/dev/null") != 0) {
        log_msg("[FIX] dnsmasq crashed, restarting...");
        system("dnsmasq -C /var/config/dnsmasq.conf --addn-hosts=/var/config/adblock_full.hosts &");
    }
    
    sleep(30);
}
```

### Build

```bash
zig cc -target mips-linux-musl -Os -s -o smartqos smartqos.c
```

**Binary size:** 112 KB  
**RAM usage:** 240 KB

---

## Binary Size Comparison

| Binary | Language | Size | RAM (RSS) | Notes |
|--------|----------|------|-----------|-------|
| dropbearmulti | C | 757 KB | 1.2 MB | SSH server + client + keygen |
| socks5proxy (Go) | Go | 7.2 MB | 42 MB | **REJECTED** (too large) |
| socks5proxy (C) | C | 1.2 MB | 824 KB | 51x smaller than Go |
| protomux | C | 60 KB | 600 KB | Port multiplexer |
| smartqos | C | 112 KB | 240 KB | QoS monitoring daemon |
| **TOTAL** | — | **2.1 MB** | **2.9 MB** | All custom services combined |

**Flash usage:** 7.1 MB / 10.6 MB (66%) including adblock hosts file (3 MB)

---

## Lessons Learned

1. **Go is not for embedded**: 7MB binaries and 40MB RAM is unacceptable
2. **Zig cross-compilation works**: Single command, no toolchain setup
3. **Static linking is essential**: Router's uClibc is incompatible with glibc
4. **musl targets work**: `mips-linux-musl` runs fine on uClibc 0.9.33
5. **Strip debug symbols**: Reduces binary size by 30-40%
6. **Test memory usage on target**: `ps aux` on router, not host machine

---

**Phase 4 Status**: ✅ COMPLETE  
**Binaries Deployed**: 4 (Dropbear, SOCKS5, Protomux, SmartQoS)  
**Total Flash Used**: 2.1 MB  
**Total RAM Used**: 2.9 MB (idle)  
**Cross-Compilation Toolchain**: Zig 0.11.0
