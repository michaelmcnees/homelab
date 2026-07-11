package portal

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type staticIdentity struct {
	identity Identity
	err      error
}

func (s staticIdentity) Resolve(ctx context.Context, remoteAddr string) (Identity, error) {
	if s.err != nil {
		return Identity{}, s.err
	}
	s.identity.RemoteAddr = remoteAddr
	return s.identity, nil
}

func TestDashboardListsOnlyAllowedApps(t *testing.T) {
	handler := NewServer(testConfig(t), staticIdentity{identity: Identity{LoginName: "mike@kenway.me"}}, discardLogger())
	req := httptest.NewRequest(http.MethodGet, "http://portal.mcnees.me/", nil)
	req.RemoteAddr = "100.64.0.10:50000"
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, "/app/sonarr/") || !strings.Contains(body, "Sonarr") {
		t.Fatalf("dashboard missing sonarr: %s", body)
	}
	if strings.Contains(body, "Lidarr") {
		t.Fatalf("dashboard leaked unauthorized app: %s", body)
	}
}

func TestDashboardRejectsUnknownIdentity(t *testing.T) {
	handler := NewServer(testConfig(t), staticIdentity{identity: Identity{LoginName: "stranger@example.com"}}, discardLogger())
	req := httptest.NewRequest(http.MethodGet, "http://portal.mcnees.me/", nil)
	req.RemoteAddr = "100.64.0.10:50000"
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestIdentityFailureReturnsServiceUnavailable(t *testing.T) {
	handler := NewServer(testConfig(t), staticIdentity{err: errors.New("whois failed")}, discardLogger())
	req := httptest.NewRequest(http.MethodGet, "http://portal.mcnees.me/", nil)
	req.RemoteAddr = "100.64.0.10:50000"
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestAppWithoutTrailingSlashRedirects(t *testing.T) {
	handler := NewServer(testConfig(t), staticIdentity{identity: Identity{LoginName: "mike@kenway.me"}}, discardLogger())
	req := httptest.NewRequest(http.MethodGet, "http://portal.mcnees.me/app/sonarr", nil)
	req.RemoteAddr = "100.64.0.10:50000"
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusMovedPermanently {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	if got, want := rec.Header().Get("Location"), "/app/sonarr/"; got != want {
		t.Fatalf("Location=%q want %q", got, want)
	}
}

func TestAuthorizedProxyStripsPrefix(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v3/system/status" {
			t.Fatalf("path=%q", r.URL.Path)
		}
		if r.URL.RawQuery != "includeHealth=true" {
			t.Fatalf("query=%q", r.URL.RawQuery)
		}
		if r.Header.Get("X-Forwarded-Prefix") != "/app/sonarr" {
			t.Fatalf("missing forwarded prefix")
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(`{"app":"sonarr"}`))
	}))
	defer upstream.Close()

	cfg := testConfigWithUpstream(t, upstream.URL)
	handler := NewServer(cfg, staticIdentity{identity: Identity{LoginName: "mike@kenway.me"}}, discardLogger())
	req := httptest.NewRequest(http.MethodGet, "http://portal.mcnees.me/app/sonarr/api/v3/system/status?includeHealth=true", nil)
	req.RemoteAddr = "100.64.0.10:50000"
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusAccepted {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	if got := rec.Body.String(); got != `{"app":"sonarr"}` {
		t.Fatalf("body=%q", got)
	}
}

func TestUnauthorizedAppPathReturnsNotFound(t *testing.T) {
	handler := NewServer(testConfig(t), staticIdentity{identity: Identity{LoginName: "mike@kenway.me"}}, discardLogger())
	req := httptest.NewRequest(http.MethodGet, "http://portal.mcnees.me/app/lidarr/", nil)
	req.RemoteAddr = "100.64.0.10:50000"
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestUpstreamFailureReturnsBadGateway(t *testing.T) {
	cfg := testConfigWithUpstream(t, "http://127.0.0.1:1")
	handler := NewServer(cfg, staticIdentity{identity: Identity{LoginName: "mike@kenway.me"}}, discardLogger())
	req := httptest.NewRequest(http.MethodGet, "http://portal.mcnees.me/app/sonarr/api", nil)
	req.RemoteAddr = "100.64.0.10:50000"
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
}

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func testConfig(t *testing.T) *Config {
	t.Helper()
	cfg, err := LoadConfig(strings.NewReader(`
users:
  mike@kenway.me:
    displayName: Mike
    apps: [sonarr, radarr]
apps:
  sonarr:
    label: Sonarr
    path: /app/sonarr
    upstream: http://sonarr.media.svc.cluster.local:8989
  radarr:
    label: Radarr
    path: /app/radarr
    upstream: http://radarr.media.svc.cluster.local:7878
  lidarr:
    label: Lidarr
    path: /app/lidarr
    upstream: http://lidarr.media.svc.cluster.local:8686
`))
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

func testConfigWithUpstream(t *testing.T, upstream string) *Config {
	t.Helper()
	cfg, err := LoadConfig(strings.NewReader(`
users:
  mike@kenway.me:
    displayName: Mike
    apps: [sonarr]
apps:
  sonarr:
    label: Sonarr
    path: /app/sonarr
    upstream: ` + upstream + `
`))
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}
