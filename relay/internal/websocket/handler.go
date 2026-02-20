// Package websocket provides WebSocket handling for the ephemeral relay server
package websocket

import (
	"encoding/json"
	"log"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/ephemeral/relay/internal/invite"
	"github.com/ephemeral/relay/internal/metrics"
	"github.com/ephemeral/relay/internal/ratelimit"
	"github.com/ephemeral/relay/internal/room"
	"github.com/gorilla/websocket"
)

// Constants
const (
	// MaxMessageSize must accommodate encrypted images/videos with Base64 overhead
	// 5MB image + padding (5.2MB) + frame header (57B) + Base64 (+33%) ≈ 7MB
	// Using 8MB to provide headroom for future expansion
	MaxMessageSize         = 8 * 1024 * 1024 // 8MB
	ReadTimeout            = 60 * time.Second
	WriteTimeout           = 30 * time.Second // Increased for large messages
	PingInterval           = 30 * time.Second
	HeartbeatCheckInterval = 3 * time.Second
	HeartbeatTimeout       = 6 * time.Second
)

// Message types
type Message struct {
	Type     string          `json:"type"`
	RoomID   string          `json:"roomId,omitempty"`
	ClientID string          `json:"clientId,omitempty"`
	Payload  json.RawMessage `json:"payload,omitempty"`
	Reason   string          `json:"reason,omitempty"`
}

var upgrader = websocket.Upgrader{
	ReadBufferSize:  64 * 1024,  // 64KB buffer for reading large messages
	WriteBufferSize: 64 * 1024,  // 64KB buffer for writing large messages
	CheckOrigin:     func(r *http.Request) bool { return true },
}

var roomIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)

// Handler handles WebSocket connections
type Handler struct {
	registry       *room.Registry
	connLimiter    *ratelimit.Limiter
	msgLimiter     *ratelimit.MessageLimiter
	inviteHandler  *invite.Handler
}

// NewHandler creates a new WebSocket handler
func NewHandler(registry *room.Registry, connLimiter *ratelimit.Limiter, msgLimiter *ratelimit.MessageLimiter, inviteHandler *invite.Handler) *Handler {
	return &Handler{
		registry:      registry,
		connLimiter:   connLimiter,
		msgLimiter:    msgLimiter,
		inviteHandler: inviteHandler,
	}
}

// ServeHTTP handles incoming HTTP requests and upgrades to WebSocket
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path

	// Extract room ID from path
	roomID := extractRoomID(path)
	if roomID == "" || !roomIDPattern.MatchString(roomID) {
		http.Error(w, "Invalid room ID", http.StatusBadRequest)
		return
	}

	// Rate limiting by IP
	clientIP := getClientIP(r)
	if !h.connLimiter.Allow(clientIP) {
		metrics.Global.IncRateLimited()
		http.Error(w, "Rate limited", http.StatusTooManyRequests)
		return
	}

	// Upgrade to WebSocket
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade failed: %v", err)
		return
	}

	metrics.Global.IncConnections()

	// Route based on path
	if strings.Contains(path, "/join") {
		// Extract invite token from query parameter
		inviteToken := r.URL.Query().Get("token")
		h.handleClientJoin(conn, roomID, inviteToken)
	} else {
		h.handleHostCreate(conn, roomID)
	}
}

func (h *Handler) handleHostCreate(conn *websocket.Conn, roomID string) {
	// Create room
	rm, err := h.registry.CreateRoom(roomID, conn)
	if err != nil {
		sendError(conn, err.Error())
		conn.Close()
		return
	}

	metrics.Global.IncRoomsCreated()
	log.Printf("Room created: %s...", roomID[:8])

	// Ensure room is destroyed when this function exits
	defer func() {
		if r := recover(); r != nil {
			log.Printf("Panic in host handler: %v", r)
		}
		h.registry.DestroyRoom(roomID, "host_disconnected")
		h.msgLimiter.RemoveRoom(roomID)
		metrics.Global.IncRoomsDestroyed()
		log.Printf("Room destroyed: %s...", roomID[:8])
	}()

	// Configure connection
	conn.SetReadLimit(MaxMessageSize)
	conn.SetReadDeadline(time.Now().Add(ReadTimeout))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(ReadTimeout))
		return nil
	})

	// Start writer goroutine
	writerDone := make(chan struct{})
	go func() {
		defer close(writerDone)
		h.hostWriter(rm, conn)
	}()

	// Start heartbeat monitor
	heartbeatDone := make(chan struct{})
	go func() {
		defer close(heartbeatDone)
		h.heartbeatMonitor(rm, roomID)
	}()

	// Send room created confirmation
	sendJSON(conn, Message{Type: "ROOM_CREATED", RoomID: roomID})

	// Read loop (blocks until disconnect)
	h.hostReader(rm, conn)

	// Cleanup
	<-writerDone
}

func (h *Handler) hostReader(rm *room.Room, conn *websocket.Conn) {
	for {
		_, message, err := conn.ReadMessage()
		if err != nil {
			return
		}

		var msg Message
		if err := json.Unmarshal(message, &msg); err != nil {
			continue
		}

		rm.UpdateHeartbeat()

		switch msg.Type {
		case "HEARTBEAT":
			select {
			case rm.HostSendCh <- []byte(`{"type":"HEARTBEAT_ACK"}`):
			default:
			}

		case "ROOM_OPEN":
			rm.OpenRoom()
			log.Printf("Room opened: %s...", rm.ID[:8])

		case "BROADCAST":
			h.handleBroadcast(rm, msg.Payload)

		case "DIRECT":
			h.handleDirect(rm, msg.ClientID, msg.Payload)

		case "JOIN_RESPONSE":
			h.handleJoinResponse(rm, msg.ClientID, message)

		case "KICK":
			h.handleKick(rm, msg.ClientID)

		case "ROOM_CLOSE":
			return
		}
	}
}

func (h *Handler) hostWriter(rm *room.Room, conn *websocket.Conn) {
	ticker := time.NewTicker(PingInterval)
	defer ticker.Stop()

	for {
		select {
		case message, ok := <-rm.HostSendCh:
			if !ok {
				return
			}
			conn.SetWriteDeadline(time.Now().Add(WriteTimeout))
			if err := conn.WriteMessage(websocket.TextMessage, message); err != nil {
				return
			}

		case <-ticker.C:
			conn.SetWriteDeadline(time.Now().Add(WriteTimeout))
			if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

func (h *Handler) heartbeatMonitor(rm *room.Room, roomID string) {
	ticker := time.NewTicker(HeartbeatCheckInterval)
	defer ticker.Stop()

	for range ticker.C {
		lastHB := rm.GetLastHeartbeat()
		if time.Since(lastHB) > HeartbeatTimeout {
			log.Printf("Heartbeat timeout: %s...", roomID[:8])
			h.registry.DestroyRoom(roomID, "heartbeat_timeout")
			return
		}

		// Check if room still exists
		if h.registry.GetRoom(roomID) == nil {
			return
		}
	}
}

func (h *Handler) handleClientJoin(conn *websocket.Conn, roomID string, inviteToken string) {
	// Check if room exists first
	rm := h.registry.GetRoom(roomID)
	if rm == nil {
		sendError(conn, "Room not found")
		conn.Close()
		return
	}

	// Generate client ID
	clientID := generateClientID()

	// If invite token provided, validate and consume it (optional - for invite link flow)
	// Even with valid token, host must still approve the join request
	if inviteToken != "" {
		tokenRoomID, err := h.inviteHandler.ConsumeToken(inviteToken)
		if err != nil {
			log.Printf("Client %s... invite token invalid: %v (host approval still required)", clientID[:8], err)
		} else if tokenRoomID != roomID {
			log.Printf("Client %s... token/room mismatch (host approval still required)", clientID[:8])
		} else {
			log.Printf("Client %s... has valid invite token for room %s...", clientID[:8], roomID[:8])
		}
	}

	// Add client to room
	client, err := rm.AddClient(clientID, conn)
	if err != nil {
		sendError(conn, err.Error())
		conn.Close()
		return
	}

	log.Printf("Client connected, awaiting host approval: %s... room: %s...", clientID[:8], roomID[:8])

	// Send connected message
	sendJSON(conn, Message{Type: "CONNECTED", ClientID: clientID})

	// Start writer goroutine
	go h.clientWriter(client)

	// Read loop
	h.clientReader(rm, client, roomID)

	// Cleanup
	rm.RemoveClient(clientID)
	log.Printf("Client left: %s... room: %s...", clientID[:8], roomID[:8])

	// Notify host
	select {
	case rm.HostSendCh <- []byte(`{"type":"CLIENT_LEFT","clientId":"` + clientID + `"}`):
	default:
	}
}

func (h *Handler) clientReader(rm *room.Room, client *room.Client, roomID string) {
	conn := client.Conn
	conn.SetReadLimit(MaxMessageSize)
	conn.SetReadDeadline(time.Now().Add(ReadTimeout))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(ReadTimeout))
		return nil
	})

	for {
		_, message, err := conn.ReadMessage()
		if err != nil {
			return
		}

		var msg Message
		if err := json.Unmarshal(message, &msg); err != nil {
			continue
		}

		// Rate limit messages
		if !h.msgLimiter.Allow(roomID, client.ID) {
			continue
		}

		switch msg.Type {
		case "JOIN_REQUEST":
			// Forward to host for approval
			fwd := Message{
				Type:     "JOIN_REQUEST",
				ClientID: client.ID,
				Payload:  msg.Payload,
			}
			if data, err := json.Marshal(fwd); err == nil {
				select {
				case rm.HostSendCh <- data:
				default:
				}
			}

		case "JOIN_CONFIRM":
			// Forward to host
			fwd := Message{
				Type:     "JOIN_CONFIRM",
				ClientID: client.ID,
				Payload:  msg.Payload,
			}
			if data, err := json.Marshal(fwd); err == nil {
				select {
				case rm.HostSendCh <- data:
				default:
				}
			}

		case "MESSAGE":
			metrics.Global.IncMessages()

			// Forward to host
			fwd := Message{
				Type:     "CLIENT_MESSAGE",
				ClientID: client.ID,
				Payload:  msg.Payload,
			}
			if data, err := json.Marshal(fwd); err == nil {
				select {
				case rm.HostSendCh <- data:
				default:
				}
			}

			// Broadcast to other clients
			bcast := Message{
				Type:     "MESSAGE",
				ClientID: client.ID,
				Payload:  msg.Payload,
			}
			if data, err := json.Marshal(bcast); err == nil {
				rm.BroadcastToOthers(client.ID, data)
			}
		}
	}
}

func (h *Handler) clientWriter(client *room.Client) {
	ticker := time.NewTicker(PingInterval)
	defer ticker.Stop()

	for {
		select {
		case message, ok := <-client.SendCh:
			if !ok {
				client.Conn.Close()
				return
			}
			client.Conn.SetWriteDeadline(time.Now().Add(WriteTimeout))
			if err := client.Conn.WriteMessage(websocket.TextMessage, message); err != nil {
				return
			}

		case <-ticker.C:
			client.Conn.SetWriteDeadline(time.Now().Add(WriteTimeout))
			if err := client.Conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

func (h *Handler) handleBroadcast(rm *room.Room, payload json.RawMessage) {
	metrics.Global.IncMessages()
	msg := Message{Type: "MESSAGE", Payload: payload}
	if data, err := json.Marshal(msg); err == nil {
		rm.BroadcastToClients(data)
	}
}

func (h *Handler) handleDirect(rm *room.Room, clientID string, payload json.RawMessage) {
	client := rm.GetClient(clientID)
	if client == nil {
		return
	}

	msg := Message{Type: "MESSAGE", Payload: payload}
	if data, err := json.Marshal(msg); err == nil {
		select {
		case client.SendCh <- data:
		default:
		}
	}
}

func (h *Handler) handleJoinResponse(rm *room.Room, clientID string, message []byte) {
	client := rm.GetClient(clientID)
	if client == nil {
		return
	}

	select {
	case client.SendCh <- message:
	default:
	}
}

func (h *Handler) handleKick(rm *room.Room, clientID string) {
	client := rm.GetClient(clientID)
	if client == nil {
		return
	}

	// Send kick message and close
	kickMsg := []byte(`{"type":"KICKED","reason":"kicked_by_host"}`)
	select {
	case client.SendCh <- kickMsg:
	default:
	}

	rm.RemoveClient(clientID)
	client.Conn.Close()
}

// Helper functions

func extractRoomID(path string) string {
	// Path format: /rooms/{roomId} or /rooms/{roomId}/join
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) >= 2 && parts[0] == "rooms" {
		return parts[1]
	}
	return ""
}

func getClientIP(r *http.Request) string {
	// Check X-Forwarded-For header first
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		return strings.TrimSpace(parts[0])
	}
	// Check X-Real-IP
	if xri := r.Header.Get("X-Real-IP"); xri != "" {
		return xri
	}
	// Fall back to RemoteAddr
	return strings.Split(r.RemoteAddr, ":")[0]
}

func generateClientID() string {
	// Generate a random client ID (16 hex chars)
	const chars = "0123456789abcdef"
	b := make([]byte, 16)
	for i := range b {
		b[i] = chars[time.Now().UnixNano()%int64(len(chars))]
		time.Sleep(time.Nanosecond)
	}
	return string(b)
}

func sendJSON(conn *websocket.Conn, msg Message) {
	data, err := json.Marshal(msg)
	if err != nil {
		return
	}
	conn.SetWriteDeadline(time.Now().Add(WriteTimeout))
	conn.WriteMessage(websocket.TextMessage, data)
}

func sendError(conn *websocket.Conn, errMsg string) {
	msg := Message{Type: "ERROR", Reason: errMsg}
	sendJSON(conn, msg)
}
