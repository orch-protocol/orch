package gossip

import (
	"sort"
	"sync"
	"time"

	orchpb "github.com/orch-protocol/orch/internal/pb"
)

type NodeState int

const (
	StateAlive NodeState = iota
	StateSuspect
	StateDead
)

type Member struct {
	Node             *orchpb.NodeId
	State            NodeState
	LastSeen         int64
	MissedHeartbeats int
	SuspectSince     int64
	CpuUsage         float32
	MemUsage         float32
	Goroutines       uint32
	IsSelf           bool
	Investigating    bool
}

type Membership struct {
	mu     sync.RWMutex
	nodes  map[string]*Member
	selfID string
}

func NewMembership(self *orchpb.NodeId) *Membership {
	m := &Membership{
		nodes:  make(map[string]*Member),
		selfID: self.Id,
	}
	m.nodes[self.Id] = &Member{
		Node:     self,
		State:    StateAlive,
		LastSeen: time.Now().UnixNano(),
		IsSelf:   true,
	}
	return m
}

func (m *Membership) AddOrUpdate(node *orchpb.NodeId) bool {
	m.mu.Lock()
	defer m.mu.Unlock()

	member, ok := m.nodes[node.Id]
	if ok {
		// Don't revive dead nodes from updates (rumors)
		if member.State == StateDead {
			return false
		}
		isSelf := member.IsSelf || node.Id == m.selfID
		member.Node = node
		member.State = StateAlive
		member.LastSeen = time.Now().UnixNano()
		member.MissedHeartbeats = 0
		member.SuspectSince = 0
		member.IsSelf = isSelf
		return false
	}
	isSelf := node.Id == m.selfID
	m.nodes[node.Id] = &Member{
		Node:     node, 
		State:    StateAlive, 
		LastSeen: time.Now().UnixNano(),
		IsSelf:   isSelf,
	}
	return true
}

func (m *Membership) AddOrRevive(node *orchpb.NodeId) bool {
	m.mu.Lock()
	defer m.mu.Unlock()

	member, ok := m.nodes[node.Id]
	if ok {
		isSelf := member.IsSelf || node.Id == m.selfID
		member.Node = node
		member.State = StateAlive
		member.LastSeen = time.Now().UnixNano()
		member.MissedHeartbeats = 0
		member.SuspectSince = 0
		member.IsSelf = isSelf
		return false
	}
	isSelf := node.Id == m.selfID
	m.nodes[node.Id] = &Member{
		Node:     node, 
		State:    StateAlive, 
		LastSeen: time.Now().UnixNano(),
		IsSelf:   isSelf,
	}
	return true
}

func (m *Membership) RecordHeartbeat(node *orchpb.NodeId, cpuUsage, memUsage float32, goroutines uint32) {
	m.mu.Lock()
	defer m.mu.Unlock()
	member, ok := m.nodes[node.Id]
	if !ok {
		member = &Member{Node: node}
		m.nodes[node.Id] = member
	}
	// Don't revive dead nodes from heartbeats
	if member.State == StateDead {
		return
	}
	member.Node = node
	member.State = StateAlive
	member.LastSeen = time.Now().UnixNano()
	member.MissedHeartbeats = 0
	member.SuspectSince = 0
	member.CpuUsage = cpuUsage
	member.MemUsage = memUsage
	member.Goroutines = goroutines
}

func (m *Membership) MarkSuspect(id string, _ int64) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	member, ok := m.nodes[id]
	if !ok {
		return false
	}
	if member.State == StateAlive {
		member.State = StateSuspect
		member.SuspectSince = time.Now().UnixNano()
		member.MissedHeartbeats = 0
		return true
	}
	return false
}

func (m *Membership) MarkDead(id string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	member, ok := m.nodes[id]
	if !ok {
		return false
	}
	if member.State == StateDead {
		return false
	}
	member.State = StateDead
	return true
}

func (m *Membership) SelfID() string {
	return m.selfID
}

func (m *Membership) Members() []*Member {
	m.mu.RLock()
	defer m.mu.RUnlock()

	result := make([]*Member, 0, len(m.nodes))
	for _, member := range m.nodes {
		copy := *member
		result = append(result, &copy)
	}
	return result
}

func (m *Membership) SetInvestigating(id string, active bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if member, ok := m.nodes[id]; ok {
		member.Investigating = active
	}
}

func (m *Membership) MarkState(id string, state NodeState) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	member, ok := m.nodes[id]
	if !ok {
		return false
	}
	if member.State == state {
		return false
	}
	
	// If transitioning to suspect, set the timestamp to NOW
	if state == StateSuspect {
		member.SuspectSince = time.Now().UnixNano()
	}
	
	member.State = state
	return true
}

func (m *Membership) Get(id string) (*Member, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	member, ok := m.nodes[id]
	return member, ok
}

func (m *Membership) Count() int {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return len(m.nodes)
}

func (m *Membership) ClusterView() []*orchpb.NodeId {
	m.mu.RLock()
	defer m.mu.RUnlock()

	result := make([]*orchpb.NodeId, 0, len(m.nodes))
	for _, member := range m.nodes {
		result = append(result, member.Node)
	}
	sort.Slice(result, func(i, j int) bool {
		return result[i].Id < result[j].Id
	})
	return result
}

func (m *Membership) AllNodes() []*orchpb.NodeId {
	return m.ClusterView()
}

func (m *Membership) KnownPeerAddrs() []string {
	m.mu.RLock()
	defer m.mu.RUnlock()

	addresses := make([]string, 0, len(m.nodes)-1)
	for id, member := range m.nodes {
		if id == m.selfID {
			continue
		}
		if member.State == StateDead {
			continue
		}
		addresses = append(addresses, member.Node.Addr)
	}
	sort.Strings(addresses)
	return addresses
}

func (m *Membership) AliveNodes() []*orchpb.NodeId {
	m.mu.RLock()
	defer m.mu.RUnlock()

	result := make([]*orchpb.NodeId, 0, len(m.nodes))
	for _, member := range m.nodes {
		if member.State == StateDead {
			continue
		}
		result = append(result, member.Node)
	}
	sort.Slice(result, func(i, j int) bool {
		return result[i].Id < result[j].Id
	})
	return result
}

// HealthyNodes returns only the nodes that are in StateAlive (not suspect or dead).
func (m *Membership) HealthyNodes() []*orchpb.NodeId {
	m.mu.RLock()
	defer m.mu.RUnlock()

	result := make([]*orchpb.NodeId, 0, len(m.nodes))
	for _, member := range m.nodes {
		if member.State != StateAlive {
			continue
		}
		result = append(result, member.Node)
	}
	sort.Slice(result, func(i, j int) bool {
		return result[i].Id < result[j].Id
	})
	return result
}
