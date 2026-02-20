# Security Policy

## Reporting a Vulnerability

We take security vulnerabilities seriously. If you discover a security issue, please report it responsibly.

### How to Report

**Do NOT open a public GitHub issue for security vulnerabilities.**

Instead, please email: **security@secretr00m.app** (or your preferred contact)

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Any suggested fixes (optional)

### What to Expect

- **Acknowledgment** within 48 hours
- **Initial assessment** within 7 days
- **Regular updates** on remediation progress
- **Credit** in release notes (if desired)

### Scope

The following are in scope for security reports:

- **iOS Application** (`ios/SecretR00M/`)
  - Cryptographic implementation flaws
  - Memory handling issues (data not wiped)
  - Network privacy leaks (IP exposure)
  - Authentication/authorization bypasses
  - Local data persistence bugs

- **Relay Server** (`relay/`)
  - Information disclosure
  - Denial of service vulnerabilities
  - Authentication issues

### Out of Scope

- Social engineering attacks
- Physical device access attacks
- Issues requiring malware on the device
- Tor network vulnerabilities (report to Tor Project)
- Theoretical attacks without practical demonstration

## Security Design Principles

SecretR00M follows these principles:

1. **Zero Knowledge** - Server cannot access message content
2. **Zero Persistence** - No data written to disk
3. **Defense in Depth** - Multiple layers of protection
4. **Fail Secure** - Errors result in disconnection, not data leaks
5. **Minimal Attack Surface** - No unnecessary features or permissions

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.x     | Yes                |

## Security Updates

Security fixes are released as soon as possible after verification. Users are encouraged to:

- Keep the app updated
- Monitor this repository for security advisories
- Follow [@SecretR00M](https://twitter.com/SecretR00M) for announcements (if applicable)

## Acknowledgments

We thank the security researchers who help keep SecretR00M safe:

- (Your name could be here)

---

Thank you for helping keep SecretR00M and its users safe.
