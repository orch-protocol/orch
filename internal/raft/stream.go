package raftpkg

import (
	"net"
	"time"

	hashiraft "github.com/hashicorp/raft"
)

type StreamLayer struct {
	listener net.Listener
	addr     net.Addr
}

func NewStreamLayer(address string) (*StreamLayer, error) {
	listener, err := net.Listen("tcp4", address)
	if err != nil {
		return nil, err
	}
	return &StreamLayer{listener: listener, addr: listener.Addr()}, nil
}

func (l *StreamLayer) Accept() (net.Conn, error) {
	return l.listener.Accept()
}

func (l *StreamLayer) Close() error {
	return l.listener.Close()
}

func (l *StreamLayer) Addr() net.Addr {
	return l.addr
}

func (s *StreamLayer) Dial(address hashiraft.ServerAddress, timeout time.Duration) (net.Conn, error) {
	return net.DialTimeout("tcp4", string(address), timeout)
}
