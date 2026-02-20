# SecretR00M

A zero-knowledge, ephemeral messaging app for iOS. Messages exist only in RAM and are never written to disk, databases, or iCloud. All traffic routes through Tor for complete anonymity.

## Why SecretR00M?

Unlike traditional messengers that store your conversations (even "encrypted" ones), SecretR00M operates on a fundamentally different principle: **if data doesn't exist, it can't be compromised.**

- **Zero local storage** - Messages live in RAM only. Close the app, they're gone.
- **No message history** - Not on your device, not on servers, nowhere.
- **Tor-only networking** - Your IP is never exposed to the relay server or other participants.
- **End-to-end encryption** - Even the relay server can't read your messages.
- **Ephemeral rooms** - Rooms vanish when the host leaves.

## Security Features

### Cryptographic Design
- **X25519** key exchange for perfect forward secrecy
- **AES-256-GCM** authenticated encryption
- **Automatic key rotation** with configurable epochs
- **Double-ratchet inspired** key derivation

### Network Privacy
- **Tor hidden service** (.onion) relay - 6-hop anonymity
- **No IP logging** - Server sees only Tor circuit IDs
- **Certificate pinning** for relay connections

### Device Security
- **Optional PIN/biometric lock**
- **No screenshots** (disabled in-app)
- **No clipboard of sensitive data**
- **Memory wiped on app termination**

### What We Don't Do
- No accounts or registration
- No phone numbers or emails required
- No contact list access
- No photo library access
- No analytics or telemetry
- No cloud backups

## Architecture Overview

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│   iOS App   │◄──Tor──►│   Relay     │◄──Tor──►│   iOS App   │
│  (Client)   │         │  (.onion)   │         │  (Client)   │
└─────────────┘         └─────────────┘         └─────────────┘
      │                       │                       │
      │ E2EE encrypted       │ Sees only:            │ E2EE encrypted
      │ messages             │ - Client IDs          │ messages
      │                      │ - Encrypted blobs     │
      │                      │ - NO IPs              │
      └──────────────────────┴───────────────────────┘
```

**The relay server:**
- Routes encrypted messages between clients
- Cannot decrypt message content (no keys)
- Cannot see client IP addresses (Tor)
- Stores nothing persistently

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed message flow diagrams.

## Building from Source

### Prerequisites
- macOS with Xcode 15+
- iOS 15.0+ deployment target
- CocoaPods (`gem install cocoapods`)

### Build Steps

1. **Clone the repository**
   ```bash
   git clone https://github.com/yourusername/SecretR00M.git
   cd SecretR00M
   ```

2. **Install dependencies**
   ```bash
   cd ios
   pod install
   ```

3. **Open in Xcode**
   ```bash
   open SecretR00M.xcworkspace
   ```

4. **Build and run**
   - Select your target device/simulator
   - Press Cmd+R to build and run

### Relay Server (Optional)

If you want to run your own relay server:

```bash
cd relay
npm install
npm start
```

See `relay/README.md` for Tor hidden service setup.

## Project Structure

```
EphemeralRooms/
├── ios/
│   ├── SecretR00M/
│   │   ├── App/              # AppDelegate, SceneDelegate
│   │   ├── UI/               # View controllers
│   │   ├── Session/          # Room state, crypto, message handling
│   │   ├── Network/          # WebSocket, Tor, invite system
│   │   ├── Coordination/     # Navigation coordinators
│   │   └── Crypto/           # Encryption primitives
│   └── Pods/                 # CocoaPods dependencies
├── relay/                    # Node.js WebSocket relay server
├── ARCHITECTURE.md           # Detailed technical documentation
├── SECURITY_ARCHITECTURE.md  # Cryptographic design details
└── SECURITY.md              # Vulnerability reporting
```

## How It Works

1. **Host creates a room** - Generates room ID, creates encryption keys
2. **Host shares invite link** - Single-use, time-limited token
3. **Guest joins via link** - Validates token, performs key exchange
4. **Messages are E2EE** - Only participants can decrypt
5. **Host leaves = room dies** - All state vanishes from everywhere

## Threat Model

SecretR00M protects against:
- Network surveillance (ISP, government)
- Server compromise (we can't leak what we don't have)
- Device seizure (nothing on disk to find)
- Participant identification (Tor anonymity)

SecretR00M does NOT protect against:
- Compromised device (malware with root access)
- Participant screenshots (social problem, not technical)
- Rubber hose cryptanalysis (physical coercion)
- Nation-state timing attacks (theoretical, expensive)

See [SECURITY_ARCHITECTURE.md](SECURITY_ARCHITECTURE.md) for full threat analysis.

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

For security issues, see [SECURITY.md](SECURITY.md).

## License

This project is licensed under the GNU General Public License v3.0 - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [Tor Project](https://www.torproject.org/) for anonymous networking
- [libsodium](https://libsodium.org/) inspiration for crypto design
- The privacy and cryptography communities

---

**Remember:** The most secure message is the one that doesn't exist.
