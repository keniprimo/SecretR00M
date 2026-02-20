# Ephemeral Host-Anchored Encrypted Messaging System

A high-security messaging system where communication only exists while the host is online. When the host disconnects, the room is destroyed, all cryptographic material is wiped, and nothing can be recovered.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         CLIENT (iOS)                             │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │  Crypto  │  │ Network  │  │ Session  │  │    UI    │        │
│  │ Module   │  │  Module  │  │  Module  │  │  Module  │        │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘        │
│       │              │             │             │              │
│       └──────────────┴─────────────┴─────────────┘              │
│                          │                                       │
│                    WebSocket (TLS)                               │
└──────────────────────────┼───────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│                      RELAY SERVER (Go)                            │
├──────────────────────────────────────────────────────────────────┤
│  • Memory-only room registry                                      │
│  • No message storage                                             │
│  • No payload inspection                                          │
│  • Encrypted blob forwarding                                      │
│  • Host heartbeat enforcement                                     │
│  • Immediate room destruction on host disconnect                  │
└──────────────────────────────────────────────────────────────────┘
```

## Security Properties

### What It Protects Against

| Threat | Protection |
|--------|------------|
| Passive eavesdropping | E2EE with ChaCha20-Poly1305 |
| Active MITM | Transcript-bound key exchange |
| Malicious server | Server sees only encrypted blobs |
| Server compromise | No stored keys or messages |
| Legal compulsion | Nothing to hand over |
| Device seizure (locked) | Keys in memory only |
| Message replay | Nonce tracking + sequence numbers |

### What It Cannot Protect Against

- Kernel-level spyware (Pegasus-class)
- Physical coercion
- Compromised app builds
- Screenshots (can only detect/react)

## Directory Structure

```
EphemeralRooms/
├── relay/                    # Go relay server
│   ├── cmd/relay/           # Main entry point
│   └── internal/
│       ├── room/            # Room management
│       ├── websocket/       # WebSocket handlers
│       ├── ratelimit/       # Rate limiting
│       └── metrics/         # Metrics (counts only)
├── ios/                      # iOS client
│   └── EphemeralRooms/
│       ├── App/             # AppDelegate, SceneDelegate
│       ├── Crypto/          # Cryptographic operations
│       ├── Network/         # WebSocket management
│       ├── Session/         # Room lifecycle
│       ├── Security/        # Capture detection
│       └── UI/              # View controllers
└── docs/                     # Documentation
```

## Cryptographic Architecture

### Primitives Used

| Purpose | Primitive |
|---------|-----------|
| Key exchange | X25519 (Curve25519) |
| Key derivation | HKDF-SHA256 |
| Message encryption | ChaCha20-Poly1305 |
| Hashing | SHA256 |
| HMAC | HMAC-SHA256 |

### Key Hierarchy

```
roomMasterKey (32 bytes, CSPRNG)
    │
    ├── messageKey[epoch] = HKDF(masterKey, epoch, "message-key")
    │
    ├── rekeyKey[epoch] = HKDF(masterKey, epoch, "rekey-wrap")
    │
    └── membershipKey[epoch] = HKDF(masterKey, epoch, "membership-key")
```

### Message Frame Format

```
┌─────────────────────────────────────────────────────────────────┐
│ version (1) │ epoch (4) │ sequence (8) │ senderId (16) │        │
│             │           │              │               │ nonce  │
│             │           │              │               │ (12)   │
├─────────────────────────────────────────────────────────────────┤
│                     ciphertext (variable)                        │
├─────────────────────────────────────────────────────────────────┤
│                     Poly1305 tag (16)                            │
└─────────────────────────────────────────────────────────────────┘
```

## Running the System

### Relay Server

```bash
cd relay

# Development (no TLS)
go run ./cmd/relay -insecure

# Production (with TLS)
go run ./cmd/relay -cert server.crt -key server.key
```

### iOS Client

1. Open `ios/EphemeralRooms.xcodeproj` in Xcode
2. Update the server URL in HomeViewController
3. Build and run on device or simulator

## Security Checklist

### iOS Client
- [ ] All keys use SecRandomCopyBytes
- [ ] Keys wiped on app background
- [ ] Keys wiped on device lock
- [ ] No UserDefaults for sensitive data
- [ ] No file storage for messages
- [ ] Privacy overlay in app switcher
- [ ] Screenshot detection implemented
- [ ] Screen recording detection implemented
- [ ] Panic button functional

### Relay Server
- [ ] Memory-only room storage
- [ ] No message logging
- [ ] Room destroyed on host disconnect
- [ ] Heartbeat timeout enforced
- [ ] Rate limiting active
- [ ] TLS 1.3 only in production
- [ ] No database connections

## License

This is security-critical software. Use at your own risk. No warranty expressed or implied.
