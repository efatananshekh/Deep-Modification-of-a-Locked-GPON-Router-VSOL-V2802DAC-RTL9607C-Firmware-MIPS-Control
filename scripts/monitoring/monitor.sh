#!/bin/sh
# Router Health Monitor v1.1 - Simplified for BusyBox

echo "=== Router Health Report ==="
echo ""

# DNS check
nslookup google.com 8.8.8.8 > /dev/null 2>&1 && echo "DNS: OK" || echo "DNS: FAILED"
pidof dnsmasq > /dev/null && echo "DNSmasq: Running" || echo "DNSmasq: NOT RUNNING"

# Services check
echo ""
echo "=== Services ==="
pidof dropbear > /dev/null && echo "Dropbear: OK" || echo "Dropbear: FAILED"
pidof socks5proxy > /dev/null && echo "SOCKS5: OK" || echo "SOCKS5: FAILED"
pidof protomux > /dev/null && echo "Protomux: OK" || echo "Protomux: FAILED"
pidof smartqos > /dev/null && echo "SmartQoS: OK" || echo "SmartQoS: FAILED"

# HWNAT check
echo ""
grep -q "ENABLED" /proc/rg/hwnat && echo "HWNAT: ENABLED" || echo "HWNAT: DISABLED"

# Memory check
echo ""
avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
avail_mb=$((avail / 1024))
echo "Memory: ${avail_mb}MB available"
if [ $avail -lt 15000 ]; then
    echo "  WARNING: Low memory!"
fi

# Load check
echo ""
echo "Load: $(cat /proc/loadavg)"
load=$(cat /proc/loadavg | awk '{print $1}' | awk -F. '{print $1}')
if [ "$load" -gt 8 ] 2>/dev/null; then
    echo "  WARNING: High load!"
fi

# Internet check
echo ""
ping -c 2 -W 3 8.8.8.8 > /dev/null 2>&1 && echo "Internet: OK" || echo "Internet: FAILED"

# DNS query stats
echo ""
echo "=== DNS Activity ==="
ps aux 2>/dev/null | grep dnsmasq | grep -v grep || ps | grep dnsmasq | grep -v grep