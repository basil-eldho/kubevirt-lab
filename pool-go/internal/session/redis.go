package session

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	keyPrefix = "session:"
	indexKey  = "sessions:index"
)

// RedisStore is the production Store implementation backed by Redis.
// All session keys include a TTL; the index set uses a longer TTL as a safety
// net — stale entries are silently ignored on read.
type RedisStore struct {
	rdb *redis.Client
}

func NewRedisStore(addr, password string, db int) *RedisStore {
	return &RedisStore{
		rdb: redis.NewClient(&redis.Options{
			Addr:     addr,
			Password: password,
			DB:       db,
		}),
	}
}

func (r *RedisStore) Set(ctx context.Context, s *Session, ttl time.Duration) error {
	b, err := json.Marshal(s)
	if err != nil {
		return fmt.Errorf("session marshal: %w", err)
	}
	pipe := r.rdb.Pipeline()
	pipe.Set(ctx, keyPrefix+s.ID, b, ttl)
	pipe.SAdd(ctx, indexKey, s.ID)
	// Index outlives any individual session so scans don't miss recent additions.
	pipe.Expire(ctx, indexKey, ttl*4)
	if _, err = pipe.Exec(ctx); err != nil {
		return fmt.Errorf("session set pipeline: %w", err)
	}
	return nil
}

func (r *RedisStore) Get(ctx context.Context, id string) (*Session, error) {
	b, err := r.rdb.Get(ctx, keyPrefix+id).Bytes()
	if errors.Is(err, redis.Nil) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("session get: %w", err)
	}
	var s Session
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, fmt.Errorf("session unmarshal: %w", err)
	}
	return &s, nil
}

func (r *RedisStore) Delete(ctx context.Context, id string) error {
	pipe := r.rdb.Pipeline()
	pipe.Del(ctx, keyPrefix+id)
	pipe.SRem(ctx, indexKey, id)
	if _, err := pipe.Exec(ctx); err != nil {
		return fmt.Errorf("session delete pipeline: %w", err)
	}
	return nil
}

func (r *RedisStore) FindByStudent(ctx context.Context, student, osType string) (*Session, error) {
	all, err := r.List(ctx)
	if err != nil {
		return nil, err
	}
	for _, s := range all {
		if s.Student == student && s.OSType == osType {
			return s, nil
		}
	}
	return nil, nil
}

func (r *RedisStore) List(ctx context.Context) ([]*Session, error) {
	ids, err := r.rdb.SMembers(ctx, indexKey).Result()
	if err != nil {
		return nil, fmt.Errorf("session list index: %w", err)
	}
	out := make([]*Session, 0, len(ids))
	for _, id := range ids {
		s, err := r.Get(ctx, id)
		if err != nil || s == nil {
			// Stale index entry — TTL expired but index not yet cleaned.
			continue
		}
		out = append(out, s)
	}
	return out, nil
}

// Ping verifies the Redis connection. Call at startup.
func (r *RedisStore) Ping(ctx context.Context) error {
	return r.rdb.Ping(ctx).Err()
}
