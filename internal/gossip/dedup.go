package gossip

import "sync"

type DedupCache struct {
	mu      sync.Mutex
	seen    map[uint64]struct{}
	entries []uint64
	pos     int
	size    int
}

func NewDedupCache(size int) *DedupCache {
	if size <= 0 {
		size = 1024
	}
	return &DedupCache{
		seen:    make(map[uint64]struct{}, size*2),
		entries: make([]uint64, 0, size),
		size:    size,
	}
}

func (d *DedupCache) Add(id uint64) bool {
	d.mu.Lock()
	defer d.mu.Unlock()

	if _, ok := d.seen[id]; ok {
		return false
	}

	if len(d.entries) < d.size {
		d.entries = append(d.entries, id)
	} else {
		old := d.entries[d.pos]
		delete(d.seen, old)
		d.entries[d.pos] = id
		d.pos = (d.pos + 1) % d.size
	}
	d.seen[id] = struct{}{}
	return true
}
