// Ephemeral Relay Server
//
// A stateless WebSocket relay for ephemeral encrypted messaging rooms.
// All state is memory-only. Server restart clears all rooms.
//
// Security properties:
// - No message logging
// - No persistent storage
// - Truncated room IDs in logs
// - No payload inspection
package main

import (
	"crypto/tls"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/ephemeral/relay/internal/invite"
	"github.com/ephemeral/relay/internal/metrics"
	"github.com/ephemeral/relay/internal/ratelimit"
	"github.com/ephemeral/relay/internal/room"
	"github.com/ephemeral/relay/internal/websocket"
)

func main() {
	// Configuration flags
	addr := flag.String("addr", ":8443", "Server address")
	metricsAddr := flag.String("metrics-addr", ":9090", "Metrics server address (internal)")
	certFile := flag.String("cert", "", "TLS certificate file")
	keyFile := flag.String("key", "", "TLS key file")
	insecure := flag.Bool("insecure", false, "Run without TLS (development only)")
	flag.Parse()

	// Setup logging - UTC, no file paths
	log.SetFlags(log.Ldate | log.Ltime | log.LUTC)
	log.SetOutput(os.Stdout)

	// Initialize components
	registry := room.NewRegistry()
	connLimiter := ratelimit.NewLimiter(10, 20)       // 10 req/s, burst 20
	msgLimiter := ratelimit.NewMessageLimiter(10, 20) // 10 msg/s per client
	tokenStore := invite.NewTokenStore()

	inviteHandler := invite.NewHandler(tokenStore, registry, connLimiter)
	handler := websocket.NewHandler(registry, connLimiter, msgLimiter, inviteHandler)

	// Setup HTTP server
	mux := http.NewServeMux()
	mux.Handle("/rooms/", handler)
	mux.Handle("/invite/", inviteHandler)

	// Health check endpoint
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	})

	server := &http.Server{
		Addr:    *addr,
		Handler: mux,
	}

	// TLS configuration (if not insecure)
	if !*insecure {
		if *certFile == "" || *keyFile == "" {
			log.Fatal("TLS cert and key files required (use -insecure for development)")
		}

		server.TLSConfig = &tls.Config{
			MinVersion: tls.VersionTLS13,
			CipherSuites: []uint16{
				tls.TLS_AES_256_GCM_SHA384,
				tls.TLS_CHACHA20_POLY1305_SHA256,
			},
		}
	}

	// Start metrics server (internal only)
	go func() {
		metricsMux := http.NewServeMux()
		metricsMux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/plain")
			w.Write([]byte(metrics.Global.String(registry.RoomCount())))
		})

		metricsServer := &http.Server{
			Addr:    *metricsAddr,
			Handler: metricsMux,
		}

		log.Printf("Metrics server starting on %s", *metricsAddr)
		if err := metricsServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("Metrics server error: %v", err)
		}
	}()

	// Graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigCh
		log.Println("Shutting down...")
		// Stop background cleanup goroutines
		tokenStore.Stop()
		// All rooms will be destroyed when server stops
		os.Exit(0)
	}()

	// Start server
	log.Printf("Ephemeral Relay Server starting on %s", *addr)
	log.Printf("Security: TLS=%v, Insecure=%v", !*insecure, *insecure)

	var err error
	if *insecure {
		log.Println("WARNING: Running in insecure mode (no TLS)")
		err = server.ListenAndServe()
	} else {
		err = server.ListenAndServeTLS(*certFile, *keyFile)
	}

	if err != nil && err != http.ErrServerClosed {
		log.Fatalf("Server error: %v", err)
	}
}

func init() {
	// Print banner
	fmt.Print(`
╔═══════════════════════════════════════════════════════╗
║         Ephemeral Relay Server                        ║
║         Memory-only • No persistence • No logs        ║
╚═══════════════════════════════════════════════════════╝
`)
}
