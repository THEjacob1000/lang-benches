package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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
	"unicode/utf16"

	"github.com/mattn/go-sqlite3"
)

const maxID = 1<<53 - 1

type user struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	Email     string `json:"email"`
	CreatedAt int64  `json:"createdAt"`
}

type post struct {
	ID        int64  `json:"id"`
	UserID    int64  `json:"userId"`
	Title     string `json:"title"`
	Body      string `json:"body"`
	CreatedAt int64  `json:"createdAt"`
}

type metadata struct {
	Runtime   string `json:"runtime"`
	Framework string `json:"framework"`
	SQLite    string `json:"sqlite"`
}

type server struct {
	user   *sql.Stmt
	posts  *sql.Stmt
	insert *sql.Stmt
	meta   metadata
}

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
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
	sql.Register("benchmark-sqlite", &sqlite3.SQLiteDriver{
		ConnectHook: func(conn *sqlite3.SQLiteConn) error {
			// mattn supports the other pragmas as DSN parameters, but not temp_store.
			_, err := conn.Exec("PRAGMA temp_store = MEMORY", nil)
			return err
		},
	})
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

	s := &server{meta: metadata{Runtime: runtime.Version(), Framework: "net/http"}}
	if err := reader.QueryRow("SELECT sqlite_version()").Scan(&s.meta.SQLite); err != nil {
		return err
	}
	s.user, err = reader.Prepare("SELECT id, name, email, created_at AS createdAt FROM users WHERE id = ?")
	if err != nil {
		return err
	}
	defer s.user.Close()
	s.posts, err = reader.Prepare("SELECT id, user_id AS userId, title, body, created_at AS createdAt FROM posts WHERE user_id = ? ORDER BY id DESC LIMIT ?")
	if err != nil {
		return err
	}
	defer s.posts.Close()
	s.insert, err = writer.Prepare("INSERT INTO posts (user_id, title, body, created_at) VALUES (?, ?, ?, ?) RETURNING id")
	if err != nil {
		return err
	}
	defer s.insert.Close()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("GET /meta", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, s.meta)
	})
	mux.HandleFunc("GET /users/{id}", s.getUser)
	mux.HandleFunc("GET /users/{id}/posts", s.getPosts)
	mux.HandleFunc("POST /posts", s.createPost)
	port := os.Getenv("PORT")
	if port == "" {
		port = "3000"
	}
	httpServer := &http.Server{
		Addr: "127.0.0.1:" + port, Handler: mux,
		ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 120 * time.Second,
	}
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
	params := url.Values{
		"_journal_mode": {"WAL"}, "_synchronous": {"NORMAL"},
		"_busy_timeout": {"5000"}, "_foreign_keys": {"on"}, "_cache_size": {"-16000"},
	}
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

func (s *server) getUser(w http.ResponseWriter, r *http.Request) {
	id, valid := positiveInteger(r.PathValue("id"), maxID)
	if !valid {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}
	var u user
	err := s.user.QueryRowContext(r.Context(), id).Scan(&u.ID, &u.Name, &u.Email, &u.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "not found")
	} else if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
	} else {
		writeJSON(w, http.StatusOK, u)
	}
}

func (s *server) getPosts(w http.ResponseWriter, r *http.Request) {
	id, valid := positiveInteger(r.PathValue("id"), maxID)
	if !valid {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}
	limit := int64(20)
	query, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid limit")
		return
	}
	if query.Has("limit") {
		limit, valid = positiveInteger(query.Get("limit"), 100)
		if !valid {
			writeError(w, http.StatusBadRequest, "invalid limit")
			return
		}
	}
	rows, err := s.posts.QueryContext(r.Context(), id, limit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	defer rows.Close()
	posts := make([]post, 0)
	for rows.Next() {
		var p post
		if err := rows.Scan(&p.ID, &p.UserID, &p.Title, &p.Body, &p.CreatedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "internal")
			return
		}
		posts = append(posts, p)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusOK, posts)
}

func (s *server) createPost(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	data, err := io.ReadAll(r.Body)
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			w.WriteHeader(http.StatusRequestEntityTooLarge)
		} else {
			writeError(w, http.StatusBadRequest, "invalid body")
		}
		return
	}
	var input struct {
		UserID *int64  `json:"userId"`
		Title  *string `json:"title"`
		Body   *string `json:"body"`
	}
	if json.Unmarshal(data, &input) != nil || input.UserID == nil || *input.UserID <= 0 || *input.UserID > maxID ||
		input.Title == nil || input.Body == nil || !validLength(*input.Title, 200) || !validLength(*input.Body, 10000) {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	p := post{UserID: *input.UserID, Title: *input.Title, Body: *input.Body, CreatedAt: time.Now().UnixMilli()}
	err = insertReturning(r.Context(), s.insert, &p)
	if err != nil {
		var sqliteErr sqlite3.Error
		if errors.As(err, &sqliteErr) && sqliteErr.ExtendedCode == sqlite3.ErrConstraintForeignKey {
			writeError(w, http.StatusNotFound, "user not found")
		} else {
			writeError(w, http.StatusInternalServerError, "internal")
		}
		return
	}
	writeJSON(w, http.StatusCreated, p)
}

// insertReturning steps the statement to SQLITE_DONE. QueryRow resets it after the first row instead,
// which commits inside sqlite3_reset and skips SQLite's WAL autocheckpoint, so the WAL grows without bound.
func insertReturning(ctx context.Context, stmt *sql.Stmt, p *post) error {
	rows, err := stmt.QueryContext(ctx, p.UserID, p.Title, p.Body, p.CreatedAt)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		if err := rows.Scan(&p.ID); err != nil {
			return err
		}
	}
	return rows.Err()
}

func validLength(value string, max int) bool {
	length := 0
	for _, r := range value {
		length += utf16.RuneLen(r)
		if length > max {
			return false
		}
	}
	return length > 0
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, struct {
		Error string `json:"error"`
	}{message})
}

func writeJSON(w http.ResponseWriter, status int, value interface{}) {
	data, err := json.Marshal(value)
	if err != nil {
		status = http.StatusInternalServerError
		data = []byte(`{"error":"internal"}`)
	}
	w.Header().Set("Content-Type", "application/json")
	// Without it net/http chunks bodies over 2 KB, which the JS servers never do.
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(status)
	w.Write(data)
}
