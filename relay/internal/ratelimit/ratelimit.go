// Package ratelimit provides rate limiting for connections and messages
package ratelimit

import (
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// Limiter provides rate limiting per IP address
type Limiter struct {
	visitors map[string]*visitor
	mu       sync.RWMutex
	r        rate.Limit
	burst    int
}

type visitor struct {
	limiter  *rate.Limiter
	lastSeen time.Time
}

// NewLimiter creates a new rate limiter
func NewLimiter(r rate.Limit, burst int) *Limiter {
	l := &Limiter{
		visitors: make(map[string]*visitor),
		r:        r,
		burst:    burst,
	}
	go l.cleanup()
	return l
}

// Allow checks if a request from the given IP should be allowed
func (l *Limiter) Allow(ip string) bool {
	l.mu.Lock()
	v, exists := l.visitors[ip]
	if !exists {
		v = &visitor{
			limiter: rate.NewLimiter(l.r, l.burst),
		}
		l.visitors[ip] = v
	}
	v.lastSeen = time.Now()
	l.mu.Unlock()

	return v.limiter.Allow()
}

// cleanup removes stale visitors periodically
func (l *Limiter) cleanup() {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()

	for range ticker.C {
		l.mu.Lock()
		for ip, v := range l.visitors {
			if time.Since(v.lastSeen) > 3*time.Minute {
				delete(l.visitors, ip)
			}
		}
		l.mu.Unlock()
	}
}

// MessageLimiter provides per-client message rate limiting
type MessageLimiter struct {
	limiters map[string]*rate.Limiter
	mu       sync.RWMutex
	r        rate.Limit
	burst    int
}

// NewMessageLimiter creates a new message rate limiter
func NewMessageLimiter(r rate.Limit, burst int) *MessageLimiter {
	return &MessageLimiter{
		limiters: make(map[string]*rate.Limiter),
		r:        r,
		burst:    burst,
	}
}

// Allow checks if a message from the given room/client should be allowed
func (l *MessageLimiter) Allow(roomID, clientID string) bool {
	key := roomID + ":" + clientID

	l.mu.Lock()
	limiter, exists := l.limiters[key]
	if !exists {
		limiter = rate.NewLimiter(l.r, l.burst)
		l.limiters[key] = limiter
	}
	l.mu.Unlock()

	return limiter.Allow()
}

// RemoveRoom removes all limiters for a room
func (l *MessageLimiter) RemoveRoom(roomID string) {
	l.mu.Lock()
	defer l.mu.Unlock()

	// Remove all entries for this room
	prefix := roomID + ":"
	for key := range l.limiters {
		if len(key) >= len(prefix) && key[:len(prefix)] == prefix {
			delete(l.limiters, key)
		}
	}
}
