package main

import (
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"
)

type post struct {
	ID             int64    `json:"id"`
	Title          string   `json:"title"`
	Body           string   `json:"body"`
	WordCount      int      `json:"wordCount"`
	ReadingMinutes int      `json:"readingMinutes"`
	Tags           []string `json:"tags"`
	CommentCount   int64    `json:"commentCount"`
	CreatedAt      int64    `json:"createdAt"`
	Author         person   `json:"author"`
}

type feedItem struct {
	ID             int64    `json:"id"`
	Title          string   `json:"title"`
	Excerpt        string   `json:"excerpt"`
	WordCount      int      `json:"wordCount"`
	ReadingMinutes int      `json:"readingMinutes"`
	Tags           []string `json:"tags"`
	CommentCount   int64    `json:"commentCount"`
	CreatedAt      int64    `json:"createdAt"`
	Author         person   `json:"author"`
}

type comment struct {
	ID        int64  `json:"id"`
	Body      string `json:"body"`
	CreatedAt int64  `json:"createdAt"`
	Author    person `json:"author"`
}

type createdComment struct {
	ID        int64  `json:"id"`
	PostID    int64  `json:"postId"`
	Body      string `json:"body"`
	CreatedAt int64  `json:"createdAt"`
	Author    person `json:"author"`
}

func derive(p *post) {
	p.Tags = make([]string, 0, 5)
	for start := 0; start < len(p.Body); {
		if p.Body[start] == ' ' {
			start++
			continue
		}
		end := start
		for end < len(p.Body) && p.Body[end] != ' ' {
			end++
		}
		word := p.Body[start:end]
		p.WordCount++
		if len(p.Tags) < 5 && len(word) > 1 && word[0] == '#' {
			tag := word[1:]
			valid := true
			for i := range len(tag) {
				c := tag[i]
				if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_') {
					valid = false
					break
				}
			}
			if valid {
				duplicate := false
				for _, previous := range p.Tags {
					if previous == tag {
						duplicate = true
						break
					}
				}
				if !duplicate {
					p.Tags = append(p.Tags, tag)
				}
			}
		}
		start = end
	}
	p.ReadingMinutes = max(1, (p.WordCount+199)/200)
}

func excerpt(body string) string {
	if len(body) <= 200 {
		return body
	}
	prefix := body[:200]
	if space := strings.LastIndexByte(prefix, ' '); space >= 0 {
		prefix = prefix[:space]
	}
	return prefix + "..."
}

func scanPost(rows *sql.Rows, p *post) error {
	return rows.Scan(&p.ID, &p.Title, &p.Body, &p.CommentCount, &p.CreatedAt, &p.Author.ID, &p.Author.Name)
}

type commentInput struct {
	Body *string `json:"body"`
}

func (s *server) getFeed(w http.ResponseWriter, r *http.Request, viewer person) {
	query := r.URL.Query()
	limit := int64(20)
	var valid bool
	if query.Has("limit") {
		limit, valid = positiveInteger(query.Get("limit"), 50)
		if !valid {
			writeError(w, 400, "invalid limit")
			return
		}
	}
	createdAt, postID := int64(maxID), int64(maxID)
	if query.Has("cursor") {
		decoded, err := decodeURL(query.Get("cursor"))
		parts := strings.Split(string(decoded), ":")
		if err != nil || len(parts) != 2 {
			writeError(w, 400, "invalid cursor")
			return
		}
		createdAt, valid = positiveInteger(parts[0], maxID)
		if !valid {
			writeError(w, 400, "invalid cursor")
			return
		}
		postID, valid = positiveInteger(parts[1], maxID)
		if !valid {
			writeError(w, 400, "invalid cursor")
			return
		}
	}
	rows, err := s.feed.QueryContext(r.Context(), viewer.ID, createdAt, postID, limit)
	if err != nil {
		writeError(w, 500, "internal")
		return
	}
	defer rows.Close()
	items := make([]feedItem, 0, limit)
	for rows.Next() {
		var p post
		if scanPost(rows, &p) != nil {
			writeError(w, 500, "internal")
			return
		}
		derive(&p)
		items = append(items, feedItem{p.ID, p.Title, excerpt(p.Body), p.WordCount, p.ReadingMinutes, p.Tags, p.CommentCount, p.CreatedAt, p.Author})
	}
	if rows.Err() != nil {
		writeError(w, 500, "internal")
		return
	}
	var nextCursor *string
	if int64(len(items)) == limit {
		last := items[len(items)-1]
		cursor := base64.RawURLEncoding.EncodeToString([]byte(strconv.FormatInt(last.CreatedAt, 10) + ":" + strconv.FormatInt(last.ID, 10)))
		nextCursor = &cursor
	}
	writeJSON(w, 200, struct {
		Viewer     person     `json:"viewer"`
		Items      []feedItem `json:"items"`
		NextCursor *string    `json:"nextCursor"`
	}{viewer, items, nextCursor})
}

func (s *server) getPost(w http.ResponseWriter, r *http.Request, _ person) {
	id, valid := positiveInteger(r.PathValue("id"), maxID)
	if !valid {
		writeError(w, 400, "invalid id")
		return
	}
	var p post
	err := s.post.QueryRowContext(r.Context(), id).Scan(&p.ID, &p.Title, &p.Body, &p.CommentCount, &p.CreatedAt, &p.Author.ID, &p.Author.Name)
	if errors.Is(err, sql.ErrNoRows) {
		writeError(w, 404, "not found")
		return
	}
	if err != nil {
		writeError(w, 500, "internal")
		return
	}
	derive(&p)
	rows, err := s.comments.QueryContext(r.Context(), id)
	if err != nil {
		writeError(w, 500, "internal")
		return
	}
	defer rows.Close()
	comments := make([]comment, 0, 20)
	for rows.Next() {
		var c comment
		if rows.Scan(&c.ID, &c.Body, &c.CreatedAt, &c.Author.ID, &c.Author.Name) != nil {
			writeError(w, 500, "internal")
			return
		}
		comments = append(comments, c)
	}
	if rows.Err() != nil {
		writeError(w, 500, "internal")
		return
	}
	writeJSON(w, 200, struct {
		Post     post      `json:"post"`
		Comments []comment `json:"comments"`
	}{p, comments})
}

func validLength(value string, maximum int) bool {
	length := 0
	for _, r := range value {
		length += utf16.RuneLen(r)
		if length > maximum {
			return false
		}
	}
	return length > 0
}

func (s *server) createComment(w http.ResponseWriter, r *http.Request, viewer person) {
	id, valid := positiveInteger(r.PathValue("id"), maxID)
	if !valid {
		writeError(w, 400, "invalid id")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	data, err := io.ReadAll(r.Body)
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			w.WriteHeader(413)
		} else {
			writeError(w, 400, "invalid body")
		}
		return
	}
	var input commentInput
	if json.Unmarshal(data, &input) != nil || input.Body == nil || !validLength(*input.Body, 2000) {
		writeError(w, 400, "invalid body")
		return
	}
	c := createdComment{PostID: id, Body: *input.Body, CreatedAt: time.Now().UnixMilli(), Author: viewer}
	tx, err := s.writer.BeginTx(r.Context(), nil)
	if err != nil {
		writeError(w, 500, "internal")
		return
	}
	defer tx.Rollback()
	result, err := tx.StmtContext(r.Context(), s.update).ExecContext(r.Context(), id)
	if err != nil {
		writeError(w, 500, "internal")
		return
	}
	changed, err := result.RowsAffected()
	if err != nil {
		writeError(w, 500, "internal")
		return
	}
	if changed == 0 {
		tx.Rollback()
		writeError(w, 404, "not found")
		return
	}
	rows, err := tx.StmtContext(r.Context(), s.insert).QueryContext(r.Context(), id, viewer.ID, c.Body, c.CreatedAt)
	if err != nil {
		writeError(w, 500, "internal")
		return
	}
	// Exhaust RETURNING rows so SQLite reaches DONE and performs WAL autocheckpointing.
	for rows.Next() {
		if err = rows.Scan(&c.ID); err != nil {
			break
		}
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		writeError(w, 500, "internal")
		return
	}
	if tx.Commit() != nil {
		writeError(w, 500, "internal")
		return
	}
	writeJSON(w, 201, c)
}
