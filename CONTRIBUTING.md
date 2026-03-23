# Contributing to Frankenrouter

Thank you for your interest in contributing to Frankenrouter!

## ⚠️ Important Notice

This project involves modifications to networking equipment. Before contributing:

1. **Test thoroughly** on your own equipment
2. **Document all changes** with before/after states
3. **Include recovery procedures** for any risky modifications
4. **Never commit credentials** or device-specific identifiers

## How to Contribute

### Reporting Issues

- Include router model and firmware version
- Describe expected vs actual behavior
- Provide relevant logs (sanitized of personal data)

### Code Contributions

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Test on actual hardware if possible
5. Update documentation
6. Submit a Pull Request

### Documentation

Documentation improvements are always welcome:
- Fix typos and clarify explanations
- Add diagrams for complex flows
- Document edge cases and gotchas
- Translate to other languages

## Code Style

### C Code
- Use 4-space indentation
- Keep functions under 100 lines
- Document non-obvious logic
- Handle all error cases

### Shell Scripts
- Use `#!/bin/sh` for POSIX compatibility
- Quote all variables
- Check command exit codes
- Log to syslog where appropriate

### Python Scripts
- Follow PEP 8
- Use type hints for public functions
- Include docstrings
- Handle network timeouts gracefully

## Testing

### Before Submitting

- [ ] Code compiles without warnings
- [ ] Binary runs on target architecture (MIPS)
- [ ] Changes don't break existing functionality
- [ ] Boot script modifications tested through reboot cycle
- [ ] Documentation updated

### Test Environment

If you don't have a VSOL router:
- Use QEMU with MIPS system emulation
- Test scripts with mocked /proc interfaces
- Validate iptables rules with `iptables-save` parsing

## Security

- Report security vulnerabilities privately via Issues (mark as security)
- Don't include working exploits in public commits
- Sanitize all example commands (use `192.168.1.x` not real IPs)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
