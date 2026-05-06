package config

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

// PoolSpec describes the desired state for one OS pool.
type PoolSpec struct {
	DataSource string
	DiskSize   string
	MinSize    int
	Memory     string
	Cores      int
}

type Config struct {
	Namespace  string
	Redis      RedisConfig
	Guacamole  GuacamoleConfig
	Ubuntu     UbuntuConfig
	Windows    WindowsConfig
	Pools      map[string]PoolSpec // keyed by "ubuntu" | "windows"
	SessionTTL time.Duration
	PortalPort int
}

type RedisConfig struct {
	Addr     string
	Password string
	DB       int
}

type GuacamoleConfig struct {
	InternalURL string
	User        string
	Password    string
	DataSource  string
}

// UbuntuConfig holds the in-guest VNC credentials. VNC authenticates on the
// password alone; User is carried only for display and session bookkeeping.
type UbuntuConfig struct {
	User        string
	VNCPassword string
}

type WindowsConfig struct {
	User     string
	Password string
}

// Role selects which settings Load requires. The binaries read disjoint halves:
// the controller never touches credentials, the API reads Pools only for keys.
type Role string

const (
	RoleAPI        Role = "api"
	RoleController Role = "controller"
)

// Load reads configuration from the environment for one binary's role.
//
// Anything that varies per deployment is required, not defaulted — a default
// here competes with the golden images and deploy/*.yaml, and every one that
// used to live here had silently drifted. Only conventions keep defaults:
// in-cluster DNS, namespace, timeouts.
func Load(role Role) (*Config, error) {
	var missing, malformed []string

	req := func(key string) string {
		v := os.Getenv(key)
		if v == "" {
			missing = append(missing, key)
		}
		return v
	}
	reqInt := func(key string) int {
		v := os.Getenv(key)
		if v == "" {
			missing = append(missing, key)
			return 0
		}
		n, err := strconv.Atoi(v)
		if err != nil {
			malformed = append(malformed, fmt.Sprintf("%s=%q (not an integer)", key, v))
			return 0
		}
		return n
	}
	// Required of this role only; anything else falls back to the default.
	forRole := func(want Role, key, fallback string) string {
		if role == want {
			return req(key)
		}
		return env(key, fallback)
	}
	forRoleInt := func(want Role, key string, fallback int) int {
		if role == want {
			return reqInt(key)
		}
		return mustInt(key, fallback)
	}

	cfg := &Config{
		Namespace: env("NAMESPACE", "default"),
		Redis: RedisConfig{
			Addr:     env("REDIS_ADDR", "redis:6379"),
			Password: env("REDIS_PASSWORD", ""),
			DB:       0,
		},
		Guacamole: GuacamoleConfig{
			InternalURL: env("GUACAMOLE_URL", "http://guacamole:8080/guacamole"),
			User:        forRole(RoleAPI, "GUACAMOLE_USER", ""),
			Password:    forRole(RoleAPI, "GUACAMOLE_PASS", ""),
			DataSource:  env("GUACAMOLE_DATA_SOURCE", "mysql"),
		},
		Ubuntu: UbuntuConfig{
			User:        forRole(RoleAPI, "UBUNTU_USER", ""),
			VNCPassword: forRole(RoleAPI, "UBUNTU_VNC_PASS", ""),
		},
		Windows: WindowsConfig{
			User:     forRole(RoleAPI, "WINDOWS_USER", ""),
			Password: forRole(RoleAPI, "WINDOWS_PASS", ""),
		},
		// The API iterates these for keys alone; only the controller reads values.
		Pools: map[string]PoolSpec{
			"ubuntu": {
				DataSource: forRole(RoleController, "DATASOURCE_UBUNTU", ""),
				DiskSize:   forRole(RoleController, "DISK_SIZE_UBUNTU", ""),
				MinSize:    forRoleInt(RoleController, "MIN_POOL_UBUNTU", 0),
				Memory:     "2Gi",
				Cores:      2,
			},
			"windows": {
				DataSource: forRole(RoleController, "DATASOURCE_WINDOWS", ""),
				DiskSize:   forRole(RoleController, "DISK_SIZE_WINDOWS", ""),
				MinSize:    forRoleInt(RoleController, "MIN_POOL_WINDOWS", 0),
				Memory:     "4Gi",
				Cores:      4,
			},
		},
		SessionTTL: time.Duration(mustInt("SESSION_TIMEOUT", 3600)) * time.Second,
		PortalPort: mustInt("PORTAL_NODEPORT", 30000),
	}

	if len(missing) > 0 || len(malformed) > 0 {
		return nil, fmt.Errorf("config for role %q: missing %v; malformed %v",
			role, missing, malformed)
	}
	return cfg, nil
}

func env(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return fallback
}

func mustInt(key string, fallback int) int {
	v, ok := os.LookupEnv(key)
	if !ok {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		panic(fmt.Sprintf("config: %s=%q is not an integer", key, v))
	}
	return n
}
