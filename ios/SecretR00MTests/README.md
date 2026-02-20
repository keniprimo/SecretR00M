# EphemeralRooms Functional Test Suite

## Overview

This test suite validates the critical functionality of the EphemeralRooms iOS app before App Store submission. All tests must pass for a ship-ready build.

## Test File Structure

```
SecretR00MTests/
├── Mocks/
│   ├── MockWebSocket.swift          # Mock WebSocket for network simulation
│   ├── MockRoomSessionDelegate.swift # Mock delegate for event capture
│   └── TestHelpers.swift            # Test utilities and helpers
├── CryptoTests.swift                # Core cryptographic tests (existing)
├── SecurityVerificationTests.swift   # Security property tests (existing)
├── RoomLifecycleTests.swift         # Room lifecycle tests (NEW)
├── NetworkResilienceTests.swift     # Network resilience tests (NEW)
├── CryptoStateMachineTests.swift    # Crypto state machine tests (NEW)
├── UIStateInteractionTests.swift    # UI/State interaction tests (NEW)
├── SmokeTests.swift                 # Critical path smoke tests (NEW)
├── StateMachineAssertionTests.swift # State machine assertions (NEW)
└── README.md                        # This file
```

## Test Categories

### 1. Room Lifecycle Tests (`RoomLifecycleTests.swift`)

| Test ID | Test Name | Status |
|---------|-----------|--------|
| ROOM_LIFECYCLE_001 | Client leaves room (non-host) | Automated |
| ROOM_LIFECYCLE_002 | Host kicks participant | Automated |

### 2. Network Resilience Tests (`NetworkResilienceTests.swift`)

| Test ID | Test Name | Status |
|---------|-----------|--------|
| NETWORK_RESILIENCE_001 | Send message during WebSocket reconnect | Automated |
| NETWORK_RESILIENCE_002 | Join request timeout (30s) | Automated |
| NETWORK_RESILIENCE_003 | Exponential backoff verification | Automated |

### 3. Crypto State Machine Tests (`CryptoStateMachineTests.swift`)

| Test ID | Test Name | Status |
|---------|-----------|--------|
| CRYPTO_STATE_001 | Late rekey confirmation after host timeout | Automated |
| RESOURCE_MGMT_001 | Memory warning while viewing messages | Automated |

### 4. UI/State Interaction Tests (`UIStateInteractionTests.swift`)

| Test ID | Test Name | Status |
|---------|-----------|--------|
| UI_STATE_001 | Navigate away from room during rekey | Automated (Unit) / MANUAL (UI) |

### 5. State Machine Assertions (`StateMachineAssertionTests.swift`)

| Assertion | Description | Status |
|-----------|-------------|--------|
| A | "Reconnecting..." UI indicator visibility | Automated |
| B | Closed room join error specificity | Automated |
| C | Late rekey confirmation ignored safely | Automated |

### 6. Smoke Tests (`SmokeTests.swift`)

| Test # | Test Name | Priority |
|--------|-----------|----------|
| 15 | Rejoin after disconnect mid-session | P0 |
| 16 | Multiple participants (3+) with rekey | P1 |
| 17 | Background/foreground preserves session | P1 |

## Mock Objects

### MockWebSocket

Simulates WebSocket behavior for testing:
- Connection/disconnection simulation
- Message queuing during disconnect
- Reconnection attempt tracking
- Server message simulation

### MockRoomSessionDelegate

Captures RoomSession events for verification:
- State change tracking
- Event capture with type filtering
- Expectation-based waiting
- Message and join request tracking

### TestHelpers

Utilities for testing:
- Test configuration with mock server URL
- Crypto test helpers (key generation, random bytes)
- Timing helpers (wait conditions, run loops)
- Assertion helpers (state machine assertions)

## Running Tests

### From Xcode

1. Open `CalculatorPR0.xcworkspace`
2. Select the test target: `SecretR00MTests`
3. Press `Cmd+U` to run all tests
4. Or select specific test file and `Cmd+U`

### From Command Line

```bash
cd /Users/kevinkulcsar/EphemeralRooms/ios
xcodebuild test \
  -workspace CalculatorPR0.xcworkspace \
  -scheme CalculatorPR0 \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Running Specific Tests

```bash
# Run only smoke tests
xcodebuild test -only-testing:SecretR00MTests/SmokeTests ...

# Run state machine assertions
xcodebuild test -only-testing:SecretR00MTests/StateMachineAssertionTests ...
```

## Manual Tests

The following tests require manual execution (not automatable):

### Tor Integration (MANUAL)
- Enable Tor in settings
- Create room
- Verify .onion connection
- Exchange messages
- Verify relay sees only encrypted traffic

### Multi-Device Tests (MANUAL)
- Test 15: Rejoin after disconnect (full flow)
- Test 16: 3+ participants with rekey
- Host kicks participant with real devices

### UI Tests (MANUAL)
- "Reconnecting..." banner visibility
- Warning dialog when leaving during rekey
- Error message specificity for closed rooms

## Automation Feasibility

| Category | Automation Level | Framework |
|----------|-----------------|-----------|
| Crypto Unit Tests | High | XCTest |
| State Machine Tests | High | XCTest |
| Network Resilience | Medium | XCTest + Mocks |
| UI State Tests | Medium | XCUITest |
| Multi-Device Tests | Low | Manual/CI Matrix |
| Tor Integration | Low | Manual |

## "All Tests Passing = Ship" Checklist

### Pre-Submission Gate

- [ ] All 8 functional tests pass (RoomLifecycle, NetworkResilience, CryptoStateMachine, UIStateInteraction)
- [ ] Both new smoke tests pass (Tests 15-16)
- [ ] All 3 state-machine assertions verified (A, B, C)
- [ ] Original CryptoTests and SecurityVerificationTests pass
- [ ] No test flakiness (run 3x)

### Build Verification

- [ ] Archive uses Release configuration
- [ ] `strings` on binary shows no `com.ephemeral.rooms` logger subsystem
- [ ] `grep -r "import os" *.swift` — all inside `#if DEBUG`
- [ ] `freopen("/dev/null")` active in Release stderr

### Security Verification

- [ ] HMAC on REKEY_CONFIRM includes hostEphemeralPublicKey
- [ ] SecureBytes.wipe() called on all session teardown paths
- [ ] SecureLogBuffer.log() returns immediately in Release
- [ ] Keychain stores Tor flag (not UserDefaults)

### Manual QA Sign-Off

- [ ] Fresh install → create room → exchange messages → leave ✓
- [ ] Tor enabled → room functions over onion circuit ✓
- [ ] Calculator stealth hides room on shake ✓
- [ ] Kill app mid-session → relaunch → session recovered ✓
- [ ] 3-participant room with rekey cycle ✓

## Success Criteria

If all tests pass:
- No dead-end UI states
- No silent message loss
- No ghost participants
- No reconnect storms
- No crashes during rekey or navigation

**The app validates that it WORKS, not that it is clever.**
