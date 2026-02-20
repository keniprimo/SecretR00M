// Package security_test provides stress testing for scalability verification
package security_test

import (
	"fmt"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/ephemeral/relay/internal/ratelimit"
	"github.com/ephemeral/relay/internal/room"
	"github.com/gorilla/websocket"
)

// ============================================================================
// STRESS-001: High Load Room Creation/Destruction
// ============================================================================

func TestStressRoomCreationDestruction(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping stress test in short mode")
	}

	registry := room.NewRegistry()
	var wg sync.WaitGroup
	var successCount int64
	var errorCount int64

	iterations := 5000
	concurrency := 50

	start := time.Now()

	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			for j := 0; j < iterations/concurrency; j++ {
				roomID := fmt.Sprintf("stress-room-%d-%d-1234567890123", workerID, j)
				_, err := registry.CreateRoom(roomID, &websocket.Conn{})
				if err == nil {
					atomic.AddInt64(&successCount, 1)
					registry.DestroyRoom(roomID, "stress_test")
				} else {
					atomic.AddInt64(&errorCount, 1)
				}
			}
		}(i)
	}

	wg.Wait()
	elapsed := time.Since(start)

	opsPerSecond := float64(successCount) / elapsed.Seconds()
	t.Logf("Stress test completed: %d successes, %d errors in %v", successCount, errorCount, elapsed)
	t.Logf("Operations per second: %.0f", opsPerSecond)

	// Should handle at least 1000 ops/second
	if opsPerSecond < 1000 {
		t.Errorf("Performance too low: %.0f ops/sec (expected >= 1000)", opsPerSecond)
	}

	// Registry should be empty after test
	if registry.RoomCount() != 0 {
		t.Errorf("Expected 0 rooms after stress test, got %d", registry.RoomCount())
	}
}

// ============================================================================
// STRESS-002: High Concurrent Client Joins
// ============================================================================

func TestStressConcurrentClientJoins(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping stress test in short mode")
	}

	registry := room.NewRegistry()
	numRooms := 100
	clientsPerRoom := 30
	var wg sync.WaitGroup

	// Create rooms
	rooms := make([]*room.Room, numRooms)
	for i := 0; i < numRooms; i++ {
		roomID := fmt.Sprintf("concurrent-room-%d-1234567890123", i)
		r, _ := registry.CreateRoom(roomID, &websocket.Conn{})
		r.OpenRoom()
		rooms[i] = r
	}

	start := time.Now()
	var totalJoins int64

	// Concurrently add clients to all rooms
	for _, r := range rooms {
		for j := 0; j < clientsPerRoom; j++ {
			wg.Add(1)
			go func(rm *room.Room, clientNum int) {
				defer wg.Done()
				clientID := fmt.Sprintf("client-%d", clientNum)
				_, err := rm.AddClient(clientID, &websocket.Conn{})
				if err == nil {
					atomic.AddInt64(&totalJoins, 1)
				}
			}(r, j)
		}
	}

	wg.Wait()
	elapsed := time.Since(start)

	t.Logf("Concurrent join stress test: %d joins in %v", totalJoins, elapsed)
	t.Logf("Joins per second: %.0f", float64(totalJoins)/elapsed.Seconds())

	// Verify total clients
	totalClients := 0
	for _, r := range rooms {
		totalClients += r.ClientCount()
	}

	expectedClients := numRooms * clientsPerRoom
	if totalClients < expectedClients {
		t.Logf("Note: %d/%d clients joined (some may have been rate limited)", totalClients, expectedClients)
	}
}

// ============================================================================
// STRESS-003: Rate Limiter Under Load
// ============================================================================

func TestStressRateLimiterPerformance(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping stress test in short mode")
	}

	limiter := ratelimit.NewLimiter(10000, 20000) // High limits for stress test
	var wg sync.WaitGroup
	var allowedCount int64
	var deniedCount int64

	numGoroutines := 100
	requestsPerGoroutine := 1000

	start := time.Now()

	for i := 0; i < numGoroutines; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			ip := fmt.Sprintf("192.168.%d.%d", workerID/256, workerID%256)
			for j := 0; j < requestsPerGoroutine; j++ {
				if limiter.Allow(ip) {
					atomic.AddInt64(&allowedCount, 1)
				} else {
					atomic.AddInt64(&deniedCount, 1)
				}
			}
		}(i)
	}

	wg.Wait()
	elapsed := time.Since(start)

	totalRequests := numGoroutines * requestsPerGoroutine
	requestsPerSecond := float64(totalRequests) / elapsed.Seconds()

	t.Logf("Rate limiter stress test: %d total requests in %v", totalRequests, elapsed)
	t.Logf("Requests per second: %.0f", requestsPerSecond)
	t.Logf("Allowed: %d, Denied: %d", allowedCount, deniedCount)

	// Should handle at least 100,000 checks/second
	if requestsPerSecond < 100000 {
		t.Errorf("Rate limiter performance too low: %.0f req/sec", requestsPerSecond)
	}
}

// ============================================================================
// STRESS-004: Memory Stability Under Sustained Load
// ============================================================================

func TestStressMemoryStability(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping stress test in short mode")
	}

	var m runtime.MemStats

	// Baseline memory
	runtime.GC()
	runtime.ReadMemStats(&m)
	baselineAlloc := m.HeapAlloc

	registry := room.NewRegistry()

	// Sustained load for multiple iterations
	for iteration := 0; iteration < 10; iteration++ {
		// Create 100 rooms with 10 clients each
		for i := 0; i < 100; i++ {
			roomID := fmt.Sprintf("memstress-%d-%d-12345678901234", iteration, i)
			r, err := registry.CreateRoom(roomID, &websocket.Conn{})
			if err != nil {
				continue
			}
			r.OpenRoom()
			for j := 0; j < 10; j++ {
				r.AddClient(fmt.Sprintf("client-%d", j), &websocket.Conn{})
			}
		}

		// Destroy all rooms
		for i := 0; i < 100; i++ {
			roomID := fmt.Sprintf("memstress-%d-%d-12345678901234", iteration, i)
			registry.DestroyRoom(roomID, "stress_test")
		}

		// Force GC
		runtime.GC()
	}

	// Final memory check
	runtime.GC()
	runtime.ReadMemStats(&m)
	finalAlloc := m.HeapAlloc

	// Memory should not have grown significantly (allow 50MB buffer)
	memoryGrowth := int64(finalAlloc) - int64(baselineAlloc)
	t.Logf("Memory baseline: %d MB, final: %d MB, growth: %d MB",
		baselineAlloc/1024/1024, finalAlloc/1024/1024, memoryGrowth/1024/1024)

	if memoryGrowth > 50*1024*1024 {
		t.Errorf("Memory grew by %d MB, possible leak", memoryGrowth/1024/1024)
	}

	// Registry should be empty
	if registry.RoomCount() != 0 {
		t.Errorf("Expected empty registry, got %d rooms", registry.RoomCount())
	}
}

// ============================================================================
// STRESS-005: Maximum Capacity Test
// ============================================================================

func TestStressMaxCapacity(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping stress test in short mode")
	}

	registry := room.NewRegistry()
	var successCount int64
	var capacityErrors int64
	var otherErrors int64

	// Try to create more than max rooms
	targetRooms := room.MaxRooms + 100

	var wg sync.WaitGroup
	for i := 0; i < targetRooms; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			roomID := fmt.Sprintf("maxcap-room-%05d-12345678901234567", n)
			_, err := registry.CreateRoom(roomID, &websocket.Conn{})
			if err == nil {
				atomic.AddInt64(&successCount, 1)
			} else if err == room.ErrServerAtCapacity {
				atomic.AddInt64(&capacityErrors, 1)
			} else {
				atomic.AddInt64(&otherErrors, 1)
			}
		}(i)
	}

	wg.Wait()

	t.Logf("Max capacity test: %d successes, %d capacity errors, %d other errors",
		successCount, capacityErrors, otherErrors)

	// Should have exactly MaxRooms successful creations
	if successCount != int64(room.MaxRooms) {
		t.Errorf("Expected %d successful room creations, got %d", room.MaxRooms, successCount)
	}

	// Should have 100 capacity errors
	if capacityErrors < 100 {
		t.Errorf("Expected at least 100 capacity errors, got %d", capacityErrors)
	}

	// Should have no other errors
	if otherErrors > 0 {
		t.Errorf("Unexpected errors: %d", otherErrors)
	}
}

// ============================================================================
// BENCHMARK: Room Operations
// ============================================================================

func BenchmarkRoomCreate(b *testing.B) {
	registry := room.NewRegistry()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		roomID := fmt.Sprintf("bench-room-%d-12345678901234567890", i)
		registry.CreateRoom(roomID, &websocket.Conn{})
	}
}

func BenchmarkRoomDestroy(b *testing.B) {
	registry := room.NewRegistry()

	// Pre-create rooms
	for i := 0; i < b.N; i++ {
		roomID := fmt.Sprintf("bench-destroy-%d-123456789012345", i)
		registry.CreateRoom(roomID, &websocket.Conn{})
	}

	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		roomID := fmt.Sprintf("bench-destroy-%d-123456789012345", i)
		registry.DestroyRoom(roomID, "benchmark")
	}
}

func BenchmarkClientAdd(b *testing.B) {
	registry := room.NewRegistry()
	r, _ := registry.CreateRoom("bench-client-room-1234567890123456", &websocket.Conn{})
	r.OpenRoom()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		clientID := fmt.Sprintf("bench-client-%d", i)
		r.AddClient(clientID, &websocket.Conn{})
		// Note: will hit room full error, but we're measuring the operation
	}
}

func BenchmarkRateLimiterAllow(b *testing.B) {
	limiter := ratelimit.NewLimiter(1000000, 2000000)
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		limiter.Allow("192.168.1.1")
	}
}

// ============================================================================
// STRESS-006: Message Throughput Under Load
// ============================================================================

func TestStressMessageThroughput(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping stress test in short mode")
	}

	registry := room.NewRegistry()
	limiter := ratelimit.NewMessageLimiter(100000, 200000) // High limits for throughput test

	// Create a room with multiple clients
	r, _ := registry.CreateRoom("throughput-room-123456789012345678", &websocket.Conn{})
	r.OpenRoom()

	numClients := 20
	clients := make([]*room.Client, numClients)
	for i := 0; i < numClients; i++ {
		client, _ := r.AddClient(fmt.Sprintf("client-%d", i), &websocket.Conn{})
		clients[i] = client
	}

	var wg sync.WaitGroup
	var messagesSent int64
	var messagesRateLimited int64

	messagesPerClient := 1000
	start := time.Now()

	// Each client sends messages concurrently
	for i, client := range clients {
		if client == nil {
			continue
		}
		wg.Add(1)
		go func(clientIdx int, c *room.Client) {
			defer wg.Done()
			for j := 0; j < messagesPerClient; j++ {
				if limiter.Allow("throughput-room-123456789012345678", c.ID) {
					atomic.AddInt64(&messagesSent, 1)
				} else {
					atomic.AddInt64(&messagesRateLimited, 1)
				}
			}
		}(i, client)
	}

	wg.Wait()
	elapsed := time.Since(start)

	throughput := float64(messagesSent) / elapsed.Seconds()
	t.Logf("Message throughput test: %d messages in %v", messagesSent, elapsed)
	t.Logf("Throughput: %.0f msg/sec", throughput)
	t.Logf("Rate limited: %d", messagesRateLimited)

	// Should handle at least 10,000 messages/second
	if throughput < 10000 {
		t.Errorf("Message throughput too low: %.0f msg/sec", throughput)
	}
}

// ============================================================================
// STRESS-007: Memory Growth Over Time (Extended)
// ============================================================================

func TestStressMemoryGrowthOverTime(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping stress test in short mode")
	}

	var m runtime.MemStats
	registry := room.NewRegistry()

	// Record memory at intervals
	type memSample struct {
		iteration int
		heapAlloc uint64
		heapInuse uint64
		numGC     uint32
		roomCount int
	}

	samples := make([]memSample, 0, 20)

	// Run 20 iterations of create/destroy cycles
	for iteration := 0; iteration < 20; iteration++ {
		// Create 500 rooms with 5 clients each
		for i := 0; i < 500; i++ {
			roomID := fmt.Sprintf("memgrow-%d-%d-1234567890123456", iteration, i)
			r, err := registry.CreateRoom(roomID, &websocket.Conn{})
			if err != nil {
				continue
			}
			r.OpenRoom()
			for j := 0; j < 5; j++ {
				r.AddClient(fmt.Sprintf("client-%d", j), &websocket.Conn{})
			}
		}

		// Sample memory at peak
		runtime.ReadMemStats(&m)
		peakSample := memSample{
			iteration: iteration,
			heapAlloc: m.HeapAlloc,
			heapInuse: m.HeapInuse,
			numGC:     m.NumGC,
			roomCount: registry.RoomCount(),
		}

		// Destroy all rooms
		for i := 0; i < 500; i++ {
			roomID := fmt.Sprintf("memgrow-%d-%d-1234567890123456", iteration, i)
			registry.DestroyRoom(roomID, "memgrow_test")
		}

		// Force GC and sample
		runtime.GC()
		runtime.ReadMemStats(&m)

		samples = append(samples, memSample{
			iteration: iteration,
			heapAlloc: m.HeapAlloc,
			heapInuse: m.HeapInuse,
			numGC:     m.NumGC,
			roomCount: registry.RoomCount(),
		})

		t.Logf("Iteration %d - Peak rooms: %d, Post-GC heap: %d KB",
			iteration, peakSample.roomCount, m.HeapAlloc/1024)
	}

	// Analyze growth trend
	firstSample := samples[0]
	lastSample := samples[len(samples)-1]

	// Memory should not have grown more than 10MB over all iterations
	growth := int64(lastSample.heapAlloc) - int64(firstSample.heapAlloc)
	t.Logf("Total memory growth: %d KB over %d iterations", growth/1024, len(samples))

	if growth > 10*1024*1024 {
		t.Errorf("Memory grew by %d MB over time, possible leak", growth/1024/1024)
	}

	// Registry should be empty
	if registry.RoomCount() != 0 {
		t.Errorf("Expected empty registry, got %d rooms", registry.RoomCount())
	}
}

// ============================================================================
// STRESS-008: Spike Behavior (Sudden Load Increase)
// ============================================================================

func TestStressSpikeBehavior(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping stress test in short mode")
	}

	registry := room.NewRegistry()
	connLimiter := ratelimit.NewLimiter(1000, 2000) // Reasonable limits

	var wg sync.WaitGroup
	var successfulCreations int64
	var rateLimited int64
	var capacityErrors int64

	// Phase 1: Baseline load (100 rooms)
	t.Log("Phase 1: Baseline load")
	for i := 0; i < 100; i++ {
		roomID := fmt.Sprintf("baseline-room-%d-12345678901234", i)
		registry.CreateRoom(roomID, &websocket.Conn{})
	}
	baselineCount := registry.RoomCount()
	t.Logf("Baseline: %d rooms", baselineCount)

	// Phase 2: Sudden spike (1000 concurrent room creation attempts)
	t.Log("Phase 2: Spike - 1000 concurrent creations")
	spikeStart := time.Now()

	for i := 0; i < 1000; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			ip := fmt.Sprintf("spike-%d.0.0.1", n%256)

			if !connLimiter.Allow(ip) {
				atomic.AddInt64(&rateLimited, 1)
				return
			}

			roomID := fmt.Sprintf("spike-room-%d-12345678901234567", n)
			_, err := registry.CreateRoom(roomID, &websocket.Conn{})
			if err == nil {
				atomic.AddInt64(&successfulCreations, 1)
			} else if err == room.ErrServerAtCapacity {
				atomic.AddInt64(&capacityErrors, 1)
			}
		}(i)
	}

	wg.Wait()
	spikeElapsed := time.Since(spikeStart)

	t.Logf("Spike completed in %v", spikeElapsed)
	t.Logf("Successful: %d, Rate limited: %d, Capacity errors: %d",
		successfulCreations, rateLimited, capacityErrors)

	// Verify system remained stable
	finalCount := registry.RoomCount()
	t.Logf("Final room count: %d", finalCount)

	// System should have handled the spike gracefully
	totalHandled := successfulCreations + rateLimited + capacityErrors
	if totalHandled != 1000 {
		t.Errorf("Not all spike requests accounted for: %d/1000", totalHandled)
	}
}

// ============================================================================
// STRESS-009: Goroutine/Channel Exhaustion (FD Simulation)
// ============================================================================

func TestStressGoroutineExhaustion(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping stress test in short mode")
	}

	registry := room.NewRegistry()

	// Track goroutine count
	initialGoroutines := runtime.NumGoroutine()
	t.Logf("Initial goroutines: %d", initialGoroutines)

	// Create many rooms (each room has channels that simulate FD-like resources)
	numRooms := 1000
	for i := 0; i < numRooms; i++ {
		roomID := fmt.Sprintf("fdtest-room-%d-123456789012345678", i)
		r, err := registry.CreateRoom(roomID, &websocket.Conn{})
		if err != nil {
			t.Logf("Room creation failed at %d: %v", i, err)
			break
		}
		r.OpenRoom()
		// Add clients (each has a send channel)
		for j := 0; j < 10; j++ {
			r.AddClient(fmt.Sprintf("client-%d", j), &websocket.Conn{})
		}
	}

	peakGoroutines := runtime.NumGoroutine()
	peakRooms := registry.RoomCount()
	t.Logf("Peak goroutines: %d, Peak rooms: %d", peakGoroutines, peakRooms)

	// Destroy all rooms
	for i := 0; i < numRooms; i++ {
		roomID := fmt.Sprintf("fdtest-room-%d-123456789012345678", i)
		registry.DestroyRoom(roomID, "fd_test")
	}

	// Give goroutines time to exit
	time.Sleep(100 * time.Millisecond)
	runtime.GC()

	finalGoroutines := runtime.NumGoroutine()
	t.Logf("Final goroutines: %d", finalGoroutines)

	// Goroutine count should return close to initial
	goroutineLeakage := finalGoroutines - initialGoroutines
	if goroutineLeakage > 50 { // Allow small buffer for test framework
		t.Errorf("Goroutine leak detected: %d goroutines not cleaned up", goroutineLeakage)
	}

	// Registry should be empty
	if registry.RoomCount() != 0 {
		t.Errorf("Expected empty registry, got %d rooms", registry.RoomCount())
	}
}

// ============================================================================
// STRESS-010: Security Under Load (No Data Accumulation)
// ============================================================================

func TestStressSecurityUnderLoad(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping stress test in short mode")
	}

	registry := room.NewRegistry()
	var wg sync.WaitGroup

	// Simulate realistic workload with security checks
	iterations := 100
	roomsPerIteration := 50
	clientsPerRoom := 10

	var totalRoomsCreated int64
	var totalRoomsDestroyed int64
	var totalClientsJoined int64

	for iter := 0; iter < iterations; iter++ {
		// Create rooms
		roomIDs := make([]string, roomsPerIteration)
		for i := 0; i < roomsPerIteration; i++ {
			roomID := fmt.Sprintf("secload-%d-%d-1234567890123456", iter, i)
			roomIDs[i] = roomID

			r, err := registry.CreateRoom(roomID, &websocket.Conn{})
			if err != nil {
				continue
			}
			atomic.AddInt64(&totalRoomsCreated, 1)
			r.OpenRoom()

			// Add clients concurrently
			for j := 0; j < clientsPerRoom; j++ {
				wg.Add(1)
				go func(rm *room.Room, clientNum int) {
					defer wg.Done()
					_, err := rm.AddClient(fmt.Sprintf("client-%d", clientNum), &websocket.Conn{})
					if err == nil {
						atomic.AddInt64(&totalClientsJoined, 1)
					}
				}(r, j)
			}
		}

		wg.Wait()

		// Security check: verify no data accumulation mid-test
		currentRooms := registry.RoomCount()
		if currentRooms > room.MaxRooms {
			t.Errorf("Room count exceeded max: %d > %d", currentRooms, room.MaxRooms)
		}

		// Destroy rooms
		for _, roomID := range roomIDs {
			registry.DestroyRoom(roomID, "secload_test")
			atomic.AddInt64(&totalRoomsDestroyed, 1)
		}

		// Verify cleanup after each iteration
		if registry.RoomCount() != 0 {
			t.Errorf("Iteration %d: Expected 0 rooms after cleanup, got %d", iter, registry.RoomCount())
		}
	}

	t.Logf("Security under load: created %d rooms, destroyed %d, %d clients joined",
		totalRoomsCreated, totalRoomsDestroyed, totalClientsJoined)

	// Final security verification: no data accumulation
	if registry.RoomCount() != 0 {
		t.Errorf("Data accumulation detected: %d rooms remaining", registry.RoomCount())
	}

	// Verify created equals destroyed
	if totalRoomsCreated != totalRoomsDestroyed {
		t.Errorf("Room count mismatch: created %d, destroyed %d", totalRoomsCreated, totalRoomsDestroyed)
	}
}

// ============================================================================
// STRESS-011: Predictable Failure Modes
// ============================================================================

func TestStressPredictableFailures(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping stress test in short mode")
	}

	registry := room.NewRegistry()

	// Test 1: Capacity exhaustion returns correct error
	t.Log("Test 1: Capacity exhaustion")
	for i := 0; i < room.MaxRooms; i++ {
		roomID := fmt.Sprintf("failure-room-%d-12345678901234567", i)
		registry.CreateRoom(roomID, &websocket.Conn{})
	}

	_, err := registry.CreateRoom("overflow-room-123456789012345678901", &websocket.Conn{})
	if err != room.ErrServerAtCapacity {
		t.Errorf("Expected ErrServerAtCapacity, got %v", err)
	}

	// Clean up
	for i := 0; i < room.MaxRooms; i++ {
		roomID := fmt.Sprintf("failure-room-%d-12345678901234567", i)
		registry.DestroyRoom(roomID, "failure_test")
	}

	// Test 2: Duplicate room returns correct error
	t.Log("Test 2: Duplicate room creation")
	registry.CreateRoom("duplicate-test-room-123456789012345", &websocket.Conn{})
	_, err = registry.CreateRoom("duplicate-test-room-123456789012345", &websocket.Conn{})
	if err != room.ErrRoomExists {
		t.Errorf("Expected ErrRoomExists, got %v", err)
	}
	registry.DestroyRoom("duplicate-test-room-123456789012345", "test")

	// Test 3: Room full returns correct error
	t.Log("Test 3: Room full")
	r, _ := registry.CreateRoom("full-room-test-1234567890123456789", &websocket.Conn{})
	r.OpenRoom()

	for i := 0; i < room.MaxClientsPerRoom; i++ {
		r.AddClient(fmt.Sprintf("client-%d", i), &websocket.Conn{})
	}

	_, err = r.AddClient("overflow-client", &websocket.Conn{})
	if err != room.ErrRoomFull {
		t.Errorf("Expected ErrRoomFull, got %v", err)
	}
	registry.DestroyRoom("full-room-test-1234567890123456789", "test")

	// Test 4: Join closed room returns correct error
	t.Log("Test 4: Join closed room")
	r2, _ := registry.CreateRoom("closed-room-test-123456789012345", &websocket.Conn{})
	// Room is not opened
	_, err = r2.AddClient("client", &websocket.Conn{})
	if err != room.ErrRoomNotOpen {
		t.Errorf("Expected ErrRoomNotOpen, got %v", err)
	}
	registry.DestroyRoom("closed-room-test-123456789012345", "test")

	t.Log("All failure modes behave predictably")
}

// ============================================================================
// STRESS-012: No Degraded Security Under Load
// ============================================================================

func TestStressNoSecurityDegradation(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping stress test in short mode")
	}

	// Rate limiters protect the system under load
	connLimiter := ratelimit.NewLimiter(100, 200)
	msgLimiter := ratelimit.NewMessageLimiter(50, 100)

	var wg sync.WaitGroup
	var rateLimitedConns int64
	var rateLimitedMsgs int64

	// Simulate heavy load
	numAttackers := 100
	requestsPerAttacker := 500

	start := time.Now()

	for i := 0; i < numAttackers; i++ {
		wg.Add(1)
		go func(attackerID int) {
			defer wg.Done()
			ip := fmt.Sprintf("attacker-%d", attackerID)

			for j := 0; j < requestsPerAttacker; j++ {
				// Try to connect
				if !connLimiter.Allow(ip) {
					atomic.AddInt64(&rateLimitedConns, 1)
					continue
				}

				// Try to send message
				if !msgLimiter.Allow("target-room", ip) {
					atomic.AddInt64(&rateLimitedMsgs, 1)
				}
			}
		}(i)
	}

	wg.Wait()
	elapsed := time.Since(start)

	totalRequests := int64(numAttackers * requestsPerAttacker)
	rateLimitedTotal := rateLimitedConns + rateLimitedMsgs

	t.Logf("Load test completed in %v", elapsed)
	t.Logf("Total requests: %d", totalRequests)
	t.Logf("Rate limited connections: %d", rateLimitedConns)
	t.Logf("Rate limited messages: %d", rateLimitedMsgs)
	t.Logf("Rate limit effectiveness: %.1f%%", float64(rateLimitedTotal)/float64(totalRequests)*100)

	// Security should NOT degrade - rate limiting must remain effective
	if rateLimitedTotal == 0 {
		t.Error("Rate limiting ineffective under load - security degraded")
	}

	// At least 50% of excessive requests should be rate limited
	if float64(rateLimitedTotal)/float64(totalRequests) < 0.5 {
		t.Errorf("Rate limiting too permissive under load: only %.1f%% blocked",
			float64(rateLimitedTotal)/float64(totalRequests)*100)
	}
}
