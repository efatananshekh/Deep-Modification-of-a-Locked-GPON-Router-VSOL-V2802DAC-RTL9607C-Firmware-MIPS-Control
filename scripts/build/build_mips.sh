#!/bin/bash
# build_mips.sh - Cross-compile for MIPS using Zig
# Target: Realtek RTL9607C-VB5 (MIPS 34Kc, big-endian, musl libc)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TARGET="mips-linux-musl"
CFLAGS="-Os -s -fno-unwind-tables -fno-asynchronous-unwind-tables"

echo "=== Frankenrouter MIPS Build ==="
echo "Repository: $REPO_ROOT"
echo "Target: $TARGET"
echo

# Check Zig
if ! command -v zig &> /dev/null; then
    echo "[!] Zig not found. Install from: https://ziglang.org/download/"
    exit 1
fi
echo "[+] Zig version: $(zig version)"

# Create builds directory
mkdir -p "$REPO_ROOT/builds"

# Build socks5proxy
echo "[*] Building socks5proxy..."
zig cc -target $TARGET $CFLAGS \
    -o "$REPO_ROOT/builds/socks5proxy" \
    "$REPO_ROOT/src/socks5proxy/socks5proxy.c"
echo "[+] socks5proxy: $(stat -f%z "$REPO_ROOT/builds/socks5proxy" 2>/dev/null || stat -c%s "$REPO_ROOT/builds/socks5proxy") bytes"

# Build protomux
echo "[*] Building protomux..."
zig cc -target $TARGET $CFLAGS \
    -o "$REPO_ROOT/builds/protomux" \
    "$REPO_ROOT/src/protomux/protomux.c"
echo "[+] protomux: $(stat -f%z "$REPO_ROOT/builds/protomux" 2>/dev/null || stat -c%s "$REPO_ROOT/builds/protomux") bytes"

# Build smartqos
echo "[*] Building smartqos..."
zig cc -target $TARGET $CFLAGS \
    -o "$REPO_ROOT/builds/smartqos" \
    "$REPO_ROOT/src/smartqos/smartqos.c"
echo "[+] smartqos: $(stat -f%z "$REPO_ROOT/builds/smartqos" 2>/dev/null || stat -c%s "$REPO_ROOT/builds/smartqos") bytes"

echo
echo "=== Build Complete ==="
ls -la "$REPO_ROOT/builds/"
