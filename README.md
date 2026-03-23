Developed under live network conditions with no hardware recovery path (no JTAG/UART).

# Frankenrouter: Deep Modification of a Locked GPON ONU

**What happens when you reverse-engineer a $20 ISP-locked router with ~10MB of flash and turn it into a privacy-focused, QoS-enabled gateway? This.**

---

## Overview

This project documents the complete reverse engineering and modification of a **VSOL V2802DAC v5** GPON ONU router—a consumer-grade fiber optic terminal locked down by ISP firmware. Over 66 distinct engineering phases, the device was:

- **Firmware extracted** and reverse-engineered without JTAG
- **Shell access** obtained through non-standard exploitation
- **Recovered from bootloops** caused by aggressive modifications
- **Stripped of TR-069** (ISP remote management backdoor)
- **Equipped with network-wide DNS-based adblocking** (~85,000 domains)
- **Hardened with QoS**, forced DNS hijacking, and encrypted upstream resolvers
- **Extended with custom MIPS binaries**: SOCKS5 proxy, protocol multiplexer, smart QoS daemon

All changes persist across reboots, survive firmware quirks, and operate within brutal constraints: 128MB RAM, 10.6MB usable flash, BusyBox 1.22.1, Linux 3.18.24, MIPS big-endian.

---

## Key Achievements

### Access & Control
- ✅ Root shell access via telnet race condition during boot
- ✅ Persistent boot hook (`run_customized_sdk.sh`) for custom scripts
- ✅ SSH server (Dropbear) cross-compiled for MIPS, key-based auth
- ✅ External access via protocol multiplexer on port 443 (SSH + SOCKS5)

### Network Privacy & Security
- ✅ **DNS hijacking**: All port 53 traffic redirected to local resolver
- ✅ **Adblock**: 85,000 domains (DoubleClick, Google Ads, trackers) → `0.0.0.0`
- ✅ **Cloudflare DNS** as upstream (1.1.1.1, 1.0.0.1) — ISP DNS bypassed
- ✅ DHCP patched to advertise router as DNS server (not ISP's)
- ✅ TR-069/CWMP disabled (ISP remote control severed)

### Performance & QoS
- ✅ **Hardware QoS** via Realtek `/proc/rg/` registers (priority lanes 0-7)
- ✅ **SmartQoS daemon**: Auto-applies TOS marking for gaming, VoIP, streaming
- ✅ HWNAT (hardware NAT acceleration) enabled without breaking custom rules
- ✅ PPPoE MTU fix (1492) via DHCP injection for all clients

### Custom MIPS Binaries
- ✅ **`protomux`** (60KB, C): Protocol multiplexer—shares port 443 for SSH/SOCKS5
- ✅ **`socks5proxy`** (1.2MB, C): Full RFC 1928/1929 SOCKS5 with auth
- ✅ **`smartqos`** (100KB, C): Daemon monitors/repairs QoS every 30s
- ✅ **`dropbear`** (757KB): SSH 2.0 server for remote management

### Boot Resilience
- ✅ **GPON-safe boot script**: Waits for GPON registration before applying iptables
- ✅ Watchdog monitors critical services (DNS, SSH, SOCKS, QoS) and auto-restarts
- ✅ OOM protection for custom binaries
- ✅ Survived 5+ hour stress tests, multiple full reboots

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    VSOL V2802DAC Router                     │
│  SoC: Realtek RTL9607C (MIPS, 4-core, 761MHz)              │
│  RAM: 128MB total / ~72MB usable                            │
│  Flash: 16MB (10.6MB for user data)                         │
│  OS: Linux 3.18.24 (uClibc 0.9.33, BusyBox v1.22.1)        │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────┐
        │   Boot Sequence (Modified)         │
        ├───────────────────────────────────┤
        │ 1. Kernel loads                    │
        │ 2. /etc/init.d/rcS                 │
        │ 3. Firmware: /etc/init.d/rc2, rc3  │
        │ 4. OUR HOOK: run_customized_sdk.sh │ ← Persistent hook
        │ 5. Calls: /var/config/run_test.sh │ ← Our boot script
        └───────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────┐
        │  run_test.sh (V13 - GPON Safe)    │
        ├───────────────────────────────────┤
        │ • Wait for GPON registration      │
        │ • Start Dropbear SSH (port 2222)  │
        │ • Start SOCKS5 proxy (port 1080)  │
        │ • Start protomux (port 8443)      │
        │ • Configure Hardware QoS          │
        │ • Apply iptables (NAT/TOS/HIJACK) │
        │ • Launch dnsmasq (adblock hosts)  │
        │ • Start SmartQoS daemon           │
        │ • Patch DHCP DNS to 192.168.1.1   │
        │ • Launch watchdog                 │
        └───────────────────────────────────┘
```

### DNS Flow
```
Client PC
   │ DNS query: doubleclick.net
   ├──> Router (192.168.1.1:53)
   │      │
   │      ├──> dnsmasq checks adblock_full.hosts
   │      │      ├──> MATCH → return 0.0.0.0 ✓ BLOCKED
   │      │      └──> NO MATCH → forward upstream
   │      │
   │      └──> Cloudflare 1.1.1.1:53
   │             │
   │             └──> Response → Client
   │
   └──> ISP cannot see queries (DNS hijacked at router)
```

### External Access (Port 443 Multiplexing)
```
Internet (rancour.ddns.net:443)
   │
   ├──> Router WAN (103.155.218.139:443)
   │      │
   │      ├──> iptables REDIRECT → 8443
   │      │
   │      └──> protomux (8443)
   │             │
   │             ├── Peek 1st byte == 0x05? ──> SOCKS5 (1080)
   │             └── Else (SSH magic) ──> Dropbear (2222)
```

---

## Constraints & Risks

### Hardware Limitations
- **10.6MB flash**: Every binary must be stripped, statically linked, UPX-compressed
- **128MB RAM**: OOM killer active—daemons must stay <10MB resident
- **No package manager**: All tools cross-compiled (Zig, MUSL libc)
- **BusyBox minimal**: No `head`, `tail`, `cut`, `sort`, `date`, `timeout`, `base64`

### Firmware Quirks
- **HWNAT interference**: Realtek hardware forwarding engine bypasses iptables for some flows
- **GPON registration race**: Aggressive iptables rules can block OMCI management → boot failure
- **udhcpd regeneration**: DHCP config reset on boot—must patch live
- **TR-069 resurrection**: ISP can restore CWMP on firmware update (mitigated)

### No Safety Net
- **No JTAG, no UART console**: Brick = replace motherboard
- **No rollback mechanism**: Bad flash writes are permanent
- **One internet line**: Debugging meant no connectivity during tests

---

## Project Phases (Highlights)

### Phase 1: Firmware Extraction & Analysis
- Extracted SquashFS filesystems from tar (uImage, rootfs, custconf)
- Identified SoC (RTL9607C), kernel (3.18.24), credentials (admin/stdONU101)
- Mapped CLI command tree via `/bin/cli` strings analysis
- Found hidden `enterlinuxshell` command

### Phase 2: Shell Access
- Exploited `SHELL_KEY_SWITCH=0` → no password required
- Achieved root shell via telnet → `enterlinuxshell` → `#` prompt
- Confirmed BusyBox v1.22.1, MTD partitions, GPON status

### Phase 3: Bootloop Recovery
- Bricked router with aggressive DNS iptables (`OUTPUT -p udp --dport 53 -j DROP`)
- Developed Python telnet client with IAC negotiation for automation
- Recovered via SSH/telnet race during brief boot window
- Lesson: GPON OMCI uses UDP/53 → blocking it kills registration

### Phase 4: Custom Binary Deployment
- Cross-compiled with Zig: `zig cc -target mips-linux-musleabi -Os -s`
- Failed attempts: Go binaries (futex ENOSYS), UPX on Go (segfault)
- Successful: Pure C, statically linked, <1MB each
- Transfer via: netcat, SSH cat pipe, base64 over telnet

### Phase 5: DNS Privacy & Adblocking
- Combined 4 blocklists: StevenBlack, AdGuard, Hagezi, Pete Lowe (~85K domains)
- dnsmasq `addn-hosts` for adblock (not iptables—too slow)
- Cloudflare 1.1.1.1 upstream (verified via `one.one.one.one/help`)
- DNS hijack: `iptables -t nat -I PREROUTING -s 192.168.1.0/24 ! -d 192.168.1.1 -p udp --dport 53 -j DNAT --to 192.168.1.1:53`

### Phase 6: QoS & Gaming Optimization
- Realtek HW QoS via `/proc/rg/assign_access_ip` (PC = priority 1)
- iptables TOS marking for: gaming, VoIP, DNS, DHCP, SSH
- pfifo_fast queue discipline (3 priority bands)
- SmartQoS daemon monitors + auto-repairs every 30s

### Phase 7: External Access (SOCKS5 + SSH)
- Deployed `socks5proxy` (RFC 1928/1929 auth: admin/stdONU101)
- Built `protomux` to share port 443 (SSH vs SOCKS5 by first byte)
- iptables `REDIRECT` WAN 443 → 8443 → protomux → {2222, 1080}
- Tested externally via phone (mobile data)

### Phase 8: Boot Persistence & GPON Safety
- V13 boot script: `wait_for_gpon()` function (polls nas0_0/ppp0 for 120s)
- Wildcard DNAT only on ppp0 (WAN), not globally
- DHCP DNS patch: force `opt dns 192.168.1.1` in udhcpd.conf
- Watchdog: checks services every 30s, restarts dead ones

---

## Security Implications

### What Was Achieved
- **ISP visibility reduced**: DNS queries encrypted (Cloudflare), adblocking prevents telemetry
- **TR-069 disabled**: ISP can't push remote configs/firmware (verified `cwmpClient` killed)
- **SSH hardened**: Key-only auth, non-standard port (2222), external via 443
- **SOCKS5 authentication**: Username/password required (not open proxy)

### What Remains Vulnerable
- **Firmware updates**: ISP can reflash—would wipe modifications (mitigated: adblock_hosts in `/var/config` persists)
- **GPON layer**: ONT still reports to OLT (ISP fiber head-end)—device can be remotely disabled
- **No HTTPS validation**: BusyBox wget doesn't verify certs—MITM risk on firmware/updates
- **Physical access**: Router is in user's home—no protection against tampering

### Disclaimer
This project is **educational**. Modifications void warranties, may violate ToS, and can result in service termination. The ISP owns the ONT—unauthorized changes may breach local laws. **Proceed at your own risk.**

---

## Repository Structure

```
frankenrouter/
├── README.md                           # This file
├── LICENSE                             # MIT License
├── docs/                               # Technical documentation
│   ├── 01_firmware_extraction.md      # Reverse engineering the firmware tar
│   ├── 02_analysis.md                 # Filesystem, binaries, config deep-dive
│   ├── 03_shell_access.md             # Exploiting enterlinuxshell
│   ├── 04_bootloop_recovery.md        # Fixing GPON registration failures
│   ├── 05_custom_binaries.md          # Cross-compiling for MIPS with Zig
│   ├── 06_dns_adblock.md              # DNS hijacking + 85K domain blocklist
│   ├── 07_qos_smartqos.md             # Hardware QoS + SmartQoS daemon
│   ├── 08_external_access.md          # SOCKS5, SSH, protomux on port 443
│   ├── 09_boot_persistence.md         # GPON-safe script + watchdog
│   └── architecture.md                # System diagrams and flows
├── scripts/                            # Automation scripts
│   ├── firmware/
│   │   ├── extract_squashfs.sh        # Extract rootfs/custconf from tar
│   │   └── analyze_cli.py             # Parse /bin/cli for commands
│   ├── access/
│   │   ├── telnet_client.py           # Python telnet with IAC negotiation
│   │   └── ssh_tunnel.sh              # Establish SSH SOCKS tunnel
│   ├── deployment/
│   │   ├── deploy_via_nc.py           # Transfer files via netcat
│   │   ├── deploy_via_ssh.sh          # Push binaries over SSH
│   │   └── apply_boot_script.sh       # Install run_test.sh to router
│   └── monitoring/
│       ├── monitor_services.py        # Check router health (SSH, DNS, SOCKS)
│       └── watchdog.sh                # Router-side service watchdog
├── configs/                            # Configuration files
│   ├── router/
│   │   ├── run_test.sh                # V13 GPON-safe boot script
│   │   ├── run_customized_sdk.sh      # Firmware boot hook
│   │   ├── dnsmasq.conf               # DNS server config
│   │   ├── adblock_full.hosts         # 85K blocked domains
│   │   └── udhcpd_patch.sh            # DHCP DNS patcher
│   └── iptables/
│       ├── nat_rules.sh               # DNS hijack, port redirect
│       ├── mangle_tos.sh              # QoS TOS marking
│       └── filter_rules.sh            # Basic firewall
├── src/                                # Source code for custom binaries
│   ├── protomux/
│   │   ├── protomux.c                 # Protocol multiplexer (SSH/SOCKS5)
│   │   └── build.sh                   # Zig cross-compile for MIPS
│   ├── socks5proxy/
│   │   ├── socks5proxy.c              # SOCKS5 server with auth
│   │   └── build.sh                   # Zig cross-compile for MIPS
│   └── smartqos/
│       ├── smartqos.c                 # QoS monitoring daemon
│       └── build.sh                   # Zig cross-compile for MIPS
└── assets/
    └── diagrams/
        ├── boot_flow.txt              # ASCII boot sequence diagram
        ├── dns_flow.txt               # DNS query path
        └── architecture.png           # System architecture diagram
```

---

## Getting Started

### Prerequisites
- VSOL V2802DAC v5 router (or similar Realtek RTL9607C-based GPON ONT)
- Telnet access to router (enabled via web UI or default-on)
- Python 3.8+ (for deployment scripts)
- Zig 0.11+ (for cross-compilation)
- SSH client (OpenSSH, PuTTY, etc.)

### Quick Start

1. **Gain Shell Access**
   ```bash
   telnet 192.168.1.1
   # Login: admin
   # Password: stdONU101
   > enterlinuxshell
   # (press Enter if no password set)
   ```

2. **Deploy Boot Hook**
   ```bash
   cd scripts/deployment
   ./apply_boot_script.sh
   ```

3. **Upload Custom Binaries**
   ```bash
   # Build first (requires Zig)
   cd src/protomux && ./build.sh
   cd src/socks5proxy && ./build.sh
   cd src/smartqos && ./build.sh
   
   # Deploy
   cd scripts/deployment
   ./deploy_via_ssh.sh
   ```

4. **Reboot and Verify**
   ```bash
   ssh -p 2222 admin@192.168.1.1
   # Check services
   ps | grep -E "dropbear|socks5|protomux|smartqos|dnsmasq"
   ```

---

## Testing

### DNS Adblock Test
```bash
# On your PC (connected to router)
nslookup doubleclick.net
# Expected: 0.0.0.0

nslookup google.com
# Expected: Normal IP (e.g., 142.250.x.x)
```

### Cloudflare Verification
Visit https://one.one.one.one/help/
- "Connected to 1.1.1.1": **Yes**
- "Using DNS over HTTPS (DoH)" or "Using DNS over TLS (DoT)": **No** (plaintext to Cloudflare is fine—ISP can't see)

### SOCKS5 Proxy Test
```bash
# Local test
curl -x socks5://admin:stdONU101@192.168.1.1:1080 http://ifconfig.me
# Should return router's WAN IP

# External test (from phone/mobile data)
curl -x socks5://admin:stdONU101@rancour.ddns.net:443 http://ifconfig.me
# Should return router's WAN IP
```

### SSH External Access
```bash
ssh -p 443 admin@rancour.ddns.net
# Connects via protomux → Dropbear (2222)
```

---

## Known Issues

### HWNAT vs iptables
- **Issue**: Realtek hardware NAT offloading bypasses some iptables rules
- **Mitigation**: Critical rules placed early in PREROUTING/POSTROUTING chains
- **Status**: Working for DNS hijack, port redirects; QoS unaffected

### GPON Registration Race
- **Issue**: Aggressive iptables (`OUTPUT -p udp --dport 53 -j DROP`) blocks GPON OMCI
- **Mitigation**: V13 script waits for GPON (nas0_0/ppp0 IP) before applying rules
- **Status**: Fixed—no boot failures in 5+ tests

### DHCP DNS Persistence
- **Issue**: `/var/udhcpd/udhcpd.conf` regenerated on boot with ISP DNS
- **Mitigation**: Boot script patches `opt dns 192.168.1.1` via sed, restarts udhcpd
- **Status**: Working—clients get router as DNS

### Flash Wear
- **Issue**: Frequent writes to `/var/config/` can wear flash
- **Mitigation**: Logs to `/tmp` (RAM), only configs in `/var/config/`
- **Status**: Monitoring—no failures after 6 months

---

## Future Work

- [ ] **DNS-over-HTTPS (DoH)**: Proxy to Cloudflare 1.1.1.1:443/dns-query
- [ ] **IPv6 support**: Requires spppd recompilation (currently IPv4-only)
- [ ] **Web UI**: Minimal HTTP interface for adblock list management
- [ ] **Auto-update adblock**: Fetch fresh lists from StevenBlack/Hagezi weekly
- [ ] **Intrusion detection**: Log suspicious port scans via iptables
- [ ] **Firmware backup**: Dump MTD partitions to USB before modifications

---

## Contributing

This is a personal project documenting real-world modifications to a specific device. Contributions welcome if you:
- Have a similar RTL9607C-based GPON ONT
- Found alternative access methods
- Improved binary sizes or performance
- Documented additional Realtek `/proc/rg/` registers

Open an issue or PR with details.

---

## License

MIT License. See [LICENSE](LICENSE) for full text.

**Disclaimer**: This project modifies ISP-provided equipment. Unauthorized changes may:
- Void warranties
- Violate terms of service
- Result in service termination
- Breach local telecommunications laws

The author is NOT responsible for bricked devices, legal consequences, or loss of service. **Use at your own risk.**

---

## Acknowledgments

- **Reverse Engineering**: binwalk, PySquashfsImage, strings, hexdump
- **Cross-Compilation**: Zig compiler, musl libc
- **Blocklists**: StevenBlack, AdGuard, Hagezi, Pete Lowe
- **DNS Verification**: Cloudflare (one.one.one.one/help)
- **Community**: OpenWrt forums, EEVblog, /r/homelab, /r/networking

---

**Project Duration**: 6 months, 66 engineering phases  
**Router Cost**: ~$20 USD  
**Flash Used**: 7.1MB / 10.6MB (66%)  
**Uptime Record**: 37 days, 14 hours (until ISP power outage)

> "The best router is the one you control."
