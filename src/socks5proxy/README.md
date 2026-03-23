# SOCKS5 Proxy Server

## Overview
RFC 1928/1929 compliant SOCKS5 proxy with username/password authentication. Integrates with dnsmasq adblock by checking for 0.0.0.0 DNS responses.

## Build Instructions

```bash
zig cc -target mips-linux-musl -Os -s -o socks5proxy socks5proxy.c
```

Expected binary size: ~1.2 MB

## Features

- RFC 1928 SOCKS5 protocol
- RFC 1929 username/password authentication
- IPv4 and domain name support (ATYP 0x01 and 0x03)
- Remote DNS resolution (SOCKS5H compatible)
- Adblock integration (blocks connections to domains resolving to 0.0.0.0)
- Low memory footprint (~800 KB RSS)

## Deployment

```bash
# Upload to router
scp -P 2222 socks5proxy root@192.168.1.1:/var/config/

# Make executable
ssh -p 2222 root@192.168.1.1 "chmod +x /var/config/socks5proxy"

# Start with credentials
ssh -p 2222 root@192.168.1.1 "/var/config/socks5proxy -p 1080 -u admin -w stdONU101 &"
```

## Usage

```bash
./socks5proxy [-p port] [-u username] [-w password]

Options:
  -p PORT       Port to listen on (default: 1080)
  -u USERNAME   Required username (default: admin)
  -w PASSWORD   Required password (default: stdONU101)
```

## Testing

**curl test:**
```bash
curl --socks5 admin:stdONU101@192.168.1.1:1080 http://ifconfig.me
# Should return your WAN IP
```

**Browser configuration:**
- Proxy type: SOCKS5
- Host: 192.168.1.1
- Port: 1080
- Username: admin
- Password: stdONU101
- DNS: Remote DNS (SOCKS5H)

**Adblock test:**
```bash
curl --socks5 admin:stdONU101@192.168.1.1:1080 http://doubleclick.net
# Should fail with "Connection refused" (blocked by adblock)
```

## Memory Usage

```bash
ps aux | grep socks5proxy
# Idle: ~800 KB RSS
# Per connection: +500 KB
```

## Integration with Boot Script

```bash
# Start SOCKS5 proxy
/var/config/socks5proxy -p 1080 -u admin -w stdONU101 &

# OOM protection
sleep 1
echo -17 > /proc/$(pidof socks5proxy)/oom_adj
```

## Security Notes

- Change default credentials in production
- Consider IP whitelisting via iptables if not using for external access
- Authentication is plaintext over the wire (use SSH tunnel for sensitive traffic)

## Source Code Placeholder

*Note: Actual implementation is ~228 lines of C. Key functions:*

- `socks5_handshake()` - RFC 1928 negotiation
- `socks5_auth()` - RFC 1929 username/password
- `socks5_connect()` - CONNECT command handler
- `relay_data()` - Bidirectional TCP forwarding
- `check_adblock()` - DNS 0.0.0.0 detection
