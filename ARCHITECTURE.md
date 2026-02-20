# EphemeralRooms - Message Flow & Security Architecture

## Network Topology Overview

```
+------------------+                                              +------------------+
|   YOUR IPHONE    |                                              |  RELAY SERVER    |
|  (192.168.x.x)   |                                              | (.onion hidden)  |
+------------------+                                              +------------------+
         |                                                                 |
         |  Your real IP visible here                                      |
         v                                                                 |
+------------------+     +------------------+     +------------------+      |
|   TOR GUARD      |---->|   TOR MIDDLE     |---->|   TOR EXIT       |     |
|     NODE         |     |     NODE         |     |     NODE         |     |
| (Entry Relay)    |     |   (Relay)        |     | (Rendezvous)     |<----+
+------------------+     +------------------+     +------------------+
   Sees: Your IP            Sees: Nothing          Sees: .onion traffic
   Knows: Nothing           useful                 No real IPs visible
```

## Detailed Message Journey

### Step 1: Message Creation on Your Device
```
+------------------------------------------------------------------+
|                        YOUR IPHONE                                |
+------------------------------------------------------------------+
|                                                                   |
|  1. You type: "Hello!"                                           |
|                                                                   |
|  2. App encrypts with END-TO-END encryption (E2EE):              |
|     +----------------------------------------------------------+ |
|     | Plaintext: "Hello!"                                      | |
|     |     |                                                    | |
|     |     v  [Your Session Key + Recipient's Public Key]       | |
|     |                                                          | |
|     | E2EE Encrypted: "x8Kj2mNp..." (only recipient can read)  | |
|     +----------------------------------------------------------+ |
|                                                                   |
|  3. Wrap in WebSocket frame:                                     |
|     {"type":"MESSAGE","payload":"x8Kj2mNp..."}                   |
|                                                                   |
+------------------------------------------------------------------+
```

### Step 2: Tor Onion Encryption (3 Layers)
```
+------------------------------------------------------------------+
|                     TOR ENCRYPTION LAYERS                         |
+------------------------------------------------------------------+
|                                                                   |
|  Your message gets wrapped in 3 layers of encryption:            |
|                                                                   |
|  Original: {"type":"MESSAGE","payload":"x8Kj2mNp..."}            |
|                                                                   |
|  Layer 3 (Exit Node Key):                                        |
|  +------------------------------------------------------------+  |
|  | Encrypted for Exit Node                                    |  |
|  | Contains: destination .onion + Layer 2 encrypted blob      |  |
|  +------------------------------------------------------------+  |
|                    |                                              |
|                    v                                              |
|  Layer 2 (Middle Node Key):                                      |
|  +------------------------------------------------------------+  |
|  | Encrypted for Middle Node                                  |  |
|  | Contains: Exit Node address + Layer 3 encrypted blob       |  |
|  +------------------------------------------------------------+  |
|                    |                                              |
|                    v                                              |
|  Layer 1 (Guard Node Key):                                       |
|  +------------------------------------------------------------+  |
|  | Encrypted for Guard Node                                   |  |
|  | Contains: Middle Node address + Layer 2 encrypted blob     |  |
|  +------------------------------------------------------------+  |
|                                                                   |
|  Final packet leaving your phone: [Layer 1 [Layer 2 [Layer 3]]]  |
|                                                                   |
+------------------------------------------------------------------+
```

### Step 3: Journey Through Tor Circuit
```
+------------------------------------------------------------------+
|                    TOR CIRCUIT JOURNEY                            |
+------------------------------------------------------------------+

YOUR PHONE ──────────────────────────────────────────────────────────>
   |
   | Source IP: 192.168.18.x (your local IP)
   | Via: Your home router -> ISP
   | Packet: [Layer1[Layer2[Layer3[E2EE Message]]]]
   |
   v
+------------------------+
|     GUARD NODE         |  IP: 185.220.101.xx (example)
|     (Entry Relay)      |
+------------------------+
   |
   | WHAT GUARD SEES:
   | - Your real IP: 192.168.18.x (via NAT: your public IP)
   | - Encrypted blob (can't read content)
   | - Next hop: Middle Node address
   |
   | WHAT GUARD DOES:
   | - Removes Layer 1 encryption
   | - Forwards to Middle Node
   |
   | Source IP now: Guard Node's IP
   | Packet: [Layer2[Layer3[E2EE Message]]]
   |
   v
+------------------------+
|     MIDDLE NODE        |  IP: 104.244.76.xx (example)
|       (Relay)          |
+------------------------+
   |
   | WHAT MIDDLE SEES:
   | - Source: Guard Node IP (NOT your IP)
   | - Encrypted blob (can't read content)
   | - Next hop: Exit/Rendezvous Node
   |
   | WHAT MIDDLE DOES:
   | - Removes Layer 2 encryption
   | - Forwards to next node
   |
   | Source IP now: Middle Node's IP
   | Packet: [Layer3[E2EE Message]]
   |
   v
+------------------------+
|   RENDEZVOUS POINT     |  (For .onion hidden services)
|   (Exit-like Node)     |
+------------------------+
   |
   | WHAT RENDEZVOUS SEES:
   | - Source: Middle Node IP (NOT your IP)
   | - Destination: .onion address (no real IP!)
   | - Encrypted blob for hidden service
   |
   | WHAT RENDEZVOUS DOES:
   | - Removes Layer 3 encryption
   | - Connects to hidden service circuit
   |
   v
+------------------------+
|    HIDDEN SERVICE      |
|    RELAY SERVER        |
| xihrxmtwitgi...onion   |
+------------------------+
   |
   | WHAT SERVER SEES:
   | - Source: Tor circuit (NO IP visible!)
   | - Message: {"type":"MESSAGE","payload":"x8Kj2mNp..."}
   | - Still E2EE encrypted (server can't read actual content)
   |
   v
SERVER PROCESSES AND RELAYS TO OTHER CLIENTS
```

## IP Visibility Matrix

```
+------------------+------------------+------------------+------------------+
|    OBSERVER      |   YOUR REAL IP   |  MESSAGE CONTENT | METADATA         |
+------------------+------------------+------------------+------------------+
| Your ISP         |       YES        |        NO        | Tor traffic only |
|                  | Sees you connect | Encrypted blob   | Can't see dest   |
|                  | to Guard Node    |                  |                  |
+------------------+------------------+------------------+------------------+
| Guard Node       |       YES        |        NO        | Next hop only    |
|                  | Entry point      | 2 layers left    | Can't see final  |
|                  |                  |                  | destination      |
+------------------+------------------+------------------+------------------+
| Middle Node      |       NO         |        NO        | Hops only        |
|                  | Sees Guard IP    | 1 layer left     | No endpoints     |
+------------------+------------------+------------------+------------------+
| Rendezvous Node  |       NO         |        NO        | .onion address   |
|                  | Sees Middle IP   | E2EE content     | No real IPs      |
+------------------+------------------+------------------+------------------+
| Relay Server     |       NO         |        NO        | Client ID only   |
| (.onion)         | No IP at all!    | E2EE encrypted   | (random hex)     |
+------------------+------------------+------------------+------------------+
| Other Room       |       NO         |      YES         | Nothing else     |
| Participants     | Never exposed    | They have keys   |                  |
+------------------+------------------+------------------+------------------+
| Room Host        |       NO         | YES (has keys)   | Client IDs       |
|                  | Never sees IPs   |                  | (not IPs)        |
+------------------+------------------+------------------+------------------+
```

## Encryption Layers Summary

```
+------------------------------------------------------------------+
|                    ENCRYPTION LAYERS                              |
+------------------------------------------------------------------+

Message: "Hello!"

LAYER 1: End-to-End Encryption (E2EE)
+------------------------------------------------------------------+
| Algorithm: X25519 key exchange + AES-256-GCM                      |
| Purpose: Only intended recipients can read message                |
| Who has keys: Room participants only                              |
| Decrypted by: Recipient's app                                     |
+------------------------------------------------------------------+
        |
        v
LAYER 2: WebSocket Frame
+------------------------------------------------------------------+
| Format: JSON {"type":"MESSAGE","payload":"<E2EE data>"}          |
| Purpose: Protocol structure for relay server                      |
+------------------------------------------------------------------+
        |
        v
LAYER 3: TOR Onion Encryption (3 sub-layers)
+------------------------------------------------------------------+
| Layer 3a: Exit/Rendezvous encryption                             |
| Layer 3b: Middle Node encryption                                  |
| Layer 3c: Guard Node encryption                                   |
| Purpose: Anonymous routing, no single node sees full path         |
+------------------------------------------------------------------+
        |
        v
LAYER 4: TLS/Transport (to Guard Node)
+------------------------------------------------------------------+
| Algorithm: TLS 1.3                                                |
| Purpose: Encrypt connection to first Tor node                     |
| Protects against: Local network eavesdropping                     |
+------------------------------------------------------------------+
```

## What Each Party Can See

### Your ISP
```
+------------------------------------------------------------------+
| YOUR ISP'S VIEW                                                   |
+------------------------------------------------------------------+
| - Your IP: 86.124.xxx.xxx (your public IP)                       |
| - Destination: 185.220.101.xx:9001 (Tor Guard Node)              |
| - Protocol: TLS encrypted traffic                                 |
| - Pattern: Tor traffic (detectable but not readable)             |
|                                                                   |
| CANNOT SEE:                                                       |
| - Final destination (.onion address)                             |
| - Message content                                                 |
| - Who you're talking to                                          |
| - What app you're using (beyond "some Tor app")                  |
+------------------------------------------------------------------+
```

### The Relay Server
```
+------------------------------------------------------------------+
| RELAY SERVER'S VIEW                                               |
+------------------------------------------------------------------+
| - Client ID: "a8f3b2c1..." (random, not linked to you)           |
| - Message type: MESSAGE, JOIN_REQUEST, etc.                       |
| - Encrypted payload: "x8Kj2mNp..." (can't decrypt)               |
| - Room ID: "abc123" (knows which room, not who's in it)          |
|                                                                   |
| CANNOT SEE:                                                       |
| - Your IP address (hidden by Tor)                                |
| - Your identity                                                   |
| - Message content (E2EE encrypted)                               |
| - Geographic location                                            |
+------------------------------------------------------------------+
```

### Other Room Participants
```
+------------------------------------------------------------------+
| OTHER PARTICIPANTS' VIEW                                          |
+------------------------------------------------------------------+
| - Your messages: "Hello!" (decrypted with shared key)            |
| - Your display name (if you set one)                             |
| - Message timestamps                                              |
|                                                                   |
| CANNOT SEE:                                                       |
| - Your IP address                                                |
| - Your device info                                               |
| - Your location                                                  |
| - Your real identity (unless you share it)                       |
+------------------------------------------------------------------+
```

## Hidden Service (.onion) Explained

```
+------------------------------------------------------------------+
|              HOW .ONION ADDRESSES WORK                            |
+------------------------------------------------------------------+

xihrxmtwitgihtxllygrgoxixuu6ib7kzmgvosv7467tnij5svgyabid.onion
|___________________________________________________|
                        |
                        v
            This is a public key hash!
            (Not a domain name, not an IP)

The server ALSO connects to Tor:
- Server has its own 3-hop circuit to rendezvous point
- Server's real IP is NEVER exposed to clients
- Even if someone controls rendezvous point, they can't find server

Connection Process:
1. Your app looks up .onion in Tor's distributed hash table
2. Finds "introduction points" for the hidden service
3. Both you and server connect to a "rendezvous point"
4. Communication happens through rendezvous (6 hops total!)

+------------------------------------------------------------------+
|  YOUR DEVICE                              RELAY SERVER            |
|      |                                          |                 |
|      +---> Guard --> Middle --> Rendezvous <--- Middle <--- Guard |
|      |         YOUR CIRCUIT         |      SERVER'S CIRCUIT       |
|      |                              |                             |
|    3 hops                      Meeting point                3 hops |
+------------------------------------------------------------------+
```

## Attack Resistance

```
+------------------------------------------------------------------+
|                    SECURITY GUARANTEES                            |
+------------------------------------------------------------------+

ATTACK                          | PROTECTED? | HOW
--------------------------------|------------|---------------------------
ISP monitors your traffic       |    YES     | Tor encryption hides dest
Government requests server logs |    YES     | No IPs stored, only Tor
Server is compromised           |    YES     | E2EE, server can't read
One Tor node is malicious       |    YES     | Need all 3 + intro points
Local WiFi snooping             |    YES     | TLS + Tor encryption
Man-in-the-middle attack        |    YES     | Tor circuit verification
Room participant is spy         |  PARTIAL   | They see messages (E2EE)
                                |            | but not your IP/identity
Timing correlation attack       |  PARTIAL   | Difficult but theoretically
                                |            | possible for nation-states
```

## Data Flow Summary

```
+------------------------------------------------------------------+
|                 COMPLETE DATA FLOW                                |
+------------------------------------------------------------------+

1. TYPE MESSAGE
   "Hello!"
       |
       v
2. E2EE ENCRYPT
   [AES-256-GCM with session key]
   "x8Kj2mNp4Qr7..."
       |
       v
3. WRAP IN PROTOCOL
   {"type":"MESSAGE","payload":"x8Kj2mNp4Qr7..."}
       |
       v
4. TOR LAYER 3 (Exit)
   [Encrypt with Exit Node pubkey]
       |
       v
5. TOR LAYER 2 (Middle)
   [Encrypt with Middle Node pubkey]
       |
       v
6. TOR LAYER 1 (Guard)
   [Encrypt with Guard Node pubkey]
       |
       v
7. TLS TO GUARD
   [Standard TLS 1.3]
       |
       v
8. SEND OVER INTERNET
   Your IP --> Guard Node IP
       |
       v
9. PEEL LAYER 1
   Guard decrypts, forwards to Middle
       |
       v
10. PEEL LAYER 2
    Middle decrypts, forwards to Exit/Rendezvous
       |
       v
11. PEEL LAYER 3
    Rendezvous connects to hidden service circuit
       |
       v
12. HIDDEN SERVICE RECEIVES
    {"type":"MESSAGE","payload":"x8Kj2mNp4Qr7..."}
    Server sees NO IP, just client ID
       |
       v
13. RELAY TO RECIPIENTS
    Server forwards to other room participants
    (Same process in reverse for them)
       |
       v
14. RECIPIENT DECRYPTS E2EE
    Uses shared session key
    Sees: "Hello!"

+------------------------------------------------------------------+
```

## Your Current Setup

```
+------------------------------------------------------------------+
|                 YOUR EPHEMERALROOMS SETUP                         |
+------------------------------------------------------------------+

iPhone (EphemeralRooms App)
    |
    | Real IP: Your home IP (visible to ISP only)
    | Using: TorManager pod (built-in Tor)
    |
    v
Tor Network (3+ nodes)
    |
    | Your IP: HIDDEN from here onwards
    |
    v
Hidden Service: xihrxmtwitgihtxllygrgoxixuu6ib7kzmgvosv7467tnij5svgyabid.onion
    |
    | Real Server: Cloud VPS (IP hidden via Tor)
    | Server IP: ALSO HIDDEN (it's a hidden service!)
    |
    v
WebSocket Relay Server (Node.js)
    |
    | Sees: Client IDs, encrypted payloads
    | Cannot see: IPs, message content
    |
    v
Other Room Participants
    |
    | See: Your messages (E2EE decrypted)
    | Cannot see: Your IP, identity, location

+------------------------------------------------------------------+
```
