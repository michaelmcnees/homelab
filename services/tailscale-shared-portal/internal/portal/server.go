package portal

import (
	"context"
	"html/template"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"path"
	"strings"
	"time"
)

type Server struct {
	cfg      *Config
	resolver IdentityResolver
	logger   *slog.Logger
}

func NewServer(cfg *Config, resolver IdentityResolver, logger *slog.Logger) http.Handler {
	if logger == nil {
		logger = slog.Default()
	}
	return &Server{
		cfg:      cfg,
		resolver: resolver,
		logger:   logger,
	}
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	identity, resolved, status := s.resolveIdentity(r.Context(), r.RemoteAddr)
	if !resolved {
		s.writeError(w, r, identity, "", "identity_error", status, started)
		return
	}

	switch {
	case r.URL.Path == "/":
		s.handleDashboard(w, r, identity, started)
	case r.URL.Path == "/_portal/style.css":
		s.handleStyle(w, r, identity, started)
	case strings.HasPrefix(r.URL.Path, "/app/"):
		s.handleApp(w, r, identity, started)
	default:
		s.writeError(w, r, identity, "", "not_found", http.StatusNotFound, started)
	}
}

func (s *Server) resolveIdentity(ctx context.Context, remoteAddr string) (Identity, bool, int) {
	identity, err := s.resolver.Resolve(ctx, remoteAddr)
	if err != nil {
		return Identity{RemoteAddr: remoteAddr}, false, http.StatusServiceUnavailable
	}
	if !s.cfg.KnownIdentity(identity) {
		return identity, false, http.StatusForbidden
	}
	return identity, true, http.StatusOK
}

func (s *Server) handleDashboard(w http.ResponseWriter, r *http.Request, identity Identity, started time.Time) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		s.writeError(w, r, identity, "", "method_not_allowed", http.StatusMethodNotAllowed, started)
		return
	}

	apps := s.cfg.AppsForIdentity(identity)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	if r.Method != http.MethodHead {
		_ = dashboardTemplate.Execute(w, struct {
			Identity Identity
			Apps     []App
		}{
			Identity: identity,
			Apps:     apps,
		})
	}
	s.logDecision(r, identity, "", "dashboard", http.StatusOK, started)
}

func (s *Server) handleStyle(w http.ResponseWriter, r *http.Request, identity Identity, started time.Time) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		s.writeError(w, r, identity, "", "method_not_allowed", http.StatusMethodNotAllowed, started)
		return
	}
	w.Header().Set("Content-Type", "text/css; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=300")
	w.WriteHeader(http.StatusOK)
	if r.Method != http.MethodHead {
		_, _ = w.Write([]byte(portalCSS))
	}
	s.logDecision(r, identity, "", "asset", http.StatusOK, started)
}

func (s *Server) handleApp(w http.ResponseWriter, r *http.Request, identity Identity, started time.Time) {
	name, ok := appNameFromPath(r.URL.Path)
	if !ok {
		s.writeError(w, r, identity, "", "not_found", http.StatusNotFound, started)
		return
	}

	app, ok := s.cfg.AppForIdentity(identity, name)
	if !ok {
		s.writeError(w, r, identity, name, "app_denied", http.StatusNotFound, started)
		return
	}

	if r.URL.Path == app.Path {
		http.Redirect(w, r, app.Path+"/", http.StatusMovedPermanently)
		s.logDecision(r, identity, name, "redirect", http.StatusMovedPermanently, started)
		return
	}

	target, err := url.Parse(app.Upstream)
	if err != nil {
		s.writeError(w, r, identity, name, "bad_upstream", http.StatusBadGateway, started)
		return
	}

	proxy := httputil.NewSingleHostReverseProxy(target)
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		req.URL.Path = stripAppPrefix(r.URL.Path, app.Path)
		req.URL.RawPath = ""
		req.URL.RawQuery = r.URL.RawQuery
		req.Header.Set("X-Forwarded-Prefix", app.Path)
		req.Header.Set("X-Forwarded-Host", r.Host)
		req.Host = target.Host
	}
	proxy.ErrorHandler = func(rw http.ResponseWriter, req *http.Request, err error) {
		s.writeError(rw, r, identity, name, "upstream_error", http.StatusBadGateway, started)
	}
	proxy.ModifyResponse = func(resp *http.Response) error {
		s.logDecision(r, identity, name, "proxy", resp.StatusCode, started)
		return nil
	}
	proxy.ServeHTTP(w, r)
}

func (s *Server) writeError(w http.ResponseWriter, r *http.Request, identity Identity, app, decision string, status int, started time.Time) {
	http.Error(w, http.StatusText(status), status)
	s.logDecision(r, identity, app, decision, status, started)
}

func (s *Server) logDecision(r *http.Request, identity Identity, app, decision string, status int, started time.Time) {
	s.logger.Info("portal request",
		"identity", identity.LoginName,
		"node", identity.NodeName,
		"node_id", identity.NodeID,
		"remote_addr", identity.RemoteAddr,
		"app", app,
		"method", r.Method,
		"path", r.URL.Path,
		"decision", decision,
		"status", status,
		"duration_ms", time.Since(started).Milliseconds(),
	)
}

func appNameFromPath(requestPath string) (string, bool) {
	trimmed := strings.TrimPrefix(requestPath, "/app/")
	if trimmed == "" {
		return "", false
	}
	name, _, _ := strings.Cut(trimmed, "/")
	if name == "" || name == "." || name == ".." {
		return "", false
	}
	return name, true
}

func stripAppPrefix(requestPath, appPath string) string {
	stripped := strings.TrimPrefix(requestPath, appPath)
	if stripped == "" || stripped == "/" {
		return "/"
	}
	if !strings.HasPrefix(stripped, "/") {
		stripped = "/" + stripped
	}
	return path.Clean(stripped)
}

var dashboardTemplate = template.Must(template.New("dashboard").Parse(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Shared Portal</title>
  <link rel="stylesheet" href="/_portal/style.css">
</head>
<body>
  <main>
    <header>
      <p class="eyebrow">Tailscale shared access</p>
      <h1>Shared Portal</h1>
      <p class="identity">{{if .Identity.LoginName}}{{.Identity.LoginName}}{{else}}{{.Identity.NodeName}}{{end}}</p>
    </header>
    <section class="apps" aria-label="Allowed apps">
      {{range .Apps}}
      <a class="app" href="{{.Path}}/">
        <span>{{.Label}}</span>
      </a>
      {{end}}
    </section>
  </main>
</body>
</html>
`))

const portalCSS = `:root {
  color-scheme: light dark;
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  background: #f6f7f9;
  color: #181b20;
}

body {
  margin: 0;
}

main {
  max-width: 960px;
  margin: 0 auto;
  padding: 48px 20px;
}

header {
  margin-bottom: 28px;
}

.eyebrow {
  color: #56616f;
  font-size: 0.84rem;
  font-weight: 700;
  letter-spacing: 0;
  margin: 0 0 8px;
  text-transform: uppercase;
}

h1 {
  font-size: clamp(2rem, 5vw, 4rem);
  line-height: 1;
  margin: 0;
}

.identity {
  color: #56616f;
  margin: 12px 0 0;
}

.apps {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
  gap: 12px;
}

.app {
  align-items: center;
  background: #ffffff;
  border: 1px solid #d9dde3;
  border-radius: 8px;
  color: inherit;
  display: flex;
  font-weight: 750;
  min-height: 72px;
  padding: 18px;
  text-decoration: none;
}

.app:hover,
.app:focus-visible {
  border-color: #2f6feb;
  outline: 2px solid transparent;
}

@media (prefers-color-scheme: dark) {
  :root {
    background: #111316;
    color: #f3f5f7;
  }

  .eyebrow,
  .identity {
    color: #aab3bf;
  }

  .app {
    background: #191d22;
    border-color: #303842;
  }
}
`
