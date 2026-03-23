#!/usr/bin/env python3
"""
build_all.py - Cross-compile all Frankenrouter binaries for MIPS
Requires Zig (for C cross-compilation with musl)
"""

import os
import sys
import subprocess
import argparse
from pathlib import Path

# Target: Realtek RTL9607C-VB5 (MIPS 34Kc, big-endian)
ZIG_TARGET = "mips-linux-musl"
ZIG_FLAGS = ["-Os", "-s", "-fno-unwind-tables", "-fno-asynchronous-unwind-tables"]

BINARIES = {
    "socks5proxy": {
        "source": "src/socks5proxy/socks5proxy.c",
        "output": "builds/socks5proxy",
        "description": "SOCKS5 proxy with adblock integration",
    },
    "protomux": {
        "source": "src/protomux/protomux.c",
        "output": "builds/protomux",
        "description": "SSH/SOCKS5 port multiplexer",
    },
    "smartqos": {
        "source": "src/smartqos/smartqos.c",
        "output": "builds/smartqos",
        "description": "QoS monitoring daemon",
    },
}

def check_zig():
    """Check if Zig is installed"""
    try:
        result = subprocess.run(["zig", "version"], capture_output=True, text=True)
        if result.returncode == 0:
            print(f"[+] Zig version: {result.stdout.strip()}")
            return True
    except FileNotFoundError:
        pass
    
    print("[!] Zig not found. Install from: https://ziglang.org/download/")
    print("    Or: winget install zig.zig")
    return False

def build_binary(name, config, repo_root, verbose=False):
    """Build a single binary"""
    source = repo_root / config["source"]
    output = repo_root / config["output"]
    
    if not source.exists():
        print(f"[!] Source not found: {source}")
        return False
    
    # Ensure output directory exists
    output.parent.mkdir(parents=True, exist_ok=True)
    
    print(f"[*] Building {name}...")
    print(f"    Source: {source}")
    print(f"    Output: {output}")
    
    cmd = [
        "zig", "cc",
        "-target", ZIG_TARGET,
        *ZIG_FLAGS,
        "-o", str(output),
        str(source)
    ]
    
    if verbose:
        print(f"    Command: {' '.join(cmd)}")
    
    try:
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        if result.returncode != 0:
            print(f"[!] Build failed for {name}:")
            print(result.stderr)
            return False
        
        # Check output size
        size = output.stat().st_size
        print(f"[+] {name} built successfully ({size:,} bytes)")
        return True
        
    except Exception as e:
        print(f"[!] Build error: {e}")
        return False

def build_all(args):
    """Build all binaries"""
    repo_root = Path(args.repo).resolve()
    
    print(f"=== Frankenrouter Build System ===")
    print(f"Repository: {repo_root}")
    print(f"Target: {ZIG_TARGET}")
    print()
    
    if not check_zig():
        return 1
    
    success = 0
    failed = 0
    
    for name, config in BINARIES.items():
        if build_binary(name, config, repo_root, args.verbose):
            success += 1
        else:
            failed += 1
    
    print()
    print(f"=== Build Summary ===")
    print(f"Successful: {success}")
    print(f"Failed: {failed}")
    
    if success > 0:
        print()
        print("Output files:")
        for name, config in BINARIES.items():
            output = repo_root / config["output"]
            if output.exists():
                size = output.stat().st_size
                print(f"  {output} ({size:,} bytes)")
    
    return 0 if failed == 0 else 1

def main():
    parser = argparse.ArgumentParser(description="Build Frankenrouter binaries")
    parser.add_argument("--repo", default=".", help="Repository root directory")
    parser.add_argument("-v", "--verbose", action="store_true", help="Verbose output")
    
    args = parser.parse_args()
    sys.exit(build_all(args))

if __name__ == "__main__":
    main()
