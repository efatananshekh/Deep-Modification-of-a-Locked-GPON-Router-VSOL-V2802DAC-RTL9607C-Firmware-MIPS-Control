#!/usr/bin/env python3
"""
deploy_ssh.py - Deploy Dropbear SSH to VSOL V2802DAC router
Handles upload, installation, and key configuration
"""

import socket
import sys
import os
import time
import http.server
import threading
import argparse

ROUTER_IP = "192.168.1.1"
ROUTER_PORT = 23
DEFAULT_USER = "admin"
DEFAULT_PASS = "stdONU101"

def telnet_send(sock, cmd, wait=0.5):
    """Send command via telnet and return response"""
    sock.send((cmd + "\n").encode())
    time.sleep(wait)
    try:
        return sock.recv(8192).decode('utf-8', errors='ignore')
    except socket.timeout:
        return ""

def telnet_login(sock, user, passwd):
    """Login to router via telnet"""
    time.sleep(1)
    data = sock.recv(4096).decode('utf-8', errors='ignore')
    
    if "login:" in data.lower():
        sock.send((user + "\n").encode())
        time.sleep(0.5)
    
    data = sock.recv(4096).decode('utf-8', errors='ignore')
    if "password:" in data.lower():
        sock.send((passwd + "\n").encode())
        time.sleep(0.5)
    
    data = sock.recv(4096).decode('utf-8', errors='ignore')
    if ">" in data:
        print("[+] Logged in, entering shell...")
        sock.send(b"enterlinuxshell\n")
        time.sleep(0.5)
        data = sock.recv(4096).decode('utf-8', errors='ignore')
        if "#" in data:
            print("[+] Got root shell!")
            return True
    
    return False

def start_http_server(port, directory):
    """Start HTTP server for file transfer"""
    os.chdir(directory)
    handler = http.server.SimpleHTTPRequestHandler
    httpd = http.server.HTTPServer(("0.0.0.0", port), handler)
    thread = threading.Thread(target=httpd.serve_forever)
    thread.daemon = True
    thread.start()
    return httpd

def deploy_dropbear(binary_path, pubkey_path, http_port=8000):
    """Deploy Dropbear to router"""
    
    if not os.path.exists(binary_path):
        print(f"[!] Binary not found: {binary_path}")
        return False
    
    if pubkey_path and not os.path.exists(pubkey_path):
        print(f"[!] Public key not found: {pubkey_path}")
        return False
    
    # Start HTTP server
    binary_dir = os.path.dirname(os.path.abspath(binary_path))
    binary_name = os.path.basename(binary_path)
    
    print(f"[*] Starting HTTP server on port {http_port}...")
    httpd = start_http_server(http_port, binary_dir)
    
    # Get local IP for router to download from
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect((ROUTER_IP, 80))
    local_ip = s.getsockname()[0]
    s.close()
    
    print(f"[*] Local IP: {local_ip}")
    
    # Connect to router
    print(f"[*] Connecting to {ROUTER_IP}:{ROUTER_PORT}...")
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(10)
    sock.connect((ROUTER_IP, ROUTER_PORT))
    
    if not telnet_login(sock, DEFAULT_USER, DEFAULT_PASS):
        print("[!] Login failed")
        return False
    
    # Create directories
    print("[*] Creating directories...")
    telnet_send(sock, "mkdir -p /var/config/.ssh")
    telnet_send(sock, "chmod 700 /var/config/.ssh")
    
    # Download binary
    print(f"[*] Downloading {binary_name}...")
    url = f"http://{local_ip}:{http_port}/{binary_name}"
    resp = telnet_send(sock, f"wget -O /var/config/dropbearmulti {url}", wait=10)
    print(resp)
    
    # Make executable
    print("[*] Setting permissions...")
    telnet_send(sock, "chmod +x /var/config/dropbearmulti")
    telnet_send(sock, "cd /var/config && ln -sf dropbearmulti dropbear")
    telnet_send(sock, "cd /var/config && ln -sf dropbearmulti dropbearkey")
    
    # Generate host keys
    print("[*] Generating host keys...")
    resp = telnet_send(sock, "/var/config/dropbearmulti dropbearkey -t ed25519 -f /var/config/.ssh/dropbear_ed25519_host_key", wait=5)
    print(resp)
    
    # Upload public key if provided
    if pubkey_path:
        print("[*] Uploading public key...")
        with open(pubkey_path, 'r') as f:
            pubkey = f.read().strip()
        
        telnet_send(sock, f'echo "{pubkey}" > /var/config/.ssh/authorized_keys')
        telnet_send(sock, "chmod 600 /var/config/.ssh/authorized_keys")
    
    # Start Dropbear
    print("[*] Starting Dropbear SSH...")
    telnet_send(sock, "killall dropbear 2>/dev/null")
    resp = telnet_send(sock, "/var/config/dropbearmulti dropbear -p 2222 -r /var/config/.ssh/dropbear_ed25519_host_key", wait=2)
    print(resp)
    
    # Verify
    print("[*] Verifying...")
    resp = telnet_send(sock, "netstat -tlnp 2>/dev/null | grep 2222 || cat /proc/net/tcp | grep :08AE")
    print(resp)
    
    sock.close()
    httpd.shutdown()
    
    print("[+] Deployment complete!")
    print(f"[+] Connect with: ssh -p 2222 root@{ROUTER_IP}")
    return True

def main():
    parser = argparse.ArgumentParser(description="Deploy Dropbear SSH to VSOL router")
    parser.add_argument("binary", help="Path to dropbearmulti binary")
    parser.add_argument("-k", "--pubkey", help="Path to SSH public key file")
    parser.add_argument("-p", "--port", type=int, default=8000, help="HTTP server port (default: 8000)")
    parser.add_argument("--router", default=ROUTER_IP, help=f"Router IP (default: {ROUTER_IP})")
    
    args = parser.parse_args()
    
    global ROUTER_IP
    ROUTER_IP = args.router
    
    deploy_dropbear(args.binary, args.pubkey, args.port)

if __name__ == "__main__":
    main()
