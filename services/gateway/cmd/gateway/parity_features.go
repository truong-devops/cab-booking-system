package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"math/rand"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"go.opentelemetry.io/otel/trace"
)

const contextPreparedBodyKey contextKey = "prepared_body"

type preparedBody struct {
	raw    []byte
	parsed interface{}
}

type parityFeatures struct {
	jsonBodyLimitBytes int64

	accessLogEnabled        bool
	auditLogEnabled         bool
	auditSuccessSampleRate  float64
	auditDenyLoadSampleRate float64

	globalWindow      time.Duration
	globalMax         int
	authWindow        time.Duration
	authLoginMax      int
	etaMax            int
	bookingCreateMax  int
	rateLimiter       *rateLimiterStore
	circuitBreaker    *circuitBreaker
	telemetryProvider *telemetryProvider
}

type rateLimiterStore struct {
	mu      sync.Mutex
	entries map[string]rateLimitEntry
}

type rateLimitEntry struct {
	count   int
	resetAt time.Time
}

type circuitBreaker struct {
	enabled          bool
	failureThreshold int
	openMS           int

	mu     sync.Mutex
	states map[string]circuitState
}

type circuitState struct {
	status              string
	consecutiveFailures int
	openUntil           int64
}

type responseCaptureWriter struct {
	http.ResponseWriter
	status int
}

func (w *responseCaptureWriter) WriteHeader(statusCode int) {
	w.status = statusCode
	w.ResponseWriter.WriteHeader(statusCode)
}

func (w *responseCaptureWriter) Write(payload []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	return w.ResponseWriter.Write(payload)
}

func initParityFeatures(cfg config) *parityFeatures {
	globalMax := parsePositiveInt(os.Getenv("RATE_LIMIT_MAX"), 60000)
	bookingCreateMaxDefault := int(math.Min(float64(globalMax), 30))
	if bookingCreateMaxDefault <= 0 {
		bookingCreateMaxDefault = 30
	}

	etaMaxDefault := int(math.Max(float64(globalMax), 120000))
	if etaMaxDefault <= 0 {
		etaMaxDefault = 120000
	}

	telemetry := initTelemetryProvider(cfg)

	return &parityFeatures{
		jsonBodyLimitBytes: int64(parsePositiveInt(os.Getenv("JSON_PAYLOAD_LIMIT_BYTES"), 102400)),

		accessLogEnabled:        parseBool(envOrDefault("HTTP_ACCESS_LOG_ENABLED", "false"), false),
		auditLogEnabled:         parseBool(envOrDefault("SECURITY_AUDIT_LOG_ENABLED", "true"), true),
		auditSuccessSampleRate:  clampFloat(parseFloat(envOrDefault("SECURITY_AUDIT_LOG_SUCCESS_SAMPLE_RATE", "0.02"), 0.02), 0, 1),
		auditDenyLoadSampleRate: clampFloat(parseFloat(envOrDefault("SECURITY_AUDIT_LOG_DENY_LOAD_SAMPLE_RATE", "0.02"), 0.02), 0, 1),

		globalWindow: durationFromMS(parsePositiveInt(os.Getenv("RATE_LIMIT_WINDOW_MS"), 60000), 60000),
		globalMax:    globalMax,
		authWindow:   durationFromMS(parsePositiveInt(os.Getenv("AUTH_RATE_LIMIT_WINDOW_MS"), 60000), 60000),
		authLoginMax: parsePositiveInt(os.Getenv("AUTH_LOGIN_RATE_LIMIT_MAX"), 80),
		etaMax:       parsePositiveInt(os.Getenv("ETA_RATE_LIMIT_MAX"), etaMaxDefault),
		bookingCreateMax: parsePositiveInt(
			os.Getenv("BOOKING_CREATE_RATE_LIMIT_MAX"),
			bookingCreateMaxDefault,
		),
		rateLimiter: &rateLimiterStore{
			entries: make(map[string]rateLimitEntry),
		},
		circuitBreaker: &circuitBreaker{
			enabled:          parseBool(envOrDefault("PROXY_CIRCUIT_BREAKER_ENABLED", "true"), true),
			failureThreshold: parsePositiveInt(os.Getenv("PROXY_CIRCUIT_BREAKER_FAILURE_THRESHOLD"), 3),
			openMS:           parsePositiveInt(os.Getenv("PROXY_CIRCUIT_BREAKER_OPEN_MS"), 10000),
			states:           make(map[string]circuitState),
		},
		telemetryProvider: telemetry,
	}
}

func (p *parityFeatures) shutdown(ctx context.Context) {
	if p == nil || p.telemetryProvider == nil {
		return
	}
	if err := p.telemetryProvider.Shutdown(ctx); err != nil {
		log.Printf("[gateway] telemetry shutdown error: %v", err)
	}
}

func (p *parityFeatures) applySecurityHeaders(w http.ResponseWriter) {
	w.Header().Set("content-security-policy", "default-src 'self';base-uri 'self';font-src 'self' https: data:;form-action 'self';frame-ancestors 'self';img-src 'self' data:;object-src 'none';script-src 'self';script-src-attr 'none';style-src 'self' https: 'unsafe-inline';upgrade-insecure-requests")
	w.Header().Set("cross-origin-opener-policy", "same-origin")
	w.Header().Set("cross-origin-resource-policy", "same-origin")
	w.Header().Set("origin-agent-cluster", "?1")
	w.Header().Set("referrer-policy", "no-referrer")
	w.Header().Set("strict-transport-security", "max-age=15552000; includeSubDomains")
	w.Header().Set("x-content-type-options", "nosniff")
	w.Header().Set("x-dns-prefetch-control", "off")
	w.Header().Set("x-download-options", "noopen")
	w.Header().Set("x-frame-options", "SAMEORIGIN")
	w.Header().Set("x-permitted-cross-domain-policies", "none")
	w.Header().Set("x-xss-protection", "0")
}

func (p *parityFeatures) preprocessJSONBody(w http.ResponseWriter, r *http.Request, traceID string) (*http.Request, bool) {
	if r.Method == http.MethodGet || r.Method == http.MethodHead || r.Method == http.MethodOptions {
		return r, true
	}
	contentType := strings.ToLower(strings.TrimSpace(r.Header.Get("Content-Type")))
	if !strings.Contains(contentType, "application/json") {
		return r, true
	}

	limit := p.jsonBodyLimitBytes
	if limit <= 0 {
		limit = 102400
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, limit+1))
	if err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "Invalid JSON payload", traceID, nil)
		return r, false
	}
	if int64(len(body)) > limit {
		writeError(w, http.StatusRequestEntityTooLarge, "PAYLOAD_TOO_LARGE", "Payload Too Large", traceID, nil)
		return r, false
	}

	trimmed := strings.TrimSpace(string(body))
	var parsed interface{}
	if trimmed == "" {
		parsed = map[string]interface{}{}
	} else {
		if err := json.Unmarshal(body, &parsed); err != nil {
			writeError(w, http.StatusBadRequest, "INVALID_JSON", "Invalid JSON payload", traceID, nil)
			return r, false
		}
	}

	normalized, err := json.Marshal(parsed)
	if err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "Invalid JSON payload", traceID, nil)
		return r, false
	}

	ctx := context.WithValue(r.Context(), contextPreparedBodyKey, preparedBody{
		raw:    normalized,
		parsed: parsed,
	})
	return r.WithContext(ctx), true
}

func (p *parityFeatures) applyEarlyRateLimits(w http.ResponseWriter, r *http.Request, traceID string) bool {
	if p == nil {
		return true
	}

	if p.isSecurityRateLimitProbe(r) {
		key := fmt.Sprintf("%s|%s|security_rate_probe", p.clientIP(r), p.authorizationOrAnon(r))
		if !p.allowRateLimit("booking_attack_probe", key, p.authWindow, 1, w, traceID) {
			return false
		}
	}

	if p.isBookingCreateRequest(r) {
		key := fmt.Sprintf("%s|%s|booking_create", p.clientIP(r), p.authorizationOrAnon(r))
		if !p.allowRateLimit("booking_burst", key, p.globalWindow, p.bookingCreateMax, w, traceID) {
			return false
		}
	}

	return true
}

func (p *parityFeatures) applyAuthLoginRateLimit(w http.ResponseWriter, r *http.Request, traceID string) bool {
	if p == nil || !p.isAuthLoginRequest(r) {
		return true
	}
	key := normalizeIPForRateLimit(p.clientIP(r))
	return p.allowRateLimit("auth_login", key, p.authWindow, p.authLoginMax, w, traceID)
}

func (p *parityFeatures) applyGlobalRateLimit(w http.ResponseWriter, r *http.Request, user authUser, traceID string) bool {
	if p == nil || p.isAuthLoginRequest(r) {
		return true
	}

	max := p.globalMax
	if p.isEtaEstimateRequest(r) {
		max = p.etaMax
	}
	if p.isBookingCreateRequest(r) {
		max = p.bookingCreateMax
	}
	if max <= 0 {
		max = 60000
	}

	clientKey := user.ID
	if strings.TrimSpace(clientKey) == "" {
		clientKey = p.clientIP(r)
	}
	routeBucket := p.routeBucket(r)
	key := fmt.Sprintf("%s|%s", clientKey, routeBucket)
	return p.allowRateLimit("global", key, p.globalWindow, max, w, traceID)
}

func (p *parityFeatures) allowRateLimit(bucket, key string, window time.Duration, max int, w http.ResponseWriter, traceID string) bool {
	if p == nil {
		return true
	}
	allowed, limit, remaining, resetSec := p.rateLimiter.allow(bucket, key, window, max)
	w.Header().Set("ratelimit-limit", fmt.Sprintf("%d", limit))
	w.Header().Set("ratelimit-remaining", fmt.Sprintf("%d", remaining))
	w.Header().Set("ratelimit-reset", fmt.Sprintf("%d", resetSec))
	if allowed {
		return true
	}
	writeError(w, http.StatusTooManyRequests, "RATE_LIMITED", "Too many requests", traceID, nil)
	return false
}

func (s *rateLimiterStore) allow(bucket, key string, window time.Duration, max int) (bool, int, int, int64) {
	if max <= 0 {
		max = 1
	}
	if window <= 0 {
		window = time.Minute
	}

	now := time.Now()
	composite := bucket + "|" + key

	s.mu.Lock()
	defer s.mu.Unlock()

	entry, found := s.entries[composite]
	if !found || !now.Before(entry.resetAt) {
		entry = rateLimitEntry{
			count:   0,
			resetAt: now.Add(window),
		}
	}

	if entry.count >= max {
		s.entries[composite] = entry
		remaining := 0
		resetSec := int64(math.Ceil(entry.resetAt.Sub(now).Seconds()))
		if resetSec < 0 {
			resetSec = 0
		}
		return false, max, remaining, resetSec
	}

	entry.count++
	s.entries[composite] = entry
	remaining := max - entry.count
	if remaining < 0 {
		remaining = 0
	}
	resetSec := int64(math.Ceil(entry.resetAt.Sub(now).Seconds()))
	if resetSec < 0 {
		resetSec = 0
	}
	return true, max, remaining, resetSec
}

func (cb *circuitBreaker) allow(domain string) (bool, int) {
	if cb == nil || !cb.enabled {
		return true, 0
	}

	now := time.Now().UnixMilli()
	state := cb.getState(domain)
	if state.status == "OPEN" && now < state.openUntil {
		return false, int(state.openUntil - now)
	}
	if state.status == "OPEN" && now >= state.openUntil {
		state.status = "HALF_OPEN"
		cb.setState(domain, state)
	}
	return true, 0
}

func (cb *circuitBreaker) markSuccess(domain string) {
	if cb == nil || !cb.enabled {
		return
	}
	state := cb.getState(domain)
	state.status = "CLOSED"
	state.consecutiveFailures = 0
	state.openUntil = 0
	cb.setState(domain, state)
}

func (cb *circuitBreaker) markFailure(domain string) {
	if cb == nil || !cb.enabled {
		return
	}
	state := cb.getState(domain)
	state.consecutiveFailures++
	failureThreshold := cb.getFailureThreshold(domain)
	openMS := cb.getOpenMS(domain)
	if state.status == "HALF_OPEN" || state.consecutiveFailures >= failureThreshold {
		state.status = "OPEN"
		state.openUntil = time.Now().UnixMilli() + int64(openMS)
	}
	cb.setState(domain, state)
}

func (cb *circuitBreaker) getState(domain string) circuitState {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	state, found := cb.states[domain]
	if !found {
		state = circuitState{
			status:              "CLOSED",
			consecutiveFailures: 0,
			openUntil:           0,
		}
		cb.states[domain] = state
	}
	return state
}

func (cb *circuitBreaker) setState(domain string, state circuitState) {
	cb.mu.Lock()
	cb.states[domain] = state
	cb.mu.Unlock()
}

func (cb *circuitBreaker) getFailureThreshold(domain string) int {
	envKey := "PROXY_CIRCUIT_BREAKER_FAILURE_THRESHOLD_" + strings.ToUpper(domain)
	value := parsePositiveInt(os.Getenv(envKey), cb.failureThreshold)
	if value <= 0 {
		return 1
	}
	return value
}

func (cb *circuitBreaker) getOpenMS(domain string) int {
	envKey := "PROXY_CIRCUIT_BREAKER_OPEN_MS_" + strings.ToUpper(domain)
	value := parsePositiveInt(os.Getenv(envKey), cb.openMS)
	if value <= 0 {
		return 100
	}
	return value
}

func (p *parityFeatures) logAndRecord(r *http.Request, status int, traceID, requestID string, actor authUser, startedAt time.Time) {
	if p == nil {
		return
	}

	if status == 0 {
		status = http.StatusOK
	}
	durationMs := float64(time.Since(startedAt).Nanoseconds()) / 1_000_000

	if p.telemetryProvider != nil {
		p.telemetryProvider.RecordHTTP(r.Context(), r.Method, r.URL.Path, status, durationMs)
	}

	shouldAuditLog := p.auditLogEnabled && (strings.HasPrefix(r.URL.Path, "/v1/") || r.URL.Path == "/webhooks/payos")
	shouldAccessLog := p.accessLogEnabled

	if shouldAccessLog {
		record := map[string]interface{}{
			"method":    r.Method,
			"path":      r.URL.RequestURI(),
			"status":    status,
			"latencyMs": math.Round(durationMs*100) / 100,
			"traceId":   traceID,
			"requestId": requestID,
		}
		span := trace.SpanFromContext(r.Context())
		if span != nil {
			spanCtx := span.SpanContext()
			if spanCtx.IsValid() {
				record["otelTraceId"] = spanCtx.TraceID().String()
			}
		}
		raw, _ := json.Marshal(record)
		log.Println(string(raw))
	}

	if !shouldAuditLog {
		return
	}

	isDeny := status >= 400
	clientTraceID := strings.TrimSpace(r.Header.Get("x-trace-id"))
	forceAuditLog := isTruthyHeader(r.Header.Get("x-force-audit-log"))
	isLoadTest := isLoadTestHeader(r.Header.Get("x-load-test"))

	if !isDeny {
		sampledSuccess := rand.Float64() < p.auditSuccessSampleRate
		if clientTraceID == "" && !forceAuditLog && !sampledSuccess {
			return
		}
		if isLoadTest && clientTraceID == "" && !forceAuditLog {
			return
		}
	} else if isLoadTest && !forceAuditLog && clientTraceID == "" {
		if rand.Float64() >= p.auditDenyLoadSampleRate {
			return
		}
	}

	actorID := interface{}(nil)
	actorRole := interface{}(nil)
	if strings.TrimSpace(actor.ID) != "" {
		actorID = actor.ID
	}
	if strings.TrimSpace(actor.Role) != "" {
		actorRole = actor.Role
	}

	result := "deny"
	if status < 400 {
		result = "allow"
	}

	auditRecord := map[string]interface{}{
		"event":                  "security_audit",
		"action":                 fmt.Sprintf("%s %s", r.Method, r.URL.Path),
		"result":                 result,
		"status":                 status,
		"actorId":                actorID,
		"actorRole":              actorRole,
		"hasAuthorizationHeader": strings.TrimSpace(r.Header.Get("authorization")) != "",
		"traceId":                traceID,
		"requestId":              requestID,
		"occurredAt":             time.Now().UTC().Format(time.RFC3339),
	}
	raw, _ := json.Marshal(auditRecord)
	log.Println(string(raw))
}

func (p *parityFeatures) clientIP(r *http.Request) string {
	xForwardedFor := strings.TrimSpace(r.Header.Get("x-forwarded-for"))
	if xForwardedFor != "" {
		parts := strings.Split(xForwardedFor, ",")
		if len(parts) > 0 {
			candidate := strings.TrimSpace(parts[0])
			if candidate != "" {
				return candidate
			}
		}
	}

	remote := strings.TrimSpace(r.RemoteAddr)
	if remote == "" {
		return "unknown"
	}
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		return remote
	}
	if host == "" {
		return "unknown"
	}
	return host
}

func (p *parityFeatures) authorizationOrAnon(r *http.Request) string {
	value := strings.TrimSpace(r.Header.Get("authorization"))
	if value == "" {
		return "anon"
	}
	return value
}

func (p *parityFeatures) isAuthLoginRequest(r *http.Request) bool {
	return r.Method == http.MethodPost && r.URL.Path == "/v1/auth/login"
}

func (p *parityFeatures) isEtaEstimateRequest(r *http.Request) bool {
	return r.Method == http.MethodPost && r.URL.Path == "/v1/eta/estimate"
}

func (p *parityFeatures) isBookingCreateRequest(r *http.Request) bool {
	return r.Method == http.MethodPost && r.URL.Path == "/v1/bookings"
}

func (p *parityFeatures) isSecurityRateLimitProbe(r *http.Request) bool {
	if !p.isBookingCreateRequest(r) {
		return false
	}
	marker := strings.ToLower(strings.TrimSpace(r.Header.Get("x-load-test")))
	return marker == "security-rate-limit"
}

func (p *parityFeatures) routeBucket(r *http.Request) string {
	if p.isBookingCreateRequest(r) {
		return "booking_create"
	}
	if p.isEtaEstimateRequest(r) {
		return "eta_estimate"
	}
	return fmt.Sprintf("%s:%s", r.Method, r.URL.Path)
}

func normalizeIPForRateLimit(value string) string {
	normalized := strings.ToLower(strings.TrimSpace(value))
	if normalized == "" {
		return "unknown"
	}
	if normalized == "::1" || normalized == "127.0.0.1" || normalized == "::ffff:127.0.0.1" {
		return "loopback"
	}
	return normalized
}

func preparedBodyFromContext(r *http.Request) (preparedBody, bool) {
	value := r.Context().Value(contextPreparedBodyKey)
	if value == nil {
		return preparedBody{}, false
	}
	body, ok := value.(preparedBody)
	if !ok {
		return preparedBody{}, false
	}
	return body, true
}

func preparedBodyAsMap(r *http.Request) (map[string]interface{}, bool) {
	prepared, ok := preparedBodyFromContext(r)
	if !ok {
		return nil, false
	}
	typed, ok := prepared.parsed.(map[string]interface{})
	if !ok {
		return nil, false
	}
	return typed, true
}

func isTruthyHeader(value string) bool {
	normalized := strings.ToLower(strings.TrimSpace(value))
	return normalized == "1" || normalized == "true" || normalized == "yes"
}

func isLoadTestHeader(value string) bool {
	if strings.TrimSpace(value) == "" {
		return false
	}
	normalized := strings.ToLower(strings.TrimSpace(value))
	return normalized != "0" && normalized != "false" && normalized != "no"
}

func parseFloat(raw string, fallback float64) float64 {
	parsed, err := strconv.ParseFloat(strings.TrimSpace(raw), 64)
	if err != nil || math.IsNaN(parsed) || math.IsInf(parsed, 0) {
		return fallback
	}
	return parsed
}

func clampFloat(value, min, max float64) float64 {
	if value < min {
		return min
	}
	if value > max {
		return max
	}
	return value
}
