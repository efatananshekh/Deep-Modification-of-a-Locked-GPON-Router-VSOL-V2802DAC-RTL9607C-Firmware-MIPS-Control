# Phase 1: Firmware Extraction and Analysis

## Overview

This phase covers the initial acquisition, extraction, and analysis of the VSOL V2802DAC v5 GPON ONU router firmware. The goal was to understand the device architecture, extract embedded credentials, and identify customization possibilities.

---

## Initial Reconnaissance

### Device Information
- **Model**: VSOL V2802DAC v5
- **Type**: GPON/EPON Optical Network Unit (customer premises equipment)
- **SoC**: Realtek RTL9607C-VB5 (MIPS big-endian)
- **ISP**: Undisclosed (Bangladesh region)
- **Status**: Production firmware, ISP-locked with TR-069 management

### Firmware Acquisition
The firmware TAR file was obtained from an undisclosed source:
```
Filename: V2802DACv5-F_all_V3.4.00-250114_RASAver1.tar
Size: ~24 MB
Format: Standard POSIX TAR archive
```

---

## Extraction Process

### Step 1: TAR Archive Analysis

```bash
# List TAR contents
tar -tvf V2802DACv5-F_all_V3.4.00-250114_RASAver1.tar

# Extract all files
tar -xvf V2802DACv5-F_all_V3.4.00-250114_RASAver1.tar
```

**Contents discovered:**
```
-rw-r--r--  fwu.sh             Firmware upgrade shell script
-rw-r--r--  uImage             Linux kernel (MIPS, LZMA compressed)
-rw-r--r--  rootfs             SquashFS 4.0 (XZ compressed, read-only system)
-rw-r--r--  custconf           SquashFS 4.0 (ISP customization overlay)
-rw-r--r--  fwu_ver            Version string (V3.4.00-250114)
-rw-r--r--  fwu_key            ECDSA signature (47 bytes, ASN.1 DER)
-rw-r--r--  hw_ver             Hardware version filter ("skip")
-rw-r--r--  flash_ver          Flash layout version (V3.3)
-rw-r--r--  md5.txt            MD5 checksums of all files
```

### Step 2: Kernel Analysis

```bash
# Examine uImage header
xxd uImage | head -20
```

**uImage Header (64 bytes):**
```
Magic:          0x27051956 (uImage)
Header CRC:     0x8BBB0DD1
Created:        2025-01-14 07:03:04 UTC
Data Size:      1,789,621 bytes
Load Address:   0x80000000 (MIPS KSEG0)
Entry Point:    0x80000000
Image Name:     "Linux Kernel Image"
OS:             Linux
Architecture:   MIPS
Type:           Kernel Image
Compression:    LZMA
```

**Key findings:**
- Big-endian MIPS architecture (confirmed by load address)
- LZMA compression (high ratio, standard for embedded Linux)
- No device tree blob (DTB) — kernel uses hardcoded board config
- Version: Linux 3.18.24 (extracted from kernel strings later)

### Step 3: SquashFS Extraction

**Challenge**: Windows environment, no native `unsquashfs` tool.

**Solution**: Python-based extraction using PySquashfsImage library.

```python
pip install PySquashfsImage
```

```python
import squashfs_image
img = squashfs_image.SquashFsImage('rootfs')

# List all files
for f in img:
    print(f"{str(f):50} {len(f.read_bytes()):>10} bytes")
```

**rootfs Statistics:**
```
Total inodes: 843
Total size:   ~8 MB (compressed)
Compression:  XZ, level 9
Block size:   131072 bytes
Filesystem:   SquashFS 4.0 (big-endian)
```

**Key directories discovered:**
```
/bin/         Core utilities (BusyBox v1.22.1)
/sbin/        System management binaries
/lib/         uClibc 0.9.33, kernel modules
/etc/         System configuration files
/usr/bin/     Additional utilities
/usr/sbin/    Daemon binaries (dnsmasq, pppd)
/var/         Empty (tmpfs mount point)
/tmp/         Empty (tmpfs mount point)
/proc/        Empty (procfs mount point)
/sys/         Empty (sysfs mount point)
```

**custconf Statistics:**
```
Total inodes: 324
Total size:   ~4 MB (compressed)
Mount point:  /custconf (overlay)
Contents:     Web UI, ISP branding, default configs
```

---

## Critical Files Analyzed

### 1. `/etc/version` — Firmware Version String
```
v3.4.00_250114
luna_SDK_V3.3.0
RASAver1
```

### 2. `/etc/inittab` — Boot Configuration
```bash
# System initialization
::sysinit:/etc/init.d/rcS

# Respawn processes
::respawn:/sbin/getty 115200 ttyS0
ttyS0::respawn:/bin/cli

# Reboot/shutdown handlers
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
```

**Key insight**: `/bin/cli` is respawned on ttyS0 (serial console) — this is the restricted CLI shell users see on telnet, NOT the Linux shell.

### 3. `/bin/cli` — Restricted CLI Binary (111,116 bytes)

**String extraction revealed the command tree:**
```
Available commands:
  config          Configure system
  debug           Debug system (hidden submenu)
  exit            Exit command line interface
  help            Help information
  reboot          Reboot system
  show            Show system information
  
Hidden command (discovered):
  enterlinuxshell  Enter Linux /bin/sh root shell
```

**Critical discovery**: The `enterlinuxshell` command was found via string analysis. It prompts for `ShellPassword:` using `calPasswdMD5()` with `crypt()` and `$1$` salt. However, if `SHELL_KEY_SWITCH=0` (default on this router), no password is required.

### 4. `/etc/init.d/rcS` — System Initialization
```bash
#!/bin/sh
mount -a
mkdir -p /var/log /var/run /var/lock /var/tmp
/bin/hostname router

# Load kernel modules
insmod /lib/modules/rtk_gpon.ko
insmod /lib/modules/switch.ko
insmod /lib/modules/wifi_rtl8192f.ko
insmod /lib/modules/wifi_rtl8822.ko

# Start services
/etc/init.d/rc2  # Network setup
/etc/init.d/rc3  # ISP services
/etc/init.d/rc35 # USER HOOK (critical)
```

### 5. `/etc/init.d/rc35` — **The User Hook**
```bash
#!/bin/sh
# Realtek SDK vendor customization hook
if [ -f /var/config/run_customized_sdk.sh ]; then
    /var/config/run_customized_sdk.sh >/dev/null 2>&1
fi
```

**This is the entry point for all our custom modifications.** The script `/var/config/run_customized_sdk.sh` is stored in persistent flash (JFFS2) and executes on every boot.

### 6. `/custconf/config_default.xml` — Default Credentials

**Extracted via XML parsing:**
```xml
<SUSER_PASSWORD>stdONU101</SUSER_PASSWORD>
<USER_PASSWORD>user</USER_PASSWORD>
<TELNET_PASSWD>stdONU101</TELNET_PASSWD>
```

**Credentials found:**
- **Superuser**: `admin` / `stdONU101`
- **User**: `user` / `user`
- **Telnet**: `admin` / `stdONU101` (drops into `/bin/cli`)

### 7. `fwu.sh` — Firmware Upgrade Script

**Critical sections analyzed:**
```bash
# Flash kernel to active slot (k0 or k1)
flash_erase /dev/$KERNEL_MTD 0 0
nandwrite -p /dev/$KERNEL_MTD uImage

# Flash rootfs to active slot (r0 or r1)
flash_erase /dev/$ROOTFS_MTD 0 0
nandwrite -p /dev/$ROOTFS_MTD rootfs

# Flash custconf to framework1 or framework2
flash_erase /dev/$FRAMEWORK_MTD 0 0
nandwrite -p /dev/$FRAMEWORK_MTD custconf
```

**Critical discovery**: The upgrade script NEVER touches `/dev/mtd3` (config partition, 10.5MB JFFS2). This means:
- Custom scripts in `/var/config/` survive firmware upgrades
- Factory reset via web UI only deletes `/var/config/lastgood.xml`, NOT all files
- There is NO SAFE WAY to wipe `/var/config/` without serial/TFTP access

---

## Security Analysis

### Signature Verification

**fwu_key structure (47 bytes):**
```
30 2D 02 15 00 DB E0 A3 ... (ASN.1 DER encoded ECDSA)
```

**Verification process (in `fwu.sh`):**
```bash
openssl dgst -sha256 -verify pubkey.pem -signature fwu_key md5.txt
if [ $? -ne 0 ]; then
    echo "Signature verification failed!"
    exit 1
fi
```

**Implication**: Any modification to the firmware TAR invalidates the signature. The router silently rejects unsigned firmware upgrades. This prevents:
- Adding cleanup scripts to `fwu.sh`
- Modifying `rootfs` or `custconf`
- Injecting backdoors via firmware

**Workaround attempted**: Modifying `fwu.sh` to delete malicious scripts before flashing. Result: Router rejected the firmware due to signature mismatch.

### Password Storage

**Plaintext storage in MIB flash:**
```bash
flash get SUSER_PASSWORD  # Returns: stdONU101
flash get TELNET_PASSWD   # Returns: stdONU101
flash get SHELL_KEY_SWITCH # Returns: 0 (shell password disabled)
```

**No encryption, no hashing** — passwords stored as plaintext in MTD partition. Anyone with `flash get` access has all credentials.

### Shell Access Control

**Conditional shell access mechanism:**
```c
if (mib_get("SHELL_KEY_SWITCH") == 1) {
    printf("ShellPassword: ");
    gets(input);
    if (calPasswdMD5(input) != mib_get("SHELL_KEY_STRING")) {
        printf("Error!\n");
        exit(1);
    }
}
execl("/bin/sh", "sh", NULL);
```

**Default on this router**: `SHELL_KEY_SWITCH=0`, so typing `enterlinuxshell` at the CLI prompt gives instant root shell with no password.

---

## Tools and Techniques

### Windows-Compatible Firmware Analysis

**Challenges:**
- No native `unsquashfs` on Windows
- No `binwalk` with auto-extraction
- No `strings` command (use PowerShell equivalent)

**Solutions:**
1. **SquashFS extraction**: PySquashfsImage Python library
2. **Binary analysis**: PowerShell `Select-String -Pattern` for string search
3. **Hex dumps**: `Format-Hex` cmdlet
4. **TAR handling**: Native Python `tarfile` module

**Example workflow:**
```python
import tarfile
import squashfs_image

# Extract TAR
with tarfile.open('firmware.tar') as tar:
    tar.extractall('firmware_extracted/')

# Mount SquashFS
img = squashfs_image.SquashFsImage('firmware_extracted/rootfs')

# Read file content
for f in img:
    if str(f) == 'etc/version':
        print(f.read_bytes().decode('utf-8'))
```

### String Analysis for Credential Discovery

**Pattern matching against binaries:**
```python
import re

with open('bin/cli', 'rb') as f:
    binary = f.read()
    
# Find password-like strings (alphanumeric 8-16 chars)
passwords = re.findall(b'[A-Za-z0-9]{8,16}', binary)

# Find command names
commands = re.findall(b'enter[a-z]+shell', binary)
```

**Results:**
- Found `enterlinuxshell` command
- Found password seeds: `phF3uTie`, `Apex_Password`, `Vansh_Null>013<$5252`
- Found MAC-based password template: `PRACT@%02X%02X%02X`

---

## OpenWrt Feasibility Assessment

**Conclusion**: OpenWrt installation is **NOT FEASIBLE**.

**Reasons:**
1. **No GPON driver**: RTL9607C OMCI layer requires proprietary `omcidrv.ko` module
2. **No upstream support**: Realtek GPON SoCs are not supported by mainline Linux
3. **Bricking risk**: Without GPON registration, the OLT (ISP side) will not provision the device
4. **WiFi driver limitations**: RTL8192F and RTL8822 have limited OpenWrt support

**Alternative approach**: Work within the existing firmware, using `/var/config/` for persistence and the `rc35` hook for custom service startup.

---

## Key Takeaways

1. **Root shell access**: `telnet 192.168.1.1` → login as `admin/stdONU101` → type `enterlinuxshell` at `>` prompt
2. **Persistent storage**: `/var/config/` is JFFS2 on mtd3, survives reboots and firmware upgrades
3. **Boot hook**: `/etc/init.d/rc35` executes `/var/config/run_customized_sdk.sh` on every boot
4. **Signature lock**: Firmware TAR is ECDSA-signed, modifications are rejected
5. **BusyBox limitations**: v1.22.1 with minimal applets (no `netstat`, limited `grep`)

---

## Next Steps

With full firmware understanding and root shell access, the next phases will cover:
- Phase 2: System log analysis and failure pattern identification
- Phase 3: Establishing persistent SSH access (Dropbear cross-compilation)
- Phase 4: Bootloop recovery (when modifications go wrong)
- Phase 5: Custom binary deployment (SOCKS5, QoS, DoT proxy)

---

**Phase 1 Status**: ✅ COMPLETE  
**Time Investment**: ~3 hours  
**Lines of Code Analyzed**: ~50,000 (binaries, scripts, configs)  
**Critical Vulnerabilities Found**: 4 (plaintext passwords, unsigned shell access, TR-069 enabled, no config erase on reset)
