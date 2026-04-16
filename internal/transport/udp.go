package transport

import (
	"net"
)

func WriteUDPPacket(conn *net.UDPConn, addr *net.UDPAddr, frame UDPFrame) error {
	data, err := MarshalUDPFrame(frame)
	if err != nil {
		return err
	}
	_, err = conn.WriteToUDP(data, addr)
	return err
}

func ReadUDPPacket(conn *net.UDPConn) (UDPFrame, *net.UDPAddr, error) {
	buf := make([]byte, UDPHeaderLength+MaxPayloadLength)
	n, addr, err := conn.ReadFromUDP(buf)
	if err != nil {
		return UDPFrame{}, nil, err
	}
	frame, err := UnmarshalUDPFrame(buf[:n])
	return frame, addr, err
}
