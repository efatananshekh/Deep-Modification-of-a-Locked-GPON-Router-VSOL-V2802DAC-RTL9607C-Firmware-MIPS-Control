# Getting Started with Frankenrouter

This guide walks you through replicating the Frankenrouter modifications on your own VSOL V2802DAC v5 (or similar Realtek RTL9607C-based GPON router).

---

## ⚠️ WARNING: READ THIS FIRST

**CRITICAL SAFETY INFORMATION:**

1. **You CAN brick your router** — There is no JTAG, limited UART access, and mistakes can require motherboard replacement
2. **This WILL void your warranty** — Proceed only if you accept full responsibility
3. **ISP connectivity may be affected** — Have a backup internet source during testing
4. **Read ALL documentation** before attempting any modifications
5. **BACKUP EVERYTHING** — See Step 0 below

**Estimated time investment:** 6-12 hours (spread over multiple days for safety)

**Skill level required:**
- Linux command line (intermediate)
- Networking concepts (TCP/IP, DNS, iptables)
- Cross-compilation (basic understanding)
- Troubleshooting (critical thinking)

**If any of the following apply to you, STOP:**
- You cannot afford to replace the router if it breaks
- This is your only internet connection with no backup
- You don't understand how NAT or DNS works
- You're uncomfortable with command-line tools
- You haven't read the full documentation

---

## Prerequisites

### Hardware
- **VSOL V2802DAC v5** (or similar RTL9607C-based GPON ONU)
- **PC/Laptop** (Windows, Linux, or macOS)
- **Ethernet cable** (for LAN connection)
- **Backup internet** (mobile hotspot recommended for recovery)

### Software
- **Telnet client** (PuTTY on Windows, `telnet` on Linux/Mac)
- **Python 3.8+** (for deployment scripts)
- **Zig compiler 0.11.0+** (for cross-compiling binaries)
- **Text editor** (VS Code, Notepad++, vim, etc.)

### Knowledge
- Read `docs/architecture.md` FIRST — understand the system
- Read `docs/01_firmware_extraction.md` — understand firmware structure
- Read `docs/02_shell_access.md` — understand access methods
- Read `docs/03_bootloop_recovery.md` — understand risks and recovery

---

## Step 0: Backup Everything

### 0.1 Backup Router Configuration (Web UI)

1. Access web UI: http://192.168.1.1
2. Login: `admin` / `stdONU101` (or your custom password)
3. Navigate: **System Tools** → **Backup/Restore**
4. Click **Backup** → Save `config.bin`
5. Store safely (you'll need this if recovery is required)

### 0.2 Backup Flash Configuration (Shell)

```bash
# Connect via telnet
telnet 192.168.1.1

# Login: admin / stdONU101

# Get shell
>enterlinuxshell

# Backup /var/config/ partition
/ # cd /var/config
/ # tar czf /tmp/config_backup.tar.gz .
/ # 

# On PC, download via HTTP server (on router):
/ # cd /tmp
/ # python -m SimpleHTTPServer 8080 &

# On PC browser: http://192.168.1.1:8080/config_backup.tar.gz
# Download and save securely
```

### 0.3 Record Critical MIB Values

```bash
/ # flash get GPON_SN
GPON_SN=HWTC007C9DA2  ← WRITE THIS DOWN

/ # flash get GPON_MAC
GPON_MAC=007C9DA2  ← WRITE THIS DOWN

/ # flash get PON_MODE
PON_MODE=1  ← WRITE THIS DOWN (1=GPON, 2=EPON)

/ # flash get SUSER_PASSWORD
SUSER_PASSWORD=stdONU101  ← WRITE THIS DOWN
```

**Store these values in a text file. You'll need them if you have to factory reset.**

---

## Step 1: Gain Shell Access

### 1.1 Connect via Telnet

```bash
telnet 192.168.1.1
```

Login:
```
login: admin
Password: stdONU101
```

### 1.2 Enter Linux Shell

At the `>` prompt, type:
```
>enterlinuxshell
```

You should see:
```
/ #
```

Verify root access:
```bash
/ # id
uid=0(root) gid=0(root)
```

✅ **SUCCESS**: You have root shell access.

---

## Step 2: Assess Flash Space

### 2.1 Check Available Space

```bash
/ # df -h /var/config
Filesystem                Size      Used Available Use% Mounted on
/dev/mtdblock3           10.6M      3.1M      7.5M  29% /var/config
```

**Available**: 7.5 MB  
**Required for full setup**: ~7 MB

**Decision point:**
- If you have <3 MB available: Clean up first (see Troubleshooting)
- If you have 3-7 MB: Proceed, but skip large adblock list (use smaller one)
- If you have >7 MB: Proceed with full setup

### 2.2 Create Working Directory

```bash
/ # mkdir -p /var/config/.ssh
/ # mkdir -p /var/config/scripts
/ # cd /var/config
```

---

## Step 3: Set Up SSH Access (Dropbear)

### 3.1 Cross-Compile Dropbear (on PC)

```bash
# Download Dropbear source
wget https://matt.ucc.asn.au/dropbear/releases/dropbear-2022.83.tar.bz2
tar -xf dropbear-2022.83.tar.bz2
cd dropbear-2022.83

# Configure for static build
./configure --host=mips-linux --disable-zlib --disable-wtmp --disable-lastlog

# Build with Zig
export CC="zig cc -target mips-linux-musl"
export CFLAGS="-Os -fno-stack-protector"
export LDFLAGS="-static"

make PROGRAMS="dropbear dbclient dropbearkey"

# Result: dropbearmulti binary (~757 KB)
```

### 3.2 Upload to Router

**On PC:**
```bash
# Start HTTP server
python3 -m http.server 8000
```

**On router:**
```bash
/ # cd /var/config
/ # wget http://192.168.1.100:8000/dropbearmulti
/ # chmod +x dropbearmulti
/ # ln -s dropbearmulti dropbear
/ # ln -s dropbearmulti dropbearkey
```

### 3.3 Generate Host Key

```bash
/ # cd /var/config/.ssh
/ # ../dropbearkey -t ed25519 -f dropbear_ed25519_host_key
Will output 256 bit ed25519 secret key to 'dropbear_ed25519_host_key'
Key fingerprint: ...
```

### 3.4 Add Your SSH Public Key

**On PC**, generate key if you don't have one:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/frankenrouter_ed25519
```

**On router**, add your public key:
```bash
/ # cat > /var/config/.ssh/authorized_keys << 'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... your-email@example.com
EOF
/ # chmod 600 /var/config/.ssh/authorized_keys
```

### 3.5 Test SSH

**Start Dropbear temporarily:**
```bash
/ # /var/config/dropbear -p 2222 -r /var/config/.ssh/dropbear_ed25519_host_key
```

**On PC:**
```bash
ssh -p 2222 -i ~/.ssh/frankenrouter_ed25519 root@192.168.1.1
```

✅ **SUCCESS**: You should get a root shell via SSH.

---

## Step 4: Deploy Boot Script (V13 GPON-Safe)

### 4.1 Create run_customized_sdk.sh

```bash
/ # cat > /var/config/run_customized_sdk.sh << 'EOF'
#!/bin/sh
/var/config/run_test.sh
EOF
/ # chmod +x /var/config/run_customized_sdk.sh
```

### 4.2 Create run_test.sh (Minimal Version)

```bash
/ # cat > /var/config/run_test.sh << 'EOF'
#!/bin/sh
echo "Boot script V13 starting..." >> /tmp/boot.log

# PHASE 1: Wait for GPON registration
MAX_WAIT=120
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
    IP=$(ifconfig nas0_0 2>/dev/null | grep 'inet addr' | cut -d: -f2 | awk '{print $1}')
    if [ -n "$IP" ] && [ "$IP" != "0.0.0.0" ]; then
        echo "GPON registered: $IP" >> /tmp/boot.log
        break
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo "ERROR: GPON timeout" >> /tmp/boot.log
fi

# PHASE 2: Start Dropbear SSH
if [ -f /var/config/dropbear ]; then
    /var/config/dropbear -p 2222 -r /var/config/.ssh/dropbear_ed25519_host_key
    echo "Dropbear started on port 2222" >> /tmp/boot.log
fi

echo "Boot script V13 completed" >> /tmp/boot.log
EOF
/ # chmod +x /var/config/run_test.sh
```

### 4.3 Test Boot Script

```bash
/ # /var/config/run_test.sh
# Wait 30 seconds
/ # cat /tmp/boot.log
Boot script V13 starting...
GPON registered: 103.155.218.139
Dropbear started on port 2222
Boot script V13 completed
```

✅ **SUCCESS**: Boot script works.

### 4.4 Test Reboot

```bash
/ # reboot
```

Wait 2-3 minutes, then test SSH:
```bash
ssh -p 2222 -i ~/.ssh/frankenrouter_ed25519 root@192.168.1.1
```

✅ **SUCCESS**: SSH persists across reboots.

---

## Step 5: Configure DNS Privacy (Optional but Recommended)

### 5.1 Create Custom dnsmasq Configuration

```bash
/ # cat > /var/config/dnsmasq.conf << 'EOF'
interface=br0
bind-interfaces
server=1.1.1.1
server=1.0.0.1
all-servers
cache-size=1000
neg-ttl=30
no-resolv
no-poll
log-queries
log-facility=/tmp/dns_queries.log
EOF
```

### 5.2 Add DNS Hijacking to Boot Script

Edit `/var/config/run_test.sh` and add AFTER the GPON wait:

```bash
# PHASE 3: DNS Hijacking
iptables -t nat -A PREROUTING -s 192.168.1.0/24 ! -d 192.168.1.1 -p udp --dport 53 -j DNAT --to 192.168.1.1:53
iptables -t nat -A PREROUTING -s 192.168.1.0/24 ! -d 192.168.1.1 -p tcp --dport 53 -j DNAT --to 192.168.1.1:53

# PHASE 4: Start Custom dnsmasq
killall dnsmasq
sleep 1
dnsmasq -C /var/config/dnsmasq.conf &
echo "dnsmasq started with Cloudflare DNS" >> /tmp/boot.log

# PHASE 5: Fix DHCP DNS
sleep 5
if grep -q "opt dns 192.10.20.2" /var/udhcpd/udhcpd.conf 2>/dev/null || \
   grep -q "opt dns 8.8.8.8" /var/udhcpd/udhcpd.conf 2>/dev/null; then
    sed -i 's/^opt dns .*/opt dns 192.168.1.1/' /var/udhcpd/udhcpd.conf
    killall -HUP udhcpd
    echo "DHCP DNS patched" >> /tmp/boot.log
fi
```

### 5.3 Test DNS

```bash
/ # nslookup google.com
Server:    127.0.0.1
Address 1: 127.0.0.1 localhost

Name:      google.com
Address 1: 142.250.67.78
```

✅ **SUCCESS**: DNS working via router.

---

## Step 6: Add Adblocking (Optional)

### 6.1 Generate Small Adblock List (on PC)

```python
# adblock_generator.py
import requests

urls = [
    'https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts',
]

domains = set()

for url in urls:
    resp = requests.get(url)
    for line in resp.text.split('\n'):
        if line.startswith('0.0.0.0 ') and len(line.split()) == 2:
            domain = line.split()[1]
            if domain != '0.0.0.0':
                domains.add(domain)

with open('adblock_small.hosts', 'w') as f:
    for domain in sorted(domains):
        f.write(f'0.0.0.0 {domain}\n')

print(f"Blocked domains: {len(domains)}")
```

Run:
```bash
python3 adblock_generator.py
# Output: adblock_small.hosts (~30,000 domains, ~1 MB)
```

### 6.2 Upload to Router

```bash
# On PC
python3 -m http.server 8000

# On router
wget http://192.168.1.100:8000/adblock_small.hosts -O /var/config/adblock.hosts
```

### 6.3 Update dnsmasq.conf

```bash
echo "addn-hosts=/var/config/adblock.hosts" >> /var/config/dnsmasq.conf
```

### 6.4 Test Adblock

```bash
/ # nslookup doubleclick.net
Server:    127.0.0.1
Address 1: 127.0.0.1 localhost

Name:      doubleclick.net
Address 1: 0.0.0.0  ← BLOCKED!
```

✅ **SUCCESS**: Adblocking working.

---

## Step 7: Hardware QoS (Optional, Advanced)

**NOTE**: Only do this if you understand QoS and have a specific gaming PC to prioritize.

### 7.1 Set Gaming PC IP Priority

```bash
# Replace 192.168.1.36 with YOUR gaming PC's IP
echo "0xc0a80124" > /proc/rg/assign_access_ip  # 0xc0a80124 = 192.168.1.36
echo "1" > /proc/rg/qos_ring_0
echo "1" > /proc/rg/qos_ring_7
```

### 7.2 Add to Boot Script

```bash
# PHASE 6: Hardware QoS
echo "0xc0a80124" > /proc/rg/assign_access_ip
echo "1" > /proc/rg/qos_ring_0
echo "1" > /proc/rg/qos_ring_7
echo "HW QoS enabled for 192.168.1.36" >> /tmp/boot.log
```

### 7.3 Test Gaming Latency

**Before**: Ping during download = 200-300ms  
**After**: Ping during download = 12-15ms

---

## Troubleshooting

### Problem: Router won't boot after script deployment

**Solution**: See `docs/03_bootloop_recovery.md` for TFTP recovery or formImportOMCIShell cleanup.

### Problem: SSH connection refused after reboot

```bash
# Via telnet:
/ # pidof dropbear
# If no output, dropbear didn't start

/ # cat /tmp/boot.log
# Check for errors

/ # /var/config/dropbear -p 2222 -r /var/config/.ssh/dropbear_ed25519_host_key
# Manual start for debugging
```

### Problem: DNS not working

```bash
/ # pidof dnsmasq
# Should show PID

/ # cat /tmp/dns_queries.log
# Check for queries

/ # netstat -ulnp | grep :53
# Should show dnsmasq listening
```

### Problem: Out of flash space

```bash
/ # df -h /var/config
# Check usage

# Delete large files:
/ # rm /var/config/adblock.hosts  # Frees 1-3 MB
/ # rm /var/config/old_backups/*
```

---

## Next Steps

Once basic setup is working:
1. Read `docs/04_custom_binaries.md` — Cross-compile SOCKS5 proxy, protomux
2. Read `docs/05_dns_privacy_adblock.md` — Advanced DNS configuration
3. Read `docs/06_smartqos_hardware_acceleration.md` — Full QoS setup

---

## Safety Reminders

- **Test incrementally**: Add one feature at a time, verify stability
- **Keep backups**: Save working configurations before major changes
- **Monitor logs**: Check `/tmp/boot.log` after each reboot
- **Have recovery plan**: Know how to use TFTP recovery BEFORE you need it
- **Don't rush**: This project took 6 months of careful testing

**Good luck, and remember: You're modifying a critical piece of network infrastructure. Take your time and understand what you're doing.**

---

**Questions or issues?** See `docs/architecture.md` for system internals, or review the 66 checkpoints in `.copilot/session-state/checkpoints/` for detailed history of how each problem was solved.
