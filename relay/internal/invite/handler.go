// Package invite provides HTTP handlers for invite token management
package invite

import (
	"encoding/json"
	"log"
	"net/http"
	"regexp"
	"strings"

	"github.com/ephemeral/relay/internal/ratelimit"
	"github.com/ephemeral/relay/internal/room"
)

var roomIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)
var tokenPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{32}$`)

// Handler handles HTTP requests for invite token operations
type Handler struct {
	tokenStore  *TokenStore
	registry    *room.Registry
	rateLimiter *ratelimit.Limiter
}

// NewHandler creates a new invite HTTP handler
func NewHandler(tokenStore *TokenStore, registry *room.Registry, rateLimiter *ratelimit.Limiter) *Handler {
	return &Handler{
		tokenStore:  tokenStore,
		registry:    registry,
		rateLimiter: rateLimiter,
	}
}

// Response types
type CreateTokenResponse struct {
	Token     string `json:"token"`
	RoomID    string `json:"roomId"`
	ExpiresIn int64  `json:"expiresIn"` // Seconds until expiration
}

type ValidateTokenResponse struct {
	Valid  bool   `json:"valid"`
	RoomID string `json:"roomId,omitempty"`
	Error  string `json:"error,omitempty"`
}

type ErrorResponse struct {
	Error string `json:"error"`
}

// ServeHTTP routes invite-related HTTP requests
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Set JSON content type for all responses
	w.Header().Set("Content-Type", "application/json")

	// Rate limiting by IP
	clientIP := getClientIP(r)
	if !h.rateLimiter.Allow(clientIP) {
		w.WriteHeader(http.StatusTooManyRequests)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "rate limited"})
		return
	}

	path := r.URL.Path

	switch {
	case strings.HasPrefix(path, "/invite/create/"):
		h.handleCreate(w, r)
	case strings.HasPrefix(path, "/invite/validate/"):
		h.handleValidate(w, r)
	default:
		w.WriteHeader(http.StatusNotFound)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "not found"})
	}
}

// handleCreate handles POST /invite/create/{roomId}
// Creates a new single-use invite token for the specified room
func (h *Handler) handleCreate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "method not allowed"})
		return
	}

	// Extract room ID from path
	roomID := strings.TrimPrefix(r.URL.Path, "/invite/create/")
	if !roomIDPattern.MatchString(roomID) {
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "invalid room ID format"})
		return
	}

	// Verify room exists
	rm := h.registry.GetRoom(roomID)
	if rm == nil {
		w.WriteHeader(http.StatusNotFound)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "room not found"})
		return
	}

	// Create token
	token, err := h.tokenStore.CreateToken(roomID)
	if err != nil {
		log.Printf("Token create failed for room %s...: %v", roomID[:8], err)
		w.WriteHeader(http.StatusServiceUnavailable)
		json.NewEncoder(w).Encode(ErrorResponse{Error: err.Error()})
		return
	}

	log.Printf("Token created for room %s...", roomID[:8])

	// Return token (only log truncated room ID for privacy)
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(CreateTokenResponse{
		Token:     token.ID,
		RoomID:    roomID,
		ExpiresIn: int64(DefaultTokenTTL.Seconds()),
	})
}

// handleValidate handles GET /invite/validate/{token}
// Validates a token without consuming it (peek operation)
func (h *Handler) handleValidate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "method not allowed"})
		return
	}

	// Extract token from path
	tokenID := strings.TrimPrefix(r.URL.Path, "/invite/validate/")
	if !tokenPattern.MatchString(tokenID) {
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(ValidateTokenResponse{
			Valid: false,
			Error: "invalid token format",
		})
		return
	}

	// Peek at token (don't consume)
	token, err := h.tokenStore.Peek(tokenID)
	if err != nil {
		w.WriteHeader(http.StatusOK) // Return 200 with valid=false
		json.NewEncoder(w).Encode(ValidateTokenResponse{
			Valid: false,
			Error: err.Error(),
		})
		return
	}

	// Verify room still exists
	rm := h.registry.GetRoom(token.RoomID)
	if rm == nil {
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(ValidateTokenResponse{
			Valid: false,
			Error: "room no longer exists",
		})
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(ValidateTokenResponse{
		Valid:  true,
		RoomID: token.RoomID,
	})
}

// ConsumeToken consumes a token and returns the room ID
// This is called during the WebSocket join flow, not via HTTP
func (h *Handler) ConsumeToken(tokenID string) (string, error) {
	return h.tokenStore.ValidateAndConsume(tokenID)
}

// RevokeRoomTokens revokes all tokens for a room
// Called when a room is destroyed
func (h *Handler) RevokeRoomTokens(roomID string) {
	count := h.tokenStore.RevokeRoomTokens(roomID)
	if count > 0 {
		log.Printf("Revoked %d tokens for room %s...", count, roomID[:8])
	}
}

func getClientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		return strings.TrimSpace(parts[0])
	}
	if xri := r.Header.Get("X-Real-IP"); xri != "" {
		return xri
	}
	return strings.Split(r.RemoteAddr, ":")[0]
}
