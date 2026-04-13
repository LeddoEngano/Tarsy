# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Tarsy, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, please email: **felipexy@hotmail.com**

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

## Response Timeline

- **Acknowledgment:** Within 48 hours
- **Initial assessment:** Within 1 week
- **Fix or mitigation:** As soon as practical, depending on severity

## Scope

The following areas are in scope for security reports:

- End-to-end encryption (`E2ECrypto`, TOFU key pinning)
- Authentication flows (`AuthManager`, OAuth, session management)
- WebSocket protocol (`WSProtocol`, packet handling)
- Relay server (authentication, authorization, rate limiting)
- Supabase edge functions (input validation, authorization)
- Remote input handling (`RemoteInputService`)
- Sudo password handling (`SudoPasswordManager`)

## Out of Scope

- Vulnerabilities in third-party dependencies (report to the upstream project)
- Issues requiring physical access to the device
- Social engineering

## Disclosure

We follow coordinated disclosure. We will work with you to understand and address the issue before any public disclosure.

## Supported Versions

Only the latest release is supported with security updates.
