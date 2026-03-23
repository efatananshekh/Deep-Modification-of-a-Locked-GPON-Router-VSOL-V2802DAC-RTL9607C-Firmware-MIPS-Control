# Security Considerations

This document outlines security implications of the Frankenrouter modifications.

## What We Removed/Disabled

### TR-069 (ISP Remote Management)
**Status**: Blocked via iptables

TR-069 allows ISPs to remotely configure, update, and monitor your router. We block this because:
- ISPs can push firmware updates without consent
- ISPs can see your network configuration
- ISPs can reset your settings remotely
- Potential attack vector if ISP infrastructure is compromised

**Iptables rule**:
```bash
iptables -A OUTPUT -p tcp --dport 7547 -j DROP
iptables -A OUTPUT -p tcp --dport 4567 -j DROP
```

### CWMP Client
**Status**: Process killed at boot

The CWMP client implements TR-069. We kill it to prevent:
- Automatic reconnection attempts
- CPU usage from retry loops
- Potential information leakage

## What We Added

### SSH Server (Dropbear)
**Security measures**:
- Key-based authentication only (password disabled)
- Non-standard port (2222)
- Ed25519 keys (more secure than RSA)
- Rate limiting via iptables

**Risks**:
- If your private key is compromised, attacker gets root
- Port scanning may reveal SSH service

### SOCKS5 Proxy
**Security measures**:
- Username/password authentication required
- Only listens on localhost by default
- Integrates with adblock (blocks known malicious domains)

**Risks**:
- Credentials sent in cleartext (use over SSH tunnel)
- If exposed to WAN, can be used for attacks

### DNS Hijacking
**Security measures**:
- Forces all DNS through router
- Uses Cloudflare (1.1.1.1) - privacy-focused provider
- Blocks known trackers/malware via adblock

**Risks**:
- You're trusting Cloudflare with your DNS queries
- DNS is unencrypted between router and Cloudflare
- Sophisticated attackers can still bypass via DoH

## Network Exposure

### Ports Open on LAN
| Port | Service | Risk Level |
|------|---------|------------|
| 22/2222 | SSH | Low (key-based auth) |
| 53 | DNS | Low (local only) |
| 80 | Web UI | Medium (has auth) |
| 1080 | SOCKS5 | Low (requires auth) |
| 8443 | Protomux | Low (multiplexer) |

### Ports Open on WAN
By default, no services are exposed to WAN. The wildcard DMZ forwards to your gaming PC.

**Warning**: If you expose the gaming PC, ensure it's properly firewalled.

## Credential Storage

### On Router
- SSH host keys: `/var/config/.ssh/dropbear_ed25519_host_key`
- SSH authorized keys: `/var/config/.ssh/authorized_keys`
- SOCKS5 credentials: Compiled into binary (change in source)
- Web UI password: In router's main config (we don't modify)

### On Your PC
- SSH private key: Your standard `.ssh/id_ed25519`
- Router backup files: May contain sensitive configs

## Firmware Integrity

### What We Don't Modify
- Bootloader (U-Boot)
- Kernel
- Root filesystem (SquashFS)
- Factory partition

### What We Modify
- `/var/config/` partition only (user data area)
- Custom boot script runs after factory boot

### Recovery
Factory reset via web UI will NOT remove our modifications (they're in /var/config which persists). To fully restore:
1. Delete `/var/config/run_test.sh`
2. Restore `/var/config/run_customized_sdk.sh` to original

## Threat Model

### Protected Against
- ISP snooping (DNS privacy)
- Ad tracking (adblock)
- Basic port scans (non-standard ports)
- Casual attackers (authentication required)

### Not Protected Against
- Sophisticated attackers targeting your specific router
- Physical access attacks
- ISP-level traffic analysis
- Compromised upstream providers (Cloudflare)

## Recommendations

1. **Change default credentials** on web UI
2. **Use strong SSH keys** (Ed25519, passphrase protected)
3. **Keep backups** of your configuration
4. **Monitor logs** for suspicious activity
5. **Update blocklists** regularly
6. **Don't expose services to WAN** unless necessary

## Incident Response

If you suspect compromise:
1. Disconnect router from ISP
2. Access via serial console if available
3. Check `/var/config/` for unexpected files
4. Review `/var/log/messages` for suspicious activity
5. Factory reset and reconfigure from scratch
