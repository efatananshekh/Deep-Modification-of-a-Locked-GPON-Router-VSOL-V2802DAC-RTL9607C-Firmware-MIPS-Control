#!/bin/sh
# ============================================================
# Security Rules for Frankenrouter
# Basic firewall hardening + TR-069 blocking
# ============================================================

# Block TR-069 (ISP Remote Management) - CRITICAL
killall cwmpClient 2>/dev/null
iptables -I INPUT -p tcp --dport 7547 -j DROP
iptables -I OUTPUT -p tcp --dport 7547 -j DROP
iptables -I OUTPUT -p tcp --sport 7547 -j DROP

# Rate limit SSH to prevent brute force
iptables -A INPUT -p tcp --dport 2222 -m limit --limit 3/min --limit-burst 5 -j ACCEPT
iptables -A INPUT -p tcp --dport 2222 -j DROP

# Drop invalid packets
iptables -A INPUT -m state --state INVALID -j DROP
iptables -A FORWARD -m state --state INVALID -j DROP

# SYN flood protection
echo 1 > /proc/sys/net/ipv4/tcp_syncookies
iptables -A INPUT -p tcp --syn -m limit --limit 50/s --limit-burst 100 -j ACCEPT
iptables -A INPUT -p tcp --syn -j DROP

# ICMP rate limiting (ping flood protection)
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/s -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -j DROP

# Block common exploit ports from WAN
iptables -A INPUT -i ppp0 -p tcp --dport 23 -j DROP    # Telnet
iptables -A INPUT -i ppp0 -p tcp --dport 21 -j DROP    # FTP
iptables -A INPUT -i ppp0 -p tcp --dport 135 -j DROP   # RPC
iptables -A INPUT -i ppp0 -p tcp --dport 445 -j DROP   # SMB
iptables -A INPUT -i ppp0 -p tcp --dport 3389 -j DROP  # RDP

# Kill unnecessary services
for svc in mqtt_vccm upnpmd_cp map_controller map_checker loopback vsOltSelfAdapt vs_log wlan_cli_mgm v6nsa timely_function ecmh dot11k_deamon ftd; do
    killall $svc 2>/dev/null
done

echo "Security rules applied"
