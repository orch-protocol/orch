package transport

import (
	"net"
)

func ReadTCPFrame(conn net.Conn) (Frame, error) {
	return ReadFrame(conn)
}

func WriteTCPFrame(conn net.Conn, frame Frame) error {
	return WriteFrame(conn, frame)
}
