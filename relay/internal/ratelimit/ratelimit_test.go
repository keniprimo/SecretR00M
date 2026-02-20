package ratelimit

import (
	"testing"
	"time"
)

func TestLimiterAllow(t *testing.T) {
	// 10 requests per second, burst of 20
	limiter := NewLimiter(10, 20)

	ip := "192.168.1.1"

	// First requests should be allowed
	for i := 0; i < 20; i++ {
		if !limiter.Allow(ip) {
			t.Errorf("Request %d should be allowed", i)
		}
	}

	// After burst, requests should be rate limited
	if limiter.Allow(ip) {
		t.Error("Request after burst should be rate limited")
	}
}

func TestLimiterDifferentIPs(t *testing.T) {
	limiter := NewLimiter(1, 1)

	// First request from IP1 should be allowed
	if !limiter.Allow("192.168.1.1") {
		t.Error("First request from IP1 should be allowed")
	}

	// First request from IP2 should also be allowed (different bucket)
	if !limiter.Allow("192.168.1.2") {
		t.Error("First request from IP2 should be allowed")
	}

	// Second request from IP1 should be limited
	if limiter.Allow("192.168.1.1") {
		t.Error("Second request from IP1 should be rate limited")
	}
}

func TestLimiterRefill(t *testing.T) {
	// 10 requests per second
	limiter := NewLimiter(10, 1)

	ip := "192.168.1.1"

	// Use up the burst
	limiter.Allow(ip)

	// Should be rate limited immediately
	if limiter.Allow(ip) {
		t.Error("Should be rate limited after burst")
	}

	// Wait for refill
	time.Sleep(150 * time.Millisecond)

	// Should be allowed again
	if !limiter.Allow(ip) {
		t.Error("Should be allowed after refill")
	}
}

func TestMessageLimiterAllow(t *testing.T) {
	limiter := NewMessageLimiter(10, 20)

	roomID := "room1"
	clientID := "client1"

	// First requests should be allowed
	for i := 0; i < 20; i++ {
		if !limiter.Allow(roomID, clientID) {
			t.Errorf("Message %d should be allowed", i)
		}
	}

	// After burst, should be rate limited
	if limiter.Allow(roomID, clientID) {
		t.Error("Message after burst should be rate limited")
	}
}

func TestMessageLimiterDifferentClients(t *testing.T) {
	limiter := NewMessageLimiter(1, 1)

	roomID := "room1"

	// Client1's first message allowed
	if !limiter.Allow(roomID, "client1") {
		t.Error("Client1's first message should be allowed")
	}

	// Client2's first message also allowed
	if !limiter.Allow(roomID, "client2") {
		t.Error("Client2's first message should be allowed")
	}

	// Client1's second message limited
	if limiter.Allow(roomID, "client1") {
		t.Error("Client1's second message should be limited")
	}
}

func TestMessageLimiterRemoveRoom(t *testing.T) {
	limiter := NewMessageLimiter(1, 1)

	roomID := "room1"
	clientID := "client1"

	limiter.Allow(roomID, clientID)

	// Should be limited
	if limiter.Allow(roomID, clientID) {
		t.Error("Should be limited before room removal")
	}

	// Remove room
	limiter.RemoveRoom(roomID)

	// After removal, should be allowed (new limiter created)
	if !limiter.Allow(roomID, clientID) {
		t.Error("Should be allowed after room removal")
	}
}
