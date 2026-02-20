// Package room provides in-memory room management for the ephemeral relay server.
// All state is memory-only and destroyed on room close or server restart.
package room

import (
	"errors"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// Errors
var (
	ErrRoomExists       = errors.New("room already exists")
	ErrRoomNotFound     = errors.New("room not found")
	ErrServerAtCapacity = errors.New("server at capacity")
	ErrRoomFull         = errors.New("room is full")
	ErrRoomNotOpen      = errors.New("room is not open for joins")
)

// Limits
const (
	MaxRooms          = 10000
	MaxClientsPerRoom = 50
)

// Client represents a connected client in a room
type Client struct {
	ID     string
	Conn   *websocket.Conn
	SendCh chan []byte
}

// Room represents an active ephemeral room
type Room struct {
	ID            string
	HostConn      *websocket.Conn
	HostSendCh    chan []byte
	Clients       map[string]*Client
	CreatedAt     time.Time
	LastHeartbeat time.Time
	IsOpen        bool
	mu            sync.RWMutex
}

// Registry manages all active rooms in memory
type Registry struct {
	rooms map[string]*Room
	mu    sync.RWMutex
}

// NewRegistry creates a new in-memory room registry
func NewRegistry() *Registry {
	return &Registry{
		rooms: make(map[string]*Room),
	}
}

// CreateRoom creates a new room with the given host connection
func (r *Registry) CreateRoom(roomID string, hostConn *websocket.Conn) (*Room, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if _, exists := r.rooms[roomID]; exists {
		return nil, ErrRoomExists
	}

	if len(r.rooms) >= MaxRooms {
		return nil, ErrServerAtCapacity
	}

	room := &Room{
		ID:            roomID,
		HostConn:      hostConn,
		HostSendCh:    make(chan []byte, 256),
		Clients:       make(map[string]*Client),
		CreatedAt:     time.Now(),
		LastHeartbeat: time.Now(),
		IsOpen:        false,
	}

	r.rooms[roomID] = room
	return room, nil
}

// GetRoom retrieves a room by ID
func (r *Registry) GetRoom(roomID string) *Room {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.rooms[roomID]
}

// DestroyRoom removes a room and closes all connections
func (r *Registry) DestroyRoom(roomID string, reason string) {
	r.mu.Lock()
	room, exists := r.rooms[roomID]
	if !exists {
		r.mu.Unlock()
		return
	}
	delete(r.rooms, roomID)
	r.mu.Unlock()

	// Notify and close all clients
	room.mu.Lock()
	for _, client := range room.Clients {
		select {
		case client.SendCh <- []byte(`{"type":"ROOM_DESTROYED","reason":"` + reason + `"}`):
		default:
		}
		close(client.SendCh)
	}
	room.Clients = nil
	room.mu.Unlock()

	// Close host channel
	if room.HostSendCh != nil {
		select {
		case room.HostSendCh <- []byte(`{"type":"ROOM_DESTROYED","reason":"` + reason + `"}`):
		default:
		}
		close(room.HostSendCh)
	}
}

// RoomCount returns the number of active rooms
func (r *Registry) RoomCount() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.rooms)
}

// OpenRoom marks a room as open for client joins
func (room *Room) OpenRoom() {
	room.mu.Lock()
	defer room.mu.Unlock()
	room.IsOpen = true
}

// AddClient adds a client to the room
func (room *Room) AddClient(clientID string, conn *websocket.Conn) (*Client, error) {
	room.mu.Lock()
	defer room.mu.Unlock()

	if !room.IsOpen {
		return nil, ErrRoomNotOpen
	}

	if len(room.Clients) >= MaxClientsPerRoom {
		return nil, ErrRoomFull
	}

	client := &Client{
		ID:     clientID,
		Conn:   conn,
		SendCh: make(chan []byte, 64),
	}

	room.Clients[clientID] = client
	return client, nil
}

// RemoveClient removes a client from the room
func (room *Room) RemoveClient(clientID string) {
	room.mu.Lock()
	defer room.mu.Unlock()

	if client, exists := room.Clients[clientID]; exists {
		close(client.SendCh)
		delete(room.Clients, clientID)
	}
}

// GetClient retrieves a client by ID
func (room *Room) GetClient(clientID string) *Client {
	room.mu.RLock()
	defer room.mu.RUnlock()
	return room.Clients[clientID]
}

// BroadcastToClients sends a message to all clients
func (room *Room) BroadcastToClients(msg []byte) {
	room.mu.RLock()
	defer room.mu.RUnlock()

	for _, client := range room.Clients {
		select {
		case client.SendCh <- msg:
		default:
			// Client buffer full, skip
		}
	}
}

// BroadcastToOthers sends a message to all clients except the sender
func (room *Room) BroadcastToOthers(senderID string, msg []byte) {
	room.mu.RLock()
	defer room.mu.RUnlock()

	for id, client := range room.Clients {
		if id != senderID {
			select {
			case client.SendCh <- msg:
			default:
			}
		}
	}
}

// UpdateHeartbeat updates the last heartbeat time
func (room *Room) UpdateHeartbeat() {
	room.mu.Lock()
	defer room.mu.Unlock()
	room.LastHeartbeat = time.Now()
}

// GetLastHeartbeat returns the last heartbeat time
func (room *Room) GetLastHeartbeat() time.Time {
	room.mu.RLock()
	defer room.mu.RUnlock()
	return room.LastHeartbeat
}

// ClientCount returns the number of clients in the room
func (room *Room) ClientCount() int {
	room.mu.RLock()
	defer room.mu.RUnlock()
	return len(room.Clients)
}
