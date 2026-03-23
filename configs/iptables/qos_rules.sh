#!/bin/sh
# ============================================================
# QoS TOS Marking Rules (Software QoS via iptables mangle)
# Creates SMART_QOS chain in mangle table
# ============================================================

# Create SMART_QOS chain
iptables -t mangle -N SMART_QOS 2>/dev/null
iptables -t mangle -F SMART_QOS 2>/dev/null

# Attach to FORWARD and OUTPUT
iptables -t mangle -D FORWARD -j SMART_QOS 2>/dev/null
iptables -t mangle -A FORWARD -j SMART_QOS
iptables -t mangle -D OUTPUT -j SMART_QOS 2>/dev/null
iptables -t mangle -A OUTPUT -j SMART_QOS

# DNS Traffic - High Priority (Band 0)
iptables -t mangle -A SMART_QOS -p udp --dport 53 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -p tcp --dport 53 -j TOS --set-tos Minimize-Delay

# Gaming PC (192.168.1.36) - High Priority
# Valorant ports
iptables -t mangle -A SMART_QOS -s 192.168.1.36 -p udp --dport 7000:8181 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -d 192.168.1.36 -p udp --sport 7000:8181 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -s 192.168.1.36 -p udp --dport 27016:27024 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -d 192.168.1.36 -p udp --sport 27016:27024 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -s 192.168.1.36 -p udp --dport 54000:54012 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -d 192.168.1.36 -p udp --sport 54000:54012 -j TOS --set-tos Minimize-Delay

# LoL/Riot ports
iptables -t mangle -A SMART_QOS -s 192.168.1.36 -p tcp --dport 2099 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -d 192.168.1.36 -p tcp --sport 2099 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -s 192.168.1.36 -p tcp --dport 5222:5223 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -d 192.168.1.36 -p tcp --sport 5222:5223 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -s 192.168.1.36 -p tcp --dport 8088 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -d 192.168.1.36 -p tcp --sport 8088 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -s 192.168.1.36 -p tcp --dport 8393:8400 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -d 192.168.1.36 -p tcp --sport 8393:8400 -j TOS --set-tos Minimize-Delay

# WebRTC/STUN (Google Meet, Discord, etc.)
iptables -t mangle -A SMART_QOS -p udp --dport 19302:19309 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -p udp --sport 19302:19309 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -p udp --dport 3478 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -p udp --sport 3478 -j TOS --set-tos Minimize-Delay

# Google Meet HTTPS (by IP range)
iptables -t mangle -A SMART_QOS -p tcp --dport 443 -m iprange --dst-range 142.250.0.0-142.251.255.255 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -p tcp --sport 443 -m iprange --src-range 142.250.0.0-142.251.255.255 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -p tcp --dport 443 -m iprange --dst-range 172.217.0.0-172.217.255.255 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -p tcp --sport 443 -m iprange --src-range 172.217.0.0-172.217.255.255 -j TOS --set-tos Minimize-Delay

# SSH - High Priority
iptables -t mangle -A SMART_QOS -p tcp --dport 22 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -p tcp --sport 22 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -p tcp --dport 2222 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -p tcp --sport 2222 -j TOS --set-tos Minimize-Delay

# NTP - High Priority
iptables -t mangle -A SMART_QOS -p udp --dport 123 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A SMART_QOS -p udp --sport 123 -j TOS --set-tos Minimize-Delay

echo "QoS TOS rules applied (32 rules)"
