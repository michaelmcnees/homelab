package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/michaelmcnees/homelab/services/tailscale-shared-portal/internal/portal"
	"tailscale.com/client/local"
	"tailscale.com/tsnet"
)

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	cfg, err := loadPortalConfig(env("PORTAL_CONFIG", "/etc/shared-portal/config.yaml"))
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	healthServer := &http.Server{
		Addr:              env("PORTAL_HEALTH_ADDR", ":8080"),
		Handler:           healthHandler(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		logger.Info("starting health listener", "addr", healthServer.Addr)
		if err := healthServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("health listener failed", "error", err)
			stop()
		}
	}()

	ts := &tsnet.Server{
		Hostname:      env("TSNET_HOSTNAME", "shared-portal"),
		Dir:           env("TSNET_STATE_DIR", "/var/lib/shared-portal/tsnet"),
		AuthKey:       os.Getenv("TS_AUTHKEY"),
		AdvertiseTags: splitCSV(os.Getenv("TSNET_ADVERTISE_TAGS")),
		UserLogf: func(format string, args ...any) {
			logger.Info("tsnet", "message", fmt.Sprintf(format, args...))
		},
	}
	defer ts.Close()

	localClient, err := ts.LocalClient()
	if err != nil {
		return fmt.Errorf("start tsnet local client: %w", err)
	}

	app := portal.NewServer(cfg, tsnetIdentityResolver{client: localClient}, logger)
	tlsAvailable := filesExist(env("PORTAL_TLS_CERT", "/tls/tls.crt"), env("PORTAL_TLS_KEY", "/tls/tls.key"))

	httpListener, err := ts.Listen("tcp", env("PORTAL_HTTP_ADDR", ":80"))
	if err != nil {
		return fmt.Errorf("listen http over tailscale: %w", err)
	}
	defer httpListener.Close()

	httpHandler := app
	if tlsAvailable {
		httpHandler = redirectToHTTPS()
	}
	httpServer := &http.Server{
		Handler:           httpHandler,
		ReadHeaderTimeout: 15 * time.Second,
	}
	go func() {
		logger.Info("starting tailscale http listener", "addr", httpListener.Addr(), "redirect_https", tlsAvailable)
		if err := httpServer.Serve(httpListener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("tailscale http listener failed", "error", err)
			stop()
		}
	}()

	var httpsServer *http.Server
	if tlsAvailable {
		httpsListener, err := ts.Listen("tcp", env("PORTAL_HTTPS_ADDR", ":443"))
		if err != nil {
			return fmt.Errorf("listen https over tailscale: %w", err)
		}
		defer httpsListener.Close()

		certFile := env("PORTAL_TLS_CERT", "/tls/tls.crt")
		keyFile := env("PORTAL_TLS_KEY", "/tls/tls.key")
		tlsConfig := &tls.Config{
			MinVersion: tls.VersionTLS12,
		}
		httpsServer = &http.Server{
			Handler:           app,
			ReadHeaderTimeout: 15 * time.Second,
			TLSConfig:         tlsConfig,
		}
		go func() {
			logger.Info("starting tailscale https listener", "addr", httpsListener.Addr())
			if err := httpsServer.ServeTLS(httpsListener, certFile, keyFile); err != nil && !errors.Is(err, http.ErrServerClosed) {
				logger.Error("tailscale https listener failed", "error", err)
				stop()
			}
		}()
	} else {
		logger.Warn("tls certificate files not found; serving http over tailscale only")
	}

	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	_ = healthServer.Shutdown(shutdownCtx)
	_ = httpServer.Shutdown(shutdownCtx)
	if httpsServer != nil {
		_ = httpsServer.Shutdown(shutdownCtx)
	}
	return nil
}

func loadPortalConfig(path string) (*portal.Config, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open portal config: %w", err)
	}
	defer file.Close()

	cfg, err := portal.LoadConfig(file)
	if err != nil {
		return nil, fmt.Errorf("load portal config: %w", err)
	}
	return cfg, nil
}

type tsnetIdentityResolver struct {
	client *local.Client
}

func (r tsnetIdentityResolver) Resolve(ctx context.Context, remoteAddr string) (portal.Identity, error) {
	who, err := r.client.WhoIs(ctx, remoteAddr)
	if err != nil {
		return portal.Identity{RemoteAddr: remoteAddr}, err
	}

	identity := portal.Identity{RemoteAddr: remoteAddr}
	if who.UserProfile != nil {
		identity.LoginName = who.UserProfile.LoginName
	}
	if who.Node != nil {
		identity.NodeName = strings.TrimSuffix(who.Node.ComputedName, ".")
		if who.Node.StableID != "" {
			identity.NodeID = string(who.Node.StableID)
		} else if !who.Node.ID.IsZero() {
			identity.NodeID = who.Node.ID.String()
		}
	}
	return identity, nil
}

func healthHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})
	return mux
}

func redirectToHTTPS() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.Host)
		if err != nil {
			host = r.Host
		}
		target := "https://" + host + r.URL.RequestURI()
		http.Redirect(w, r, target, http.StatusMovedPermanently)
	})
}

func filesExist(paths ...string) bool {
	for _, path := range paths {
		if path == "" {
			return false
		}
		info, err := os.Stat(filepath.Clean(path))
		if err != nil || info.IsDir() {
			return false
		}
	}
	return true
}

func splitCSV(value string) []string {
	parts := strings.Split(value, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}

func env(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}
