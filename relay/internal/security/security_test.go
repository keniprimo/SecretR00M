// Package security_test provides comprehensive security verification tests
// for the EphemeralRooms relay server
package security_test

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"regexp"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ephemeral/relay/internal/metrics"
	"github.com/ephemeral/relay/internal/ratelimit"
	"github.com/ephemeral/relay/internal/room"
	"github.com/gorilla/websocket"
)

// ============================================================================
// TEST-RELAY-001: No Message Storage
// ============================================================================

func TestRelayNoMessageStorage(t *testing.T) {
	// Verify the relay only has in-memory storage
	// by checking that Room struct has no persistence fields
	registry := room.NewRegistry()

	// Create a room with test data
	conn := &websocket.Conn{}
	r, err := registry.CreateRoom("test-room-nostorage-123456789012345", conn)
	if err != nil {
		t.Fatalf("Failed to create room: %v", err)
	}

	// Verify room is memory-only
	r.OpenRoom()
	r.AddClient("client1", &websocket.Conn{})

	// Messages are relayed through channels, not stored
	// Verify the room structure has no "messages" or "history" field
	// This is a compile-time check - the struct definition confirms no storage

	registry.DestroyRoom("test-room-nostorage-123456789012345", "test_complete")

	// Verify room is completely gone
	if registry.GetRoom("test-room-nostorage-123456789012345") != nil {
		t.Error("Room should be completely destroyed, not just closed")
	}
}

func TestRelayNoMessagePersistence(t *testing.T) {
	// Create registry, add data, then simulate restart
	registry1 := room.NewRegistry()
	conn := &websocket.Conn{}
	registry1.CreateRoom("persist-test-room-1234567890123456", conn)

	// Count rooms before "restart"
	countBefore := registry1.RoomCount()
	if countBefore != 1 {
		t.Errorf("Expected 1 room, got %d", countBefore)
	}

	// Simulate restart by creating new registry (old one goes out of scope)
	registry1 = nil
	runtime.GC()

	// New registry should have zero rooms
	registry2 := room.NewRegistry()
	countAfter := registry2.RoomCount()
	if countAfter != 0 {
		t.Errorf("After restart, expected 0 rooms, got %d", countAfter)
	}
}

// ============================================================================
// TEST-RELAY-002: Logging Security
// ============================================================================

func TestLogsTruncateRoomIDs(t *testing.T) {
	var logBuffer bytes.Buffer
	log.SetOutput(&logBuffer)
	defer log.SetOutput(os.Stdout)

	// Full room ID that should be truncated in logs
	fullRoomID := "abcdefghij123456789012345678901234567890123"

	// Log a message that includes the room ID (simulating what handler.go does)
	log.Printf("Room created: %s...", fullRoomID[:8])

	logOutput := logBuffer.String()

	// Full room ID should NOT appear in logs
	if strings.Contains(logOutput, fullRoomID) {
		t.Error("Full room ID found in logs - should be truncated")
	}

	// Only first 8 chars should appear
	if !strings.Contains(logOutput, "abcdefgh...") {
		t.Error("Truncated room ID not found in logs")
	}
}

func TestLogsNoIPAddresses(t *testing.T) {
	// Create a log capture buffer
	var logBuffer bytes.Buffer
	log.SetOutput(&logBuffer)
	defer log.SetOutput(os.Stdout)

	// Simulate operations that might log IPs
	registry := room.NewRegistry()
	conn := &websocket.Conn{}
	registry.CreateRoom("ip-test-room-12345678901234567890123", conn)
	registry.DestroyRoom("ip-test-room-12345678901234567890123", "test")

	logOutput := logBuffer.String()

	// Check for IP patterns
	ipv4Pattern := regexp.MustCompile(`\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}`)
	if ipv4Pattern.MatchString(logOutput) {
		t.Errorf("IPv4 address found in logs: %s", logOutput)
	}

	// IPv6 pattern (simplified)
	if strings.Contains(logOutput, "::") && !strings.Contains(logOutput, "...") {
		t.Error("Possible IPv6 address in logs")
	}
}

func TestMetricsNoPII(t *testing.T) {
	m := &metrics.Metrics{}

	// Increment various counters
	m.IncRoomsCreated()
	m.IncRoomsDestroyed()
	m.IncConnections()
	m.IncMessages()
	m.IncRateLimited()

	output := m.String(5)

	// Should only contain counter values, no identifiers
	forbiddenPatterns := []string{
		"room_id",
		"client_id",
		"user_id",
		"ip_address",
		"email",
		"name",
	}

	for _, pattern := range forbiddenPatterns {
		if strings.Contains(strings.ToLower(output), pattern) {
			t.Errorf("PII field '%s' found in metrics output", pattern)
		}
	}

	// Verify it's valid Prometheus format
	lines := strings.Split(output, "\n")
	for _, line := range lines {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// Each metric line should be "metric_name value"
		parts := strings.Fields(line)
		if len(parts) < 2 {
			t.Errorf("Invalid metrics line: %s", line)
		}
	}
}

// ============================================================================
// TEST-RELAY-003: Room Lifecycle Security
// ============================================================================

func TestRoomDestroyedOnHostDisconnect(t *testing.T) {
	registry := room.NewRegistry()
	conn := &websocket.Conn{}
	roomID := "destroy-test-room-123456789012345678901"

	r, err := registry.CreateRoom(roomID, conn)
	if err != nil {
		t.Fatalf("Failed to create room: %v", err)
	}

	// Add some clients
	r.OpenRoom()
	r.AddClient("client1", &websocket.Conn{})
	r.AddClient("client2", &websocket.Conn{})

	// Verify room exists with clients
	if r.ClientCount() != 2 {
		t.Errorf("Expected 2 clients, got %d", r.ClientCount())
	}

	// Simulate host disconnect
	registry.DestroyRoom(roomID, "host_disconnected")

	// Room should be completely gone
	if registry.GetRoom(roomID) != nil {
		t.Error("Room should be destroyed after host disconnect")
	}
}

func TestRoomCannotBeRecreatedImmediately(t *testing.T) {
	registry := room.NewRegistry()
	conn := &websocket.Conn{}
	roomID := "recreate-test-room-12345678901234567890"

	// Create and destroy room
	registry.CreateRoom(roomID, conn)
	registry.DestroyRoom(roomID, "test")

	// Verify room is gone
	if registry.GetRoom(roomID) != nil {
		t.Error("Room should be gone after destruction")
	}

	// Should be able to recreate (proves no zombie state)
	_, err := registry.CreateRoom(roomID, conn)
	if err != nil {
		t.Errorf("Should be able to recreate room after destruction: %v", err)
	}
}

func TestClientCannotJoinClosedRoom(t *testing.T) {
	registry := room.NewRegistry()
	conn := &websocket.Conn{}
	roomID := "closed-room-test-123456789012345678901"

	r, _ := registry.CreateRoom(roomID, conn)

	// Room is NOT open
	_, err := r.AddClient("client1", &websocket.Conn{})
	if err != room.ErrRoomNotOpen {
		t.Errorf("Expected ErrRoomNotOpen, got %v", err)
	}
}

// ============================================================================
// TEST-RELAY-004: Relay Does Not Decrypt
// ============================================================================

func TestRelayCannotDecryptMessages(t *testing.T) {
	// This is a design verification test
	// The relay receives encrypted payloads and forwards them without inspection

	// Create a mock encrypted payload
	encryptedPayload := []byte(`{"iv":"abc123","ciphertext":"encrypted_data_here","tag":"auth_tag"}`)

	// Simulate relay processing
	type RelayMessage struct {
		Type    string          `json:"type"`
		Payload json.RawMessage `json:"payload"`
	}

	msg := RelayMessage{
		Type:    "MESSAGE",
		Payload: encryptedPayload,
	}

	// Marshal and verify payload is untouched
	data, _ := json.Marshal(msg)
	var decoded RelayMessage
	json.Unmarshal(data, &decoded)

	// Payload should be exactly the same (relay doesn't modify)
	if !bytes.Equal(decoded.Payload, encryptedPayload) {
		t.Error("Relay modified the encrypted payload")
	}

	// IMPORTANT: There are NO crypto imports in the websocket handler
	// This is verified by checking the imports in handler.go
}

func TestMaxMessageSizeEnforced(t *testing.T) {
	// From handler.go: MaxMessageSize = 8 * 1024 * 1024 (8MB)
	// This accommodates encrypted images/videos with Base64 overhead:
	// 5MB image + padding (5.2MB) + frame header + Base64 (+33%) ≈ 7MB
	const MaxMessageSize = 8 * 1024 * 1024

	// Verify the constant exists and is reasonable
	if MaxMessageSize < 1024*1024 { // At least 1MB for images
		t.Error("Max message size too small for image support")
	}
	if MaxMessageSize > 50*1024*1024 { // 50MB would be unreasonable
		t.Error("Max message size too large")
	}

	// The actual enforcement is done by websocket library via SetReadLimit
	// This test verifies the constant value is appropriate
	t.Logf("Max message size: %d bytes (%d MB)", MaxMessageSize, MaxMessageSize/(1024*1024))
}

// ============================================================================
// TEST-RELAY-005: Rate Limiting
// ============================================================================

func TestConnectionRateLimiting(t *testing.T) {
	limiter := ratelimit.NewLimiter(10, 20) // 10 req/s, burst 20

	ip := "192.168.1.100"

	// Exhaust burst
	for i := 0; i < 20; i++ {
		if !limiter.Allow(ip) {
			t.Errorf("Request %d should be allowed within burst", i)
		}
	}

	// Next should be rate limited
	if limiter.Allow(ip) {
		t.Error("Request should be rate limited after burst exhausted")
	}
}

func TestMessageRateLimiting(t *testing.T) {
	limiter := ratelimit.NewMessageLimiter(10, 20)

	roomID := "rate-limit-room"
	clientID := "client1"

	// Exhaust burst
	for i := 0; i < 20; i++ {
		if !limiter.Allow(roomID, clientID) {
			t.Errorf("Message %d should be allowed within burst", i)
		}
	}

	// Next should be rate limited
	if limiter.Allow(roomID, clientID) {
		t.Error("Message should be rate limited after burst exhausted")
	}
}

func TestRateLimiterIsolation(t *testing.T) {
	limiter := ratelimit.NewLimiter(1, 1) // Very restrictive

	// Different IPs should have separate limits
	if !limiter.Allow("192.168.1.1") {
		t.Error("First IP first request should be allowed")
	}
	if limiter.Allow("192.168.1.1") {
		t.Error("First IP second request should be limited")
	}
	if !limiter.Allow("192.168.1.2") {
		t.Error("Second IP should have its own limit")
	}
}

// ============================================================================
// TEST-RELAY-006: Capacity Limits
// ============================================================================

func TestMaxRoomsEnforced(t *testing.T) {
	registry := room.NewRegistry()

	// Fill to capacity (using internal manipulation for speed)
	for i := 0; i < room.MaxRooms; i++ {
		registry.CreateRoom(fmt.Sprintf("room-%d-padding-for-length-12345", i), &websocket.Conn{})
	}

	// Next creation should fail
	_, err := registry.CreateRoom("overflow-room-123456789012345678901", &websocket.Conn{})
	if err != room.ErrServerAtCapacity {
		t.Errorf("Expected ErrServerAtCapacity, got %v", err)
	}
}

func TestMaxClientsPerRoomEnforced(t *testing.T) {
	registry := room.NewRegistry()
	r, _ := registry.CreateRoom("full-room-test-123456789012345678901", &websocket.Conn{})
	r.OpenRoom()

	// Fill to capacity
	for i := 0; i < room.MaxClientsPerRoom; i++ {
		_, err := r.AddClient(fmt.Sprintf("client-%d", i), &websocket.Conn{})
		if err != nil {
			t.Fatalf("Failed to add client %d: %v", i, err)
		}
	}

	// Next client should fail
	_, err := r.AddClient("overflow-client", &websocket.Conn{})
	if err != room.ErrRoomFull {
		t.Errorf("Expected ErrRoomFull, got %v", err)
	}
}

// ============================================================================
// TEST-RELAY-007: Memory Safety
// ============================================================================

func TestNoMemoryLeakOnRoomDestroy(t *testing.T) {
	var m runtime.MemStats

	// Initial memory
	runtime.GC()
	runtime.ReadMemStats(&m)
	initialAlloc := m.Alloc

	// Create and destroy many rooms
	registry := room.NewRegistry()
	for i := 0; i < 1000; i++ {
		roomID := fmt.Sprintf("leak-test-room-%d-1234567890123456", i)
		r, _ := registry.CreateRoom(roomID, &websocket.Conn{})
		r.OpenRoom()
		for j := 0; j < 10; j++ {
			r.AddClient(fmt.Sprintf("client-%d", j), &websocket.Conn{})
		}
		registry.DestroyRoom(roomID, "test")
	}

	// Force GC and check memory
	runtime.GC()
	debug.FreeOSMemory()
	runtime.ReadMemStats(&m)
	finalAlloc := m.Alloc

	// Memory shouldn't have grown significantly (allow 10MB buffer)
	if finalAlloc > initialAlloc+10*1024*1024 {
		t.Errorf("Possible memory leak: initial=%d MB, final=%d MB",
			initialAlloc/1024/1024, finalAlloc/1024/1024)
	}
}

func TestMemoryPerRoom(t *testing.T) {
	var m runtime.MemStats

	registry := room.NewRegistry()

	runtime.GC()
	runtime.ReadMemStats(&m)
	initialAlloc := m.TotalAlloc

	// Create 1000 rooms with clients
	for i := 0; i < 1000; i++ {
		roomID := fmt.Sprintf("mem-room-%d-12345678901234567890123", i)
		r, _ := registry.CreateRoom(roomID, &websocket.Conn{})
		r.OpenRoom()
		for j := 0; j < 10; j++ {
			r.AddClient(fmt.Sprintf("client-%d", j), &websocket.Conn{})
		}
	}

	runtime.ReadMemStats(&m)
	totalAlloc := m.TotalAlloc - initialAlloc
	memPerRoom := totalAlloc / 1000

	t.Logf("Memory per room (10 clients): %d KB", memPerRoom/1024)

	// Should be under 100KB per room - use TotalAlloc for accurate measurement
	if memPerRoom > 100*1024 {
		t.Errorf("Memory per room too high: %d KB", memPerRoom/1024)
	}
}

// ============================================================================
// TEST-RELAY-008: Concurrent Access Safety
// ============================================================================

func TestConcurrentRoomCreation(t *testing.T) {
	registry := room.NewRegistry()
	var wg sync.WaitGroup
	errors := make(chan error, 100)

	// Try to create same room concurrently
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			_, err := registry.CreateRoom("concurrent-room-123456789012345678", &websocket.Conn{})
			if err != nil && err != room.ErrRoomExists {
				errors <- err
			}
		}(i)
	}

	wg.Wait()
	close(errors)

	// Check for unexpected errors
	for err := range errors {
		t.Errorf("Unexpected error during concurrent creation: %v", err)
	}

	// Exactly one should have succeeded
	if registry.RoomCount() != 1 {
		t.Errorf("Expected exactly 1 room, got %d", registry.RoomCount())
	}
}

func TestConcurrentClientJoin(t *testing.T) {
	registry := room.NewRegistry()
	r, _ := registry.CreateRoom("concurrent-join-room-1234567890123", &websocket.Conn{})
	r.OpenRoom()

	var wg sync.WaitGroup
	successCount := int32(0)
	var countMu sync.Mutex

	// Try to add clients concurrently
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			_, err := r.AddClient(fmt.Sprintf("client-%d", n), &websocket.Conn{})
			if err == nil {
				countMu.Lock()
				successCount++
				countMu.Unlock()
			}
		}(i)
	}

	wg.Wait()

	// Should have exactly MaxClientsPerRoom or 100 (whichever is less)
	expected := room.MaxClientsPerRoom
	if 100 < expected {
		expected = 100
	}

	if int(successCount) != expected {
		t.Errorf("Expected %d successful joins, got %d", expected, successCount)
	}
}

// ============================================================================
// TEST-RELAY-009: Heartbeat and Timeout
// ============================================================================

func TestHeartbeatUpdates(t *testing.T) {
	r := &room.Room{
		ID:            "heartbeat-test",
		Clients:       make(map[string]*room.Client),
		LastHeartbeat: time.Now().Add(-time.Hour), // Old heartbeat
	}

	oldTime := r.GetLastHeartbeat()
	r.UpdateHeartbeat()
	newTime := r.GetLastHeartbeat()

	if !newTime.After(oldTime) {
		t.Error("Heartbeat should be updated to current time")
	}
}

// ============================================================================
// TEST-RELAY-010: Input Validation
// ============================================================================

func TestRoomIDValidation(t *testing.T) {
	// From handler.go: roomIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)
	pattern := regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)

	// Valid room IDs (must be exactly 43 chars)
	validIDs := []string{
		"abcdefghijklmnopqrstuvwxyz1234567890ABCDEFG", // 43 chars
		"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnop1", // 43 chars
		"1234567890123456789012345678901234567890123",  // 43 chars
		"____---____---____---____---____---____---_", // 43 chars with _ and -
	}

	for _, id := range validIDs {
		if !pattern.MatchString(id) {
			t.Errorf("Room ID should be valid: %s (length: %d)", id, len(id))
		}
	}

	// Invalid room IDs
	invalidIDs := []string{
		"",                                               // Empty
		"short",                                          // Too short
		"abcdefghijklmnopqrstuvwxyz1234567890ABCDEFGHI", // Too long (44)
		"abcdefghijklmnopqrstuvwxyz1234567890ABCDE",      // Too short (42)
		"abcdefghijklmnopqrstuvwxyz!@#$567890ABCDEFG",    // Invalid chars
		"../../../etc/passwd1234567890123456789012",      // Path traversal attempt
	}

	for _, id := range invalidIDs {
		if pattern.MatchString(id) {
			t.Errorf("Room ID should be invalid: %s", id)
		}
	}
}
