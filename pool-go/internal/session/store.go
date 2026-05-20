package session

import (
	"context"
	"time"
)

// Session holds all state for one active student desktop.
type Session struct {
	ID        string    `json:"id"`
	VMName    string    `json:"vm_name"`
	OSType    string    `json:"os_type"`
	URL       string    `json:"url"`
	Student   string    `json:"student"`
	ConnID    string    `json:"conn_id,omitempty"`   // Guacamole connection ID
	GuacUser  string    `json:"guac_user,omitempty"` // per-session Guacamole account, deleted on release
	CreatedAt time.Time `json:"created_at"`
}

// Store is the session persistence interface.
// Swap implementations (Redis → Postgres, etc.) without touching handlers.
type Store interface {
	Set(ctx context.Context, s *Session, ttl time.Duration) error
	Get(ctx context.Context, id string) (*Session, error)
	Delete(ctx context.Context, id string) error
	FindByStudent(ctx context.Context, student, osType string) (*Session, error)
	List(ctx context.Context) ([]*Session, error)
}
