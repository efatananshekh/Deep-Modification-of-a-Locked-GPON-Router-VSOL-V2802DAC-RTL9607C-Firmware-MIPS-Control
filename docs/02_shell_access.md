# Phase 2: Achieving Root Shell Access

## Overview

With firmware analysis complete and credentials extracted, this phase covers the practical steps to gain full root shell access to the router. The challenge: the router's default telnet login drops users into a restricted CLI shell (`/bin/cli`), not a Linux shell.

---

## The Telnet Trap

### Initial Connection

```bash
telnet 192.168.1.1
```

**Expected behavior**: Login prompt for username/password.

**Actual behavior**: After successful login with `admin/stdONU101`, the router presents a custom CLI:

```
login: admin
Password: ****
It's recommended to change your default password for this device for security and safety reasons.
>
```

This is **NOT** a Linux shell. It's a restricted CLI implemented by `/bin/cli`.

### The Restricted CLI

**Available commands** (discovered via firmware analysis):
```
>help
    config      Configure system
    debug       Debug system
    exit        Exit command line interface
    help        Help information
    reboot      Reboot system
    show        Show system information
```

**Attempting standard Linux commands fails:**
```
>ls
command error!

>flash get GPON_SN
command error!
```

The CLI parser only accepts hardcoded commands. It does NOT execute shell commands.

---

## Discovery of enterlinuxshell

### Binary Analysis

During Phase 1 firmware extraction, string analysis of `/bin/cli` (111,116 bytes) revealed:

```python
import re

with open('rootfs_extracted/bin/cli', 'rb') as f:
    data = f.read()
    
# Search for shell-related strings
shell_cmds = re.findall(b'enter[a-z]+shell', data)
print(shell_cmds)  # Output: [b'enterlinuxshell']
```

**Critical finding**: The string `enterlinuxshell` appears in the binary, but it's NOT listed in the `help` command output. This suggests a **hidden command**.

### Password Mechanism

Further analysis found this code pattern:
```c
if (strcmp(input, "enterlinuxshell") == 0) {
    if (mib_get("SHELL_KEY_SWITCH") == 1) {
        printf("ShellPassword: ");
        fgets(password, 64, stdin);
        if (calPasswdMD5(password) != mib_get("SHELL_KEY_STRING")) {
            printf("Error!\n");
            return 1;
        }
    }
    execl("/bin/sh", "sh", NULL);
}
```

**Key variables:**
- `SHELL_KEY_SWITCH`: 0 = no password required, 1 = password required
- `SHELL_KEY_STRING`: MD5-hashed password (crypt format: `$1$salt$hash`)

### Testing SHELL_KEY_SWITCH Value

**After gaining shell access**, we checked the MIB value:
```bash
>enterlinuxshell
/ # flash get SHELL_KEY_SWITCH
SHELL_KEY_SWITCH=0

/ # flash get SHELL_KEY_STRING
SHELL_KEY_STRING=
```

**Confirmation**: This router has shell password disabled by default.

---

## Successful Root Shell Access

### Step-by-Step Procedure

1. **Connect via telnet:**
   ```bash
   telnet 192.168.1.1
   ```

2. **Login with admin credentials:**
   ```
   login: admin
   Password: stdONU101
   ```

3. **Type the hidden command directly at the `>` prompt:**
   ```
   >enterlinuxshell
   ```

4. **No password is required** (SHELL_KEY_SWITCH=0):
   ```
   / #
   ```

5. **Verify root access:**
   ```bash
   / # id
   uid=0(root) gid=0(root)
   
   / # whoami
   root
   
   / # pwd
   /
   ```

**Result**: Full root shell access to the embedded Linux system.

---

## Common Mistakes and Troubleshooting

### Mistake 1: Trying to use `debug` first

**Wrong approach:**
```
>debug
debug> enterlinuxshell
command error!
```

**Correct approach:**
```
>enterlinuxshell
/ #
```

The `enterlinuxshell` command is at the **root level** of the CLI parser, not under the `debug` submenu.

### Mistake 2: Using wrong passwords

During research, we found password generation seeds in the `/bin/startup` binary:
- `phF3uTie`
- `PRACT@%02X%02X%02X` (MAC address-derived)
- `Apex_Password`
- `Vansh_Null>013<$5252`

**Reality**: None of these were needed because `SHELL_KEY_SWITCH=0`.

### Mistake 3: PuTTY connection closing instantly

**Symptom**: Type password, connection closes with brief "Error!" message.

**Cause**: User was entering a shell password when none was required. Typing anything (even newline) when `SHELL_KEY_SWITCH=0` causes the session to close.

**Solution**: Just press Enter immediately after typing `enterlinuxshell`.

---

## Verifying System Access

### Hardware Information
```bash
/ # cat /proc/cpuinfo
system type             : RTL9607C
machine                 : Unknown
processor               : 0
cpu model               : MIPS 34Kc V5.5
BogoMIPS                : 761.85
cpu MHz                 : 761.856
```

### Memory Information
```bash
/ # cat /proc/meminfo
MemTotal:         124104 kB
MemFree:           37812 kB
Buffers:            6892 kB
Cached:            48128 kB
```

### Flash Partitions
```bash
/ # cat /proc/mtd
dev:    size   erasesize  name
mtd0: 000c0000 00020000 "boot"
mtd1: 00020000 00020000 "env"
mtd2: 00020000 00020000 "env2"
mtd3: 00a80000 00020000 "config"
mtd4: 00500000 00020000 "k0"
mtd5: 01400000 00020000 "r0"
mtd6: 00500000 00020000 "k1"
mtd7: 01400000 00020000 "r1"
mtd8: 00800000 00020000 "framework1"
mtd9: 00800000 00020000 "framework2"
mtd10: 03000000 00020000 "app"
```

**Critical discovery**: `mtd3` is the `config` partition — 10.5 MB writable storage at `/var/config/`.

### Network Interfaces
```bash
/ # ifconfig
br0       Link encap:Ethernet  HWaddr 00:00:00:7C:9D:A2
          inet addr:192.168.1.1  Bcast:192.168.1.255  Mask:255.255.255.0

nas0_0    Link encap:Ethernet  HWaddr 00:00:00:7C:9D:A2
          inet addr:103.155.218.139  Bcast:103.155.218.255  Mask:255.255.255.0

ppp0      Link encap:Point-to-Point Protocol
          inet addr:103.155.218.139  P-t-P:192.10.20.1  Mask:255.255.255.255
```

**Key interfaces:**
- `br0`: LAN bridge (192.168.1.1), includes eth0-3, wlan0, wlan1
- `nas0_0`: GPON uplink (DHCP from ISP)
- `ppp0`: PPPoE session (WAN IP)

### GPON Information
```bash
/ # flash get GPON_SN
GPON_SN=HWTC007C9DA2

/ # flash get PON_MODE
PON_MODE=1

/ # flash get GPON_MAC
GPON_MAC=007C9DA2
```

**GPON serial number** format: 4-char vendor code + 8-char hex MAC.

### Running Processes
```bash
/ # ps
  PID USER       VSZ STAT COMMAND
    1 admin     1632 S    init
   82 admin     1632 S    /bin/sh /etc/init.d/rc2
  134 admin     1632 S    /bin/sh /etc/init.d/rc3
  156 admin     2368 S    boa
  198 admin     1632 S    udhcpd /var/udhcpd/udhcpd.conf
  224 admin     2240 S    pppd call 2000_1_1
  256 admin     3152 S    /bin/cwmpClient
  289 admin     1632 S    crond -c /var/spool/cron/crontabs
  312 admin     1632 S    dnsmasq -C /var/dnsmasq.conf
  445 admin     1632 S    /sbin/getty 115200 ttyS0
```

**Key services:**
- `boa` (PID 156): Web server on port 80
- `cwmpClient` (PID 256): TR-069 management (our enemy)
- `dnsmasq` (PID 312): DNS/DHCP server
- `pppd` (PID 224): PPPoE client

---

## BusyBox Limitations

### Available Applets
```bash
/ # busybox --list
[
[[
ash
awk
cat
cp
crond
crontab
cut
df
diff
echo
egrep
false
find
grep
head
ifconfig
kill
less
ln
ls
md5sum
mkdir
mount
mv
netstat  # Actually missing on this build!
ping
ps
pwd
reboot
rm
rmdir
route
sed
sh
sleep
sort
tail
tar
top
true
umount
uname
wget
which
```

**Gotcha**: This BusyBox build is v1.22.1 with **minimal applets**. Commands like `netstat`, `ss`, `curl`, `base64`, `timeout` are NOT available.

### Workarounds
```bash
# No netstat? Read /proc/net/tcp directly
cat /proc/net/tcp | awk '{print $2}' | cut -d: -f2

# No curl? Use wget
wget -O- http://ifconfig.me

# No timeout? Use background jobs with sleep
my_command & sleep 5; kill $!

# No base64? Use hexdump and manual decoding
# (or upload a static base64 binary)
```

---

## Securing Shell Access

### Changing Shell Password

**Enable password protection:**
```bash
/ # flash set SHELL_KEY_SWITCH 1
/ # flash set SHELL_KEY_STRING $(echo "MySecurePassword123" | openssl passwd -1 -stdin)
/ # flash commit
/ # reboot
```

After reboot, `enterlinuxshell` will require the password.

**Reverting to no password:**
```bash
/ # flash set SHELL_KEY_SWITCH 0
/ # flash set SHELL_KEY_STRING ""
/ # flash commit
```

### Disabling Telnet (After Setting Up SSH)

```bash
/ # killall telnetd
/ # flash set TELNET_ENABLE 0
/ # flash commit
```

**Warning**: Only do this AFTER you have SSH working, or you'll lose all remote access.

---

## Persistence Considerations

### Ephemeral vs. Persistent Storage

**Ephemeral (lost on reboot):**
- `/tmp/` — ramfs, 8 MB
- `/var/log/`, `/var/run/` — symlinks to /tmp
- Processes and kernel modules

**Persistent (survives reboot):**
- `/var/config/` — JFFS2 on mtd3, 10.5 MB
- MIB flash values (`flash set` + `flash commit`)
- Active kernel/rootfs partition (k0/r0 or k1/r1)

### Creating Persistent Scripts

**Example: Custom boot script**
```bash
/ # cat > /var/config/run_customized_sdk.sh << 'EOF'
#!/bin/sh
echo "Custom boot script started at $(date)" >> /tmp/boot.log
/var/config/run_test.sh
EOF

/ # chmod +x /var/config/run_customized_sdk.sh
```

**On next boot**, `/etc/init.d/rc35` will execute this script.

---

## Security Implications

### Attack Surface

**Exposed services (default):**
- **Port 23 (telnet)**: No rate limiting, no fail2ban
- **Port 80 (HTTP)**: Boa web server with form handlers
- **Port 21 (FTP)**: Often enabled by ISP

**Post-exploitation capabilities:**
- Full filesystem read/write (except SquashFS rootfs)
- Kernel module loading (`insmod`)
- Network packet capture (`tcpdump` if uploaded)
- GPON serial number spoofing (`flash set GPON_SN`)
- ISP config hijacking (modify TR-069 ACS URL)

### Hardening Recommendations

1. **Disable telnet**: Use SSH with key authentication only
2. **Firewall port 80**: Block WAN access to web UI
3. **Kill TR-069**: `killall cwmpClient` (ISP can't push configs)
4. **Set shell password**: Enable `SHELL_KEY_SWITCH=1`
5. **Monitor /var/config/**: Check for unauthorized scripts

---

## Key Takeaways

1. **enterlinuxshell** is the magic command — type it at the `>` prompt, not in `debug` submenu
2. **No password required** if `SHELL_KEY_SWITCH=0` (default on most units)
3. **Root access** is instant — `uid=0`, full system control
4. **BusyBox v1.22.1** has limited applets — check availability before scripting
5. **/var/config/** is the persistent storage — use it for custom binaries and scripts
6. **rc35 hook** executes `/var/config/run_customized_sdk.sh` on every boot

---

## Next Steps

With root shell access established, subsequent phases will cover:
- **Phase 3**: Bootloop recovery (when scripts go wrong)
- **Phase 4**: Custom binary cross-compilation (Dropbear SSH, SOCKS5 proxy)
- **Phase 5**: DNS privacy and adblocking (dnsmasq + Cloudflare)
- **Phase 6**: QoS and hardware acceleration (Realtek registers)

---

**Phase 2 Status**: ✅ COMPLETE  
**Access Level**: Root shell via telnet  
**Privilege Escalation**: None needed (telnet gives root by default)  
**Stealth Level**: ISP-visible via TR-069 (addressed in later phases)
