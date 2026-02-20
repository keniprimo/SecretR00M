package room

import (
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestRegistryCreateRoom(t *testing.T) {
	registry := NewRegistry()

	// Create mock connection
	conn := &websocket.Conn{}
	roomID := "test-room-123456789012345678901234567890123"

	room, err := registry.CreateRoom(roomID, conn)
	if err != nil {
		t.Fatalf("Failed to create room: %v", err)
	}

	if room.ID != roomID {
		t.Errorf("Expected room ID %s, got %s", roomID, room.ID)
	}

	if registry.RoomCount() != 1 {
		t.Errorf("Expected 1 room, got %d", registry.RoomCount())
	}
}

func TestRegistryDuplicateRoom(t *testing.T) {
	registry := NewRegistry()
	conn := &websocket.Conn{}
	roomID := "test-room-123456789012345678901234567890123"

	_, err := registry.CreateRoom(roomID, conn)
	if err != nil {
		t.Fatalf("Failed to create first room: %v", err)
	}

	_, err = registry.CreateRoom(roomID, conn)
	if err != ErrRoomExists {
		t.Errorf("Expected ErrRoomExists, got %v", err)
	}
}

func TestRegistryGetRoom(t *testing.T) {
	registry := NewRegistry()
	conn := &websocket.Conn{}
	roomID := "test-room-123456789012345678901234567890123"

	_, err := registry.CreateRoom(roomID, conn)
	if err != nil {
		t.Fatalf("Failed to create room: %v", err)
	}

	room := registry.GetRoom(roomID)
	if room == nil {
		t.Error("Expected to find room, got nil")
	}

	room = registry.GetRoom("nonexistent")
	if room != nil {
		t.Error("Expected nil for nonexistent room")
	}
}

func TestRegistryDestroyRoom(t *testing.T) {
	registry := NewRegistry()
	conn := &websocket.Conn{}
	roomID := "test-room-123456789012345678901234567890123"

	_, err := registry.CreateRoom(roomID, conn)
	if err != nil {
		t.Fatalf("Failed to create room: %v", err)
	}

	registry.DestroyRoom(roomID, "test")

	if registry.RoomCount() != 0 {
		t.Errorf("Expected 0 rooms after destroy, got %d", registry.RoomCount())
	}

	room := registry.GetRoom(roomID)
	if room != nil {
		t.Error("Expected nil after room destroyed")
	}
}

func TestRoomOpenClose(t *testing.T) {
	room := &Room{
		ID:       "test",
		Clients:  make(map[string]*Client),
		IsOpen:   false,
	}

	if room.IsOpen {
		t.Error("Room should not be open initially")
	}

	room.OpenRoom()

	if !room.IsOpen {
		t.Error("Room should be open after OpenRoom()")
	}
}

func TestRoomAddClient(t *testing.T) {
	room := &Room{
		ID:       "test",
		Clients:  make(map[string]*Client),
		IsOpen:   false,
	}

	conn := &websocket.Conn{}

	// Should fail when room not open
	_, err := room.AddClient("client1", conn)
	if err != ErrRoomNotOpen {
		t.Errorf("Expected ErrRoomNotOpen, got %v", err)
	}

	room.OpenRoom()

	// Should succeed when room open
	client, err := room.AddClient("client1", conn)
	if err != nil {
		t.Fatalf("Failed to add client: %v", err)
	}

	if client.ID != "client1" {
		t.Errorf("Expected client ID client1, got %s", client.ID)
	}

	if room.ClientCount() != 1 {
		t.Errorf("Expected 1 client, got %d", room.ClientCount())
	}
}

func TestRoomClientLimit(t *testing.T) {
	room := &Room{
		ID:       "test",
		Clients:  make(map[string]*Client),
		IsOpen:   true,
	}

	conn := &websocket.Conn{}

	// Add max clients
	for i := 0; i < MaxClientsPerRoom; i++ {
		_, err := room.AddClient(string(rune('a'+i)), conn)
		if err != nil {
			t.Fatalf("Failed to add client %d: %v", i, err)
		}
	}

	// Try to add one more
	_, err := room.AddClient("overflow", conn)
	if err != ErrRoomFull {
		t.Errorf("Expected ErrRoomFull, got %v", err)
	}
}

func TestRoomRemoveClient(t *testing.T) {
	room := &Room{
		ID:       "test",
		Clients:  make(map[string]*Client),
		IsOpen:   true,
	}

	conn := &websocket.Conn{}
	room.AddClient("client1", conn)

	if room.ClientCount() != 1 {
		t.Fatalf("Expected 1 client, got %d", room.ClientCount())
	}

	room.RemoveClient("client1")

	if room.ClientCount() != 0 {
		t.Errorf("Expected 0 clients after remove, got %d", room.ClientCount())
	}
}

func TestRoomHeartbeat(t *testing.T) {
	room := &Room{
		ID:            "test",
		Clients:       make(map[string]*Client),
		LastHeartbeat: time.Now().Add(-time.Hour),
	}

	oldTime := room.GetLastHeartbeat()
	room.UpdateHeartbeat()
	newTime := room.GetLastHeartbeat()

	if !newTime.After(oldTime) {
		t.Error("Heartbeat time should be updated")
	}
}

func TestRegistryCapacity(t *testing.T) {
	// This test verifies the capacity check without actually creating 10000 rooms
	registry := NewRegistry()

	// Manually set capacity to test
	for i := 0; i < MaxRooms; i++ {
		registry.rooms[string(rune(i))] = &Room{}
	}

	conn := &websocket.Conn{}
	_, err := registry.CreateRoom("overflow", conn)
	if err != ErrServerAtCapacity {
		t.Errorf("Expected ErrServerAtCapacity, got %v", err)
	}
}
