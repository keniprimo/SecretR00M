# Security Architecture & Data Flow Description

## CalculatorPR0 / EphemeralRooms

**Version:** 1.0
**Date:** January 2026
**Classification:** Technical Security Documentation

---

## Table of Contents

1. [Threat Model](#1-threat-model)
2. [High-Level Architecture](#2-high-level-architecture)
3. [End-to-End Data Flow](#3-end-to-end-data-flow)
4. [Cryptography Design](#4-cryptography-design)
5. [Metadata Minimization](#5-metadata-minimization)
6. [Forensics & Evidence Reduction](#6-forensics--evidence-reduction)
7. [Failure & Compromise Scenarios](#7-failure--compromise-scenarios)
8. [What Makes This System Unusually Strong](#8-what-makes-this-system-unusually-strong)
9. [Security Guarantees Summary](#9-security-guarantees-summary)
10. [Explicit Limitations](#10-explicit-limitations)

---

## 1. Threat Model

### 1.1 Threats Defended Against

#### Passive Network Observers
- **Threat:** ISP, corporate network, or nation-state observing network traffic
- **Defense:** All traffic routed through Tor hidden services. Observer sees only encrypted Tor traffic to entry nodes, never the destination relay or message content.
- **Verification:** `RoomConfiguration` enforces `.onion` URLs only (`RoomState.swift:317-323`). Direct connections are architecturally impossible.

#### Malicious Relay Operators
- **Threat:** Compromised or malicious relay server attempting to read messages, inject content, or correlate users
- **Defense:**
  - End-to-end encryption with client-only key material
  - Relay sees only opaque ciphertext (base64-encoded ChaCha20-Poly1305)
  - Relay cannot forge messages (lacks master key)
  - Relay cannot decrypt content (lacks session keys)
  - Relay cannot correlate real identities (only sees Tor circuits and relay-assigned client IDs)
- **Verification:** `MessageCrypto.swift` encryption occurs before WebSocket transmission; relay never receives plaintext

#### Compromised Servers
- **Threat:** Full server compromise with database access
- **Defense:**
  - No message storage on server (relay is stateless message router)
  - No user accounts or credentials stored
  - No encryption keys ever transmitted to or stored on server
  - Room destruction leaves no server-side evidence
- **Verification:** Relay protocol in `MessageTransport.swift` shows no persistence operations

#### Compromised Past Keys (Forward Secrecy)
- **Threat:** Attacker obtains old master key and captured ciphertext
- **Defense:**
  - Per-message keys derived from master key + epoch + sequence number
  - Automatic rekeying every 20 messages OR 60 seconds (`RoomState.swift:297-301`)
  - Rekey uses fresh X25519 ephemeral DH exchange per client (`Handshake.swift:327-399`)
  - Old master key hash mixed into new key derivation for continuity
  - Compromise of old key does NOT reveal new key (requires ephemeral private key)
- **Verification:** `KeyExchange.deriveRekeyKeyDH()` requires fresh DH shared secret

#### Device Seizure - Locked Device
- **Threat:** Adversary seizes device while locked
- **Defense:**
  - All cryptographic material in memory only, never written to disk
  - Memory cleared on app termination/background
  - Keychain items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` - inaccessible while locked
  - No message persistence; buffer cleared on app exit
- **Verification:** `SecureBytes` class with `wipe()` in `deinit`; no Core Data/UserDefaults for messages

#### Device Seizure - Unlocked Device
- **Threat:** Adversary seizes device while unlocked and app running
- **Defense:**
  - Messages auto-expire from buffer after 5 minutes (`RoomSession.swift:100`)
  - High security mode reduces to 60 seconds (`RoomSession.swift:241`)
  - Panic button instantly wipes all keys and messages
  - No persistent message history
- **Limitation:** Currently-displayed messages visible in UI until dismissed

#### Traffic Analysis
- **Threat:** Relay or network observer inferring content type or user identity from traffic patterns
- **Defense:**
  - Message padding to 7 fixed bucket sizes (256B to 5MB) (`MessageCrypto.swift:42-60`)
  - Random ±10% variance within each bucket (`MessageCrypto.swift:99-108`)
  - Random padding bytes (not zeros) prevent content inference
  - 0-300ms random timing jitter per message (`RoomSession.swift:831-839`)
  - Heartbeat interval jitter ±30%
  - Tor circuit rotation every 10 minutes with ±20% jitter
- **Limitation:** Long-term activity patterns (room creation times, session duration) remain observable

### 1.2 Threats Explicitly Out of Scope

| Threat | Rationale |
|--------|-----------|
| Jailbroken/rooted device | OS security boundary compromised; attacker has kernel access |
| Live memory forensics | Requires physical access + running device + forensic tools |
| Hardware implants | Physical security outside software scope |
| Malware on device | Compromised OS can read all memory |
| User sharing screenshots/photos of screen | Social, not technical |
| Coerced key disclosure | Legal/physical coercion outside technical scope |
| Side-channel attacks (EM, power) | Requires specialized equipment and physical proximity |
| Supply chain compromise of iOS/CryptoKit | Trust in Apple's implementation required |

---

## 2. High-Level Architecture

### 2.1 Design Principles

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CLIENT-ONLY CRYPTOGRAPHY                      │
│  All encryption, decryption, key generation, and key exchange       │
│  occur exclusively on user devices. The relay is cryptographically  │
│  blind to all content.                                               │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                     RELAY AS BLIND MESSAGE ROUTER                    │
│  The relay:                                                          │
│  - Routes opaque ciphertext between participants                     │
│  - Tracks room membership for routing (relay client IDs only)       │
│  - Never sees plaintext, keys, or real identities                   │
│  - Stores nothing persistently                                       │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                       TOR-ONLY TRANSPORT                             │
│  - All connections use .onion hidden service (validated at init)    │
│  - No clearnet fallback exists in code                              │
│  - Direct WebSocket to clearnet is architecturally impossible       │
│  - IP addresses never exposed to relay                               │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                      EPHEMERAL ROOM MODEL                            │
│  - Rooms exist only while active participants connected              │
│  - No server-side room state persists after destruction             │
│  - Client-side: all data in memory, wiped on exit                   │
│  - No accounts, no history, no recovery                              │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 Component Overview

```
┌──────────────────┐     Tor Circuit      ┌──────────────────┐
│   Host Device    │◄───────────────────►│    Relay (.onion) │
│                  │                      │                  │
│  ┌────────────┐  │                      │  Routes opaque   │
│  │ RoomSession│  │                      │  ciphertext only │
│  │            │  │                      │                  │
│  │ MasterKey  │  │                      │  No storage      │
│  │ EphemeralKP│  │                      │  No decryption   │
│  └────────────┘  │                      └────────┬─────────┘
└──────────────────┘                               │
                                                   │ Tor Circuit
┌──────────────────┐                               │
│  Client Device   │◄──────────────────────────────┘
│                  │
│  ┌────────────┐  │
│  │ RoomSession│  │
│  │            │  │
│  │ MasterKey  │  │  (received encrypted from host)
│  │ EphemeralKP│  │
│  └────────────┘  │
└──────────────────┘
```

### 2.3 Step-by-Step Protocol Flows

#### Room Creation (Host)

1. **Key Generation** (`RoomSession.swift:271-285`)
   - Generate 32-byte room ID (random or SHA256 hash of custom ID)
   - Generate 32-byte master key via `SecRandomCopyBytes`
   - Generate ephemeral X25519 key pair

2. **Connection** (`RoomSession.swift:305-315`)
   - Connect WebSocket through Tor to `.onion` relay
   - Send `ROOM_OPEN` with host's X25519 public key
   - Room ID becomes URL path (base64url encoded)

3. **State Transition**
   - `.none` → `.creating` → `.created(roomId)` → `.open`
   - Room now accepting join requests

#### Room Join (Client)

1. **Connection** (`RoomSession.swift:471-519`)
   - Generate ephemeral X25519 key pair
   - Connect WebSocket through Tor
   - Send `JOIN_REQUEST` containing:
     - Client X25519 public key (32 bytes)
     - Random join nonce (16 bytes)
     - Timestamp (Unix milliseconds)
     - Optional display name

2. **Host Approval** (`RoomSession.swift:350-407`)
   - Host validates timestamp (±60 second window)
   - Host derives session key via X25519 ECDH
   - Host encrypts master key with session key (ChaCha20-Poly1305)
   - Host sends `JOIN_APPROVED` with encrypted master key

3. **Client Confirmation** (`Handshake.swift:258-266`)
   - Client decrypts master key using derived session key
   - Client sends HMAC proof of key possession
   - Host verifies HMAC before adding to participants

4. **State Transition**
   - `.none` → `.creating` → `.active`

#### Message Send

1. **Key Derivation** (`RoomSession.swift:600`)
   ```
   perMessageKey = HKDF(masterKey, epoch, sequence)
   ```

2. **Padding** (`MessageCrypto.swift:62-135`)
   - Select bucket based on plaintext size
   - Add random variance (0-10% of bucket size)
   - Prefix with 4-byte length
   - Fill remainder with random bytes

3. **Encryption** (`MessageCrypto.swift:159-221`)
   - Generate random 12-byte nonce
   - Construct AAD: version || epoch || sequence || senderId
   - Encrypt with ChaCha20-Poly1305
   - Assemble frame: header (41 bytes) + ciphertext + tag (16 bytes)

4. **Transmission**
   - Add 0-300ms random delay
   - Base64 encode frame
   - Send via WebSocket as JSON `{"type":"BROADCAST","payload":"..."}`

#### Message Receive

1. **Frame Parsing** (`MessageCrypto.swift:232-314`)
   - Decode base64 payload
   - Extract: version, epoch, sequence, senderId, nonce, ciphertext, tag

2. **Replay Check** (`NonceTracker.swift:53-63`)
   - Validate sequence within window (64 messages)
   - Reject if already seen (bitmap check)
   - Mark as seen

3. **Decryption**
   - Derive per-message key from master key + epoch + sequence
   - Reconstruct AAD
   - Decrypt and verify tag
   - Remove padding (extract original length)

4. **Delivery**
   - Add to in-memory message buffer
   - Notify delegate
   - Auto-expire after 5 minutes

#### Rekey Operation

1. **Trigger** (`RoomSession.swift:961-979`)
   - Every 20 messages OR 60 seconds (whichever first)
   - On screenshot/recording detection
   - Manual trigger available

2. **Host Initiates** (`RoomSession.swift:853-959`)
   - Generate new master key
   - Generate fresh ephemeral X25519 key pair
   - For each participant:
     - Derive wrapping key via DH with participant's current public key
     - Encrypt new master key
     - Send as encrypted DIRECT message

3. **Client Processes** (`Handshake.swift:415-476`)
   - Decrypt new master key
   - Generate fresh ephemeral key pair
   - Send confirmation with new public key + HMAC

4. **Host Verifies**
   - Validate HMAC binding
   - Update client's ephemeral public key for next rekey
   - Increment epoch

5. **Forward Secrecy Achieved**
   - Old master key wiped
   - Old ephemeral keys wiped
   - Past messages cannot be decrypted even with new key

---

## 3. End-to-End Data Flow

### 3.1 Message Send: Complete Path

```
User types "Hello"
        │
        ▼
┌───────────────────────────────────────────────────────────────────┐
│ STEP 1: Content Encoding (ChatRoomView → RoomSession)             │
│                                                                   │
│ Input: "Hello" (5 bytes UTF-8)                                   │
│ Output: [0x01][timestamp:8][Hello] = 14 bytes                    │
│                                                                   │
│ Who can see: Only local device (plaintext in memory)             │
└───────────────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────────────┐
│ STEP 2: Key Derivation (KeyExchange.swift:164-194)                │
│                                                                   │
│ Input: masterKey (32B), epoch (4B), sequence (8B)                │
│ Process: HKDF-SHA256 with domain separator                        │
│ Output: perMessageKey (32B symmetric key)                         │
│                                                                   │
│ Key exists: Only in memory, discarded after encryption           │
│ Who can see: Only local device                                   │
└───────────────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────────────┐
│ STEP 3: Padding (MessageCrypto.swift:62-135)                      │
│                                                                   │
│ Input: 14 bytes content                                          │
│ Bucket selected: tiny (256 bytes base)                           │
│ Variance: +0-25 random bytes                                      │
│ Output: [length:4][content:14][random:238-263] = 256-281 bytes   │
│                                                                   │
│ Padding bytes: SecRandomCopyBytes (not zeros)                    │
│ Who can see: Only local device (plaintext padded)                │
└───────────────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────────────┐
│ STEP 4: Encryption (MessageCrypto.swift:159-221)                  │
│                                                                   │
│ Algorithm: ChaCha20-Poly1305 (AEAD)                              │
│ Nonce: 12 random bytes (SecRandomCopyBytes)                      │
│ AAD: version(1) || epoch(4) || sequence(8) || senderId(16) = 29B │
│                                                                   │
│ Frame assembly:                                                   │
│ [version:1][epoch:4][sequence:8][senderId:16][nonce:12]          │
│ [ciphertext:256-281][tag:16]                                      │
│ Total: 313-338 bytes                                              │
│                                                                   │
│ After this step: Content is ciphertext                           │
│ Who can see plaintext: NO ONE (key discarded)                    │
└───────────────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────────────┐
│ STEP 5: Encoding & Timing (RoomSession.swift:829-839)             │
│                                                                   │
│ Base64 encode: 313-338 bytes → 420-452 characters                │
│ JSON wrap: {"type":"BROADCAST","payload":"base64..."}            │
│ Random delay: 0-300ms                                             │
│                                                                   │
│ Who can see: Only ciphertext visible                             │
└───────────────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────────────┐
│ STEP 6: Tor Transport                                             │
│                                                                   │
│ Path: Device → Tor Guard → Middle → Exit → .onion Relay          │
│                                                                   │
│ Guard node sees: Encrypted Tor traffic from device IP            │
│ Middle node sees: Encrypted Tor traffic (no source/dest)         │
│ Exit node: N/A (hidden service, no exit)                         │
│ Relay sees: JSON with base64 ciphertext from Tor circuit         │
│                                                                   │
│ Device IP: Hidden from relay                                      │
│ Message content: Encrypted, relay cannot read                    │
└───────────────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────────────┐
│ STEP 7: Relay Routing                                             │
│                                                                   │
│ Relay action: Forward to all room participants                   │
│ Relay sees:                                                       │
│   - Room ID (URL path)                                           │
│   - Message size (padded, base64)                                │
│   - Arrival timestamp                                             │
│   - Relay-assigned client IDs                                     │
│                                                                   │
│ Relay CANNOT see:                                                 │
│   - Message content                                               │
│   - Original message size                                         │
│   - Participant real identities                                   │
│   - Encryption keys                                               │
└───────────────────────────────────────────────────────────────────┘
```

### 3.2 Message Receive: Complete Path

```
Relay forwards ciphertext to recipient
        │
        ▼
┌───────────────────────────────────────────────────────────────────┐
│ STEP 1: Reception (WebSocket → RoomSession)                       │
│                                                                   │
│ Received: {"type":"BROADCAST","payload":"base64..."}             │
│ Base64 decode: 313-338 bytes frame                               │
│                                                                   │
│ At this point: Still ciphertext                                  │
└───────────────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────────────┐
│ STEP 2: Frame Parsing (MessageCrypto.swift:232-280)               │
│                                                                   │
│ Extract: version, epoch, sequence, senderId, nonce               │
│ Separate: ciphertext (variable) and tag (16 bytes)               │
│                                                                   │
│ Validation: Minimum size check (57 bytes)                        │
└───────────────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────────────┐
│ STEP 3: Replay Protection (NonceTracker.swift:53-63)              │
│                                                                   │
│ Check: Is (senderId, sequence) within valid window?              │
│ Check: Has this exact sequence been seen before?                 │
│                                                                   │
│ If replay detected: REJECT message, do not decrypt               │
│ If valid: Mark sequence as seen in bitmap                        │
└───────────────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────────────┐
│ STEP 4: Key Derivation (same as sender)                           │
│                                                                   │
│ Derive: perMessageKey = HKDF(masterKey, epoch, sequence)         │
│ Key matches sender's key (same inputs)                           │
└───────────────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────────────┐
│ STEP 5: Decryption (MessageCrypto.swift:297-302)                  │
│                                                                   │
│ Reconstruct AAD from frame header                                │
│ Decrypt: ChaChaPoly.open(sealedBox, key, aad)                    │
│                                                                   │
│ If tag invalid: REJECT (tampering detected)                      │
│ If valid: paddedPlaintext recovered                              │
└───────────────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────────────┐
│ STEP 6: Unpadding (MessageCrypto.swift:330-353)                   │
│                                                                   │
│ Read: 4-byte length prefix                                       │
│ Extract: original plaintext (14 bytes)                           │
│ Discard: random padding bytes                                     │
│                                                                   │
│ Output: [0x01][timestamp:8][Hello]                               │
└───────────────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────────────┐
│ STEP 7: Content Decoding & Display                                │
│                                                                   │
│ Parse: content type (0x01 = text), timestamp, UTF-8 string       │
│ Store: In-memory buffer (auto-expires in 5 minutes)              │
│ Display: In ChatRoomView                                          │
│                                                                   │
│ Who can see plaintext: Only recipient device                     │
└───────────────────────────────────────────────────────────────────┘
```

### 3.3 Encryption Boundary Summary

| Location | Data State | Who Can See |
|----------|------------|-------------|
| User input | Plaintext | Local device only |
| After encoding | Plaintext (formatted) | Local device only |
| After padding | Plaintext (padded) | Local device only |
| **After encryption** | **Ciphertext** | **No one can read content** |
| On WebSocket | Ciphertext (base64) | Relay sees opaque blob |
| On Tor network | Encrypted tunnel | Entry guard sees device IP only |
| At relay | Ciphertext | Relay routes blindly |
| Recipient receives | Ciphertext | Cannot read until decryption |
| After decryption | Plaintext | Recipient device only |

---

## 4. Cryptography Design

### 4.1 Algorithm Suite

| Purpose | Algorithm | Key/Output Size | Standard |
|---------|-----------|-----------------|----------|
| Random generation | `SecRandomCopyBytes` | Variable | Apple Security Framework |
| Key agreement | X25519 ECDH | 32-byte keys | RFC 7748 |
| Key derivation | HKDF-SHA256 | 32-byte output | RFC 5869 |
| Authenticated encryption | ChaCha20-Poly1305 | 32-byte key, 12-byte nonce | RFC 7539 |
| Hashing | SHA-256 | 32-byte output | FIPS 180-4 |
| Message authentication | HMAC-SHA256 | 32-byte output | RFC 2104 |

### 4.2 Key Hierarchy

```
                    ┌─────────────────────────────┐
                    │      Room Master Key        │
                    │   (32 bytes, SecureBytes)   │
                    │   Generated: Host only      │
                    │   Distributed: Encrypted    │
                    └──────────────┬──────────────┘
                                   │
            ┌──────────────────────┼──────────────────────┐
            │                      │                      │
            ▼                      ▼                      ▼
   ┌────────────────┐    ┌────────────────┐    ┌────────────────┐
   │  Epoch Key     │    │  Confirm Key   │    │  Membership    │
   │  (per epoch)   │    │  (per rekey)   │    │  Key           │
   │                │    │                │    │                │
   │ HKDF(master,   │    │ HKDF(master,   │    │ HKDF(master,   │
   │   epoch,       │    │   epoch,       │    │   epoch,       │
   │   "message")   │    │   confirmNonce,│    │   "membership")│
   └───────┬────────┘    │   "confirm")   │    └────────────────┘
           │             └────────────────┘
           │
           ▼
   ┌────────────────┐
   │ Per-Message Key│
   │ (unique/msg)   │
   │                │
   │ HKDF(epochKey, │
   │   sequence,    │
   │   "per-msg")   │
   └────────────────┘
```

### 4.3 Per-Message Key Derivation

**File:** `KeyExchange.swift:164-194`

```
Input:
  - masterKey: 32-byte SecureBytes
  - epoch: uint32 (increments on rekey)
  - sequence: uint64 (increments per message)

Process:
  1. Build salt:
     salt = SHA256(epoch || sequence || "EphemeralRooms-per-message-salt-v1")

  2. Derive key:
     perMessageKey = HKDF-SHA256(
       inputKeyMaterial: masterKey,
       salt: salt,
       info: "per-message-key-v1",
       outputLength: 32
     )

Output:
  - 32-byte symmetric key for ChaCha20-Poly1305

Lifecycle:
  - Derived immediately before encryption
  - Used once for single message
  - Discarded after encryption completes
  - Never stored
```

**Security Properties:**
- Each message uses unique key (collision probability negligible)
- Key cannot be computed without master key
- Compromise of one per-message key reveals nothing about others

### 4.4 Epoch-Based Rekeying

**Trigger Conditions** (`RoomSession.swift:961-979`):
- Every 20 messages (configurable)
- Every 60 seconds (configurable)
- On screenshot detection
- On screen recording detection
- Manual trigger

**Rekey Process:**

```
Host Device                                  Client Device
     │                                            │
     │ 1. Generate new master key                 │
     │    newMasterKey = SecRandomCopyBytes(32)   │
     │                                            │
     │ 2. Generate fresh ephemeral key pair       │
     │    hostEphemeral = X25519.generateKeyPair()│
     │                                            │
     │ 3. For each client:                        │
     │    a. DH shared secret:                    │
     │       shared = DH(hostEphemeral.priv,      │
     │                   clientCurrentPub)        │
     │                                            │
     │    b. Derive wrapping key:                 │
     │       rekeyKey = HKDF(shared,              │
     │         SHA256(oldMasterKey) || roomId ||  │
     │         newEpoch || "ratchet-rekey-v2")    │
     │                                            │
     │    c. Encrypt new master key:              │
     │       wrapped = ChaCha20Poly1305.seal(     │
     │         newMasterKey, rekeyKey, nonce,     │
     │         aad: epoch||roomId||hostPub||      │
     │              clientPub)                     │
     │                                            │
     │ 4. Send encrypted payload ──────────────► │
     │    (as MESSAGE frame, indistinguishable    │
     │     from normal messages to relay)         │
     │                                            │
     │                                 5. Decrypt │
     │                                    newKey  │
     │                                            │
     │                           6. Generate new  │
     │                              ephemeral pair│
     │                                            │
     │ ◄────────────────────────── 7. Send conf  │
     │                                 + new pub  │
     │                                 + HMAC     │
     │                                            │
     │ 8. Verify HMAC                             │
     │ 9. Update client's public key             │
     │ 10. Wipe old master key                   │
     │ 11. Increment epoch                        │
     │                                            │
```

### 4.5 Forward Secrecy Guarantees

**Per-Client DH Rekey** (`Handshake.swift:327-399`):

The critical security property: **Compromise of the old master key does NOT reveal the new master key.**

Why:
1. New master key is encrypted with `rekeyKey`
2. `rekeyKey` is derived from DH shared secret
3. DH shared secret requires `hostEphemeral.privateKey`
4. `hostEphemeral.privateKey` is:
   - Generated fresh for each rekey
   - Never transmitted
   - Wiped immediately after use

Therefore:
- Attacker with old master key cannot derive `rekeyKey`
- Attacker cannot decrypt new master key
- Forward secrecy achieved

**Additional binding:**
- Old master key hash mixed into context (prevents key injection)
- Room ID and epoch in AAD (prevents cross-room/replay attacks)
- Client must echo confirm nonce with HMAC (prevents relay forgery)

### 4.6 Keys in Memory

| Key | Location | Lifetime | Wiping |
|-----|----------|----------|--------|
| Master key | `SecureBytes` | Room session | `wipe()` on destroy, `deinit` |
| Ephemeral private | Swift struct | Until rekey | Replaced on rekey |
| Per-message key | Stack variable | Single encryption | ARC deallocation |
| Session keys | Dictionary | Room session | Cleared on destroy |

**SecureBytes Implementation** (`SecureBytes.swift:86-100`):
```swift
func wipe() {
    storage.withUnsafeMutableBufferPointer { ptr in
        if let baseAddress = ptr.baseAddress {
            memset_s(baseAddress, ptr.count, 0, ptr.count)
        }
    }
    OSMemoryBarrier()
    isWiped = true
}
```

- Uses `memset_s` (not optimized away by compiler)
- Memory barrier ensures write completes
- Automatic wipe in `deinit`

---

## 5. Metadata Minimization

### 5.1 What the Relay Can See

| Metadata | Visible | Mitigation |
|----------|---------|------------|
| Room ID | Yes (URL path) | Random or hashed, no meaning |
| Message arrival time | Yes | 0-300ms jitter applied |
| Padded message size | Yes (base64) | 7 buckets + 10% variance |
| Relay client ID | Yes | Not real identity, relay-assigned |
| Room participant count | Inferred | From routing, not explicit |
| Join/leave events | Yes | Only relay IDs visible |
| Heartbeat timing | Yes | ±30% jitter |

### 5.2 What the Relay Cannot See

| Data | Protection |
|------|------------|
| Message content | End-to-end encryption |
| Original message size | Padding buckets |
| Participant real identities | No accounts, only ephemeral IDs |
| Participant IP addresses | Tor hidden service |
| Encryption keys | Never transmitted plaintext |
| Rekey events | Encrypted as normal messages |
| Message types (text/image/video) | Same encryption, bucket padding |

### 5.3 Traffic Analysis Resistance

**Padding Buckets** (`MessageCrypto.swift:42-60`):
```
Bucket      Size        Use Case
────────────────────────────────────
tiny        256 B       Short text
small       1 KB        Medium text
medium      8 KB        Small images
large       64 KB       Medium images
xlarge      256 KB      Large images
xxlarge     1 MB        Short videos
maximum     5 MB        Long videos
```

**Variance Layer** (`MessageCrypto.swift:99-108`):
- Random 0-10% added to bucket size
- Different messages in same bucket → different sizes
- Prevents exact-size fingerprinting

**Random Padding Bytes**:
- Padding filled with `SecRandomCopyBytes`
- Not zeros (which could leak information)
- Indistinguishable from ciphertext

**Timing Obfuscation**:
- Per-message: 0-300ms random delay
- Heartbeats: ±30% jitter around base interval
- Circuit rotation: ±20% jitter around 10-minute base

### 5.4 Message Indistinguishability

From the relay's perspective, all messages are indistinguishable:

```
Text message "Hello":
  → Encrypted → Padded to 256-281 bytes → Base64 → 342-375 chars

Image (50 KB):
  → Encrypted → Padded to 65536-72089 bytes → Base64 → 87382-96119 chars

Rekey payload:
  → Encrypted → Padded → Base64 → Same structure as messages

System notification:
  → Encrypted → Padded → Base64 → Same structure
```

All appear as: `{"type":"BROADCAST","payload":"<base64 blob>"}`

---

## 6. Forensics & Evidence Reduction

### 6.1 Data Storage Policy

| Data Type | Storage Location | Persistence |
|-----------|------------------|-------------|
| Messages | RAM only | Until app exit or 5-min expiry |
| Master key | SecureBytes (RAM) | Until room destroy |
| Ephemeral keys | RAM | Until rekey |
| Room ID | RAM | Until room destroy |
| Participant list | RAM | Until room destroy |
| Tor enabled flag | Keychain | Encrypted, device-bound |
| High security mode | Keychain | Encrypted, device-bound |

**Nothing written to:**
- UserDefaults
- Core Data
- SQLite
- Files
- Logs (in Release builds)

### 6.2 Keychain Usage

**What's stored** (`TorManager.swift:652-695`):
- Tor enabled preference (1 byte)
- Accessed via `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`

**Keychain attributes:**
- `kSecAttrSynchronizable`: NO (not synced to iCloud)
- `kSecAttrAccessible`: After first unlock, this device only
- Data Protection: Encrypted at rest

**Migration from UserDefaults** (`TorManager.swift:661-674`):
- Legacy preferences migrated to Keychain
- UserDefaults entry deleted after migration
- One-time operation

### 6.3 Clipboard Handling

**Not implemented in core messaging:**
- No automatic clipboard operations
- Room ID sharing via QR code or manual entry
- No message copy-to-clipboard in UI

**If clipboard used (invite flow):**
- Should implement expiration
- Should clear after use
- Currently a gap for invite tokens

### 6.4 Logging

**Debug builds only** (`RoomSession.swift:5-8`):
```swift
#if DEBUG
import os.log
private let logger = Logger(...)
#endif
```

**SecureLogBuffer** (`SecureLogBuffer.swift`):
- In-memory only log buffer
- `#if !DEBUG return` guard in `log()` method
- Never writes to disk
- Wipes on app exit

**Release builds:**
- All `logger.*` calls compile to nothing
- All `print()` calls inside `#if DEBUG`
- No os_log, NSLog, or stdout output
- stderr redirected to `/dev/null` in AppDelegate

### 6.5 Memory Wiping

**SecureBytes** (`SecureBytes.swift:86-100`):
```swift
func wipe() {
    storage.withUnsafeMutableBufferPointer { ptr in
        memset_s(baseAddress, count, 0, count)
    }
    OSMemoryBarrier()
    isWiped = true
}
```

**Data.secureWipe()** (`SecureBytes.swift:139-151`):
- Extension method for temporary Data objects
- Uses `memset_s` for secure zeroing
- Memory barrier ensures completion

**Automatic cleanup:**
- `SecureBytes.deinit` calls `wipe()`
- RoomSession.closeRoom() calls `wipeAllKeys()`
- Message buffer cleared on room destroy

### 6.6 iOS/Swift Limitations

| Limitation | Impact | Mitigation |
|------------|--------|------------|
| Swift String immutability | Strings cannot be securely wiped | Use Data/SecureBytes for sensitive data |
| ARC non-deterministic | Deallocation timing unpredictable | Explicit wipe before discard |
| Copy-on-write | Data may have multiple copies | Use withUnsafeMutableBytes |
| Virtual memory | Pages may be swapped | iOS doesn't swap to disk |
| JIT compilation | Code in memory | N/A for this app |

**Honest assessment:**
- Memory wiping is best-effort, not guaranteed
- iOS may retain copies in framework buffers
- Debugger/jailbreak can access memory
- Defense-in-depth approach, not absolute

---

## 7. Failure & Compromise Scenarios

### 7.1 Relay Compromise

**Scenario:** Attacker gains full control of relay server

**What leaks:**
- Room IDs (opaque identifiers)
- Participant relay client IDs (not real identities)
- Message timing and sizes (padded)
- Room membership patterns

**What does NOT leak:**
- Message content (encrypted)
- Participant real identities (no accounts)
- Participant IP addresses (Tor)
- Encryption keys (never on server)
- Historical messages (no storage)

**Attacker capabilities:**
- Traffic analysis on current sessions
- Message injection (but cannot forge valid ciphertext)
- Denial of service
- Correlation attempts via timing

**What attacker CANNOT do:**
- Decrypt any message
- Impersonate any participant
- Recover past messages (none stored)
- Identify users by IP

### 7.2 Old Key Compromise

**Scenario:** Attacker obtains master key from epoch N

**What leaks:**
- Messages encrypted in epoch N (if ciphertext captured)
- Sequence numbers and sender IDs from epoch N

**What does NOT leak:**
- Messages from epoch N+1 and later (forward secrecy)
- Messages from epoch N-1 and earlier (different keys)
- New master keys (DH-protected)
- Participant identities

**Why forward secrecy holds:**
- New master key encrypted with DH-derived key
- DH requires host ephemeral private key
- Host ephemeral is fresh per rekey, wiped after
- Old master key hash in context is one-way

### 7.3 Message Replay

**Scenario:** Attacker captures and replays encrypted message

**Protection mechanisms:**
1. **Nonce tracking** (`NonceTracker.swift`):
   - Per-sender sequence numbers tracked
   - 64-message sliding window
   - Replay of seen sequence rejected

2. **Epoch binding**:
   - Messages include epoch in AAD
   - Old epoch messages rejected after rekey

3. **Timing:**
   - Join requests have 60-second timestamp window
   - Rekey confirmations require fresh nonce

**Result:** Replay attacks detected and rejected

### 7.4 Rekey Interruption

**Scenario:** Network failure during rekey process

**Host state:**
- New master key generated but not confirmed
- Old master key still valid
- Pending confirmations tracked per client

**Client state:**
- May or may not have received rekey payload
- Old master key still valid until confirmed

**Recovery:**
- Host waits for confirmations
- Timeout triggers retry or participant removal
- Old keys remain valid until successful rekey
- No data loss (in-flight messages use old key)

### 7.5 Client Disconnect Mid-Rekey

**Scenario:** Client disconnects after receiving rekey but before confirming

**Impact:**
- Client has new master key
- Host hasn't confirmed client's new ephemeral
- Client can still decrypt with new key

**On reconnect:**
- Client must rejoin room
- Fresh handshake establishes new session
- No permanent state corruption

### 7.6 Network MITM

**Scenario:** Attacker intercepts Tor traffic

**Tor protection:**
- Traffic encrypted in 3 layers (Guard, Middle, Rendezvous)
- Hidden service: no exit node exposure
- Attacker sees only encrypted Tor cells

**If Tor compromised (guard + middle + relay):**
- Attacker could correlate traffic
- Still cannot decrypt messages (E2E encryption)
- Would need to compromise all 3 Tor nodes

**If WebSocket layer attacked:**
- Messages already encrypted before WebSocket
- MITM sees only ciphertext
- Cannot inject valid messages (lacks keys)

---

## 8. What Makes This System Unusually Strong

### 8.1 No Long-Term Identity Keys

**Typical messaging apps:**
- Persistent identity key pairs per user
- Compromise reveals all past/future sessions
- Key recovery mechanisms create attack surface

**This system:**
- Ephemeral X25519 keys per session
- Fresh key pair for each room
- Fresh key pair on each rekey
- No identity to compromise

**Security benefit:**
- No persistent target for key extraction
- Compromise of one session doesn't affect others
- No key escrow or recovery attack surface

### 8.2 No Account System

**Typical messaging apps:**
- Username/password or phone number
- Account database is target
- Metadata about user relationships stored
- Password reset creates vulnerability

**This system:**
- No accounts
- No usernames, passwords, phone numbers
- No server-side user database
- No friend lists or contact graphs

**Security benefit:**
- No credential stuffing attacks
- No account takeover possible
- No social graph to leak
- No server compromise reveals users

### 8.3 No Message History Persistence

**Typical messaging apps:**
- Messages stored locally (encrypted at rest)
- Messages backed up to cloud
- Sync across devices
- Search/archive features

**This system:**
- Messages in RAM only
- Auto-expire after 5 minutes
- No local database
- No cloud backup
- No sync (single device per session)

**Security benefit:**
- Device seizure reveals nothing after timeout
- No backup to subpoena
- No sync protocol to attack
- No search index to mine

### 8.4 No Server-Side Trust

**Typical messaging apps:**
- Trust server for key distribution
- Trust server for message delivery
- Trust server not to log
- Trust server's security practices

**This system:**
- Server (relay) is untrusted by design
- Keys never touch server
- Server sees only ciphertext
- Server compromise cannot reveal content
- Server cannot forge messages

**Security benefit:**
- No need to trust relay operator
- Works even with malicious relay
- No server-side key escrow
- No lawful intercept capability

### 8.5 No Recoverable Backups

**Typical messaging apps:**
- iCloud/Google backup includes messages
- "Forgot password" reveals keys
- Device migration transfers history
- Export features create copies

**This system:**
- Nothing to back up
- No password to forget
- Device migration = start fresh
- No export functionality

**Security benefit:**
- Cannot be compelled to produce backups
- No backup service to compromise
- No "just restore from backup" attack
- Data truly ephemeral

### 8.6 Security Tradeoff Acknowledgment

These properties provide strong security but sacrifice:
- **Convenience:** No message history
- **Recoverability:** Lost device = lost access
- **Multi-device:** Single device per session
- **Async messaging:** Requires both parties online
- **Discoverability:** No contact lists

This is intentional: the tradeoffs maximize security for sensitive communications where these limitations are acceptable.

---

## 9. Security Guarantees Summary

### What This System Guarantees (Verifiable from Code)

| Guarantee | Mechanism | Verification |
|-----------|-----------|--------------|
| **Message confidentiality** | ChaCha20-Poly1305 E2E encryption | `MessageCrypto.swift` |
| **Message integrity** | Poly1305 authentication tag | `MessageCrypto.swift:187-192` |
| **Replay protection** | Sequence-based nonce tracking | `NonceTracker.swift` |
| **Forward secrecy** | Per-client DH rekey | `Handshake.swift:327-399` |
| **IP anonymity (relay)** | Tor hidden service only | `RoomConfiguration:317-323` |
| **No persistent messages** | RAM-only storage | `RoomSession.swift:88` |
| **No server trust required** | Client-only crypto | All crypto in client code |
| **Key wiping** | SecureBytes with memset_s | `SecureBytes.swift:86-100` |
| **No account data** | No registration system | No account code exists |
| **Authenticated key exchange** | X25519 ECDH + HMAC confirmation | `Handshake.swift` |

### What This System Does NOT Guarantee

| Non-Guarantee | Reason |
|---------------|--------|
| Perfect anonymity | Tor has known limitations |
| Protection from device compromise | OS/hardware trust required |
| Protection from memory forensics | Physical access defeats software |
| Traffic analysis immunity | Timing/size patterns observable |
| Availability | Relay can deny service |
| Protection from social attacks | Screenshots, photos, sharing |

---

## 10. Explicit Limitations

### 10.1 Traffic Analysis

**Observable patterns:**
- Room creation/destruction times
- Session duration
- Message frequency
- Approximate message sizes (within buckets)
- User activity hours (over time)

**Mitigation effectiveness:**
- Padding reduces size correlation: HIGH
- Timing jitter (0-300ms): MODERATE
- Long-term pattern analysis: NOT PREVENTED

### 10.2 Endpoint Security

**Required trust:**
- iOS kernel integrity
- CryptoKit implementation
- Secure Enclave (for some operations)
- No malware on device

**If compromised:**
- Jailbroken device: All bets off
- Malware: Can read memory
- Debug access: Can extract keys

### 10.3 Memory Security

**Best-effort wiping:**
- `memset_s` used where possible
- Memory barrier after wipe
- Automatic wipe in destructors

**Limitations:**
- Swift/iOS may retain copies
- Framework buffers not controlled
- Virtual memory pages uncertain
- GC/ARC timing unpredictable

### 10.4 Metadata at Relay

**Unavoidably exposed:**
- Room ID (routing requirement)
- Message presence (for delivery)
- Timing (network physics)
- Approximate participant count

**This enables:**
- Traffic analysis attacks
- Intersection attacks (over time)
- Pattern correlation

### 10.5 Tor Network Limitations

**Known Tor issues:**
- Guard node sees source IP
- Timing correlation attacks
- Denial of service possible
- Network-level adversaries

**This system inherits:**
- All Tor's limitations
- Hidden service reliability issues
- Tor bootstrap time requirements

### 10.6 User Behavior

**Not protected against:**
- Screenshots (detection triggers rekey, but image captured)
- Screen recording (same)
- Photographing screen
- Sharing content externally
- Social engineering
- Coercion

---

## Document Verification

This document describes the security architecture of the EphemeralRooms/CalculatorPR0 iOS application based on code review. All claims are verifiable by examining the referenced source files:

- **Crypto:** `CalculatorPR0/Crypto/*.swift`
- **Session:** `CalculatorPR0/Session/*.swift`
- **Network:** `CalculatorPR0/Network/*.swift`
- **Security:** `CalculatorPR0/Security/*.swift`

The document does not claim unbreakable security. It describes what the system protects against, how it does so, and what limitations exist.

---

*End of Security Architecture Document*
