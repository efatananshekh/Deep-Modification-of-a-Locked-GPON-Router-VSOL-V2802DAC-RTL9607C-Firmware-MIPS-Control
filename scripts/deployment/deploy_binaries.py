#!/usr/bin/env python3
"""
deploy_binaries.py - Deploy all custom binaries to VSOL V2802DAC router
Handles: socks5proxy, protomux, smartqos, adblock hosts
"""

import socket
import sys
import os
import time
import http.server
import threading
import argparse
from pathlib import Path

ROUTER_IP = "192.168.1.1"
ROUTER_PORT = 2222  # SSH port (assumes Dropbear already deployed)
DEFAULT_USER = "root"

# Files to deploy
BINARIES = {
    "socks5proxy": {
        "local": "builds/socks5proxy",
        "remote": "/var/config/socks5proxy",
        "start_cmd": "/var/config/socks5proxy 1080 admin:stdONU101 &",
    },
    "protomux": {
        "local": "builds/protomux",
        "remote": "/var/config/protomux",
        "start_cmd": "/var/config/protomux 8443 2222 1080 &",
    },
    "smartqos": {
        "local": "builds/smartqos",
        "remote": "/var/config/smartqos",
        "start_cmd": "/var/config/smartqos &",
    },
}

CONFIGS = {
    "dnsmasq.conf": {
        "local": "configs/router/dnsmasq.conf",
        "remote": "/var/config/dnsmasq.conf",
    },
    "adblock_hosts": {
        "local": "configs/router/adblock_small.hosts",
        "remote": "/var/config/adblock_full.hosts",
    },
}

def run_ssh_command(host, port, user, cmd, timeout=30):
    """Run command via SSH and return output"""
    import subprocess
    ssh_cmd = [
        "ssh",
        "-p", str(port),
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", f"ConnectTimeout={timeout}",
        f"{user}@{host}",
        cmd
    ]
    try:
        result = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=timeout)
        return result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        return "[TIMEOUT]"
    except Exception as e:
        return f"[ERROR] {e}"

def upload_file(host, port, user, local_path, remote_path):
    """Upload file via SCP"""
    import subprocess
    scp_cmd = [
        "scp",
        "-P", str(port),
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        local_path,
        f"{user}@{host}:{remote_path}"
    ]
    try:
        result = subprocess.run(scp_cmd, capture_output=True, text=True, timeout=60)
        return result.returncode == 0
    except Exception as e:
        print(f"[!] SCP error: {e}")
        return False

def deploy_all(args):
    """Deploy all binaries and configs"""
    
    host = args.router
    port = args.port
    user = args.user
    repo_root = Path(args.repo)
    
    print(f"[*] Deploying to {host}:{port} as {user}")
    print(f"[*] Repository root: {repo_root}")
    
    # Test SSH connection
    print("[*] Testing SSH connection...")
    result = run_ssh_command(host, port, user, "id")
    if "uid=0" not in result:
        print(f"[!] SSH connection failed: {result}")
        return False
    print("[+] SSH connection OK")
    
    # Check available space
    print("[*] Checking available space...")
    result = run_ssh_command(host, port, user, "df -h /var/config")
    print(result)
    
    # Deploy binaries
    for name, config in BINARIES.items():
        local_path = repo_root / config["local"]
        remote_path = config["remote"]
        
        if not local_path.exists():
            print(f"[!] Skipping {name}: {local_path} not found")
            continue
        
        print(f"[*] Deploying {name}...")
        
        # Stop existing process
        run_ssh_command(host, port, user, f"killall {name} 2>/dev/null")
        
        # Upload
        if not upload_file(host, port, user, str(local_path), remote_path):
            print(f"[!] Failed to upload {name}")
            continue
        
        # Make executable
        run_ssh_command(host, port, user, f"chmod +x {remote_path}")
        
        # Start if requested
        if args.start:
            print(f"[*] Starting {name}...")
            run_ssh_command(host, port, user, config["start_cmd"])
        
        print(f"[+] {name} deployed")
    
    # Deploy configs
    for name, config in CONFIGS.items():
        local_path = repo_root / config["local"]
        remote_path = config["remote"]
        
        if not local_path.exists():
            print(f"[!] Skipping {name}: {local_path} not found")
            continue
        
        print(f"[*] Deploying {name}...")
        
        if not upload_file(host, port, user, str(local_path), remote_path):
            print(f"[!] Failed to upload {name}")
            continue
        
        print(f"[+] {name} deployed")
    
    # Verify deployment
    print("\n[*] Verifying deployment...")
    result = run_ssh_command(host, port, user, "ls -la /var/config/*.{sh,hosts} /var/config/socks5proxy /var/config/protomux /var/config/smartqos 2>/dev/null")
    print(result)
    
    result = run_ssh_command(host, port, user, "ps | grep -E 'socks5|protomux|smartqos|dnsmasq' | grep -v grep")
    print(result)
    
    print("\n[+] Deployment complete!")
    return True

def main():
    parser = argparse.ArgumentParser(description="Deploy binaries to VSOL router")
    parser.add_argument("-r", "--router", default=ROUTER_IP, help=f"Router IP (default: {ROUTER_IP})")
    parser.add_argument("-p", "--port", type=int, default=ROUTER_PORT, help=f"SSH port (default: {ROUTER_PORT})")
    parser.add_argument("-u", "--user", default=DEFAULT_USER, help=f"SSH user (default: {DEFAULT_USER})")
    parser.add_argument("--repo", default=".", help="Repository root directory")
    parser.add_argument("--start", action="store_true", help="Start services after deployment")
    
    args = parser.parse_args()
    deploy_all(args)

if __name__ == "__main__":
    main()
