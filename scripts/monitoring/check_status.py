#!/usr/bin/env python3
"""
check_status.py - Real-time status check for Frankenrouter
Quick health dashboard for monitoring router services
"""

import socket
import sys
import time
import argparse

ROUTER_IP = "192.168.1.1"

def check_port(host, port, timeout=2):
    """Quick TCP port check"""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        result = sock.connect_ex((host, port))
        sock.close()
        return result == 0
    except:
        return False

def main():
    parser = argparse.ArgumentParser(description="Quick status check")
    parser.add_argument("-r", "--router", default=ROUTER_IP)
    parser.add_argument("-w", "--watch", action="store_true", help="Watch mode (refresh every 5s)")
    args = parser.parse_args()
    
    services = [
        ("SSH", 2222),
        ("SOCKS5", 1080),
        ("Protomux", 8443),
        ("WebUI", 80),
        ("DNS", 53),
    ]
    
    while True:
        print(f"\n=== Router Status: {args.router} ===")
        print(f"Time: {time.strftime('%Y-%m-%d %H:%M:%S')}")
        print("-" * 40)
        
        for name, port in services:
            status = "✓ UP" if check_port(args.router, port) else "✗ DOWN"
            print(f"{name:12} (:{port:5}) : {status}")
        
        if not args.watch:
            break
        
        time.sleep(5)
        print("\033[H\033[J", end="")  # Clear screen

if __name__ == "__main__":
    main()
