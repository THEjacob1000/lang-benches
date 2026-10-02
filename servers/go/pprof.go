//go:build pprof

package main

import (
	"log"
	"net/http"
	_ "net/http/pprof"
	"os"
	"time"
)

func init() {
	addr := os.Getenv("PPROF_ADDR")
	if addr == "" {
		addr = "127.0.0.1:6060"
	}
	go func() {
		server := &http.Server{Addr: addr, Handler: http.DefaultServeMux, ReadHeaderTimeout: 5 * time.Second}
		if err := server.ListenAndServe(); err != nil {
			log.Printf("pprof: %v", err)
		}
	}()
}
