package portal

import (
	"errors"
	"fmt"
	"io"
	"net/url"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Users map[string]UserConfig `yaml:"users"`
	Apps  map[string]App        `yaml:"apps"`
}

type UserConfig struct {
	DisplayName string   `yaml:"displayName"`
	Apps        []string `yaml:"apps"`
}

type App struct {
	Name     string `yaml:"-"`
	Label    string `yaml:"label"`
	Path     string `yaml:"path"`
	Upstream string `yaml:"upstream"`
}

func LoadConfig(r io.Reader) (*Config, error) {
	decoder := yaml.NewDecoder(r)
	decoder.KnownFields(true)

	var cfg Config
	if err := decoder.Decode(&cfg); err != nil {
		return nil, fmt.Errorf("decode config: %w", err)
	}
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func (c *Config) AppsForIdentity(identity Identity) []App {
	user, ok := c.userForIdentity(identity)
	if !ok {
		return nil
	}

	apps := make([]App, 0, len(user.Apps))
	for _, name := range user.Apps {
		app, ok := c.Apps[name]
		if !ok {
			continue
		}
		apps = append(apps, app)
	}

	sort.Slice(apps, func(i, j int) bool {
		if apps[i].Label == apps[j].Label {
			return apps[i].Name < apps[j].Name
		}
		return apps[i].Label < apps[j].Label
	})
	return apps
}

func (c *Config) AppForIdentity(identity Identity, name string) (App, bool) {
	user, ok := c.userForIdentity(identity)
	if !ok {
		return App{}, false
	}
	for _, allowed := range user.Apps {
		if allowed == name {
			app, ok := c.Apps[name]
			return app, ok
		}
	}
	return App{}, false
}

func (c *Config) KnownIdentity(identity Identity) bool {
	_, ok := c.userForIdentity(identity)
	return ok
}

func (c *Config) userForIdentity(identity Identity) (UserConfig, bool) {
	candidates := []string{
		strings.TrimSpace(identity.LoginName),
		"node:" + strings.TrimSpace(identity.NodeID),
		strings.TrimSpace(identity.NodeName),
	}
	for _, candidate := range candidates {
		if candidate == "" || candidate == "node:" {
			continue
		}
		user, ok := c.Users[candidate]
		if ok {
			return user, true
		}
	}
	return UserConfig{}, false
}

func (c *Config) validate() error {
	if c == nil {
		return errors.New("config is nil")
	}
	if len(c.Users) == 0 {
		return errors.New("config requires at least one user")
	}
	if len(c.Apps) == 0 {
		return errors.New("config requires at least one app")
	}

	seenPaths := map[string]string{}
	for name, app := range c.Apps {
		if strings.TrimSpace(name) == "" {
			return errors.New("app name cannot be empty")
		}
		if strings.TrimSpace(app.Label) == "" {
			return fmt.Errorf("app %q requires label", name)
		}
		if !strings.HasPrefix(app.Path, "/app/") {
			return fmt.Errorf("app %q path must start with /app/", name)
		}
		if strings.Contains(app.Path, "//") {
			return fmt.Errorf("app %q path cannot contain //", name)
		}
		app.Path = strings.TrimRight(app.Path, "/")
		if app.Path == "/app" {
			return fmt.Errorf("app %q path must include app name", name)
		}
		parsed, err := url.Parse(app.Upstream)
		if err != nil || parsed.Scheme == "" || parsed.Host == "" {
			return fmt.Errorf("app %q upstream must be absolute URL", name)
		}
		if parsed.Scheme != "http" && parsed.Scheme != "https" {
			return fmt.Errorf("app %q upstream must use http or https", name)
		}
		if owner, exists := seenPaths[app.Path]; exists {
			return fmt.Errorf("app %q path duplicates app %q", name, owner)
		}
		app.Name = name
		app.Path = strings.TrimRight(app.Path, "/")
		c.Apps[name] = app
		seenPaths[app.Path] = name
	}

	for identity, user := range c.Users {
		if strings.TrimSpace(identity) == "" {
			return errors.New("user identity cannot be empty")
		}
		if len(user.Apps) == 0 {
			return fmt.Errorf("user %q requires at least one app", identity)
		}
		for _, appName := range user.Apps {
			if _, ok := c.Apps[appName]; !ok {
				return fmt.Errorf("user %q references unknown app %q", identity, appName)
			}
		}
	}

	return nil
}
