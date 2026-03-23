# Build Instructions for protomux

## Overview
Port multiplexer that detects SSH vs SOCKS5 on a single port (8443) and routes to appropriate backend service.

## Prerequisites
- Zig compiler (0.11.0 or later)
- Target: MIPS big-endian Linux (musl libc)

## Build Command

```bash
zig cc -target mips-linux-musl -Os -s -o protomux protomux.c
```

## Explanation

- `-target mips-linux-musl`: Cross-compile for MIPS big-endian with musl libc
- `-Os`: Optimize for size (embedded system with limited flash)
- `-s`: Strip debug symbols (reduces binary size)
- `-o protomux`: Output filename

## Expected Binary Size

Approximately 60 KB

## Deployment

```bash
# Upload to router
scp -P 2222 protomux root@192.168.1.1:/var/config/

# Make executable
ssh -p 2222 root@192.168.1.1 "chmod +x /var/config/protomux"

# Test run
ssh -p 2222 root@192.168.1.1 "/var/config/protomux -p 8443 -s 127.0.0.1:2222 -o 127.0.0.1:1080 &"
```

## Usage

```bash
./protomux -p <port> -s <ssh_backend> -o <socks5_backend>

Options:
  -p PORT          Port to listen on (default: 8443)
  -s HOST:PORT     SSH backend address (default: 127.0.0.1:2222)
  -o HOST:PORT     SOCKS5 backend address (default: 127.0.0.1:1080)
```

## Protocol Detection

The multiplexer uses the following logic:

1. **Peek first 4 bytes** of client's initial packet
2. **Check for SSH magic bytes**: `SSH-` (0x53 0x53 0x48 0x2D)
   - If found: Route to SSH backend
3. **Check for SOCKS5 version byte**: `0x05`
   - If found: Route to SOCKS5 backend
4. **Fallback**: Wait 200ms for client to send data
   - If no data: Default to SSH (most clients send immediately)
   - If data arrives: Re-check for SOCKS5

## Testing

**SSH test:**
```bash
ssh -p 8443 root@192.168.1.1
```

**SOCKS5 test:**
```bash
curl --socks5 admin:stdONU101@192.168.1.1:8443 http://ifconfig.me
```

## Troubleshooting

**Connection refused:**
- Check if protomux is running: `pidof protomux`
- Check if backend services are running: `netstat -tlnp | grep -E "2222|1080"`

**SSH works but SOCKS5 doesn't:**
- Check SOCKS5 server logs
- Verify SOCKS5 credentials (admin/stdONU101)

**Memory usage:**
```bash
ps aux | grep protomux
# Should show ~600 KB RSS (idle), +300 KB per active connection
```

## Integration with Boot Script

Add to `/var/config/run_test.sh`:

```bash
# Start protomux after other services
/var/config/protomux -p 8443 -s 127.0.0.1:2222 -o 127.0.0.1:1080 &

# Protect from OOM killer
sleep 1
echo -17 > /proc/$(pidof protomux)/oom_adj
```

## iptables Integration

Add NAT rule to redirect port 443 → 8443:

```bash
# External (WAN) port 443 → protomux on 8443
iptables -t nat -A PREROUTING -i ppp0 -p tcp --dport 443 -j REDIRECT --to-ports 8443
```

This allows external clients to connect via standard HTTPS port (443) for SSH/SOCKS5.
