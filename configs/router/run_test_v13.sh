#!/bin/sh
# Comprehensive Router Boot Script - V12.4 (Safe DHCP + Wildcard DMZ)
# Services: SSH, SOCKS5 Proxy, Protocol Mux, WoL, Wildcard DMZ
# Features: HW QoS, DNS-based Priority Swapping, Adblock, Cloudflare DNS, WiFi Opt, TCP Tuning, Watchdog
# Called by /var/config/run_customized_sdk.sh from rc35

# ============================================================
# PHASE 1: IMMEDIATE - Realtek HW QoS
# ============================================================
echo 0xc0a80124 > /proc/rg/assign_access_ip 2>/dev/null
echo 7 > /proc/rg/assign_access_ip_priority 2>/dev/null
echo 6 > /proc/rg/assign_ack_priority 2>/dev/null
echo 1 > /proc/rg/assign_arp_priority 2>/dev/null
echo 1 > /proc/rg/assign_dhcp_priority 2>/dev/null
echo 1 > /proc/rg/assign_igmp_priority 2>/dev/null

# ============================================================
# PHASE 2: BACKGROUND
# ============================================================
(
  PIDFILE="/var/run/run_test_bg.pid"
  if [ -f "$PIDFILE" ]; then
    old_pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      exit 0
    fi
  fi
  echo $$ > "$PIDFILE"

  sleep 5

  # Fix Admin Shell
  if grep -q '/bin/cli' /etc/passwd || grep -q ':/tmp:' /etc/passwd; then
    sed 's|/bin/cli|/bin/sh|;s|:/tmp:|:/var/config:|' /etc/passwd > /tmp/pw_fix
    cp /tmp/pw_fix /etc/passwd
    rm -f /tmp/pw_fix
  fi

  # SSH Keys
  mkdir -p /var/config/.ssh
  chmod 700 /var/config/.ssh
  chmod 600 /var/config/.ssh/authorized_keys 2>/dev/null
  if [ ! -f /var/config/dropbear_rsa ]; then
    /var/config/dropbearmulti dropbearkey -t rsa -f /var/config/dropbear_rsa -s 2048
  fi
  if [ ! -f /var/config/dropbear_ed25519 ]; then
    /var/config/dropbearmulti dropbearkey -t ed25519 -f /var/config/dropbear_ed25519
  fi

  # Services
  /var/config/dropbearmulti dropbear -r /var/config/dropbear_rsa -r /var/config/dropbear_ed25519 -p 2222 -F > /tmp/dropbear.log 2>&1 &
  /var/config/socks5proxy 1080 admin:stdONU101 > /tmp/socks5.log 2>&1 &
  /var/config/protomux 8443 2222 1080 > /tmp/mux.log 2>&1 &

  # Wait for WAN
  i=0
  while [ $i -lt 90 ]; do
    ifconfig ppp0 2>/dev/null | grep -q "inet addr" && break
    sleep 2
    i=$(($i+1))
  done
  sleep 5

  # WiFi Opt
  iwpriv wlan0 set_mib shortGI20M=1 2>/dev/null
  iwpriv wlan0 set_mib shortGI40M=1 2>/dev/null
  iwpriv wlan0 set_mib ampdu=1 2>/dev/null
  iwpriv wlan0 set_mib amsdu=2 2>/dev/null
  iwpriv wlan1 set_mib shortGI20M=1 2>/dev/null
  iwpriv wlan1 set_mib shortGI40M=1 2>/dev/null
  iwpriv wlan1 set_mib ampdu=1 2>/dev/null
  iwpriv wlan1 set_mib amsdu=2 2>/dev/null

  # Security
  killall cwmpClient 2>/dev/null
  iptables -I INPUT -p tcp --dport 7547 -j DROP 2>/dev/null
  iptables -I OUTPUT -p tcp --dport 7547 -j DROP 2>/dev/null
  iptables -I OUTPUT -p tcp --sport 7547 -j DROP 2>/dev/null

  # Cleanup
  for svc in mqtt_vccm upnpmd_cp map_controller map_checker loopback vsOltSelfAdapt vs_log wlan_cli_mgm v6nsa timely_function ecmh dot11k_deamon ftd; do
    killall $svc 2>/dev/null
  done

  # DNS Hijack (insert at top)
  iptables -t nat -I PREROUTING -i br0 -p udp --dport 53 ! -d 192.168.1.1 -j DNAT --to 192.168.1.1:53 2>/dev/null
  iptables -t nat -I PREROUTING -i br0 -p tcp --dport 53 ! -d 192.168.1.1 -j DNAT --to 192.168.1.1:53 2>/dev/null
  echo "1.1.1.1" > /var/ppp/resolv.conf.ppp0 2>/dev/null
  echo "1.0.0.1" >> /var/ppp/resolv.conf.ppp0 2>/dev/null

  ensure_dns_input() {
    iptables -D INPUT -i br0 -p udp --dport 53 -j ACCEPT 2>/dev/null
    iptables -D INPUT -i br0 -p udp --dport 53 -j ACCEPT 2>/dev/null
    iptables -D INPUT -i br0 -p tcp --dport 53 -j ACCEPT 2>/dev/null
    iptables -D INPUT -i br0 -p tcp --dport 53 -j ACCEPT 2>/dev/null
    iptables -I INPUT 1 -i br0 -p tcp --dport 53 -j ACCEPT 2>/dev/null
    iptables -I INPUT 1 -i br0 -p udp --dport 53 -j ACCEPT 2>/dev/null
  }
  ensure_dns_input

  # DNS Leak Prevent
  iptables -I OUTPUT -p udp --dport 53 -d 127.0.0.1 -j ACCEPT 2>/dev/null
  iptables -I OUTPUT -p tcp --dport 53 -d 127.0.0.1 -j ACCEPT 2>/dev/null
  iptables -I OUTPUT -p udp --dport 53 -d 1.1.1.1 -j ACCEPT 2>/dev/null
  iptables -I OUTPUT -p udp --dport 53 -d 1.0.0.1 -j ACCEPT 2>/dev/null
  iptables -I OUTPUT -p tcp --dport 53 -d 1.1.1.1 -j ACCEPT 2>/dev/null
  iptables -I OUTPUT -p tcp --dport 53 -d 1.0.0.1 -j ACCEPT 2>/dev/null
  iptables -A OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
  iptables -A OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null

  # Enable HWNAT/Shortcut for full speed (SmartQoS v2.2 maintains this)
  echo 1 > /proc/rg/hwnat 2>/dev/null
  echo 0 > /proc/rg/turn_off_ipv4_shortcut 2>/dev/null
  echo 0 > /proc/rg/turn_off_ipv6_shortcut 2>/dev/null
  echo 20 > /proc/rg/tcp_short_timeout 2>/dev/null
  echo 1 > /proc/rg/house_keep_sec 2>/dev/null

  # Queue/Bufferbloat
  ifconfig br0 txqueuelen 1000 2>/dev/null
  ifconfig ppp0 txqueuelen 32 2>/dev/null
  ifconfig eth0.2 txqueuelen 100 2>/dev/null
  echo 1 > /proc/sys/net/ipv4/tcp_ecn 2>/dev/null

  # Firewall Input
  iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT
  iptables -I INPUT 1 -p tcp --dport 8443 -j ACCEPT
  iptables -I INPUT 1 -p tcp --dport 1080 -j ACCEPT
  iptables -I INPUT 1 -p tcp --dport 2222 -j ACCEPT
  iptables -I INPUT 1 -i tun0 -j ACCEPT 2>/dev/null

  # 443 -> 8443 Redirect (Ensure this is always present)
  iptables -t nat -D PREROUTING -i ppp0 -p tcp --dport 443 -j REDIRECT --to-port 8443 2>/dev/null
  iptables -t nat -I PREROUTING 1 -i ppp0 -p tcp --dport 443 -j REDIRECT --to-port 8443

  # Dnsmasq Config
  restart_dnsmasq() {
    killall dnsmasq 2>/dev/null
    sleep 1
    killall -9 dnsmasq 2>/dev/null
    sleep 1
    while pidof dnsmasq >/dev/null 2>&1; do
      for pid in $(pidof dnsmasq); do kill -9 $pid 2>/dev/null; done
      sleep 1
    done
    /bin/dnsmasq -C /var/dnsmasq.conf 2>/dev/null
    sleep 3
    for pid in $(pidof dnsmasq); do echo -1000 > /proc/$pid/oom_score_adj 2>/dev/null; done
  }

  fix_dns_config() {
    ADBLOCK_LINE=""
    [ -f /var/config/adblock_full.hosts ] && ADBLOCK_LINE="addn-hosts=/var/config/adblock_full.hosts"
    SUPPLEMENT_LINE=""
    [ -f /var/config/adblock_custom_supplement.hosts ] && SUPPLEMENT_LINE="addn-hosts=/var/config/adblock_custom_supplement.hosts"
    cat > /tmp/dnsmasq_new.conf << DEOF
user=
group=
no-resolv
server=1.1.1.1
server=1.0.0.1
all-servers
cache-size=1000
neg-ttl=30
dns-forward-max=150
domain-needed
bogus-priv
local=/wpad.hgu_lan/
listen-address=192.168.1.1,127.0.0.1
bind-interfaces
log-queries
log-facility=/tmp/dns_queries.log
${ADBLOCK_LINE}
${SUPPLEMENT_LINE}
DEOF
    cp /tmp/dnsmasq_new.conf /var/dnsmasq.conf
    rm -f /tmp/dnsmasq_new.conf
    restart_dnsmasq
  }

  fix_dns_config
  (
    j=0
    while [ $j -lt 30 ]; do
      sleep 10
      if ! grep -q "^server=1.1.1.1" /var/dnsmasq.conf 2>/dev/null; then fix_dns_config; fi
      j=$(($j+1))
    done
  ) &

  # DHCP MTU
  if [ -f /var/udhcpd/udhcpd.conf ] && ! grep -q "opt mtu" /var/udhcpd/udhcpd.conf; then
      echo "opt mtu 1492" >> /var/udhcpd/udhcpd.conf
      killall udhcpd 2>/dev/null
      sleep 1
      udhcpd -S /var/udhcpd/udhcpd.conf &
  fi

  # Sysctl Tuning
  echo 524288 > /proc/sys/net/core/rmem_max
  echo 524288 > /proc/sys/net/core/wmem_max
  echo 262144 > /proc/sys/net/core/rmem_default
  echo 262144 > /proc/sys/net/core/wmem_default
  echo "4096 131072 524288" > /proc/sys/net/ipv4/tcp_rmem
  echo "4096 65536 524288" > /proc/sys/net/ipv4/tcp_wmem
  echo 15 > /proc/sys/net/ipv4/tcp_fin_timeout
  echo 1 > /proc/sys/net/ipv4/tcp_tw_reuse
  echo 1 > /proc/sys/net/ipv4/tcp_tw_recycle
  echo 4096 > /proc/sys/net/ipv4/tcp_max_tw_buckets
  echo 2000 > /proc/sys/net/core/netdev_max_backlog
  echo 1024 > /proc/sys/net/ipv4/tcp_max_syn_backlog
  echo 1024 > /proc/sys/net/core/somaxconn
  echo 3 > /proc/sys/net/ipv4/tcp_fastopen
  echo 1 > /proc/sys/net/ipv4/tcp_no_metrics_save
  echo 1 > /proc/sys/net/ipv4/tcp_mtu_probing
  echo 1 > /proc/sys/net/ipv4/tcp_low_latency
  echo "1024 65535" > /proc/sys/net/ipv4/ip_local_port_range
  echo 300 > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established 2>/dev/null
  echo 4096 > /proc/sys/vm/min_free_kbytes

  # Smart QoS v2 Daemon
  if [ -x /var/config/smartqos ]; then
    killall smartqos 2>/dev/null
    /var/config/smartqos > /tmp/smartqos.log 2>&1 &
    sleep 1
    for pid in $(pidof smartqos); do echo -1000 > /proc/$pid/oom_score_adj 2>/dev/null; done
  fi

  # ========================================
  # WILDCARD PORT FORWARDING (Ordered Insertion)
  # ========================================
  
  # 1. Clean up old attempts
  iptables -t nat -D PREROUTING -p tcp -j DNAT --to 192.168.1.36 2>/dev/null
  iptables -t nat -D PREROUTING -p udp -j DNAT --to 192.168.1.36 2>/dev/null
  iptables -t nat -D PREROUTING -p tcp -j DNAT --to 192.168.1.36 2>/dev/null
  iptables -t nat -D PREROUTING -p udp -j DNAT --to 192.168.1.36 2>/dev/null

  # 2. Insert Wildcard DNAT at Position 2 (After REDIRECT 443)
  iptables -t nat -I PREROUTING 2 -p udp -j DNAT --to 192.168.1.36
  iptables -t nat -I PREROUTING 2 -p tcp -j DNAT --to 192.168.1.36

  # 3. Insert Offset Port Rules (Overrides Wildcard)
  # Position 2 pushes Wildcard down to 4
  iptables -t nat -I PREROUTING 2 -p tcp --dport 5678 -j DNAT --to 192.168.1.36:15678
  iptables -t nat -I PREROUTING 2 -p tcp --dport 5432 -j DNAT --to 192.168.1.36:15432
  iptables -t nat -I PREROUTING 2 -p tcp --dport 6379 -j DNAT --to 192.168.1.36:16379
  iptables -t nat -I PREROUTING 2 -p tcp --dport 8000 -j DNAT --to 192.168.1.36:18000
  iptables -t nat -I PREROUTING 2 -p tcp --dport 11434 -j DNAT --to 192.168.1.36:21434

  # 4. Insert Router Protection + DHCP Safety (Overrides Everything)
  # Position 2 pushes Offset down to ~7
  # CRITICAL: Allow DHCP (UDP 67/68) to bypass Wildcard DNAT
  iptables -t nat -I PREROUTING 2 -p udp --dport 67 -j ACCEPT
  iptables -t nat -I PREROUTING 2 -p udp --dport 68 -j ACCEPT
  
  # CRITICAL: Allow Router Web UI (TCP 80)
  iptables -t nat -I PREROUTING 2 -p tcp --dport 80 -j ACCEPT
  
  iptables -t nat -I PREROUTING 2 -p udp --dport 53 -j ACCEPT
  iptables -t nat -I PREROUTING 2 -p tcp --dport 53 -j ACCEPT
  iptables -t nat -I PREROUTING 2 -p tcp --dport 8443 -j ACCEPT
  iptables -t nat -I PREROUTING 2 -p tcp --dport 2222 -j ACCEPT
  iptables -t nat -I PREROUTING 2 -p tcp --dport 1080 -j ACCEPT

  # 5. Forwarding permission
  iptables -D FORWARD -d 192.168.1.36 -j ACCEPT 2>/dev/null
  iptables -I FORWARD -d 192.168.1.36 -j ACCEPT

  # 6. Hairpin NAT
  iptables -t nat -D POSTROUTING -s 192.168.1.0/24 -d 192.168.1.36 -j MASQUERADE 2>/dev/null
  iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -d 192.168.1.36 -j MASQUERADE

  # ========================================
  # WATCHDOG
  # ========================================
  while true; do
    sleep 30
    if ! ifconfig ppp0 2>/dev/null | grep -q "inet addr"; then :; fi
    if ! grep -q ":20FB" /proc/net/tcp 2>/dev/null; then
       killall protomux 2>/dev/null
       /var/config/protomux 8443 2222 1080 > /tmp/mux.log 2>&1 &
    fi
    : > /var/log/easymesh_log.txt 2>/dev/null
  done
) &

# Start watchdog for auto-healing
/var/config/watchdog.sh &
