#!/bin/sh
# ============================================================
# NAT/DNS Hijacking Rules for Frankenrouter
# Apply AFTER GPON registration completes
# ============================================================

# DNS Hijacking (Force all LAN DNS queries to router)
iptables -t nat -I PREROUTING -i br0 -p udp --dport 53 ! -d 192.168.1.1 -j DNAT --to 192.168.1.1:53
iptables -t nat -I PREROUTING -i br0 -p tcp --dport 53 ! -d 192.168.1.1 -j DNAT --to 192.168.1.1:53

# DNS Input Allow (Required for dnsmasq to receive queries)
iptables -I INPUT 1 -i br0 -p tcp --dport 53 -j ACCEPT
iptables -I INPUT 1 -i br0 -p udp --dport 53 -j ACCEPT

# DNS Leak Prevention (Router only talks to Cloudflare)
iptables -I OUTPUT -p udp --dport 53 -d 127.0.0.1 -j ACCEPT
iptables -I OUTPUT -p tcp --dport 53 -d 127.0.0.1 -j ACCEPT
iptables -I OUTPUT -p udp --dport 53 -d 1.1.1.1 -j ACCEPT
iptables -I OUTPUT -p udp --dport 53 -d 1.0.0.1 -j ACCEPT
iptables -I OUTPUT -p tcp --dport 53 -d 1.1.1.1 -j ACCEPT
iptables -I OUTPUT -p tcp --dport 53 -d 1.0.0.1 -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j DROP
iptables -A OUTPUT -p tcp --dport 53 -j DROP

# Port 443 Redirect (External HTTPS -> protomux)
iptables -t nat -I PREROUTING 1 -i ppp0 -p tcp --dport 443 -j REDIRECT --to-port 8443

# Custom Services Input
iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 8443 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 1080 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 2222 -j ACCEPT

echo "NAT rules applied"
