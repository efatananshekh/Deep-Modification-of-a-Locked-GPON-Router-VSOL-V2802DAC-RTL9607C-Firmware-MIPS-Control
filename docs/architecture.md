# System Architecture

This document details the internal architecture of the modified VSOL V2802DAC router, including boot flow, network packet paths, and where custom modifications hook into the system.

---

## Hardware Specifications

```
Device: VSOL V2802DAC v5 GPON/EPON ONU
SoC: Realtek RTL9607C-VB5
├── CPU: MIPS 34Kc (Big Endian, MSB)
├── Cores: 4 VPEs @ 761 MHz
├── L1 Cache: 32KB I-cache + 32KB D-cache per core
└── L2 Cache: 256KB shared

Memory:
├── RAM: 128MB DDR2 (72MB usable after kernel/firmware)
└── Flash: 16MB NOR (SPI)
    ├── Boot: 256KB (U-Boot)
    ├── Kernel: 2MB (uImage - Linux 3.18.24)
    ├── rootfs: 8MB (SquashFS 4.0, XZ compressed, read-only)
    ├── custconf: 4MB (SquashFS 4.0, configurations)
    └── /var/config: 10.6MB (JFFS2, read-write, persistent)

Network:
├── WAN: GPON SFP (up to 2.5Gbps down / 1.25Gbps up)
├── LAN: 4x GbE RJ45 (Realtek switch fabric)
├── WiFi 2.4GHz: RTL8192F (802.11n, 2T2R)
└── WiFi 5GHz: RTL8822 (802.11ac, 2T2R)

Peripherals:
├── LED Controller: GPIO-driven (power, internet, GPON, WiFi, LAN1-4)
├── Reset Button: GPIO input (10s hold = factory reset)
└── USB 2.0: 1 port (480Mbps, host mode only)
```

---

## Software Stack

```
┌─────────────────────────────────────────────────┐
│              User Space (uClibc 0.9.33)         │
├─────────────────────────────────────────────────┤
│  BusyBox v1.22.1       │  Dropbear SSH (ours)   │
│  dnsmasq               │  socks5proxy (ours)    │
│  udhcpd (ISP)          │  protomux (ours)       │
│  pppd (ISP)            │  smartqos (ours)       │
│  boa (web server)      │  Custom scripts        │
├─────────────────────────────────────────────────┤
│          Linux Kernel 3.18.24 (luna_SDK_V3.3.0) │
│  ├─ Netfilter/iptables (NAT, mangle, filter)    │
│  ├─ pfifo_fast qdisc (3 priority bands)         │
│  ├─ Realtek fwdEngine (hardware NAT)            │
│  └─ GPON MAC driver (rtk_gpon.ko)               │
├─────────────────────────────────────────────────┤
│           Hardware (RTL9607C Registers)         │
│  /proc/rg/                                      │
│  ├─ hwnat (on/off/bypass)                       │
│  ├─ assign_access_ip (HW QoS priority)          │
│  ├─ qos_ring_0 to qos_ring_7 (priority queues)  │
│  └─ flow tables (hardware conntrack)            │
└─────────────────────────────────────────────────┘
```

---

## Boot Flow

```
Power On
  │
  ▼
┌────────────────────────┐
│   U-Boot (256KB)       │  Loads kernel from flash @ 0x00040000
│   - Environment vars   │  Default: boot from uImage
│   - Network boot opt   │  Timeout: 3 seconds
└────────────────────────┘
  │
  ▼
┌────────────────────────┐
│  Linux Kernel 3.18.24  │  Unpacks to RAM @ 0x80000000
│  - Load address        │  Init: /etc/preinit → /sbin/init
└────────────────────────┘
  │
  ▼
┌────────────────────────┐
│  /sbin/init            │  Reads /etc/inittab
│  - PID 1               │  Starts getty, respawn services
└────────────────────────┘
  │
  ▼
┌────────────────────────┐
│  /etc/init.d/rcS       │  System initialization
│  - Mount /proc, /sys   │  - Configure network interfaces
│  - Load kernel modules │  - Start syslogd, klogd
│  - /etc/init.d/rc2     │  - Run level 2 scripts
└────────────────────────┘
  │
  ▼
┌────────────────────────┐
│  /etc/init.d/rc3       │  ISP services (TR-069, web UI, PPPoE)
│  - pppd                │  - boa (HTTP server on port 80)
│  - cwmpClient (TR-069) │  - udhcpd (DHCP server)
│  - dnsmasq (ISP)       │  - network config from lastgood.xml
└────────────────────────┘
  │
  ▼
┌────────────────────────────────────────────────┐
│  /etc/init.d/rc35 (runlevel 3.5)               │
│  - Calls: /var/config/run_customized_sdk.sh   │ ← OUR HOOK
│  - If file exists: execute it                  │
└────────────────────────────────────────────────┘
  │
  ▼
┌────────────────────────────────────────────────┐
│  /var/config/run_customized_sdk.sh (ours)     │
│  #!/bin/sh                                     │
│  /var/config/run_test.sh                      │ ← Calls our main script
└────────────────────────────────────────────────┘
  │
  ▼
┌──────────────────────────────────────────────────────────────┐
│  /var/config/run_test.sh (V13 - GPON Safe)                   │
│  ──────────────────────────────────────────────────────────  │
│  PHASE 1: IMMEDIATE (Safe - doesn't affect GPON)             │
│    • Set Realtek HW QoS priority (PC = 192.168.1.36)         │
│    • Disable QoS rings 1-5 (unused priority lanes)           │
│                                                               │
│  PHASE 2: WAIT FOR GPON (Critical!)                          │
│    • Loop: Check nas0_0 or ppp0 has IP (max 120 seconds)     │
│    • If timeout: Log error, continue anyway (degraded mode)  │
│                                                               │
│  PHASE 3: NETWORK SETUP (After GPON registration)            │
│    • Start Dropbear SSH (port 2222, key auth)                │
│    • Start SOCKS5 proxy (port 1080, user/pass auth)          │
│    • Start protomux (port 8443, routes SSH/SOCKS5)           │
│    • Apply iptables:                                          │
│      - NAT: DNS hijack (port 53 → 192.168.1.1)               │
│      - NAT: Port 443 redirect → 8443 (WAN only)              │
│      - Mangle: TOS marking for QoS (gaming, DNS, VoIP)       │
│      - Filter: Basic security (drop invalid, syn flood)      │
│                                                               │
│  PHASE 4: DNS & ADBLOCK                                      │
│    • Kill ISP dnsmasq                                         │
│    • Launch our dnsmasq:                                      │
│      - Upstream: 1.1.1.1, 1.0.0.1 (Cloudflare)               │
│      - Adblock: adblock_full.hosts (85K domains)             │
│      - Cache: 1000 entries, 30s negative TTL                 │
│      - Logging: /tmp/dns_queries.log                         │
│                                                               │
│  PHASE 5: QoS DAEMON                                          │
│    • Start smartqos daemon (monitors HW QoS + iptables)      │
│    • Daemonizes, logs to /tmp/smartqos.log                   │
│                                                               │
│  PHASE 6: DHCP DNS PATCH                                      │
│    • Check /var/udhcpd/udhcpd.conf for "opt dns"             │
│    • If ISP DNS found: replace with 192.168.1.1              │
│    • Restart udhcpd if changed                               │
│                                                               │
│  PHASE 7: TUNING & WATCHDOG                                   │
│    • Sysctl: TCP buffers, FIN timeout, TIME_WAIT reuse       │
│    • OOM protection: Protect custom binaries from killer     │
│    • Launch watchdog (checks services every 30s)             │
│                                                               │
│  DONE: Log completion to /tmp/boot.log                       │
└──────────────────────────────────────────────────────────────┘
  │
  ▼
[Router fully operational with all custom services]
```

---

## Network Packet Paths

### 1. DNS Query Flow (Client → Router → Cloudflare)

```
Client PC (192.168.1.50)
  │
  │ UDP 192.168.1.50:random → 8.8.8.8:53
  │ (PC has ISP DNS from cached DHCP, but...)
  │
  ▼
┌──────────────────────────────────────────────────┐
│  Router br0 (192.168.1.1)                        │
│  Packet enters PREROUTING chain                  │
│                                                   │
│  Rule 1: -s 192.168.1.0/24 ! -d 192.168.1.1 \   │
│           -p udp --dport 53 \                    │
│           -j DNAT --to 192.168.1.1:53            │
│                                                   │
│  ✓ MATCH: Dest changed to 192.168.1.1:53        │ ← DNS HIJACK
└──────────────────────────────────────────────────┘
  │
  ▼
┌──────────────────────────────────────────────────┐
│  dnsmasq (127.0.0.1:53, listening on br0)        │
│  Receives: "Resolve doubleclick.net A?"          │
│                                                   │
│  1. Check /var/config/adblock_full.hosts         │
│     ├─ Hash lookup: "doubleclick.net"            │
│     └─ MATCH: "0.0.0.0 doubleclick.net"          │
│                                                   │
│  2. Return: A record → 0.0.0.0                   │ ← BLOCKED
│     (Never forwarded upstream)                   │
└──────────────────────────────────────────────────┘
  │
  ▼
Client receives: doubleclick.net = 0.0.0.0
(Browser/app fails to load ad)
```

### 2. Normal DNS Query (Not Blocked)

```
Client PC
  │ UDP → 192.168.1.1:53 (hijacked or direct)
  ▼
┌──────────────────────────────────────────────────┐
│  dnsmasq                                         │
│  Query: "google.com A?"                          │
│                                                   │
│  1. Check adblock_full.hosts                     │
│     └─ NO MATCH (google.com not in blocklist)    │
│                                                   │
│  2. Check cache (1000 entries)                   │
│     └─ MISS (or expired)                         │
│                                                   │
│  3. Forward upstream: 1.1.1.1 or 1.0.0.1         │ ← Cloudflare
│     (all-servers mode: query both, use fastest)  │
└──────────────────────────────────────────────────┘
  │
  │ UDP 103.155.218.139:random → 1.1.1.1:53
  ▼
┌──────────────────────────────────────────────────┐
│  Cloudflare DNS (1.1.1.1)                        │
│  Resolves: google.com → 142.250.67.78            │
│  Returns: A record                               │
└──────────────────────────────────────────────────┘
  │
  ▼
dnsmasq caches result (30s-24h TTL)
  │
  ▼
Client receives: google.com = 142.250.67.78
```

---

### 3. External SSH Access (Port 443 Multiplexing)

```
Internet Client (Phone on mobile data)
  │
  │ TCP SYN → rancour.ddns.net:443
  │          (DNS: rancour.ddns.net → 103.155.218.139)
  ▼
┌──────────────────────────────────────────────────┐
│  ISP Network                                     │
│  Routes to: 103.155.218.139:443 (WAN interface)  │
└──────────────────────────────────────────────────┘
  │
  ▼
┌──────────────────────────────────────────────────┐
│  Router WAN (ppp0, IP: 103.155.218.139)          │
│  Packet enters PREROUTING chain                  │
│                                                   │
│  Rule: -i ppp0 -p tcp --dport 443 \             │
│         -j REDIRECT --to-ports 8443              │
│                                                   │
│  ✓ MATCH: Dest port changed to 8443             │ ← PORT REDIRECT
└──────────────────────────────────────────────────┘
  │
  ▼
┌──────────────────────────────────────────────────┐
│  protomux (0.0.0.0:8443)                         │
│  Accepts connection, peeks first 4 bytes         │
│                                                   │
│  Received: "SSH-2.0-OpenSSH_..."                 │
│  ├─ Magic bytes match "SSH-"                     │
│  └─ Route to: 127.0.0.1:2222 (Dropbear)          │ ← SSH DETECTED
│                                                   │
│  [Proxy mode: bidirectional TCP relay]           │
└──────────────────────────────────────────────────┘
  │
  ▼
┌──────────────────────────────────────────────────┐
│  Dropbear SSH (127.0.0.1:2222)                   │
│  Key exchange, user auth (ed25519 key)           │
│  Shell spawned: /bin/sh (root)                   │
└──────────────────────────────────────────────────┘
  │
  ▼
User has root shell access over encrypted SSH tunnel
```

### 4. External SOCKS5 Access (Same Port 443)

```
Internet Client
  │ TCP → rancour.ddns.net:443
  ▼
[WAN ppp0 → iptables REDIRECT 443→8443]
  │
  ▼
┌──────────────────────────────────────────────────┐
│  protomux (8443)                                 │
│  Peeks first byte: 0x05 (SOCKS5 version)         │
│  ├─ NOT "SSH-"                                   │
│  └─ Route to: 127.0.0.1:1080 (SOCKS5 proxy)      │ ← SOCKS5 DETECTED
└──────────────────────────────────────────────────┘
  │
  ▼
┌──────────────────────────────────────────────────┐
│  socks5proxy (127.0.0.1:1080)                    │
│  SOCKS5 handshake:                               │
│    Client → 0x05 0x01 0x02 (auth method 2)       │
│    Server → 0x05 0x02 (require user/pass)        │
│                                                   │
│  Auth phase (RFC 1929):                          │
│    Client → 0x01 <len> "admin" <len> "stdONU101" │
│    Server → 0x01 0x00 (success)                  │
│                                                   │
│  CONNECT request:                                │
│    Client → 0x05 0x01 0x00 0x03 <len> "ifconfig.me" 0x00 0x50 │
│    Server → Connects to ifconfig.me:80           │
│    Server → 0x05 0x00 ... (success)              │
│                                                   │
│  [Proxy mode: relay data]                        │
└──────────────────────────────────────────────────┘
  │
  ▼
HTTP request sent to ifconfig.me via SOCKS5 tunnel
Response: "103.155.218.139" (router's WAN IP)
```

---

## QoS Packet Flow

### Hardware QoS (Realtek RTL9607C)

```
Ingress Packet (from WAN/LAN)
  │
  ▼
┌──────────────────────────────────────────────────┐
│  Realtek Switch Fabric                           │
│  Reads: Source MAC, IP, port                     │
│                                                   │
│  Check /proc/rg/assign_access_ip:                │
│    0xc0a80124 (192.168.1.36 - PC)                │
│                                                   │
│  IF source IP == 192.168.1.36:                   │
│    → Assign to qos_ring_0 (HIGHEST priority)     │ ← HW QoS
│  ELSE:                                            │
│    → Assign to qos_ring_7 (LOWEST priority)      │
│                                                   │
│  Queue depth: ring_0 = 512 packets               │
│                ring_7 = 128 packets               │
└──────────────────────────────────────────────────┘
  │
  ▼
[Hardware scheduler: ring_0 always serviced first]
  │
  ▼
Egress (to WAN/LAN)
```

### Software QoS (iptables + pfifo_fast)

```
Outbound Packet (from LAN → WAN)
  │
  ▼
┌──────────────────────────────────────────────────┐
│  iptables POSTROUTING (mangle table)             │
│  SMART_QOS chain (32 rules):                     │
│                                                   │
│  1. TCP dport 53 (DNS)         → TOS 0x10 (pri 2)│
│  2. UDP dport 53 (DNS)         → TOS 0x10 (pri 2)│
│  3. TCP dport 443 (HTTPS)      → TOS 0x08 (pri 1)│
│  4. UDP dport 3478 (STUN)      → TOS 0x10 (pri 2)│
│  5. UDP dport 3074 (Xbox Live) → TOS 0x10 (pri 2)│
│  6. TCP dport 27015 (Steam)    → TOS 0x10 (pri 2)│
│  7. UDP 5000-5100 (Valorant)   → TOS 0x10 (pri 2)│
│  ... (32 rules total)                            │
│                                                   │
│  Sets: IP TOS field (DSCP/ECN bits)              │ ← TOS MARKING
└──────────────────────────────────────────────────┘
  │
  ▼
┌──────────────────────────────────────────────────┐
│  pfifo_fast qdisc (3 priority bands)             │
│  Reads: IP TOS field                             │
│                                                   │
│  Band 0 (HIGHEST): TOS 0x10, 0x08 (marked pkts)  │
│  Band 1 (MEDIUM):  TOS 0x00 (default)            │
│  Band 2 (LOWEST):  TOS 0x02 (bulk)               │
│                                                   │
│  Scheduler: Strict priority (band 0 first)       │
└──────────────────────────────────────────────────┘
  │
  ▼
[Packet sent to WAN with QoS priority]
```

### SmartQoS Daemon Monitoring Loop

```
┌────────────────────────────────────────────────────────────┐
│  smartqos daemon (PID: varies, runs every 30 seconds)      │
│                                                             │
│  while (true) {                                             │
│    // 1. Check Hardware QoS                                │
│    ip_val = read("/proc/rg/assign_access_ip");             │
│    if (ip_val != "0xc0a80124") {                            │
│      write("/proc/rg/assign_access_ip", "0xc0a80124");     │
│      log("[FIX] Restored HW QoS priority for PC");         │
│    }                                                        │
│                                                             │
│    // 2. Check iptables rules count                        │
│    rule_count = system("iptables -t mangle -L SMART_QOS | wc -l");
│    if (rule_count < 32) {                                  │
│      log("[ERROR] Missing TOS rules! Re-applying...");     │
│      system("sh /var/config/apply_qos_rules.sh");          │
│    }                                                        │
│                                                             │
│    // 3. Check dnsmasq                                     │
│    if (!process_exists("dnsmasq")) {                       │
│      system("dnsmasq -C /var/dnsmasq.conf");               │
│      log("[FIX] Restarted dnsmasq");                       │
│    }                                                        │
│                                                             │
│    sleep(30);                                               │
│  }                                                          │
└────────────────────────────────────────────────────────────┘
```

---

## Memory Layout

```
Physical RAM: 128 MB (0x00000000 - 0x08000000)

┌────────────────────────────────────┐ 0x00000000
│  Kernel Code + Data (12 MB)        │
│  - .text, .data, .bss              │
├────────────────────────────────────┤ 0x00C00000
│  Kernel Modules (4 MB)             │
│  - rtk_gpon.ko, switch driver      │
├────────────────────────────────────┤ 0x01000000
│  DMA Buffers (8 MB)                │
│  - Network RX/TX rings             │
│  - GPON MAC buffers                │
├────────────────────────────────────┤ 0x01800000
│  Page Cache (16 MB)                │
│  - SquashFS decompression cache    │
│  - Dirty page writeback            │
├────────────────────────────────────┤ 0x02800000
│  User Space (72 MB usable)         │
│  ├─ /bin/sh, boa, pppd, dnsmasq    │
│  ├─ dropbear, socks5proxy          │
│  ├─ protomux, smartqos             │
│  └─ /tmp (RAM disk, 8 MB)          │
├────────────────────────────────────┤ 0x07000000
│  Hardware Registers (8 MB MMIO)    │
│  - 0xB8000000 mapped here          │
│  - Switch fabric, GPON MAC, GPIO   │
└────────────────────────────────────┘ 0x08000000

Flash Layout (16 MB):
┌────────────────────────────────────┐ 0x00000000
│  U-Boot (256 KB)                   │
├────────────────────────────────────┤ 0x00040000
│  uImage (2 MB, Linux kernel)       │
├────────────────────────────────────┤ 0x00240000
│  rootfs (8 MB, SquashFS, RO)       │
│  - /bin, /sbin, /lib, /etc         │
├────────────────────────────────────┤ 0x00A40000
│  custconf (4 MB, SquashFS, RO)     │
│  - ISP default configs             │
├────────────────────────────────────┤ 0x00E40000
│  /var/config (1.6 MB, JFFS2, RW)   │ ← Our custom files
│  - run_test.sh (13 KB)             │
│  - dropbearmulti (757 KB)          │
│  - socks5proxy (1.2 MB)            │
│  - protomux (60 KB)                │
│  - smartqos (100 KB)               │
│  - adblock_full.hosts (3 MB)       │
│  Usage: 7.1 MB / 10.6 MB (66%)     │
└────────────────────────────────────┘ 0x01000000
```

---

## Critical Realtek Registers

### `/proc/rg/hwnat`
```
Values:
  0 = Disabled (all packets through Linux stack)
  1 = Enabled (hardware NAT + Linux stack coexist) ← USED
  2 = Bypass (hardware only, breaks PPPoE)

Effect:
  hwnat=1 + fwdEngine=ENABLED:
    - New flows: Linux iptables → hardware learns
    - Established flows: Hardware fast-path (20 Gbps)
    - Our modifications: Applied to new flows only
```

### `/proc/rg/assign_access_ip`
```
Format: 0xAABBCCDD (hex IP address)
Example: 0xc0a80124 = 192.168.1.36

Effect:
  Packets from this IP → qos_ring_0 (highest priority)
  All other IPs → qos_ring_7 (lowest priority)
  
Hardware queues:
  ring_0: 512 packets, always serviced first
  ring_7: 128 packets, serviced last
```

### `/proc/rg/qos_ring_N` (N = 0-7)
```
Values:
  0 = Disabled
  1 = Enabled

Current config:
  qos_ring_0 = 1 (PC priority)
  qos_ring_1-5 = 0 (unused)
  qos_ring_6 = 1 (ACK packets)
  qos_ring_7 = 1 (default/bulk)
```

---

## Failure Modes & Recovery

### 1. GPON Registration Failure
**Symptom**: LED blinks forever, no WAN IP  
**Cause**: iptables rules block GPON OMCI (UDP/53)  
**Recovery**:
```bash
# Via telnet (LAN still works)
iptables -F OUTPUT
iptables -F PREROUTING -t nat
reboot
```

### 2. Boot Script Infinite Loop
**Symptom**: Router boots but services never start  
**Cause**: Syntax error in run_test.sh (e.g., unclosed `if`)  
**Recovery**:
```bash
# Via telnet
mv /var/config/run_test.sh /var/config/run_test.sh.bad
reboot
```

### 3. Out of Flash Space
**Symptom**: "No space left on device" when uploading  
**Cause**: /var/config JFFS2 full (10.6 MB limit)  
**Recovery**:
```bash
# Delete largest files
cd /var/config
ls -lS  # Sort by size
rm adblock_full.hosts  # Frees 3 MB
# Re-upload smaller blocklist
```

### 4. SSH Lockout (Wrong Keys)
**Symptom**: SSH refuses connection, password auth disabled  
**Cause**: authorized_keys corrupted or wrong key  
**Recovery**:
```bash
# Via telnet
rm /var/config/.ssh/authorized_keys
# Re-add key via telnet + echo
```

### 5. OOM Killer Strikes
**Symptom**: Services randomly disappear  
**Cause**: RAM exhaustion, kernel kills processes  
**Detection**: `dmesg | grep -i oom`  
**Recovery**:
```bash
# Protect critical services
echo -17 > /proc/$(pidof dnsmasq)/oom_adj
echo -17 > /proc/$(pidof dropbear)/oom_adj
```

---

## Performance Characteristics

### Throughput
- **PPPoE WAN**: 940 Mbps (limited by GbE, not router)
- **LAN-to-LAN**: 950 Mbps (wire speed)
- **WiFi 2.4 GHz**: ~100 Mbps (802.11n, 2x2 MIMO)
- **WiFi 5 GHz**: ~450 Mbps (802.11ac, 2x2 MIMO)

### Latency (Ping to 1.1.1.1)
- **With HWNAT**: 1-2 ms (hardware fast-path)
- **Without HWNAT**: 3-5 ms (Linux stack)
- **DNS lookup**: 8-15 ms (dnsmasq → Cloudflare)
- **Adblock hit**: <1 ms (local hosts file)

### CPU Usage
- **Idle**: 2-5% (4 cores, 761 MHz each)
- **Full WAN load**: 15-25% (HWNAT offloading works)
- **Without HWNAT**: 60-80% (Linux NAT bottleneck)
- **smartqos daemon**: <0.1% (sleeps 29.5s of 30s)

### Memory Usage
```
        Total:    128 MB
        Kernel:    12 MB
        Buffers:   16 MB
        Cache:     28 MB
        Free:      72 MB

Custom binaries RSS:
  dropbear:      ~1.2 MB (per connection)
  socks5proxy:   ~800 KB (idle), +500 KB per client
  protomux:      ~600 KB (idle), +300 KB per client
  smartqos:      ~240 KB (daemon)
  dnsmasq:       ~8 MB (with 3 MB adblock hosts loaded)
```

---

## Security Model

### Attack Surface
```
External (WAN):
  Port 443: protomux (SSH + SOCKS5)
    ├─ SSH: Key auth only, no password
    └─ SOCKS5: Username/password (admin/stdONU101)

Internal (LAN):
  Port 23: Telnet (CLI shell, requires enterlinuxshell)
  Port 80: Web UI (admin/stdONU101)
  Port 2222: SSH direct (bypasses protomux)
  Port 1080: SOCKS5 direct
```

### Trust Boundaries
```
┌─────────────────────────────────────────┐
│  Internet (Untrusted)                   │
│    ↓ Filtered by ISP + our iptables     │
├─────────────────────────────────────────┤
│  WAN Interface (ppp0)                   │
│    ↓ Only port 443 allowed in           │
├─────────────────────────────────────────┤
│  Router Services (Semi-trusted)         │
│    • protomux (auth required)           │
│    • dnsmasq (adblock + Cloudflare)     │
│    ↓ Full control from LAN              │
├─────────────────────────────────────────┤
│  LAN (192.168.1.0/24) (Trusted)         │
│    • Full router access                 │
│    • Telnet, SSH, web UI                │
└─────────────────────────────────────────┘
```

### Defense Mechanisms
- **Rate limiting**: iptables limit for SSH (3 conn/min)
- **SYN cookies**: Enabled (mitigates SYN flood)
- **Invalid packet drop**: iptables -m state INVALID -j DROP
- **No UPnP**: Disabled (prevents LAN malware opening ports)
- **CWMP disabled**: TR-069 killed (ISP can't push configs)

---

## Monitoring & Debugging

### Real-time Logs
```bash
# Boot log
tail -f /tmp/boot.log

# DNS queries (live)
tail -f /tmp/dns_queries.log

# SmartQoS status
tail -f /tmp/smartqos.log

# Kernel messages (crashes, OOM)
dmesg -w
```

### Service Health Checks
```bash
# All custom services
ps | grep -v grep | grep -E "dropbear|socks5|protomux|smartqos|dnsmasq"

# Port listeners
cat /proc/net/tcp | awk '{print $2}' | cut -d: -f2 | sort -u | while read port; do echo "Port: $((16#$port))"; done

# Hardware QoS
cat /proc/rg/assign_access_ip  # Should be 0xc0a80124
cat /proc/rg/qos_ring_0         # Should be 1

# iptables rule counts
iptables -t nat -L PREROUTING --line-numbers | wc -l
iptables -t mangle -L SMART_QOS | wc -l  # Should be 32+

# Flash usage
df -h /var/config
```

### Performance Metrics
```bash
# CPU usage per process
top -n 1

# Network throughput (requires iftop or similar - not available on router)
cat /proc/net/dev

# Memory breakdown
cat /proc/meminfo

# Active connections
cat /proc/net/nf_conntrack | wc -l  # Conntrack table size
```

---

## Glossary

- **GPON**: Gigabit Passive Optical Network (fiber to home)
- **ONU**: Optical Network Unit (customer premises equipment)
- **OLT**: Optical Line Terminal (ISP side, at fiber hub)
- **OMCI**: ONT Management and Control Interface (GPON layer 2 protocol)
- **CWMP/TR-069**: ISP remote management protocol (our enemy)
- **HWNAT**: Hardware Network Address Translation (Realtek fast-path)
- **fwdEngine**: Realtek forwarding engine (hardware packet processor)
- **TOS**: Type of Service (IP header field for QoS)
- **DSCP**: Differentiated Services Code Point (modern QoS marking)
- **pfifo_fast**: Priority FIFO queue discipline (Linux traffic shaping)
- **SquashFS**: Compressed read-only filesystem (firmware root)
- **JFFS2**: Journaling Flash File System (writable persistent storage)
- **BusyBox**: Swiss-army knife of embedded Linux (multi-call binary)
- **uClibc**: Lightweight C library for embedded systems
- **MIPS**: Microprocessor without Interlocked Pipeline Stages (RISC ISA)
- **IAC**: Interpret As Command (telnet protocol negotiation byte 0xFF)

---

**Last Updated**: 2026-03-23  
**Boot Script Version**: V13 (GPON-Safe)  
**Uptime Record**: 37 days, 14 hours
