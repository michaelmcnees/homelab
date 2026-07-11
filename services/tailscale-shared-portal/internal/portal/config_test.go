package portal

import (
	"strings"
	"testing"
)

func TestLoadConfigSortsAllowedAppsForIdentity(t *testing.T) {
	cfg, err := LoadConfig(strings.NewReader(`
users:
  mike@kenway.me:
    displayName: Mike
    apps: [radarr, sonarr]
apps:
  sonarr:
    label: Sonarr
    path: /app/sonarr
    upstream: http://sonarr.media.svc.cluster.local:8989
  radarr:
    label: Radarr
    path: /app/radarr
    upstream: http://radarr.media.svc.cluster.local:7878
`))
	if err != nil {
		t.Fatal(err)
	}

	apps := cfg.AppsForIdentity(Identity{LoginName: "mike@kenway.me"})
	if got, want := len(apps), 2; got != want {
		t.Fatalf("len(apps)=%d want %d", got, want)
	}
	if apps[0].Name != "radarr" || apps[1].Name != "sonarr" {
		t.Fatalf("apps sorted by label/name = %#v", apps)
	}
}

func TestLoadConfigRejectsUnknownUserApp(t *testing.T) {
	_, err := LoadConfig(strings.NewReader(`
users:
  mike@kenway.me:
    apps: [missing]
apps:
  sonarr:
    label: Sonarr
    path: /app/sonarr
    upstream: http://sonarr.media.svc.cluster.local:8989
`))
	if err == nil {
		t.Fatal("expected unknown app error")
	}
}

func TestAppForIdentityAllowsNodeIDFallback(t *testing.T) {
	cfg, err := LoadConfig(strings.NewReader(`
users:
  node:1234:
    displayName: Shared Node
    apps: [sonarr]
apps:
  sonarr:
    label: Sonarr
    path: /app/sonarr
    upstream: http://sonarr.media.svc.cluster.local:8989
`))
	if err != nil {
		t.Fatal(err)
	}

	app, ok := cfg.AppForIdentity(Identity{NodeID: "1234"}, "sonarr")
	if !ok {
		t.Fatal("expected node id fallback to authorize sonarr")
	}
	if app.Upstream != "http://sonarr.media.svc.cluster.local:8989" {
		t.Fatalf("upstream=%q", app.Upstream)
	}
}

func TestLoadConfigRejectsInvalidAppPath(t *testing.T) {
	_, err := LoadConfig(strings.NewReader(`
users:
  mike@kenway.me:
    apps: [sonarr]
apps:
  sonarr:
    label: Sonarr
    path: sonarr
    upstream: http://sonarr.media.svc.cluster.local:8989
`))
	if err == nil {
		t.Fatal("expected invalid path error")
	}
}
