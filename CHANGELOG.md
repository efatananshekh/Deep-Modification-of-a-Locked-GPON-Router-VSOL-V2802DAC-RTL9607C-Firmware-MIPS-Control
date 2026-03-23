# Changelog

All notable changes to the Frankenrouter project.

## [1.0.0] - 2026-03-23

### Initial Release

This release documents 6 months of reverse engineering and customization work on the VSOL V2802DAC GPON router.

### Added

#### Core Modifications
- **Root shell access** via telnet `enterlinuxshell` escape
- **SSH server** (Dropbear) with key-based authentication
- **Custom boot script** (`run_test.sh`) for persistent modifications
- **Watchdog daemon** for service recovery

#### DNS & Privacy
- **DNS hijacking** - All DNS queries forced through router
- **Cloudflare upstream** (1.1.1.1, 1.0.0.1) for privacy
- **Network-wide adblock** - ~90,000 domains blocked via dnsmasq
- **TR-069 blocked** - ISP remote management disabled

#### QoS & Performance
- **Hardware QoS** via Realtek RTL9607C registers
- **Software QoS** with iptables TOS marking
- **Gaming priority** for designated IP (Band 0)
- **HWNAT enabled** for line-speed routing

#### Custom Binaries
- **socks5proxy** (C) - SOCKS5 proxy with adblock integration
- **protomux** (C) - SSH/SOCKS5 port multiplexer on single port
- **smartqos** (C) - QoS monitoring and auto-repair daemon

#### Developer Features
- **Port forwarding** for development services
- **Wildcard DMZ** for gaming PC
- **Wake-on-LAN** support

### Technical Achievements
- Cross-compiled binaries using Zig for MIPS-musl
- Recovered from multiple bootloops without JTAG
- Achieved <1MB total binary footprint
- Maintained ~3.5MB free flash space

### Documentation
- Comprehensive firmware extraction guide
- Shell access methods
- Bootloop recovery procedures
- Full system architecture diagrams

---

## Development Notes

### Versioning
This project uses semantic versioning:
- MAJOR: Breaking changes to router configuration
- MINOR: New features, backward compatible
- PATCH: Bug fixes and documentation

### Future Plans
- [ ] DNS-over-TLS (DoT) proxy implementation
- [ ] tinc VPN integration
- [ ] Web-based management interface
- [ ] Automated backup/restore scripts
