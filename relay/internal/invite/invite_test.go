package invite

import (
	"sync"
	"testing"
	"time"
)

// TestTokenCreation verifies basic token creation
func TestTokenCreation(t *testing.T) {
	ts := NewTokenStore()
	defer ts.Stop()

	token, err := ts.CreateToken("test-room-id-1234567890123456789012345")
	if err != nil {
		t.Fatalf("Failed to create token: %v", err)
	}

	if token.ID == "" {
		t.Error("Token ID should not be empty")
	}

	if len(token.ID) != 32 { // 24 bytes base64url encoded = 32 chars
		t.Errorf("Token ID length should be 32, got %d", len(token.ID))
	}

	if token.RoomID != "test-room-id-1234567890123456789012345" {
		t.Errorf("Room ID mismatch: %s", token.RoomID)
	}

	if token.Used {
		t.Error("New token should not be marked as used")
	}

	if token.ExpiresAt.Before(time.Now()) {
		t.Error("Token should not be expired immediately")
	}
}

// TestTokenUniqueness verifies each token is unique
func TestTokenUniqueness(t *testing.T) {
	ts := NewTokenStore()
	defer ts.Stop()

	tokens := make(map[string]bool)

	// Use multiple rooms to avoid per-room limit
	for i := 0; i < 1000; i++ {
		roomID := "uniqueness-room-" + string(rune('A'+i/100)) + "-" + string(rune('0'+i%100/10)) + string(rune('0'+i%10)) + "-123456789012"
		token, err := ts.CreateToken(roomID)
		if err != nil {
			t.Fatalf("Failed to create token %d: %v", i, err)
		}

		if tokens[token.ID] {
			t.Fatalf("Duplicate token generated: %s", token.ID)
		}
		tokens[token.ID] = true
	}
}

// TestSingleUseToken verifies tokens can only be used once
func TestSingleUseToken(t *testing.T) {
	ts := NewTokenStore()
	defer ts.Stop()

	roomID := "single-use-test-room-123456789012345"
	token, _ := ts.CreateToken(roomID)

	// First use should succeed
	gotRoomID, err := ts.ValidateAndConsume(token.ID)
	if err != nil {
		t.Fatalf("First use should succeed: %v", err)
	}
	if gotRoomID != roomID {
		t.Errorf("Room ID mismatch: expected %s, got %s", roomID, gotRoomID)
	}

	// Second use should fail
	_, err = ts.ValidateAndConsume(token.ID)
	if err != ErrTokenNotFound {
		t.Errorf("Second use should fail with ErrTokenNotFound, got: %v", err)
	}
}

// TestPeekDoesNotConsume verifies Peek doesn't consume the token
func TestPeekDoesNotConsume(t *testing.T) {
	ts := NewTokenStore()
	defer ts.Stop()

	roomID := "peek-test-room-1234567890123456789012"
	token, _ := ts.CreateToken(roomID)

	// Peek multiple times
	for i := 0; i < 10; i++ {
		peeked, err := ts.Peek(token.ID)
		if err != nil {
			t.Fatalf("Peek %d should succeed: %v", i, err)
		}
		if peeked.RoomID != roomID {
			t.Error("Peek returned wrong room ID")
		}
	}

	// Token should still be consumable
	_, err := ts.ValidateAndConsume(token.ID)
	if err != nil {
		t.Fatalf("Token should still be consumable after peeks: %v", err)
	}
}

// TestExpiredToken verifies expired tokens are rejected
func TestExpiredToken(t *testing.T) {
	ts := &TokenStore{
		tokens:      make(map[string]*Token),
		roomTokens:  make(map[string]int),
		cleanupDone: make(chan struct{}),
	}
	defer ts.Stop()

	// Manually create an expired token
	expiredToken := &Token{
		ID:        "expired-token-12345678901234567890",
		RoomID:    "expired-room-id-12345678901234567890",
		CreatedAt: time.Now().Add(-2 * time.Hour),
		ExpiresAt: time.Now().Add(-1 * time.Hour), // Expired 1 hour ago
		Used:      false,
	}
	ts.tokens[expiredToken.ID] = expiredToken
	ts.roomTokens[expiredToken.RoomID] = 1

	// Should fail to validate
	_, err := ts.ValidateAndConsume(expiredToken.ID)
	if err != ErrTokenNotFound {
		t.Errorf("Expired token should return ErrTokenNotFound, got: %v", err)
	}

	// Peek should also fail
	_, err = ts.Peek(expiredToken.ID)
	if err != ErrTokenNotFound {
		t.Errorf("Peek on expired token should fail, got: %v", err)
	}
}

// TestRevokeRoomTokens verifies all tokens for a room are revoked
func TestRevokeRoomTokens(t *testing.T) {
	ts := NewTokenStore()
	defer ts.Stop()

	roomID := "revoke-test-room-12345678901234567890"

	// Create multiple tokens
	var tokenIDs []string
	for i := 0; i < 10; i++ {
		token, _ := ts.CreateToken(roomID)
		tokenIDs = append(tokenIDs, token.ID)
	}

	if ts.RoomTokenCount(roomID) != 10 {
		t.Errorf("Expected 10 tokens, got %d", ts.RoomTokenCount(roomID))
	}

	// Revoke all
	count := ts.RevokeRoomTokens(roomID)
	if count != 10 {
		t.Errorf("Expected to revoke 10 tokens, revoked %d", count)
	}

	if ts.RoomTokenCount(roomID) != 0 {
		t.Errorf("Expected 0 tokens after revoke, got %d", ts.RoomTokenCount(roomID))
	}

	// All tokens should now be invalid
	for _, tokenID := range tokenIDs {
		_, err := ts.Peek(tokenID)
		if err != ErrTokenNotFound {
			t.Errorf("Revoked token should be not found")
		}
	}
}

// TestMaxTokensPerRoom verifies per-room token limits
func TestMaxTokensPerRoom(t *testing.T) {
	ts := NewTokenStore()
	defer ts.Stop()

	roomID := "max-tokens-room-123456789012345678901"

	// Create up to limit
	for i := 0; i < MaxTokensPerRoom; i++ {
		_, err := ts.CreateToken(roomID)
		if err != nil {
			t.Fatalf("Should be able to create token %d: %v", i, err)
		}
	}

	// Next one should fail
	_, err := ts.CreateToken(roomID)
	if err != ErrRoomTokenLimit {
		t.Errorf("Should fail with ErrRoomTokenLimit, got: %v", err)
	}
}

// TestConcurrentTokenCreation verifies thread safety
func TestConcurrentTokenCreation(t *testing.T) {
	ts := NewTokenStore()
	defer ts.Stop()

	var wg sync.WaitGroup
	tokens := make(chan string, 1000)

	// Create 100 tokens concurrently across 10 rooms
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			roomID := "concurrent-room-" + string(rune('A'+idx%10)) + "-12345678901234"
			token, err := ts.CreateToken(roomID)
			if err != nil {
				return
			}
			tokens <- token.ID
		}(i)
	}

	wg.Wait()
	close(tokens)

	// Verify all tokens are unique
	seen := make(map[string]bool)
	for tokenID := range tokens {
		if seen[tokenID] {
			t.Error("Duplicate token in concurrent creation")
		}
		seen[tokenID] = true
	}
}

// TestConcurrentValidation verifies concurrent validation/consumption
func TestConcurrentValidation(t *testing.T) {
	ts := NewTokenStore()
	defer ts.Stop()

	roomID := "concurrent-val-room-12345678901234567"
	token, _ := ts.CreateToken(roomID)

	var wg sync.WaitGroup
	successCount := 0
	var mu sync.Mutex

	// Try to consume the same token from 100 goroutines
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := ts.ValidateAndConsume(token.ID)
			if err == nil {
				mu.Lock()
				successCount++
				mu.Unlock()
			}
		}()
	}

	wg.Wait()

	// Exactly one should succeed
	if successCount != 1 {
		t.Errorf("Expected exactly 1 successful consumption, got %d", successCount)
	}
}

// TestTokenFormat verifies token format is URL-safe base64
func TestTokenFormat(t *testing.T) {
	ts := NewTokenStore()
	defer ts.Stop()

	token, _ := ts.CreateToken("format-test-room-12345678901234567890")

	// Should only contain URL-safe base64 characters
	for _, c := range token.ID {
		if !((c >= 'A' && c <= 'Z') ||
			(c >= 'a' && c <= 'z') ||
			(c >= '0' && c <= '9') ||
			c == '-' || c == '_') {
			t.Errorf("Invalid character in token: %c", c)
		}
	}
}

// TestCleanupExpired verifies background cleanup works
func TestCleanupExpired(t *testing.T) {
	ts := &TokenStore{
		tokens:      make(map[string]*Token),
		roomTokens:  make(map[string]int),
		cleanupDone: make(chan struct{}),
	}
	defer ts.Stop()

	// Add mix of expired and valid tokens
	for i := 0; i < 5; i++ {
		// Expired
		ts.tokens["expired-"+string(rune('0'+i))+"-12345678901234567890"] = &Token{
			ID:        "expired-" + string(rune('0'+i)) + "-12345678901234567890",
			RoomID:    "cleanup-room-12345678901234567890123",
			ExpiresAt: time.Now().Add(-1 * time.Hour),
		}
		ts.roomTokens["cleanup-room-12345678901234567890123"]++

		// Valid
		ts.tokens["valid-"+string(rune('0'+i))+"-123456789012345678901"] = &Token{
			ID:        "valid-" + string(rune('0'+i)) + "-123456789012345678901",
			RoomID:    "cleanup-room-12345678901234567890123",
			ExpiresAt: time.Now().Add(1 * time.Hour),
		}
		ts.roomTokens["cleanup-room-12345678901234567890123"]++
	}

	if ts.TokenCount() != 10 {
		t.Fatalf("Expected 10 tokens before cleanup, got %d", ts.TokenCount())
	}

	// Run cleanup
	ts.cleanupExpired()

	if ts.TokenCount() != 5 {
		t.Errorf("Expected 5 tokens after cleanup, got %d", ts.TokenCount())
	}

	// Verify only valid ones remain
	for i := 0; i < 5; i++ {
		validID := "valid-" + string(rune('0'+i)) + "-123456789012345678901"
		if _, exists := ts.tokens[validID]; !exists {
			t.Errorf("Valid token %s should still exist", validID)
		}
	}
}

// BenchmarkTokenCreate benchmarks token creation
func BenchmarkTokenCreate(b *testing.B) {
	ts := NewTokenStore()
	defer ts.Stop()

	roomID := "benchmark-room-123456789012345678901"
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		ts.CreateToken(roomID)
	}
}

// BenchmarkTokenValidate benchmarks token validation
func BenchmarkTokenValidate(b *testing.B) {
	ts := NewTokenStore()
	defer ts.Stop()

	roomID := "benchmark-val-room-1234567890123456"

	// Pre-create tokens
	tokenIDs := make([]string, b.N)
	for i := 0; i < b.N; i++ {
		token, _ := ts.CreateToken(roomID)
		tokenIDs[i] = token.ID
	}

	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		ts.ValidateAndConsume(tokenIDs[i])
	}
}
