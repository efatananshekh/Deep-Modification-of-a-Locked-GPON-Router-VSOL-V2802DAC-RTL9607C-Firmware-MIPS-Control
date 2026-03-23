#!/usr/bin/env python3
"""
verify_setup.py - Verify all Frankenrouter services are running correctly
Performs comprehensive health checks after deployment
"""

import socket
import subprocess
import sys
import time
import argparse

ROUTER_IP = "192.168.1.1"
SSH_PORT = 2222
SOCKS_PORT = 1080
MUX_PORT = 8443
DNS_PORT = 53

class Colors:
    GREEN = '\033[92m'
    RED = '\033[91m'
    YELLOW = '\033[93m'
    RESET = '\033[0m'

def ok(msg): print(f"{Colors.GREEN}[✓]{Colors.RESET} {msg}")
def fail(msg): print(f"{Colors.RED}[✗]{Colors.RESET} {msg}")
def warn(msg): print(f"{Colors.YELLOW}[!]{Colors.RESET} {msg}")

def check_port(host, port, timeout=5):
    """Check if TCP port is open"""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        result = sock.connect_ex((host, port))
        sock.close()
        return result == 0
    except:
        return False

def check_ssh(host, port):
    """Check SSH connectivity"""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect((host, port))
        data = sock.recv(256)
        sock.close()
        return b"SSH" in data
    except:
        return False

def check_socks5(host, port, user="admin", passwd="stdONU101"):
    """Check SOCKS5 proxy with auth"""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(10)
        sock.connect((host, port))
        
        # SOCKS5 greeting with auth method 0x02
        sock.send(b'\x05\x01\x02')
        resp = sock.recv(2)
        if resp != b'\x05\x02':
            return False, "Server rejected auth method"
        
        # Username/password auth
        auth = bytes([0x01, len(user)]) + user.encode() + bytes([len(passwd)]) + passwd.encode()
        sock.send(auth)
        resp = sock.recv(2)
        if resp != b'\x01\x00':
            return False, "Auth failed"
        
        sock.close()
        return True, "Auth successful"
    except Exception as e:
        return False, str(e)

def check_dns(host, domain="google.com"):
    """Check DNS resolution via router"""
    try:
        import dns.resolver
        resolver = dns.resolver.Resolver()
        resolver.nameservers = [host]
        resolver.timeout = 5
        resolver.lifetime = 5
        
        answers = resolver.resolve(domain, 'A')
        if answers:
            return True, str(answers[0])
        return False, "No answer"
    except ImportError:
        # Fallback without dnspython
        try:
            result = subprocess.run(
                ["nslookup", domain, host],
                capture_output=True, text=True, timeout=10
            )
            if "Address:" in result.stdout:
                return True, "Resolved"
            return False, result.stderr
        except:
            return False, "nslookup failed"
    except Exception as e:
        return False, str(e)

def check_adblock(host):
    """Check if adblock is working"""
    blocked_domains = [
        "doubleclick.net",
        "googleadservices.com",
        "facebook.com"  # if in blocklist
    ]
    
    for domain in blocked_domains:
        success, result = check_dns(host, domain)
        if success and ("0.0.0.0" in str(result) or "127.0.0.1" in str(result)):
            return True, domain
    
    return False, "No blocked domains detected"

def ssh_command(host, port, cmd):
    """Run command via SSH"""
    try:
        result = subprocess.run(
            ["ssh", "-p", str(port), "-o", "StrictHostKeyChecking=no",
             "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=5",
             f"root@{host}", cmd],
            capture_output=True, text=True, timeout=30
        )
        return result.stdout + result.stderr
    except:
        return None

def verify_all(args):
    """Run all verification checks"""
    host = args.router
    
    print(f"\n{'='*60}")
    print(f"  Frankenrouter Health Check - {host}")
    print(f"{'='*60}\n")
    
    results = {}
    
    # 1. SSH Check
    print("[*] Checking SSH (port 2222)...")
    if check_ssh(host, SSH_PORT):
        ok("SSH server responding")
        results['ssh'] = True
    else:
        fail("SSH not responding")
        results['ssh'] = False
    
    # 2. SOCKS5 Check
    print("[*] Checking SOCKS5 proxy (port 1080)...")
    success, msg = check_socks5(host, SOCKS_PORT)
    if success:
        ok(f"SOCKS5 proxy working: {msg}")
        results['socks5'] = True
    else:
        fail(f"SOCKS5 proxy failed: {msg}")
        results['socks5'] = False
    
    # 3. Protomux Check
    print("[*] Checking Protomux (port 8443)...")
    if check_port(host, MUX_PORT):
        ok("Protomux listening")
        results['protomux'] = True
    else:
        fail("Protomux not responding")
        results['protomux'] = False
    
    # 4. DNS Check
    print("[*] Checking DNS resolution...")
    success, msg = check_dns(host, "google.com")
    if success:
        ok(f"DNS working: google.com = {msg}")
        results['dns'] = True
    else:
        fail(f"DNS failed: {msg}")
        results['dns'] = False
    
    # 5. Adblock Check
    print("[*] Checking Adblock...")
    success, msg = check_adblock(host)
    if success:
        ok(f"Adblock working: {msg} blocked")
        results['adblock'] = True
    else:
        warn(f"Adblock may not be working: {msg}")
        results['adblock'] = False
    
    # 6. Process Check (via SSH)
    if results['ssh']:
        print("[*] Checking running processes...")
        output = ssh_command(host, SSH_PORT, "ps | grep -E 'dropbear|socks5|protomux|smartqos|dnsmasq' | grep -v grep")
        if output:
            processes = output.strip().split('\n')
            for proc in processes:
                if proc.strip():
                    ok(f"Running: {proc.split()[-1] if proc.split() else proc}")
        
        # 7. HW QoS Check
        print("[*] Checking Hardware QoS...")
        output = ssh_command(host, SSH_PORT, "cat /proc/rg/assign_access_ip 2>/dev/null")
        if output and "0xc0a80124" in output:
            ok("HW QoS enabled for gaming PC (192.168.1.36)")
            results['hwqos'] = True
        else:
            warn("HW QoS may not be configured")
            results['hwqos'] = False
        
        # 8. Flash Usage
        print("[*] Checking Flash usage...")
        output = ssh_command(host, SSH_PORT, "df -h /var/config")
        if output:
            lines = output.strip().split('\n')
            if len(lines) > 1:
                print(f"    {lines[-1]}")
    
    # Summary
    print(f"\n{'='*60}")
    print("  Summary")
    print(f"{'='*60}")
    
    total = len(results)
    passed = sum(1 for v in results.values() if v)
    
    for check, status in results.items():
        if status:
            ok(check)
        else:
            fail(check)
    
    print(f"\n  {passed}/{total} checks passed\n")
    
    return passed == total

def main():
    parser = argparse.ArgumentParser(description="Verify Frankenrouter setup")
    parser.add_argument("-r", "--router", default=ROUTER_IP, help=f"Router IP (default: {ROUTER_IP})")
    
    args = parser.parse_args()
    
    success = verify_all(args)
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
