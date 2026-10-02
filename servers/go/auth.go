package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"strings"
	"time"
)

type person struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

type jwtHeader struct {
	Alg string `json:"alg"`
}

type jwtPayload struct {
	Sub  *float64 `json:"sub"`
	Name *string  `json:"name"`
	Iss  string   `json:"iss"`
	Exp  *float64 `json:"exp"`
}

func decodeURL(value string) ([]byte, error) {
	if value == "" {
		return nil, errors.New("empty base64url")
	}
	for i := range len(value) {
		c := value[i]
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return nil, errors.New("invalid base64url")
		}
	}
	return base64.RawURLEncoding.Strict().DecodeString(value)
}

func (s *server) authenticate(header string) (person, bool) {
	if !strings.HasPrefix(header, "Bearer ") {
		return person{}, false
	}
	token := strings.TrimPrefix(header, "Bearer ")
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return person{}, false
	}
	headerJSON, err := decodeURL(parts[0])
	if err != nil {
		return person{}, false
	}
	payloadJSON, err := decodeURL(parts[1])
	if err != nil {
		return person{}, false
	}
	signature, err := decodeURL(parts[2])
	if err != nil {
		return person{}, false
	}
	var headerValue jwtHeader
	if json.Unmarshal(headerJSON, &headerValue) != nil || headerValue.Alg != "HS256" {
		return person{}, false
	}
	mac := hmac.New(sha256.New, s.secret)
	mac.Write([]byte(token[:len(parts[0])+1+len(parts[1])]))
	if !hmac.Equal(mac.Sum(nil), signature) {
		return person{}, false
	}
	var payload jwtPayload
	if json.Unmarshal(payloadJSON, &payload) != nil || payload.Sub == nil || *payload.Sub < 1 || *payload.Sub > maxID || math.Trunc(*payload.Sub) != *payload.Sub || payload.Name == nil || payload.Iss != "gbb" || payload.Exp == nil || *payload.Exp < 0 || *payload.Exp > maxID || math.Trunc(*payload.Exp) != *payload.Exp || *payload.Exp*1000 <= float64(time.Now().UnixMilli()) {
		return person{}, false
	}
	return person{ID: int64(*payload.Sub), Name: *payload.Name}, true
}

func (s *server) auth(next func(http.ResponseWriter, *http.Request, person)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		viewer, valid := s.authenticate(r.Header.Get("Authorization"))
		if !valid {
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		next(w, r, viewer)
	}
}
