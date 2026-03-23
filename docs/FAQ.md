# Frequently Asked Questions

## General

### What routers does this work on?
This project was specifically developed for the **VSOL V2802DAC** GPON ONU. It may work on similar Realtek RTL9607C-based devices, but has not been tested on other models.

### Will this brick my router?
There is always risk when modifying embedded devices. This project uses only the writable `/var/config/` partition and does not modify the firmware or bootloader. Recovery is possible through:
1. Factory reset via web UI (if accessible)
2. Telnet recovery during boot
3. TFTP recovery mode (if enabled)

### Is this legal?
Modifying your own router is generally legal. However:
- Check your ISP's terms of service
- Some modifications (GPON serial changes) may violate telecommunications regulations
- This project is for educational purposes

## Access

### What are the default credentials?
| Service | Username | Password |
|---------|----------|----------|
| Web UI | admin | stdONU101 |
| Telnet | admin | stdONU101 |
| SSH (after setup) | root | (key-based) |

### How do I enable telnet?
Telnet is often disabled by default. Check if:
1. Port 23 responds: `telnet 192.168.1.1 23`
2. Enable via web UI: Management → Access Control
3. Some ISP firmwares permanently disable telnet

### I can't get root shell
Try these methods in order:
1. Login via telnet, type `enterlinuxshell`
2. Login via telnet, type `debug` then `shell`
3. Use the factory CLI if available

## DNS & Adblock

### Why is my adblock not working?
Common issues:
1. **DNS not hijacked**: Check `iptables -t nat -L PREROUTING`
2. **dnsmasq not running**: Check `ps | grep dnsmasq`
3. **Hosts file missing**: Verify `/var/config/adblock_full.hosts` exists
4. **Client using DoH**: Browsers may bypass local DNS

### How do I update the blocklist?
```bash
# On your PC, download new list
curl -o adblock.hosts https://hosts.oisd.nl/

# Convert to dnsmasq format
awk '/^0\.0\.0\.0/ {print "address=/"$2"/0.0.0.0"}' adblock.hosts > adblock_dnsmasq.conf

# Upload to router
scp -P 2222 adblock_dnsmasq.conf root@192.168.1.1:/var/config/adblock_full.hosts

# Restart dnsmasq
ssh -p 2222 root@192.168.1.1 "killall dnsmasq; dnsmasq -C /var/config/dnsmasq.conf"
```

### Why does DNS leak test show my ISP?
The ISP may be intercepting DNS at the network level. Verify:
1. Router is using Cloudflare: `nslookup google.com 192.168.1.1`
2. Check dnsmasq config: `server=1.1.1.1`

## QoS

### Is hardware QoS enabled?
```bash
ssh -p 2222 root@192.168.1.1 "cat /proc/rg/assign_access_ip"
# Should show 0xc0a80124 for 192.168.1.36
```

### How do I change the priority IP?
Edit run_test.sh:
```bash
# Convert IP to hex (e.g., 192.168.1.100 = 0xc0a80164)
echo 0xc0a80164 > /proc/rg/assign_access_ip
```

### Why is my latency still high?
Check for:
1. **ISP throttling**: Run speed test during off-peak hours
2. **Buffer bloat**: Test with dslreports.com/speedtest
3. **WiFi interference**: Connect via Ethernet for testing

## Troubleshooting

### Router won't boot after changes
1. **Wait 5 minutes**: First boot after changes may be slow
2. **Power cycle**: Unplug for 30 seconds
3. **Recovery mode**: Some routers have a button combination

### SSH connection refused
1. Verify dropbear is running: `netstat -tlnp | grep 2222`
2. Check firewall rules: `iptables -L INPUT -n`
3. Regenerate host keys if corrupted

### Services don't start after reboot
1. Check if run_test.sh is executable: `ls -la /var/config/run_test.sh`
2. Verify run_customized_sdk.sh calls it
3. Check syntax: `sh -n /var/config/run_test.sh`

## Development

### How do I compile for MIPS?
Install Zig and use:
```bash
zig cc -target mips-linux-musl -Os -s -o binary source.c
```

### How do I debug on the router?
1. Use `printf` debugging (no gdb available)
2. Log to `/tmp/debug.log`
3. Use `strace` if available in busybox

### Can I use Docker for development?
Yes, for cross-compilation:
```dockerfile
FROM alpine:latest
RUN apk add --no-cache zig
WORKDIR /build
CMD ["zig", "cc", "-target", "mips-linux-musl", "-Os", "-s", "-o", "/out/binary", "/src/main.c"]
```
