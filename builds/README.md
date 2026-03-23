# Frankenrouter - Compiled Binaries

This directory contains pre-compiled MIPS binaries for the VSOL V2802DAC router.

## Binary Details

| File | Size | Description |
|------|------|-------------|
| `dropbearmulti` | 740KB | SSH server (Dropbear) with multi-call support |
| `socks5proxy` | 1.2MB | SOCKS5 proxy with adblock integration |
| `protomux` | 60KB | SSH/SOCKS5 port multiplexer |
| `smartqos` | 98KB | QoS monitoring daemon |

## Target Architecture

- **CPU**: Realtek RTL9607C-VB5 (MIPS 34Kc, big-endian)
- **Toolchain**: Zig (`zig cc -target mips-linux-musl`)
- **Libc**: musl (statically linked)
- **Kernel**: Linux 3.18.21

## Verification

```bash
# Check binary architecture
file socks5proxy
# socks5proxy: ELF 32-bit MSB executable, MIPS, MIPS32 rel2 version 1 (SYSV), statically linked, stripped

# Check it runs on router
ssh -p 2222 root@192.168.1.1 "/var/config/socks5proxy --help"
```

## Building from Source

To rebuild these binaries:

```bash
# Install Zig (https://ziglang.org/download/)
# Windows: winget install zig.zig
# Linux: snap install zig --classic

# Run build script
python scripts/build/build_all.py

# Or manually:
zig cc -target mips-linux-musl -Os -s -o socks5proxy src/socks5proxy/socks5proxy.c
```

## Deployment

```bash
# Copy to router (requires SSH access)
scp -P 2222 socks5proxy root@192.168.1.1:/var/config/
ssh -p 2222 root@192.168.1.1 "chmod +x /var/config/socks5proxy"
```

## Security Note

These binaries were compiled from the source code in `src/`. Always review source code before deploying to production routers.
