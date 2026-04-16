package gossip

import (
	"context"
	"log"
	"net"
	"runtime"
	"time"

	"github.com/orch-protocol/orch/internal/transport"
	orchpb "github.com/orch-protocol/orch/internal/pb"
	"google.golang.org/protobuf/proto"
)

type pingRequestState struct {
	requester *net.UDPAddr
	done      chan bool
}

func (g *GossipNode) handleUDPFrame(frame transport.UDPFrame, addr *net.UDPAddr) {
	switch frame.MsgType {
	case transport.MsgTypeHeartbeat:
		g.handleHeartbeat(frame, addr)
	case transport.MsgTypeHeartbeatAck:
		g.handleHeartbeatAck(frame, addr)
	case transport.MsgTypePing:
		g.handlePing(frame, addr)
	case transport.MsgTypePingAck:
		g.handlePingAck(frame)
	case transport.MsgTypePingReq:
		g.handlePingReq(frame, addr)
	case transport.MsgTypePingReqAck:
		g.handlePingReqAck(frame)
	default:
		log.Printf("udp unsupported msg type: %02x", frame.MsgType)
	}
}

func (g *GossipNode) handleHeartbeat(frame transport.UDPFrame, addr *net.UDPAddr) {
	var heartbeat orchpb.Heartbeat
	if err := proto.Unmarshal(frame.Payload, &heartbeat); err != nil {
		log.Printf("invalid heartbeat payload: %v", err)
		return
	}
	g.membership.RecordHeartbeat(heartbeat.Node, heartbeat.CpuUsage, heartbeat.MemUsage, heartbeat.Goroutines)

	ackPayload, err := proto.Marshal(&orchpb.Heartbeat{
		Node:       g.getSelfNode(),
		Timestamp:  uint64(time.Now().UnixNano()),
		CpuUsage:   0,
		MemUsage:   0,
		Goroutines: uint32(runtime.NumGoroutine()),
	})
	if err != nil {
		log.Printf("failed marshal heartbeat ack: %v", err)
		return
	}
	if err := transport.WriteUDPPacket(g.udpConn, addr, transport.UDPFrame{MsgType: transport.MsgTypeHeartbeatAck, Flags: 0, Payload: ackPayload}); err != nil {
		log.Printf("failed send heartbeat ack: %v", err)
	}
}

func (g *GossipNode) handleHeartbeatAck(frame transport.UDPFrame, addr *net.UDPAddr) {
	var heartbeat orchpb.Heartbeat
	if err := proto.Unmarshal(frame.Payload, &heartbeat); err != nil {
		log.Printf("invalid heartbeat ack payload: %v", err)
		return
	}
	g.membership.RecordHeartbeat(heartbeat.Node, heartbeat.CpuUsage, heartbeat.MemUsage, heartbeat.Goroutines)
}

func (g *GossipNode) handlePing(frame transport.UDPFrame, addr *net.UDPAddr) {
	var ping orchpb.Ping
	if err := proto.Unmarshal(frame.Payload, &ping); err != nil {
		log.Printf("invalid ping payload: %v", err)
		return
	}
	ackPayload, err := proto.Marshal(&orchpb.PingAck{RequestId: ping.RequestId, Helper: g.getSelfNode()})
	if err != nil {
		log.Printf("failed marshal ping ack: %v", err)
		return
	}
	if err := transport.WriteUDPPacket(g.udpConn, addr, transport.UDPFrame{MsgType: transport.MsgTypePingAck, Flags: 0, Payload: ackPayload}); err != nil {
		log.Printf("failed send ping ack: %v", err)
	}
}

func (g *GossipNode) handlePingAck(frame transport.UDPFrame) {
	var ack orchpb.PingAck
	if err := proto.Unmarshal(frame.Payload, &ack); err != nil {
		log.Printf("invalid ping ack payload: %v", err)
		return
	}
	g.pingLock.Lock()
	defer g.pingLock.Unlock()
	state, ok := g.pingRequests[ack.RequestId]
	if !ok {
		return
	}
	select {
	case state.done <- true:
	default:
	}
}

func (g *GossipNode) handlePingReq(frame transport.UDPFrame, addr *net.UDPAddr) {
	var req orchpb.PingReq
	if err := proto.Unmarshal(frame.Payload, &req); err != nil {
		log.Printf("invalid ping req payload: %v", err)
		return
	}
	if req.Target == nil || req.Target.Addr == "" {
		log.Printf("ping req target missing")
		return
	}

	ping := &orchpb.Ping{RequestId: req.RequestId, Helper: g.getSelfNode()}
	payload, err := proto.Marshal(ping)
	if err != nil {
		log.Printf("failed marshal ping: %v", err)
		return
	}

	targetAddr, err := net.ResolveUDPAddr("udp4", req.Target.Addr)
	if err != nil {
		return
	}

	state := &pingRequestState{requester: addr, done: make(chan bool, 1)}
	g.pingLock.Lock()
	g.pingRequests[req.RequestId] = state
	g.pingLock.Unlock()
	defer func() {
		g.pingLock.Lock()
		delete(g.pingRequests, req.RequestId)
		g.pingLock.Unlock()
	}()

	if err := transport.WriteUDPPacket(g.udpConn, targetAddr, transport.UDPFrame{MsgType: transport.MsgTypePing, Flags: 0, Payload: payload}); err != nil {
		log.Printf("failed send ping to target %s: %v", req.Target.Addr, err)
		return
	}

	select {
	case alive := <-state.done:
		ackPayload, err := proto.Marshal(&orchpb.PingReqAck{RequestId: req.RequestId, Target: req.Target, Alive: alive})
		if err != nil {
			log.Printf("failed marshal ping req ack: %v", err)
			return
		}
		if err := transport.WriteUDPPacket(g.udpConn, addr, transport.UDPFrame{MsgType: transport.MsgTypePingReqAck, Flags: 0, Payload: ackPayload}); err != nil {
			log.Printf("failed send ping req ack: %v", err)
		}
	case <-time.After(g.cfg.HeartbeatTimeout):
		return
	}
}

func (g *GossipNode) handlePingReqAck(frame transport.UDPFrame) {
	var ack orchpb.PingReqAck
	if err := proto.Unmarshal(frame.Payload, &ack); err != nil {
		log.Printf("invalid ping req ack payload: %v", err)
		return
	}
	g.pingReqLock.Lock()
	defer g.pingReqLock.Unlock()
	ch, ok := g.pingReqWaiters[ack.RequestId]
	if !ok {
		return
	}
	select {
	case ch <- ack.Alive:
	default:
	}
}

func (g *GossipNode) broadcastHeartbeat() {
	self := g.getSelfNode()
	heartbeat := &orchpb.Heartbeat{
		Node:       self,
		Timestamp:  uint64(time.Now().UnixNano()),
		CpuUsage:   0,
		MemUsage:   0,
		Goroutines: uint32(runtime.NumGoroutine()),
	}
	// Record our own heartbeat to keep LastSeen fresh in our own membership list
	g.membership.RecordHeartbeat(self, 0, 0, uint32(runtime.NumGoroutine()))

	payload, err := proto.Marshal(heartbeat)
	if err != nil {
		log.Printf("failed marshal heartbeat: %v", err)
		return
	}

	for _, addr := range g.membership.KnownPeerAddrs() {
		udpAddr, err := net.ResolveUDPAddr("udp4", addr)
		if err != nil {
			continue
		}
		_ = transport.WriteUDPPacket(g.udpConn, udpAddr, transport.UDPFrame{MsgType: transport.MsgTypeHeartbeat, Flags: 0, Payload: payload})
	}
}

func (g *GossipNode) failureLoop(ctx context.Context) {
	ticker := time.NewTicker(g.cfg.HeartbeatInterval / 2)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			g.checkFailureStates()
		}
	}
}

func (g *GossipNode) checkFailureStates() {
	now := time.Now().UnixNano()
	selfID := g.membership.SelfID()
	for _, member := range g.membership.Members() {
		// TRIPLE GUARD: Use flag, string comparison, and membership SelfID
		if member.IsSelf || member.Node.Id == selfID || member.Node.Id == g.self.Id {
			continue
		}
		if member.State == StateDead {
			continue
		}
		if member.State == StateSuspect {
			if now-member.SuspectSince >= int64(g.cfg.SuspectTimeout) {
				if g.membership.MarkDead(member.Node.Id) {
					log.Printf("failure detector: node %s marked as DEAD", member.Node.Id)
					g.broadcastNodeEvent(orchpb.NodeEvent_DEAD, member.Node)
				}
			}
			continue
		}

		// Don't start another goroutine if the node is already being investigated.
		if member.Investigating {
			continue
		}

		if now-member.LastSeen > int64(g.cfg.HeartbeatTimeout) {
			g.membership.SetInvestigating(member.Node.Id, true)
			go func(m Member) {
				defer g.membership.SetInvestigating(m.Node.Id, false)
				// double check state inside the goroutine
				if g.indirectConfirm(m.Node) {
					return
				}
				if g.membership.MarkSuspect(m.Node.Id, time.Now().UnixNano()) {
					log.Printf("failure detector: node %s marked as SUSPECT", m.Node.Id)
					g.broadcastNodeEvent(orchpb.NodeEvent_SUSPECT, m.Node)
				}
			}(*member)
		}
	}
}

func (g *GossipNode) indirectConfirm(target *orchpb.NodeId) bool {
	helpers := g.selectIndirectHelpers(target.Id)
	if len(helpers) == 0 {
		return false
	}

	req := &orchpb.PingReq{RequestId: g.nextMsgID(), Target: target}
	payload, err := proto.Marshal(req)
	if err != nil {
		log.Printf("failed marshal ping req: %v", err)
		return false
	}

	ch := make(chan bool, 1)
	g.pingReqLock.Lock()
	g.pingReqWaiters[req.RequestId] = ch
	g.pingReqLock.Unlock()
	defer func() {
		g.pingReqLock.Lock()
		delete(g.pingReqWaiters, req.RequestId)
		g.pingReqLock.Unlock()
	}()

	for _, helper := range helpers {
		addr, err := net.ResolveUDPAddr("udp", helper.Addr)
		if err != nil {
			continue
		}
		_ = transport.WriteUDPPacket(g.udpConn, addr, transport.UDPFrame{MsgType: transport.MsgTypePingReq, Flags: 0, Payload: payload})
	}

	select {
	case alive := <-ch:
		if alive {
			g.membership.RecordHeartbeat(target, 0, 0, 0)
		}
		return alive
	case <-time.After(g.cfg.HeartbeatTimeout):
		return false
	}
}

func (g *GossipNode) selectIndirectHelpers(targetID string) []*orchpb.NodeId {
	candidates := make([]*orchpb.NodeId, 0)
	// IMPORTANT: Only use TRULY healthy nodes (not suspect) as helpers.
	// If we use suspect nodes, they are likely to time out themselves.
	for _, member := range g.membership.HealthyNodes() {
		if member.Id == g.self.Id || member.Id == targetID {
			continue
		}
		candidates = append(candidates, member)
	}
	if len(candidates) == 0 {
		return nil
	}

	count := g.cfg.IndirectPingCount
	if count <= 0 {
		count = 3
	}
	if count >= len(candidates) {
		return candidates
	}
	perm := g.rand.Perm(len(candidates))
	result := make([]*orchpb.NodeId, 0, count)
	for i := 0; i < count; i++ {
		result = append(result, candidates[perm[i]])
	}
	return result
}
