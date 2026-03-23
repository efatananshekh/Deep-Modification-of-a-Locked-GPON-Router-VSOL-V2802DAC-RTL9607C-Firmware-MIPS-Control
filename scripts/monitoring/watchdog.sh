#!/bin/sh
# Smart Router Watchdog v1.2 - Auto-fixes common issues

LOG="/var/log/watchdog.log"
log() { echo "$1" >> $LOG; }

fix_dns_iptables() {
    iptables -C OUTPUT -p udp --dport 53 -d 192.10.20.2 -j ACCEPT 2>/dev/null || {
        iptables -I OUTPUT 1 -p udp --dport 53 -d 192.10.20.2 -j ACCEPT
        iptables -I OUTPUT 2 -p udp --dport 53 -d 8.8.8.8 -j ACCEPT
        iptables -I OUTPUT 3 -p tcp --dport 53 -d 192.10.20.2 -j ACCEPT
        iptables -I OUTPUT 4 -p tcp --dport 53 -d 8.8.8.8 -j ACCEPT
        log "FIXED: DNS iptables rules"
    }
}

fix_dnsmasq() {
    pidof dnsmasq > /dev/null || {
        cat > /var/dnsmasq.conf << EOF
server=192.10.20.2
server=8.8.8.8
listen-address=192.168.1.1
bind-interfaces
cache-size=1000
addn-hosts=/var/config/adblock_hosts.txt
log-queries
log-facility=/var/log/dnsmasq.log
EOF
        /bin/dnsmasq -C /var/dnsmasq.conf
        log "FIXED: dnsmasq restarted"
    }
}

fix_hwnat() {
    grep -q "ENABLED" /proc/rg/hwnat 2>/dev/null || {
        echo 1 > /proc/rg/hwnat
        echo 0 > /proc/rg/turn_off_ipv4_shortcut
        echo 0 > /proc/rg/turn_off_ipv6_shortcut
        log "FIXED: HWNAT re-enabled"
    }
}

fix_services() {
    pidof dropbear > /dev/null || {
        /var/config/dropbearmulti dropbear -r /var/config/dropbear_rsa_host_key -p 2222 &
        log "FIXED: Dropbear"
    }
    pidof socks5proxy > /dev/null || {
        /var/config/socks5proxy 1080 admin:stdONU101 &
        log "FIXED: SOCKS5"
    }
    pidof protomux > /dev/null || {
        /var/config/protomux 8443 2222 1080 &
        log "FIXED: Protomux"
    }
    pidof smartqos > /dev/null || {
        /var/config/smartqos &
        log "FIXED: SmartQoS"
    }
}

log "=== Watchdog v1.2 started ==="
while true; do
    fix_dns_iptables
    fix_dnsmasq
    fix_hwnat
    fix_services
    sleep 60
done