// Package metrics provides simple in-memory metrics for the relay server
package metrics

import (
	"fmt"
	"sync/atomic"
)

// Metrics holds server metrics (counts only, no PII)
type Metrics struct {
	RoomsCreated     uint64
	RoomsDestroyed   uint64
	ConnectionsTotal uint64
	MessagesRelayed  uint64
	RateLimited      uint64
}

// Global metrics instance
var Global = &Metrics{}

// IncRoomsCreated increments the rooms created counter
func (m *Metrics) IncRoomsCreated() {
	atomic.AddUint64(&m.RoomsCreated, 1)
}

// IncRoomsDestroyed increments the rooms destroyed counter
func (m *Metrics) IncRoomsDestroyed() {
	atomic.AddUint64(&m.RoomsDestroyed, 1)
}

// IncConnections increments the connections counter
func (m *Metrics) IncConnections() {
	atomic.AddUint64(&m.ConnectionsTotal, 1)
}

// IncMessages increments the messages relayed counter
func (m *Metrics) IncMessages() {
	atomic.AddUint64(&m.MessagesRelayed, 1)
}

// IncRateLimited increments the rate limited counter
func (m *Metrics) IncRateLimited() {
	atomic.AddUint64(&m.RateLimited, 1)
}

// String returns a prometheus-style metrics string
func (m *Metrics) String(activeRooms int) string {
	return fmt.Sprintf(`# HELP ephemeral_rooms_created_total Total rooms created
# TYPE ephemeral_rooms_created_total counter
ephemeral_rooms_created_total %d
# HELP ephemeral_rooms_destroyed_total Total rooms destroyed
# TYPE ephemeral_rooms_destroyed_total counter
ephemeral_rooms_destroyed_total %d
# HELP ephemeral_rooms_active Current active rooms
# TYPE ephemeral_rooms_active gauge
ephemeral_rooms_active %d
# HELP ephemeral_connections_total Total connections
# TYPE ephemeral_connections_total counter
ephemeral_connections_total %d
# HELP ephemeral_messages_relayed_total Total messages relayed
# TYPE ephemeral_messages_relayed_total counter
ephemeral_messages_relayed_total %d
# HELP ephemeral_rate_limited_total Total rate limited requests
# TYPE ephemeral_rate_limited_total counter
ephemeral_rate_limited_total %d
`,
		atomic.LoadUint64(&m.RoomsCreated),
		atomic.LoadUint64(&m.RoomsDestroyed),
		activeRooms,
		atomic.LoadUint64(&m.ConnectionsTotal),
		atomic.LoadUint64(&m.MessagesRelayed),
		atomic.LoadUint64(&m.RateLimited),
	)
}
