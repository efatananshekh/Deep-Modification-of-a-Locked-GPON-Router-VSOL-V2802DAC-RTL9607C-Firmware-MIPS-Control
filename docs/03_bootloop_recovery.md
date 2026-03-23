# Phase 3: Bootloop Recovery and Safety Mechanisms

## Overview

One of the most dangerous aspects of embedded router modification is the risk of creating an unrecoverable boot loop. This phase documents multiple boot loop incidents, their root causes, and the recovery techniques developed through trial and error.

**Critical context**: This router has:
- NO JTAG port (no hardware debugging)
- NO UART access (serial console disabled in production units)
- NO factory reset that clears `/var/config/` (only deletes `lastgood.xml`)
- ECDSA-signed firmware (can't inject cleanup scripts)

Bricking the router means **motherboard replacement** or **TFTP recovery** (requires special button timing).

---

## Boot Loop #1: The Adblock Disaster

### The Mistake

Following generic "router adblock" instructions from ChatGPT, the following files were created in `/var/config/`:

```bash
# /var/config/run_test.sh
#!/bin/sh
killall dnsmasq
dnsmasq -C /var/dnsmasq.conf --addn-hosts=/var/config/adblock.hosts
```

```bash
# /var/config/adblock_boot.sh
#!/bin/sh
wget -O /var/config/adblock.hosts https://example.com/adblock.txt
```

```bash
# /var/config/crontab
0 3 * * * /var/config/adblock_boot.sh
```

### The Chain Reaction

1. **Boot starts**: `/etc/init.d/rc35` calls `/var/config/run_customized_sdk.sh`
2. **Script executes**: `run_test.sh` kills ISP's dnsmasq
3. **dnsmasq crashes**: Port 53 stuck open (socket in TIME_WAIT)
4. **DHCP fails**: Clients can't get IP addresses
5. **Watchdog triggers**: "System unresponsive" after 90 seconds
6. **Reboot**: Cycle repeats every 2-3 minutes

### Symptoms Observed

- **GPON LED**: Blinking constantly (not solid green)
- **WiFi**: Comes up when GPON fiber is unplugged, disappears when plugged in
- **LAN**: DHCP fails (Windows shows "169.254.x.x" address)
- **Telnet**: Connection refused (port 23 not open)
- **Web UI**: Briefly accessible (30-60 seconds), then router reboots

### Why It Happened

**Timing issue**: The script killed dnsmasq BEFORE GPON registration completed. This caused:
- DNS queries from GPON OMCI stack to fail
- ISP OLT couldn't communicate with the ONU
- GPON registration loop

**Port conflict**: Killing dnsmasq didn't immediately free port 53. The new dnsmasq instance failed to bind, causing silent failure.

---

## Recovery Attempt #1: Firmware Modification (Failed)

### Strategy

Modify the firmware TAR to add cleanup code to `fwu.sh`:

```bash
# Added to start of fwu.sh
rm -rf /var/config/run_test.sh
rm -rf /var/config/adblock_boot.sh
rm -rf /var/config/adblock.hosts
rm -rf /var/config/crontab
sync
```

### Execution

```python
import tarfile

# Extract TAR
tar = tarfile.open('firmware.tar', 'r')
tar.extractall('firmware_extracted/')
tar.close()

# Modify fwu.sh
with open('firmware_extracted/fwu.sh', 'r') as f:
    content = f.read()

new_content = """#!/bin/sh
# CLEANUP MALICIOUS SCRIPTS
rm -rf /var/config/run_test.sh
rm -rf /var/config/adblock_boot.sh
rm -rf /var/config/adblock.hosts
rm -rf /var/config/crontab
sync

""" + content

with open('firmware_extracted/fwu.sh', 'w') as f:
    f.write(new_content)

# Repack TAR
tar = tarfile.open('firmware_FIXED.tar', 'w')
for file in os.listdir('firmware_extracted/'):
    tar.add(f'firmware_extracted/{file}', arcname=file)
tar.close()
```

### Result

**FAILED**: Router rejected the firmware with no error message.

### Root Cause Analysis

The `fwu_key` file (47 bytes) is an **ECDSA signature** of `md5.txt`:

```bash
openssl dgst -sha256 -verify pubkey.pem -signature fwu_key md5.txt
```

**Verification flow in fwu.sh:**
1. Calculate MD5 of all TAR files
2. Verify MD5 sums match `md5.txt`
3. Verify ECDSA signature of `md5.txt` using embedded public key
4. If any step fails: silently reject firmware (no flash write)

**Modifying fwu.sh changes its MD5 → md5.txt mismatch → signature invalid → rejection.**

**Implication**: We cannot use firmware upgrades to recover from `/var/config/` corruption.

---

## Recovery Attempt #2: Web UI Command Injection (Blocked)

### Strategy

Exploit the web UI's diagnostic ping form to execute shell commands.

### Code Analysis

**boa binary** (web server) contains:
```c
sprintf(cmd, "ping -c 3 -w 6 %s -I nas0_0 > /tmp/pon_diag_ping.tmp", dest);
system(cmd);
```

**Injection attempt:**
```
Destination: 8.8.8.8; rm -rf /var/config/run_test.sh #
```

**Expected command:**
```bash
ping -c 3 -w 6 8.8.8.8; rm -rf /var/config/run_test.sh # -I nas0_0 > /tmp/pon_diag_ping.tmp
```

### Execution

```powershell
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$cookie = New-Object System.Net.Cookie('sessionid', '1234567890', '/', '192.168.1.1')
$session.Cookies.Add($cookie)

Invoke-WebRequest -Uri "http://192.168.1.1/boaform/admin/formPing" `
    -Method POST `
    -Body "dest=8.8.8.8;rm+-rf+/var/config/run_test.sh%23" `
    -WebSession $session
```

### Result

**BLOCKED**: Server returned "Incorrect destination address or WAN interface!"

### Root Cause

**Server-side validation** in boa:
```c
if (!is_valid_ip(dest) && !is_valid_hostname(dest)) {
    send_error("Incorrect destination address or WAN interface!");
    return;
}
```

The server checks input BEFORE constructing the shell command. Injection characters like `;`, `#`, `|` cause validation failure.

**Implication**: Command injection via web UI is not possible (at least not via formPing).

---

## Recovery Attempt #3: OMCI Shell Upload (Success!)

### Discovery

**Boa binary analysis** revealed a hidden form handler:
```c
void formImportOMCIShell(request *req) {
    save_uploaded_file(req, "/tmp/omcishell");
    system("/bin/sh /tmp/omcishell");
    send_response(req, "OMCI shell executed");
}
```

**Key insight**: This endpoint accepts file uploads and executes them with `/bin/sh`. No validation, no restrictions.

### Exploitation

**Step 1: Create cleanup script**
```bash
#!/bin/sh
rm -rf /var/config/run_test.sh
rm -rf /var/config/adblock_boot.sh
rm -rf /var/config/adblock.hosts
rm -rf /var/config/crontab
rm -rf /var/config/rc.local
sync
reboot
```

**Step 2: Upload via web UI**
```powershell
$boundary = [System.Guid]::NewGuid().ToString()
$bodyLines = @(
    "--$boundary",
    'Content-Disposition: form-data; name="file"; filename="cleanup.sh"',
    'Content-Type: application/x-sh',
    '',
    (Get-Content cleanup.sh -Raw),
    "--$boundary--"
)
$body = $bodyLines -join "`r`n"

Invoke-WebRequest -Uri "http://192.168.1.1/boaform/admin/formImportOMCIShell" `
    -Method POST `
    -ContentType "multipart/form-data; boundary=$boundary" `
    -Body $body `
    -WebSession $session
```

### Result

**SUCCESS**: Router executed the script, deleted malicious files, and rebooted into clean state.

### Why It Worked

- No input validation on uploaded file
- `/tmp/omcishell` executed with root privileges
- Script had full `/var/config/` write access
- `sync` ensured flash writes completed before reboot

**Lesson learned**: Always look for file upload endpoints in embedded web UIs — they often lack proper sanitization.

---

## Boot Loop #2: GPON Registration Race Condition

### The Mistake

**V12 boot script** applied aggressive iptables rules immediately on boot:

```bash
#!/bin/sh
# run_test.sh V12
iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53
iptables -A INPUT -p udp --dport 53 -m limit --limit 100/sec -j ACCEPT
iptables -A INPUT -p udp --dport 53 -j DROP

# Start services...
dropbear -p 2222
dnsmasq -C /var/dnsmasq.conf
```

### The Chain Reaction

1. **Boot starts**: Script applies iptables rules
2. **DNS queries blocked**: GPON OMCI can't resolve ISP servers
3. **GPON registration fails**: LED blinks forever
4. **No WAN IP**: `nas0_0` and `ppp0` stay down
5. **Clients have no internet**: LAN works, WAN doesn't

### Symptoms Observed

- **GPON LED**: Blinking (not solid)
- **WAN IP**: None (`ifconfig nas0_0` shows no IP)
- **Internet**: Completely down
- **Telnet/SSH**: Accessible (LAN works)

### Why It Happened

**iptables rules blocked GPON OMCI traffic** (UDP port 53 used by ISP's provisioning system). The `--limit 100/sec` was too restrictive for the burst of DNS queries during GPON registration.

---

## Recovery Strategy: V13 GPON-Safe Script

### The Solution

**Wait for GPON registration BEFORE applying iptables rules.**

```bash
#!/bin/sh
# run_test.sh V13 — GPON-Safe

# PHASE 1: Hardware QoS (safe, doesn't affect GPON)
echo "0xc0a80124" > /proc/rg/assign_access_ip
echo "1" > /proc/rg/qos_ring_0

# PHASE 2: WAIT FOR GPON REGISTRATION
MAX_WAIT=120
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
    # Check if nas0_0 or ppp0 has an IP
    IP=$(ifconfig nas0_0 2>/dev/null | grep 'inet addr' | cut -d: -f2 | awk '{print $1}')
    if [ -n "$IP" ] && [ "$IP" != "0.0.0.0" ]; then
        echo "GPON registered with IP: $IP" >> /tmp/boot.log
        break
    fi
    
    IP=$(ifconfig ppp0 2>/dev/null | grep 'inet addr' | cut -d: -f2 | awk '{print $1}')
    if [ -n "$IP" ] && [ "$IP" != "0.0.0.0" ]; then
        echo "PPPoE registered with IP: $IP" >> /tmp/boot.log
        break
    fi
    
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo "ERROR: GPON registration timeout after ${MAX_WAIT}s" >> /tmp/boot.log
    # Continue anyway (degraded mode)
fi

# PHASE 3: Apply iptables (NOW SAFE)
iptables -t nat -A PREROUTING -s 192.168.1.0/24 ! -d 192.168.1.1 -p udp --dport 53 -j DNAT --to 192.168.1.1:53
iptables -t nat -A PREROUTING -s 192.168.1.0/24 ! -d 192.168.1.1 -p tcp --dport 53 -j DNAT --to 192.168.1.1:53

# PHASE 4: Start services
dropbear -p 2222 -r /var/config/.ssh/dropbear_ed25519_host_key
/var/config/socks5proxy -p 1080 -u admin -w stdONU101 &
/var/config/protomux -p 8443 -s 127.0.0.1:2222 -o 127.0.0.1:1080 &

# PHASE 5: DNS + Adblock
killall dnsmasq
sleep 1
dnsmasq -C /var/config/dnsmasq.conf --addn-hosts=/var/config/adblock_full.hosts &

# PHASE 6: SmartQoS daemon
/var/config/smartqos daemon &

# PHASE 7: DHCP DNS patch
sleep 5  # Wait for GPON to fully stabilize
if grep -q "opt dns 192.10.20.2" /var/udhcpd/udhcpd.conf 2>/dev/null || \
   grep -q "opt dns 8.8.8.8" /var/udhcpd/udhcpd.conf 2>/dev/null; then
    sed -i 's/^opt dns .*/opt dns 192.168.1.1/' /var/udhcpd/udhcpd.conf
    killall -HUP udhcpd
    echo "DHCP DNS patched" >> /tmp/boot.log
fi

echo "Boot script V13 completed" >> /tmp/boot.log
```

### Key Safety Features

1. **Hardware QoS first**: Realtek register writes don't affect network traffic
2. **GPON wait loop**: Checks every 2 seconds for WAN IP (max 120s)
3. **Degraded mode**: Continues even if GPON times out (allows telnet recovery)
4. **Sleep delays**: Prevents race conditions between services
5. **DHCP patch timing**: Waits 5 extra seconds after GPON for full stability

### Testing Results

```
Attempt 1: SUCCESS (GPON registered in 37 seconds, all services started)
Attempt 2: SUCCESS (GPON registered in 42 seconds, all services started)
Attempt 3: SUCCESS (GPON registered in 28 seconds, all services started)
Attempt 4: SUCCESS (GPON registered in 51 seconds, all services started)
Attempt 5: SUCCESS (GPON registered in 34 seconds, all services started)
```

**Longest uptime achieved**: 37 days, 14 hours (ended due to ISP maintenance, not router crash)

---

## Safety Checklist for Boot Scripts

### ✅ DO:
- Check for WAN IP before applying iptables rules
- Use `sleep` delays between dependent services
- Log all actions to `/tmp/boot.log` for debugging
- Test scripts manually before adding to `rc35` hook
- Keep old script versions as `/var/config/run_test.sh.v12.backup`
- Use `sync` before any reboot
- Protect custom binaries from OOM killer (`echo -17 > /proc/$PID/oom_adj`)

### ❌ DON'T:
- Apply iptables OUTPUT rules during GPON registration
- Kill system daemons (dnsmasq, pppd) without replacements
- Use `reboot` in scripts (creates flash write race conditions)
- Assume /tmp files exist (they're created by other services)
- Modify `/etc/` files (rootfs is read-only)
- Use `flash set` without `flash commit`
- Run blocking commands (use `&` for background jobs)

---

## Emergency Recovery Methods

### Method 1: TFTP Recovery (No Bricking)

1. **Prepare**: TFTP server on PC (192.168.1.100) with firmware TAR
2. **Power off router**
3. **Hold reset button**
4. **Power on** (keep holding reset for 10 seconds)
5. **Release**: Router enters recovery mode (power LED blinking)
6. **TFTP upload**: Router downloads firmware from 192.168.1.100
7. **Auto-flash**: Router flashes and reboots

**CRITICAL**: This method **DOES** erase `/var/config/` (confirmed via testing).

### Method 2: Web UI During Boot Window

1. **Watch for web UI**: Access http://192.168.1.1 during 30-60s window
2. **Login**: admin/stdONU101 (fast!)
3. **Navigate to**: System Tools → Restore Factory Defaults
4. **Click**: "Restore" (this only deletes `lastgood.xml`, NOT our files)
5. **Manually**: Use formImportOMCIShell to upload cleanup script

### Method 3: Serial Console (Requires Hardware Mod)

**Not attempted** (production units have UART disabled, requires soldering).

---

## Lessons Learned

1. **Race conditions are real**: Always wait for GPON before iptables
2. **Signature verification prevents firmware mods**: Can't inject cleanup
3. **Factory reset is useless**: Only deletes XML configs, not scripts
4. **formImportOMCIShell is a lifesaver**: Hidden endpoint saved the router
5. **TFTP recovery works**: Last resort, but erases all custom configs
6. **Logging is essential**: `/tmp/boot.log` makes debugging possible
7. **Test, test, test**: Manual script execution before automation

---

**Phase 3 Status**: ✅ COMPLETE  
**Boot Loops Survived**: 2  
**Recovery Methods Developed**: 3  
**Current Script Version**: V13 (GPON-Safe)  
**Uptime Record**: 37 days, 14 hours
