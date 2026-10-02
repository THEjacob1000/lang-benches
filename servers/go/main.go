package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"syscall"
	"time"

	"github.com/mattn/go-sqlite3"
)

const maxID = 1<<53 - 1

type metadata struct {
	Runtime   string `json:"runtime"`
	Framework string `json:"framework"`
	SQLite    string `json:"sqlite"`
}

type server struct {
	reader, writer                       *sql.DB
	feed, post, comments, update, insert *sql.Stmt
	secret                               []byte
	meta                                 metadata
}

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	secret := os.Getenv("JWT_SECRET")
	if secret == "" {
		return errors.New("JWT_SECRET is required")
	}
	path := os.Getenv("DB_PATH")
	if path == "" {
		return errors.New("DB_PATH is required")
	}
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("DB_PATH: %w", err)
	}
	if !info.Mode().IsRegular() {
		return errors.New("DB_PATH must be a regular file")
	}
	path, err = filepath.Abs(path)
	if err != nil {
		return err
	}
	sql.Register("benchmark-sqlite", &sqlite3.SQLiteDriver{ConnectHook: func(conn *sqlite3.SQLiteConn) error {
		_, err := conn.Exec("PRAGMA temp_store = MEMORY", nil)
		return err
	}})
	writer, err := openDB(path, false)
	if err != nil {
		return err
	}
	defer writer.Close()
	reader, err := openDB(path, true)
	if err != nil {
		return err
	}
	defer reader.Close()
	s := &server{reader: reader, writer: writer, secret: []byte(secret), meta: metadata{Runtime: runtime.Version(), Framework: "net/http"}}
	if err := reader.QueryRow("SELECT sqlite_version()").Scan(&s.meta.SQLite); err != nil {
		return err
	}
	for _, statement := range []struct {
		db     *sql.DB
		target **sql.Stmt
		query  string
	}{
		{reader, &s.feed, "SELECT p.id, p.title, p.body, p.comment_count, p.created_at, u.id, u.name FROM feed_items f JOIN posts p ON p.id = f.post_id JOIN users u ON u.id = p.user_id WHERE f.user_id = ? AND (f.created_at, f.post_id) < (?, ?) ORDER BY f.created_at DESC, f.post_id DESC LIMIT ?"},
		{reader, &s.post, "SELECT p.id, p.title, p.body, p.comment_count, p.created_at, u.id, u.name FROM posts p JOIN users u ON u.id = p.user_id WHERE p.id = ?"},
		{reader, &s.comments, "SELECT c.id, c.body, c.created_at, u.id, u.name FROM comments c JOIN users u ON u.id = c.user_id WHERE c.post_id = ? ORDER BY c.id DESC LIMIT 20"},
		{writer, &s.update, "UPDATE posts SET comment_count = comment_count + 1 WHERE id = ?"},
		{writer, &s.insert, "INSERT INTO comments (post_id, user_id, body, created_at) VALUES (?, ?, ?, ?) RETURNING id"},
	} {
		*statement.target, err = statement.db.Prepare(statement.query)
		if err != nil {
			return err
		}
		defer (*statement.target).Close()
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Content-Length", "2")
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("GET /meta", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, http.StatusOK, s.meta) })
	mux.HandleFunc("GET /feed", s.auth(s.getFeed))
	mux.HandleFunc("GET /posts/{id}", s.auth(s.getPost))
	mux.HandleFunc("POST /posts/{id}/comments", s.auth(s.createComment))
	port := os.Getenv("PORT")
	if port == "" {
		port = "3000"
	}
	httpServer := &http.Server{Addr: "127.0.0.1:" + port, Handler: mux, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 120 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	result := make(chan error, 1)
	go func() { result <- httpServer.ListenAndServe() }()
	select {
	case err := <-result:
		return err
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			httpServer.Close()
			return err
		}
		if err := <-result; !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	}
}

func openDB(path string, readOnly bool) (*sql.DB, error) {
	params := url.Values{"_journal_mode": {"WAL"}, "_synchronous": {"NORMAL"}, "_busy_timeout": {"5000"}, "_foreign_keys": {"on"}, "_cache_size": {"-16000"}}
	connections := 1
	if readOnly {
		params.Set("mode", "ro")
		connections = runtime.GOMAXPROCS(0)
	} else {
		params.Set("mode", "rw")
		params.Set("_txlock", "immediate")
	}
	uri := url.URL{Scheme: "file", Path: path, RawQuery: params.Encode()}
	db, err := sql.Open("benchmark-sqlite", uri.String())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(connections)
	db.SetMaxIdleConns(connections)
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

func positiveInteger(value string, max int64) (int64, bool) {
	if value == "" {
		return 0, false
	}
	for i := range len(value) {
		if value[i] < '0' || value[i] > '9' {
			return 0, false
		}
	}
	n, err := strconv.ParseInt(value, 10, 64)
	return n, err == nil && n > 0 && n <= max
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, struct {
		Error string `json:"error"`
	}{message})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	err := encoder.Encode(value)
	data := bytes.TrimSuffix(buffer.Bytes(), []byte("\n"))
	if err != nil {
		status = http.StatusInternalServerError
		data = []byte(`{"error":"internal"}`)
	}
	w.Header().Set("Content-Type", "application/json")
	// Without Content-Length net/http chunks responses larger than 2 KiB.
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(status)
	w.Write(data)
}
