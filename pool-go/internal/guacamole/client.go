package guacamole

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Client is a typed, token-refreshing Guacamole REST client.
// Each method fetches a fresh short-lived token so callers are stateless.
type Client struct {
	baseURL    string
	user       string
	password   string
	dataSource string
	http       *http.Client
}

func New(baseURL, user, password, dataSource string) *Client {
	return &Client{
		baseURL:    strings.TrimRight(baseURL, "/"),
		user:       user,
		password:   password,
		dataSource: dataSource,
		http:       &http.Client{Timeout: 15 * time.Second},
	}
}

// Connection is returned from CreateConnection.
type Connection struct {
	// ID is the Guacamole connection identifier.
	ID string
	// URL is the browser-ready URL for the student (via NGINX proxy).
	URL string
	// User is the per-session Guacamole account the URL's token belongs to.
	// Callers must delete it when the session ends.
	User string
}

// ConnectionSpec describes the desktop guacd should connect to. Both OS types
// serve a listener from inside the guest, so the only per-OS differences are
// the protocol, the port, and which parameters guacd expects.
type ConnectionSpec struct {
	VMName   string
	Protocol string // "vnc" (Ubuntu) or "rdp" (Windows)
	Hostname string // ClusterIP service DNS name, e.g. desktop-ubu-pool-abc.default.svc
	Port     int32
	User     string // unused for VNC — the protocol authenticates on password alone
	Password string
}

// CreateConnection creates a Guacamole connection for a pool VM and returns a
// browser URL that auto-logs in via the ?token= parameter.
//
// The token in that URL belongs to a throwaway per-session account holding READ
// on this one connection — never to the admin account. An admin token handed to
// a student would let them list every other student's connection, read its
// parameters (the desktop hostname and password are returned in plaintext), and
// open it. Guacamole scopes every REST response to the caller's permissions, so
// a scoped account turns those requests into 404s.
func (c *Client) CreateConnection(ctx context.Context, spec ConnectionSpec, sessionID, nodeIP string, portalPort int) (*Connection, error) {
	token, err := c.token(ctx)
	if err != nil {
		return nil, err
	}

	payload := map[string]any{
		"name":       spec.VMName,
		"protocol":   spec.Protocol,
		"parameters": connectionParameters(spec),
		"attributes": map[string]string{
			"max-connections":          "1",
			"max-connections-per-user": "1",
		},
	}

	body, _ := json.Marshal(payload)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		fmt.Sprintf("%s/api/session/data/%s/connections", c.baseURL, c.dataSource),
		bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Guacamole-Token", token)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("guacamole create connection: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("guacamole create connection: status %d", resp.StatusCode)
	}

	var result struct {
		Identifier string `json:"identifier"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("guacamole decode connection: %w", err)
	}

	// Scope the student to this connection alone. On any failure the connection
	// is removed again: handing back an admin-token URL as a fallback would
	// silently reintroduce the cross-student access this exists to prevent.
	username := sessionUser(sessionID)
	studentToken, err := c.grantScopedAccess(ctx, token, username, result.Identifier)
	if err != nil {
		if delErr := c.DeleteConnection(ctx, result.Identifier); delErr != nil {
			return nil, fmt.Errorf("%w (and connection %s was left behind: %v)",
				err, result.Identifier, delErr)
		}
		return nil, err
	}

	// Guacamole client ID = base64("{connID}\0c\0{dataSource}")
	clientID := base64.StdEncoding.EncodeToString(
		[]byte(result.Identifier + "\x00c\x00" + c.dataSource),
	)
	connURL := fmt.Sprintf("http://%s:%d/guacamole/#/client/%s?token=%s",
		nodeIP, portalPort, clientID, studentToken)

	return &Connection{ID: result.Identifier, URL: connURL, User: username}, nil
}

// sessionUser is the Guacamole account name for a session. The random session
// ID doubles as the account name, so accounts never collide between students.
func sessionUser(sessionID string) string { return "lab-" + sessionID }

// grantScopedAccess creates the per-session account, gives it READ on connID
// only, and returns a login token for it.
func (c *Client) grantScopedAccess(ctx context.Context, adminToken, username, connID string) (string, error) {
	password, err := randomPassword()
	if err != nil {
		return "", err
	}
	if err := c.createUser(ctx, adminToken, username, password); err != nil {
		return "", err
	}
	// From here the account exists, so every failure has to remove it again —
	// an orphaned account would linger with access to a connection that gets
	// handed to the next student.
	if err := c.grantConnection(ctx, adminToken, username, connID); err != nil {
		return "", c.cleanupUser(ctx, username, err)
	}
	studentToken, err := c.tokenFor(ctx, username, password)
	if err != nil {
		return "", c.cleanupUser(ctx, username, err)
	}
	return studentToken, nil
}

// cleanupUser deletes a half-provisioned account and returns cause, noting the
// account name if it could not be removed.
func (c *Client) cleanupUser(ctx context.Context, username string, cause error) error {
	if err := c.DeleteUser(ctx, username); err != nil {
		return fmt.Errorf("%w (and user %s was left behind: %v)", cause, username, err)
	}
	return cause
}

func (c *Client) createUser(ctx context.Context, adminToken, username, password string) error {
	body, _ := json.Marshal(map[string]any{
		"username":   username,
		"password":   password,
		"attributes": map[string]string{},
	})
	return c.do(ctx, http.MethodPost,
		fmt.Sprintf("%s/api/session/data/%s/users", c.baseURL, c.dataSource),
		adminToken, "application/json", body, "create user")
}

// grantConnection adds READ on one connection. READ is enough to open a desktop
// and, unlike UPDATE, does not expose the connection's parameters — which hold
// the desktop password.
func (c *Client) grantConnection(ctx context.Context, adminToken, username, connID string) error {
	body, _ := json.Marshal([]map[string]string{{
		"op":    "add",
		"path":  "/connectionPermissions/" + connID,
		"value": "READ",
	}})
	return c.do(ctx, http.MethodPatch,
		fmt.Sprintf("%s/api/session/data/%s/users/%s/permissions",
			c.baseURL, c.dataSource, url.PathEscape(username)),
		adminToken, "application/json", body, "grant connection permission")
}

// DeleteUser removes a per-session account. Safe to call for a session whose
// account is already gone.
func (c *Client) DeleteUser(ctx context.Context, username string) error {
	token, err := c.token(ctx)
	if err != nil {
		return err
	}
	return c.do(ctx, http.MethodDelete,
		fmt.Sprintf("%s/api/session/data/%s/users/%s",
			c.baseURL, c.dataSource, url.PathEscape(username)),
		token, "", nil, "delete user")
}

// DeleteSessionUser removes the account belonging to a session ID.
func (c *Client) DeleteSessionUser(ctx context.Context, sessionID string) error {
	return c.DeleteUser(ctx, sessionUser(sessionID))
}

// randomPassword returns a password the student never sees — the URL token is
// what authenticates them, and the account is deleted when the session ends.
func randomPassword() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("generate password: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

// do issues a request and treats any non-2xx as an error. 404 on DELETE is
// success — the caller wanted it gone.
func (c *Client) do(ctx context.Context, method, url, token, contentType string, body []byte, what string) error {
	var rdr io.Reader
	if body != nil {
		rdr = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, url, rdr)
	if err != nil {
		return err
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	req.Header.Set("Guacamole-Token", token)

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("guacamole %s: %w", what, err)
	}
	defer resp.Body.Close()

	if method == http.MethodDelete && resp.StatusCode == http.StatusNotFound {
		return nil
	}
	if resp.StatusCode >= 300 {
		return fmt.Errorf("guacamole %s: status %d", what, resp.StatusCode)
	}
	return nil
}

// connectionParameters builds the guacd parameter set for a protocol. VNC
// authenticates on a password alone (x11vnc -rfbauth), so it takes no username.
func connectionParameters(spec ConnectionSpec) map[string]string {
	port := strconv.Itoa(int(spec.Port))

	if spec.Protocol == "vnc" {
		return map[string]string{
			"hostname":    spec.Hostname,
			"port":        port,
			"password":    spec.Password,
			"color-depth": "24",
			"autoretry":   "5",
		}
	}

	return map[string]string{
		"hostname":      spec.Hostname,
		"port":          port,
		"username":      spec.User,
		"password":      spec.Password,
		"security":      "any",
		"ignore-cert":   "true",
		"resize-method": "display-update",
		"enable-drive":  "false",
	}
}

// DeleteConnection removes a Guacamole connection by ID.
func (c *Client) DeleteConnection(ctx context.Context, connID string) error {
	token, err := c.token(ctx)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodDelete,
		fmt.Sprintf("%s/api/session/data/%s/connections/%s", c.baseURL, c.dataSource, connID),
		nil)
	if err != nil {
		return err
	}
	req.Header.Set("Guacamole-Token", token)

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("guacamole delete connection: %w", err)
	}
	resp.Body.Close()
	return nil
}

// token logs in as the admin account. Its tokens are for this client's own
// REST calls only and must never reach a student — see CreateConnection.
func (c *Client) token(ctx context.Context) (string, error) {
	return c.tokenFor(ctx, c.user, c.password)
}

func (c *Client) tokenFor(ctx context.Context, username, password string) (string, error) {
	form := url.Values{"username": {username}, "password": {password}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		c.baseURL+"/api/tokens",
		strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := c.http.Do(req)
	if err != nil {
		return "", fmt.Errorf("guacamole token: %w", err)
	}
	defer resp.Body.Close()

	var body struct {
		AuthToken string `json:"authToken"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return "", fmt.Errorf("guacamole token decode: %w", err)
	}
	if body.AuthToken == "" {
		return "", fmt.Errorf("guacamole returned empty token")
	}
	return body.AuthToken, nil
}
