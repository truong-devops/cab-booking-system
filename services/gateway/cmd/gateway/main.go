package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	jwt "github.com/golang-jwt/jwt/v5"
	"go.opentelemetry.io/otel/trace"
)

const (
	defaultPort                = 3000
	defaultProxyTimeoutMS      = 5000
	defaultRetryBackoffMS      = 100
	defaultKeepaliveMaxSockets = 1024
)

type config struct {
	serviceName string
	port        int
	https       httpsConfig
	corsOrigin  string

	jwtSecret     string
	jwtAlgorithms []string

	internalAPIKey string

	proxyTimeoutMS        int
	proxyRetryBackoffMS   int
	proxyKeepaliveSockets int

	authVerifyEnabled          bool
	authVerifyTimeoutMS        int
	authVerifyCacheTTLMS       int
	authVerifyNegativeCacheTTL int
	authVerifySkipPrefixes     []string
	authLocalJWTCacheTTLMS     int

	authPublicDomains map[string]struct{}
	authPublicPaths   map[string]struct{}

	serviceURLs map[string]string
}

type httpsConfig struct {
	enabled  bool
	port     int
	certPath string
	keyPath  string
}

type authUser struct {
	ID     string
	Role   string
	Roles  []string
	Scopes []string
}

type cachedLocalUser struct {
	user      authUser
	expiresAt time.Time
}

type cachedVerifyResult struct {
	valid     bool
	expiresAt time.Time
}

type gateway struct {
	cfg config

	proxyClient *http.Client
	authClient  *http.Client
	parity      *parityFeatures

	localUserCacheMu sync.RWMutex
	localUserCache   map[string]cachedLocalUser

	verifyCacheMu sync.RWMutex
	verifyCache   map[string]cachedVerifyResult
}

type contextKey string

const (
	contextTraceIDKey   contextKey = "trace_id"
	contextRequestIDKey contextKey = "request_id"
)

type errorDetail struct {
	Path    string `json:"path"`
	Message string `json:"message"`
}

type errorBody struct {
	Error struct {
		Code    string        `json:"code"`
		Message string        `json:"message"`
		Details []errorDetail `json:"details"`
	} `json:"error"`
	TraceID string `json:"traceId"`
}

func main() {
	cfg := loadConfig()

	gw := &gateway{
		cfg:            cfg,
		proxyClient:    buildProxyHTTPClient(cfg.proxyKeepaliveSockets),
		authClient:     buildAuthHTTPClient(),
		localUserCache: make(map[string]cachedLocalUser),
		verifyCache:    make(map[string]cachedVerifyResult),
	}
	gw.parity = initParityFeatures(cfg)

	mainServer := &http.Server{
		Addr:              fmt.Sprintf(":%d", cfg.port),
		Handler:           gw,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	errCh := make(chan error, 2)
	go func() {
		log.Printf("[%s] listening on :%d", cfg.serviceName, cfg.port)
		errCh <- mainServer.ListenAndServe()
	}()

	var httpsServer *http.Server
	if cfg.https.enabled {
		cert, err := loadTLSCertificate(cfg)
		if err != nil {
			log.Fatalf("[%s] unable to initialize HTTPS certificate: %v", cfg.serviceName, err)
		}
		if !fileExists(cfg.https.certPath) || !fileExists(cfg.https.keyPath) {
			log.Printf("%s", tlsFallbackLogMessage(cfg))
		}

		httpsServer = &http.Server{
			Addr:              fmt.Sprintf(":%d", cfg.https.port),
			Handler:           gw,
			ReadHeaderTimeout: 5 * time.Second,
			IdleTimeout:       120 * time.Second,
			TLSConfig: &tls.Config{
				MinVersion:   tls.VersionTLS12,
				Certificates: []tls.Certificate{cert},
			},
		}

		go func() {
			log.Printf("[%s] https listening on :%d", cfg.serviceName, cfg.https.port)
			errCh <- httpsServer.ListenAndServeTLS("", "")
		}()
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	select {
	case sig := <-stop:
		log.Printf("[%s] received signal: %s", cfg.serviceName, sig.String())
	case err := <-errCh:
		if !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("[%s] server error: %v", cfg.serviceName, err)
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_ = mainServer.Shutdown(ctx)
	if httpsServer != nil {
		_ = httpsServer.Shutdown(ctx)
	}
	if gw.parity != nil {
		gw.parity.shutdown(ctx)
	}
}

func (g *gateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	startedAt := time.Now()
	responseWriter := &responseCaptureWriter{ResponseWriter: w, status: http.StatusOK}

	traceID := chooseID(r.Header.Get("x-trace-id"))
	requestID := chooseID(r.Header.Get("x-request-id"))
	responseWriter.Header().Set("x-trace-id", traceID)
	responseWriter.Header().Set("x-request-id", requestID)

	g.applyCORS(responseWriter)
	if g.parity != nil {
		g.parity.applySecurityHeaders(responseWriter)
	}
	if r.Method == http.MethodOptions {
		responseWriter.WriteHeader(http.StatusNoContent)
		return
	}

	ctx := context.WithValue(r.Context(), contextTraceIDKey, traceID)
	ctx = context.WithValue(ctx, contextRequestIDKey, requestID)
	r = r.WithContext(ctx)

	var requestSpan trace.Span
	if g.parity != nil && g.parity.telemetryProvider != nil {
		spanCtx, span := g.parity.telemetryProvider.StartRequestSpan(r.Context(), r.Method, r.URL.Path)
		requestSpan = span
		r = r.WithContext(spanCtx)
	}

	authActor := authUser{}
	defer func() {
		if g.parity != nil {
			g.parity.logAndRecord(r, responseWriter.status, traceID, requestID, authActor, startedAt)
			if g.parity.telemetryProvider != nil {
				g.parity.telemetryProvider.FinishRequestSpan(requestSpan, responseWriter.status)
			}
		}
	}()

	if g.parity != nil {
		var ok bool
		r, ok = g.parity.preprocessJSONBody(responseWriter, r, traceID)
		if !ok {
			return
		}
		if !g.parity.applyEarlyRateLimits(responseWriter, r, traceID) {
			return
		}
	}

	path := r.URL.Path

	switch path {
	case "/health", "/healthz", "/readyz":
		writeJSON(responseWriter, http.StatusOK, map[string]bool{"ok": true})
		return
	case "/webhooks/payos":
		if g.parity != nil {
			authActor = authUser{}
		}
		g.handleProxy(responseWriter, r, "payments", authUser{})
		return
	}

	domain, domainFound := domainFromPath(path)
	if !domainFound {
		writeError(responseWriter, http.StatusNotFound, "NOT_FOUND", "Route not found", traceID, nil)
		return
	}

	if !g.isKnownDomain(domain) {
		writeError(responseWriter, http.StatusNotFound, "NOT_FOUND", fmt.Sprintf("Unknown domain: %s", domain), traceID, nil)
		return
	}

	if g.parity != nil && !g.parity.applyAuthLoginRateLimit(responseWriter, r, traceID) {
		return
	}

	user := authUser{}
	if !g.isPublicRequest(path, domain) {
		authedUser, status, code, message := g.authenticate(r, traceID)
		if status != 0 {
			writeError(responseWriter, status, code, message, traceID, nil)
			return
		}
		user = authedUser
		authActor = authedUser
	}

	if g.parity != nil && !g.parity.applyGlobalRateLimit(responseWriter, r, user, traceID) {
		return
	}

	if domain == "fraud" && path == "/v1/fraud/check" && r.Method == http.MethodPost {
		g.handleFraudCheck(responseWriter, r, traceID)
		return
	}

	g.handleProxy(responseWriter, r, domain, user)
}

func (g *gateway) applyCORS(w http.ResponseWriter) {
	allowOrigin := g.cfg.corsOrigin
	if allowOrigin == "" {
		allowOrigin = "*"
	}
	w.Header().Set("access-control-allow-origin", allowOrigin)
	w.Header().Set("access-control-allow-methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS")
	w.Header().Set("access-control-allow-headers", "Content-Type,Authorization,X-Trace-Id,X-Request-Id,Idempotency-Key,X-Load-Test,X-Booking-Fast-Path")
}

func (g *gateway) isPublicRequest(path, domain string) bool {
	if _, ok := g.cfg.authPublicPaths[path]; ok {
		return true
	}
	_, ok := g.cfg.authPublicDomains[domain]
	return ok
}

func (g *gateway) isKnownDomain(domain string) bool {
	if domain == "fraud" {
		return true
	}
	_, ok := g.cfg.serviceURLs[domain]
	return ok
}

func (g *gateway) authenticate(r *http.Request, traceID string) (authUser, int, string, string) {
	authHeader := strings.TrimSpace(r.Header.Get("Authorization"))
	tokenValue, ok := parseBearerToken(authHeader)
	if !ok {
		return authUser{}, http.StatusUnauthorized, "UNAUTHORIZED", "Missing authorization token"
	}

	if g.cfg.jwtSecret == "" {
		return authUser{}, http.StatusInternalServerError, "INTERNAL", "JWT secret not configured"
	}

	if cached, found := g.getCachedLocalUser(tokenValue); found {
		return cached, 0, "", ""
	}

	user, expTime, err := g.parseJWT(tokenValue)
	if err != nil {
		if errors.Is(err, jwt.ErrTokenExpired) {
			return authUser{}, http.StatusUnauthorized, "UNAUTHORIZED", "Token expired"
		}
		if strings.Contains(strings.ToLower(err.Error()), "token is expired") {
			return authUser{}, http.StatusUnauthorized, "UNAUTHORIZED", "Token expired"
		}
		if err.Error() == "invalid token subject" {
			return authUser{}, http.StatusUnauthorized, "UNAUTHORIZED", "Invalid token subject"
		}
		return authUser{}, http.StatusUnauthorized, "UNAUTHORIZED", "Invalid token"
	}

	g.setCachedLocalUser(tokenValue, user, expTime)

	shouldSkipRemoteVerify := !g.cfg.authVerifyEnabled ||
		g.cfg.serviceURLs["auth"] == "" ||
		hasAnyPrefix(r.URL.Path, g.cfg.authVerifySkipPrefixes)
	if shouldSkipRemoteVerify {
		return user, 0, "", ""
	}

	valid, verifyErr := g.verifyTokenWithAuthService(r.Context(), tokenValue, traceID)
	if verifyErr == nil && !valid {
		return authUser{}, http.StatusUnauthorized, "UNAUTHORIZED", "Invalid token"
	}

	// Best effort behavior: if auth-service verification is unavailable, fall back to local JWT check.
	return user, 0, "", ""
}

func (g *gateway) parseJWT(tokenValue string) (authUser, time.Time, error) {
	claims := jwt.MapClaims{}
	parser := jwt.NewParser(jwt.WithValidMethods(g.cfg.jwtAlgorithms))
	parsedToken, err := parser.ParseWithClaims(tokenValue, claims, func(_ *jwt.Token) (interface{}, error) {
		return []byte(g.cfg.jwtSecret), nil
	})
	if err != nil {
		return authUser{}, time.Time{}, err
	}
	if !parsedToken.Valid {
		return authUser{}, time.Time{}, errors.New("invalid token")
	}

	userID := firstNonEmpty(
		claimAsString(claims, "sub"),
		claimAsString(claims, "id"),
	)
	if userID == "" {
		return authUser{}, time.Time{}, errors.New("invalid token subject")
	}

	roles := claimAsStringSlice(claims, "roles")
	role := claimAsString(claims, "role")
	if role == "" && len(roles) > 0 {
		role = roles[0]
	}

	user := authUser{
		ID:     userID,
		Role:   role,
		Roles:  roles,
		Scopes: claimAsStringSlice(claims, "scopes"),
	}

	var expTime time.Time
	if expRaw, ok := claims["exp"]; ok {
		if expUnix, ok := toUnixSeconds(expRaw); ok {
			expTime = time.Unix(expUnix, 0).UTC()
		}
	}

	return user, expTime, nil
}

func (g *gateway) verifyTokenWithAuthService(ctx context.Context, tokenValue, traceID string) (bool, error) {
	if valid, found := g.getCachedVerifyResult(tokenValue); found {
		return valid, nil
	}

	verifyURL := strings.TrimRight(g.cfg.serviceURLs["auth"], "/") + "/auth/verify"
	timeout := durationFromMS(g.cfg.authVerifyTimeoutMS, 1200)
	requestCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(requestCtx, http.MethodGet, verifyURL, nil)
	if err != nil {
		return false, err
	}
	req.Header.Set("Authorization", "Bearer "+tokenValue)
	req.Header.Set("x-trace-id", traceID)

	resp, err := g.authClient.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)

	valid := resp.StatusCode == http.StatusOK
	g.setCachedVerifyResult(tokenValue, valid)
	return valid, nil
}

func (g *gateway) getCachedLocalUser(tokenValue string) (authUser, bool) {
	g.localUserCacheMu.RLock()
	entry, ok := g.localUserCache[tokenValue]
	g.localUserCacheMu.RUnlock()
	if !ok {
		return authUser{}, false
	}
	if time.Now().After(entry.expiresAt) {
		g.localUserCacheMu.Lock()
		delete(g.localUserCache, tokenValue)
		g.localUserCacheMu.Unlock()
		return authUser{}, false
	}
	return entry.user, true
}

func (g *gateway) setCachedLocalUser(tokenValue string, user authUser, tokenExp time.Time) {
	ttlMs := g.cfg.authLocalJWTCacheTTLMS
	if ttlMs <= 0 {
		return
	}

	expiresAt := time.Now().Add(time.Duration(ttlMs) * time.Millisecond)
	if !tokenExp.IsZero() {
		tokenBound := tokenExp.Add(-250 * time.Millisecond)
		if tokenBound.Before(expiresAt) {
			expiresAt = tokenBound
		}
	}
	if !expiresAt.After(time.Now()) {
		return
	}

	g.localUserCacheMu.Lock()
	g.localUserCache[tokenValue] = cachedLocalUser{
		user:      user,
		expiresAt: expiresAt,
	}
	g.localUserCacheMu.Unlock()
}

func (g *gateway) getCachedVerifyResult(tokenValue string) (bool, bool) {
	g.verifyCacheMu.RLock()
	entry, ok := g.verifyCache[tokenValue]
	g.verifyCacheMu.RUnlock()
	if !ok {
		return false, false
	}
	if time.Now().After(entry.expiresAt) {
		g.verifyCacheMu.Lock()
		delete(g.verifyCache, tokenValue)
		g.verifyCacheMu.Unlock()
		return false, false
	}
	return entry.valid, true
}

func (g *gateway) setCachedVerifyResult(tokenValue string, valid bool) {
	ttlMs := g.cfg.authVerifyNegativeCacheTTL
	if valid {
		ttlMs = g.cfg.authVerifyCacheTTLMS
	}
	if ttlMs <= 0 {
		return
	}

	g.verifyCacheMu.Lock()
	g.verifyCache[tokenValue] = cachedVerifyResult{
		valid:     valid,
		expiresAt: time.Now().Add(time.Duration(ttlMs) * time.Millisecond),
	}
	g.verifyCacheMu.Unlock()
}

func (g *gateway) handleFraudCheck(w http.ResponseWriter, r *http.Request, traceID string) {
	payload, ok := preparedBodyAsMap(r)
	if !ok {
		payload = map[string]interface{}{}
	}

	required := []string{"user_id", "driver_id", "booking_id", "amount"}
	missing := make([]errorDetail, 0, len(required))
	for _, field := range required {
		value, ok := payload[field]
		if !ok || value == nil {
			missing = append(missing, errorDetail{
				Path:    "body." + field,
				Message: "is required",
			})
			continue
		}
		if s, ok := value.(string); ok && strings.TrimSpace(s) == "" {
			missing = append(missing, errorDetail{
				Path:    "body." + field,
				Message: "is required",
			})
		}
	}

	if len(missing) > 0 {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "missing required fields", traceID, missing)
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"data": map[string]interface{}{
			"decision":   "allow",
			"risk_score": 0,
		},
		"traceId": traceID,
	})
}

func (g *gateway) handleProxy(w http.ResponseWriter, r *http.Request, domain string, user authUser) {
	traceID, _ := r.Context().Value(contextTraceIDKey).(string)
	requestID, _ := r.Context().Value(contextRequestIDKey).(string)

	baseURL, ok := g.cfg.serviceURLs[domain]
	if !ok || strings.TrimSpace(baseURL) == "" {
		writeError(w, http.StatusNotFound, "NOT_FOUND", fmt.Sprintf("Unknown domain: %s", domain), traceID, nil)
		return
	}

	targetURL, err := buildTargetURL(r, domain, baseURL)
	if err != nil {
		writeError(w, http.StatusBadGateway, "UPSTREAM_UNAVAILABLE", "Upstream unavailable", traceID, nil)
		return
	}

	method := strings.ToUpper(r.Method)
	var bodyBytes []byte
	if method != http.MethodGet && method != http.MethodHead {
		if prepared, found := preparedBodyFromContext(r); found {
			bodyBytes = prepared.raw
		} else {
			bodyBytes, err = io.ReadAll(io.LimitReader(r.Body, 4<<20))
			if err != nil {
				writeError(w, http.StatusBadRequest, "INVALID_BODY", "Invalid request body", traceID, nil)
				return
			}
		}
	}

	attempts := 1
	if method == http.MethodGet {
		attempts = 2
	}

	timeout := resolveDomainTimeout(domain, g.cfg.proxyTimeoutMS)
	var lastErr error
	operation := "proxy_" + strings.ToLower(method)

	if g.parity != nil {
		allowed, retryAfterMS := g.parity.circuitBreaker.allow(domain)
		if !allowed {
			writeError(
				w,
				http.StatusServiceUnavailable,
				"UPSTREAM_CIRCUIT_OPEN",
				"Upstream temporarily unavailable (circuit open)",
				traceID,
				[]errorDetail{
					{
						Path:    "proxy",
						Message: fmt.Sprintf("retry_after_ms=%d", retryAfterMS),
					},
				},
			)
			return
		}
	}

	for attempt := 0; attempt < attempts; attempt++ {
		attemptName := "initial"
		if attempt > 0 {
			attemptName = "retry"
		}
		status, respHeaders, respBody, callErr := g.callUpstream(r.Context(), callUpstreamInput{
			method:         method,
			targetURL:      targetURL,
			body:           bodyBytes,
			headers:        buildUpstreamHeaders(r.Context(), r, user, traceID, requestID, g.cfg.internalAPIKey),
			timeout:        timeout,
			dependencyName: domain,
			operation:      operation,
			attempt:        attemptName,
		})
		if callErr == nil {
			if g.parity != nil {
				if status < http.StatusInternalServerError {
					g.parity.circuitBreaker.markSuccess(domain)
				} else {
					g.parity.circuitBreaker.markFailure(domain)
				}
			}
			copyResponseHeaders(w.Header(), respHeaders)
			w.WriteHeader(status)
			_, _ = w.Write(respBody)
			return
		}

		if g.parity != nil {
			g.parity.circuitBreaker.markFailure(domain)
		}
		lastErr = callErr
		if attempt+1 < attempts {
			if g.parity != nil {
				allowed, _ := g.parity.circuitBreaker.allow(domain)
				if !allowed {
					writeError(
						w,
						http.StatusServiceUnavailable,
						"UPSTREAM_CIRCUIT_OPEN",
						"Upstream temporarily unavailable (circuit open)",
						traceID,
						nil,
					)
					return
				}
			}
			time.Sleep(durationFromMS(g.cfg.proxyRetryBackoffMS, defaultRetryBackoffMS))
			continue
		}
	}

	if isTimeoutError(lastErr) {
		writeError(w, http.StatusGatewayTimeout, "UPSTREAM_TIMEOUT", "Upstream request timed out", traceID, nil)
		return
	}
	writeError(w, http.StatusBadGateway, "UPSTREAM_UNAVAILABLE", "Upstream unavailable", traceID, nil)
}

type callUpstreamInput struct {
	method         string
	targetURL      string
	body           []byte
	headers        map[string]string
	timeout        time.Duration
	dependencyName string
	operation      string
	attempt        string
}

func (g *gateway) callUpstream(parentCtx context.Context, input callUpstreamInput) (int, http.Header, []byte, error) {
	ctx, cancel := context.WithTimeout(parentCtx, input.timeout)
	defer cancel()
	startedAt := time.Now()

	var bodyReader io.Reader
	if len(input.body) > 0 {
		bodyReader = bytes.NewReader(input.body)
	}

	req, err := http.NewRequestWithContext(ctx, input.method, input.targetURL, bodyReader)
	if err != nil {
		return 0, nil, nil, err
	}
	for key, value := range input.headers {
		if value == "" {
			continue
		}
		req.Header.Set(key, value)
	}

	resp, err := g.proxyClient.Do(req)
	if err != nil {
		if g.parity != nil && g.parity.telemetryProvider != nil {
			durationMs := float64(time.Since(startedAt).Nanoseconds()) / 1_000_000
			g.parity.telemetryProvider.RecordDependency(
				parentCtx,
				input.dependencyName,
				input.operation,
				input.attempt,
				0,
				durationMs,
				err,
			)
		}
		return 0, nil, nil, err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		if g.parity != nil && g.parity.telemetryProvider != nil {
			durationMs := float64(time.Since(startedAt).Nanoseconds()) / 1_000_000
			g.parity.telemetryProvider.RecordDependency(
				parentCtx,
				input.dependencyName,
				input.operation,
				input.attempt,
				resp.StatusCode,
				durationMs,
				err,
			)
		}
		return 0, nil, nil, err
	}
	if g.parity != nil && g.parity.telemetryProvider != nil {
		durationMs := float64(time.Since(startedAt).Nanoseconds()) / 1_000_000
		g.parity.telemetryProvider.RecordDependency(
			parentCtx,
			input.dependencyName,
			input.operation,
			input.attempt,
			resp.StatusCode,
			durationMs,
			nil,
		)
	}
	return resp.StatusCode, resp.Header.Clone(), respBody, nil
}

func buildTargetURL(r *http.Request, domain, baseURL string) (string, error) {
	const (
		authDomainPrefix = "/auth"
		notiDomainPrefix = "/v1/notifications"
	)
	authHealth := map[string]string{
		"/v1/auth/health":  "/health",
		"/v1/auth/healthz": "/healthz",
		"/v1/auth/readyz":  "/readyz",
	}

	originalPath := r.URL.Path
	originalQuery := r.URL.RawQuery
	originalURI := originalPath
	if originalQuery != "" {
		originalURI = originalURI + "?" + originalQuery
	}

	if domain == "auth" {
		if mapped, ok := authHealth[originalPath]; ok {
			if originalQuery != "" {
				return resolveRelativeURL(baseURL, mapped+"?"+originalQuery)
			}
			return resolveRelativeURL(baseURL, mapped)
		}
	}

	if domain == "notifications" && strings.HasPrefix(originalPath, "/v1/notifications/users") {
		suffix := strings.TrimPrefix(originalPath, notiDomainPrefix)
		mappedPath := "/v1" + suffix
		if originalQuery != "" {
			mappedPath += "?" + originalQuery
		}
		return resolveRelativeURL(baseURL, mappedPath)
	}

	if domain == "auth" && strings.HasPrefix(originalPath, "/v1/auth") {
		suffix := strings.TrimPrefix(originalPath, "/v1/auth")
		mappedPath := authDomainPrefix + suffix
		if mappedPath == "" {
			mappedPath = authDomainPrefix
		}
		if originalQuery != "" {
			mappedPath += "?" + originalQuery
		}
		return resolveRelativeURL(baseURL, mappedPath)
	}

	return resolveRelativeURL(baseURL, originalURI)
}

func resolveRelativeURL(base, relative string) (string, error) {
	baseURL, err := url.Parse(base)
	if err != nil {
		return "", err
	}
	relURL, err := url.Parse(relative)
	if err != nil {
		return "", err
	}
	return baseURL.ResolveReference(relURL).String(), nil
}

func buildUpstreamHeaders(ctx context.Context, r *http.Request, user authUser, traceID, requestID, internalAPIKey string) map[string]string {
	headers := map[string]string{
		"x-trace-id":   traceID,
		"x-request-id": requestID,
	}

	if authHeader := strings.TrimSpace(r.Header.Get("Authorization")); authHeader != "" {
		headers["authorization"] = authHeader
	}
	if internalAPIKey != "" {
		headers["x-internal-key"] = internalAPIKey
	}
	if idempotencyKey := strings.TrimSpace(r.Header.Get("Idempotency-Key")); idempotencyKey != "" {
		headers["idempotency-key"] = idempotencyKey
	}
	if contentType := strings.TrimSpace(r.Header.Get("Content-Type")); contentType != "" {
		headers["content-type"] = contentType
	}
	if loadHint := strings.TrimSpace(r.Header.Get("X-Load-Test")); loadHint != "" {
		headers["x-load-test"] = loadHint
	}
	if fastPath := strings.TrimSpace(r.Header.Get("X-Booking-Fast-Path")); fastPath != "" {
		headers["x-booking-fast-path"] = fastPath
	}

	if user.ID != "" {
		headers["x-user-id"] = user.ID
	}
	if user.Role != "" {
		headers["x-user-role"] = user.Role
	}
	if len(user.Roles) > 0 {
		headers["x-user-roles"] = strings.Join(user.Roles, ",")
	}
	if len(user.Scopes) > 0 {
		headers["x-user-scopes"] = strings.Join(user.Scopes, ",")
	}
	injectTraceContext(ctx, headers)

	return headers
}

func copyResponseHeaders(dst, src http.Header) {
	hopHeaders := map[string]struct{}{
		"connection":          {},
		"proxy-connection":    {},
		"keep-alive":          {},
		"proxy-authenticate":  {},
		"proxy-authorization": {},
		"te":                  {},
		"trailer":             {},
		"transfer-encoding":   {},
		"upgrade":             {},
	}

	for key, values := range src {
		if _, skip := hopHeaders[strings.ToLower(key)]; skip {
			continue
		}
		dst.Del(key)
		for _, value := range values {
			dst.Add(key, value)
		}
	}
}

func writeError(w http.ResponseWriter, status int, code, message, traceID string, details []errorDetail) {
	if details == nil {
		details = []errorDetail{}
	}
	body := errorBody{TraceID: traceID}
	body.Error.Code = code
	body.Error.Message = message
	body.Error.Details = details
	writeJSON(w, status, body)
}

func writeJSON(w http.ResponseWriter, status int, value interface{}) {
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func parseBearerToken(headerValue string) (string, bool) {
	parts := strings.SplitN(headerValue, " ", 2)
	if len(parts) != 2 {
		return "", false
	}
	if !strings.EqualFold(parts[0], "Bearer") {
		return "", false
	}
	tokenValue := strings.TrimSpace(parts[1])
	if tokenValue == "" {
		return "", false
	}
	return tokenValue, true
}

func domainFromPath(path string) (string, bool) {
	if !strings.HasPrefix(path, "/v1/") {
		return "", false
	}
	rest := strings.TrimPrefix(path, "/v1/")
	if rest == "" {
		return "", false
	}
	parts := strings.SplitN(rest, "/", 2)
	domain := strings.TrimSpace(parts[0])
	if domain == "" {
		return "", false
	}
	return domain, true
}

func chooseID(value string) string {
	value = strings.TrimSpace(value)
	if value != "" {
		return value
	}
	return randomHexID(16)
}

func randomHexID(size int) string {
	if size <= 0 {
		size = 16
	}
	buf := make([]byte, size)
	if _, err := rand.Read(buf); err != nil {
		now := time.Now().UnixNano()
		return strconv.FormatInt(now, 16)
	}
	return hex.EncodeToString(buf)
}

func resolveDomainTimeout(domain string, defaultMs int) time.Duration {
	envKey := "PROXY_TIMEOUT_MS_" + strings.ToUpper(domain)
	if domainTimeout := parsePositiveInt(os.Getenv(envKey), 0); domainTimeout > 0 {
		return time.Duration(domainTimeout) * time.Millisecond
	}
	return durationFromMS(defaultMs, defaultProxyTimeoutMS)
}

func isTimeoutError(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return true
	}
	return false
}

func hasAnyPrefix(path string, prefixes []string) bool {
	for _, prefix := range prefixes {
		if prefix != "" && strings.HasPrefix(path, prefix) {
			return true
		}
	}
	return false
}

func claimAsString(claims jwt.MapClaims, key string) string {
	raw, ok := claims[key]
	if !ok || raw == nil {
		return ""
	}
	switch value := raw.(type) {
	case string:
		return strings.TrimSpace(value)
	case fmt.Stringer:
		return strings.TrimSpace(value.String())
	case float64:
		return strconv.FormatInt(int64(value), 10)
	case json.Number:
		return value.String()
	default:
		return strings.TrimSpace(fmt.Sprint(value))
	}
}

func claimAsStringSlice(claims jwt.MapClaims, key string) []string {
	raw, ok := claims[key]
	if !ok || raw == nil {
		return nil
	}
	list, ok := raw.([]interface{})
	if !ok {
		return nil
	}
	out := make([]string, 0, len(list))
	for _, item := range list {
		text := strings.TrimSpace(fmt.Sprint(item))
		if text != "" {
			out = append(out, text)
		}
	}
	return out
}

func toUnixSeconds(value interface{}) (int64, bool) {
	switch v := value.(type) {
	case float64:
		return int64(v), true
	case float32:
		return int64(v), true
	case int64:
		return v, true
	case int32:
		return int64(v), true
	case int:
		return int64(v), true
	case json.Number:
		parsed, err := v.Int64()
		return parsed, err == nil
	case string:
		parsed, err := strconv.ParseInt(v, 10, 64)
		return parsed, err == nil
	default:
		return 0, false
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func durationFromMS(value int, fallback int) time.Duration {
	if value <= 0 {
		value = fallback
	}
	return time.Duration(value) * time.Millisecond
}

func buildProxyHTTPClient(maxSockets int) *http.Client {
	if maxSockets <= 0 {
		maxSockets = defaultKeepaliveMaxSockets
	}
	transport := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		DialContext:           (&net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		MaxIdleConns:          maxSockets * 2,
		MaxIdleConnsPerHost:   maxSockets,
		MaxConnsPerHost:       maxSockets * 2,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   5 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		ForceAttemptHTTP2:     true,
	}
	return &http.Client{Transport: transport}
}

func buildAuthHTTPClient() *http.Client {
	maxSockets := parsePositiveInt(os.Getenv("AUTH_VERIFY_HTTP_MAX_SOCKETS"), 512)
	transport := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		DialContext:           (&net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		MaxIdleConns:          maxSockets,
		MaxIdleConnsPerHost:   maxSockets,
		MaxConnsPerHost:       maxSockets,
		IdleConnTimeout:       60 * time.Second,
		TLSHandshakeTimeout:   5 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		ForceAttemptHTTP2:     true,
	}
	return &http.Client{Transport: transport}
}

func loadConfig() config {
	serviceURLs := map[string]string{
		"rides":         envOrDefault("RIDE_SERVICE_URL", "http://localhost:3005"),
		"users":         envOrDefault("USER_SERVICE_URL", "http://localhost:3002"),
		"driver":        envOrDefault("DRIVER_SERVICE_URL", "http://localhost:3011"),
		"drivers":       envOrDefault("DRIVER_SERVICE_URL", "http://localhost:3011"),
		"internal":      envOrDefault("DRIVER_SERVICE_URL", "http://localhost:3011"),
		"admin":         envOrDefault("DRIVER_SERVICE_URL", "http://localhost:3011"),
		"bookings":      envOrDefault("BOOKING_SERVICE_URL", "http://localhost:3003"),
		"eta":           envOrDefault("ETA_SERVICE_URL", "http://localhost:3012"),
		"places":        envOrDefault("PLACES_SERVICE_URL", "http://localhost:3014"),
		"pricing":       envOrDefault("PRICING_SERVICE_URL", "http://localhost:3006"),
		"ai":            envOrDefault("AI_SERVICE_URL", "http://localhost:3013"),
		"payments":      envOrDefault("PAYMENT_SERVICE_URL", "http://localhost:3007"),
		"reviews":       envOrDefault("REVIEW_SERVICE_URL", "http://localhost:3009"),
		"auth":          envOrDefault("AUTH_SERVICE_URL", "http://localhost:4001"),
		"notifications": envOrDefault("NOTIFICATION_SERVICE_URL", "http://localhost:3010"),
	}

	return config{
		serviceName: envOrDefault("SERVICE_NAME", "gateway"),
		port:        parsePositiveInt(os.Getenv("PORT"), defaultPort),
		https: httpsConfig{
			enabled:  parseBool(os.Getenv("GATEWAY_HTTPS_ENABLED"), true),
			port:     parsePositiveInt(os.Getenv("HTTPS_PORT"), 3443),
			certPath: envOrDefault("HTTPS_CERT_PATH", "/app/src/certs/dev-gateway.crt"),
			keyPath:  envOrDefault("HTTPS_KEY_PATH", "/app/src/certs/dev-gateway.key"),
		},
		corsOrigin: envOrDefault("CORS_ORIGIN", ""),

		jwtSecret:     envOrDefault("JWT_SECRET", ""),
		jwtAlgorithms: parseCSV(envOrDefault("JWT_ALGORITHMS", "HS256")),

		internalAPIKey: envOrDefault("INTERNAL_API_KEY", ""),

		proxyTimeoutMS:        parsePositiveInt(os.Getenv("PROXY_TIMEOUT_MS"), defaultProxyTimeoutMS),
		proxyRetryBackoffMS:   parsePositiveInt(os.Getenv("PROXY_RETRY_BACKOFF_MS"), defaultRetryBackoffMS),
		proxyKeepaliveSockets: parsePositiveInt(os.Getenv("PROXY_KEEPALIVE_MAX_SOCKETS"), defaultKeepaliveMaxSockets),

		authVerifyEnabled:          parseBool(envOrDefault("AUTH_VERIFY_ENABLED", "true"), true),
		authVerifyTimeoutMS:        parsePositiveInt(os.Getenv("AUTH_VERIFY_TIMEOUT_MS"), 1200),
		authVerifyCacheTTLMS:       parsePositiveInt(os.Getenv("AUTH_VERIFY_CACHE_TTL_MS"), 15000),
		authVerifyNegativeCacheTTL: parsePositiveInt(os.Getenv("AUTH_VERIFY_NEGATIVE_CACHE_TTL_MS"), 3000),
		authVerifySkipPrefixes:     parseCSV(envOrDefault("AUTH_VERIFY_SKIP_PREFIXES", "/v1/payments")),
		authLocalJWTCacheTTLMS:     parsePositiveInt(os.Getenv("AUTH_LOCAL_JWT_CACHE_TTL_MS"), 5000),

		authPublicDomains: toSet(parseCSV(envOrDefault("AUTH_PUBLIC_DOMAINS", "auth"))),
		authPublicPaths: toSet(parseCSV(
			envOrDefault("AUTH_PUBLIC_PATHS", "/health,/healthz,/readyz,/webhooks/payos"),
		)),

		serviceURLs: serviceURLs,
	}
}

func parseCSV(raw string) []string {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	result := make([]string, 0, len(parts))
	for _, item := range parts {
		trimmed := strings.TrimSpace(item)
		if trimmed != "" {
			result = append(result, trimmed)
		}
	}
	return result
}

func toSet(values []string) map[string]struct{} {
	set := make(map[string]struct{}, len(values))
	for _, value := range values {
		trimmed := strings.TrimSpace(value)
		if trimmed != "" {
			set[trimmed] = struct{}{}
		}
	}
	return set
}

func parseBool(raw string, fallback bool) bool {
	normalized := strings.TrimSpace(strings.ToLower(raw))
	switch normalized {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return fallback
	}
}

func parsePositiveInt(raw string, fallback int) int {
	value, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || value <= 0 {
		return fallback
	}
	return value
}

func envOrDefault(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}
