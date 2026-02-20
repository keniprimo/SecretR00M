// Package invite provides single-use invite token management for room joining.
// Tokens are ephemeral, single-use, and time-limited for security.
package invite

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"sync"
	"time"
)

// Errors
var (
	ErrTokenNotFound     = errors.New("token not found or expired")
	ErrTokenAlreadyUsed  = errors.New("token already used")
	ErrInvalidToken      = errors.New("invalid token format")
	ErrRoomTokenLimit    = errors.New("room has too many active tokens")
	ErrTooManyTokens     = errors.New("server token limit reached")
)

// Limits
const (
	TokenLength           = 24              // 192 bits of entropy (base64 encoded = 32 chars)
	DefaultTokenTTL       = 24 * time.Hour  // Tokens expire after 24 hours
	MaxTokensPerRoom      = 100             // Max active tokens per room
	MaxTotalTokens        = 100000          // Max total tokens server-wide
	CleanupInterval       = 5 * time.Minute // How often to clean expired tokens
)

// Token represents a single-use invite token
type Token struct {
	ID        string    // The token string (base64url)
	RoomID    string    // Associated room
	CreatedAt time.Time
	ExpiresAt time.Time
	Used      bool
}

// TokenStore manages all invite tokens in memory
type TokenStore struct {
	tokens       map[string]*Token // token ID -> Token
	roomTokens   map[string]int    // roomID -> count of active tokens
	mu           sync.RWMutex
	cleanupDone  chan struct{}
}

// NewTokenStore creates a new in-memory token store with background cleanup
func NewTokenStore() *TokenStore {
	ts := &TokenStore{
		tokens:      make(map[string]*Token),
		roomTokens:  make(map[string]int),
		cleanupDone: make(chan struct{}),
	}

	// Start background cleanup goroutine
	go ts.cleanupLoop()

	return ts
}

// CreateToken generates a new single-use invite token for a room
func (ts *TokenStore) CreateToken(roomID string) (*Token, error) {
	ts.mu.Lock()
	defer ts.mu.Unlock()

	// Check server-wide limit
	if len(ts.tokens) >= MaxTotalTokens {
		return nil, ErrTooManyTokens
	}

	// Check per-room limit
	if ts.roomTokens[roomID] >= MaxTokensPerRoom {
		return nil, ErrRoomTokenLimit
	}

	// Generate cryptographically secure token
	tokenBytes := make([]byte, TokenLength)
	if _, err := rand.Read(tokenBytes); err != nil {
		return nil, err
	}

	tokenID := base64.RawURLEncoding.EncodeToString(tokenBytes)

	token := &Token{
		ID:        tokenID,
		RoomID:    roomID,
		CreatedAt: time.Now(),
		ExpiresAt: time.Now().Add(DefaultTokenTTL),
		Used:      false,
	}

	ts.tokens[tokenID] = token
	ts.roomTokens[roomID]++

	return token, nil
}

// ValidateAndConsume validates a token and marks it as used (single-use)
// Returns the room ID if valid, or an error if invalid/expired/used
func (ts *TokenStore) ValidateAndConsume(tokenID string) (string, error) {
	ts.mu.Lock()
	defer ts.mu.Unlock()

	token, exists := ts.tokens[tokenID]
	if !exists {
		return "", ErrTokenNotFound
	}

	// Check expiration
	if time.Now().After(token.ExpiresAt) {
		// Clean up expired token
		delete(ts.tokens, tokenID)
		ts.roomTokens[token.RoomID]--
		return "", ErrTokenNotFound
	}

	// Check if already used
	if token.Used {
		return "", ErrTokenAlreadyUsed
	}

	// Mark as used and remove from store (single-use)
	roomID := token.RoomID
	delete(ts.tokens, tokenID)
	ts.roomTokens[roomID]--
	if ts.roomTokens[roomID] <= 0 {
		delete(ts.roomTokens, roomID)
	}

	return roomID, nil
}

// Peek checks if a token is valid without consuming it
// Used for pre-validation before join attempt
func (ts *TokenStore) Peek(tokenID string) (*Token, error) {
	ts.mu.RLock()
	defer ts.mu.RUnlock()

	token, exists := ts.tokens[tokenID]
	if !exists {
		return nil, ErrTokenNotFound
	}

	// Check expiration
	if time.Now().After(token.ExpiresAt) {
		return nil, ErrTokenNotFound
	}

	// Check if already used
	if token.Used {
		return nil, ErrTokenAlreadyUsed
	}

	// Return a copy to prevent external modification
	return &Token{
		ID:        token.ID,
		RoomID:    token.RoomID,
		CreatedAt: token.CreatedAt,
		ExpiresAt: token.ExpiresAt,
		Used:      token.Used,
	}, nil
}

// RevokeRoomTokens removes all tokens for a specific room
// Called when a room is destroyed
func (ts *TokenStore) RevokeRoomTokens(roomID string) int {
	ts.mu.Lock()
	defer ts.mu.Unlock()

	count := 0
	for tokenID, token := range ts.tokens {
		if token.RoomID == roomID {
			delete(ts.tokens, tokenID)
			count++
		}
	}
	delete(ts.roomTokens, roomID)

	return count
}

// TokenCount returns the number of active tokens
func (ts *TokenStore) TokenCount() int {
	ts.mu.RLock()
	defer ts.mu.RUnlock()
	return len(ts.tokens)
}

// RoomTokenCount returns the number of active tokens for a specific room
func (ts *TokenStore) RoomTokenCount(roomID string) int {
	ts.mu.RLock()
	defer ts.mu.RUnlock()
	return ts.roomTokens[roomID]
}

// Stop stops the background cleanup goroutine
func (ts *TokenStore) Stop() {
	close(ts.cleanupDone)
}

// cleanupLoop periodically removes expired tokens
func (ts *TokenStore) cleanupLoop() {
	ticker := time.NewTicker(CleanupInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			ts.cleanupExpired()
		case <-ts.cleanupDone:
			return
		}
	}
}

// cleanupExpired removes all expired tokens
func (ts *TokenStore) cleanupExpired() {
	ts.mu.Lock()
	defer ts.mu.Unlock()

	now := time.Now()
	for tokenID, token := range ts.tokens {
		if now.After(token.ExpiresAt) {
			delete(ts.tokens, tokenID)
			ts.roomTokens[token.RoomID]--
			if ts.roomTokens[token.RoomID] <= 0 {
				delete(ts.roomTokens, token.RoomID)
			}
		}
	}
}
