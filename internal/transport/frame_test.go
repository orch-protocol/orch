package transport

import (
	"net"
	"testing"
)

func TestMarshalUnmarshalFrame(t *testing.T) {
	source := Frame{
		MsgType: 0x20,
		Flags:   0x0001,
		SeqNo:   0x1234567890abcdef,
		Payload: []byte("hello orch transport"),
	}

	data, err := MarshalFrame(source)
	if err != nil {
		t.Fatalf("MarshalFrame failed: %v", err)
	}

	result, err := UnmarshalFrame(data)
	if err != nil {
		t.Fatalf("UnmarshalFrame failed: %v", err)
	}

	if result.MsgType != source.MsgType || result.Flags != source.Flags || result.SeqNo != source.SeqNo {
		t.Fatalf("unexpected frame header: got %+v want %+v", result, source)
	}
	if string(result.Payload) != string(source.Payload) {
		t.Fatalf("unexpected payload: got %q want %q", result.Payload, source.Payload)
	}
}

func TestTCPReadWriteFrame(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	frame := Frame{
		MsgType: 0x10,
		Flags:   0x0000,
		SeqNo:   1,
		Payload: []byte("tcp-messaging"),
	}

	go func() {
		if err := WriteTCPFrame(client, frame); err != nil {
			t.Errorf("WriteTCPFrame failed: %v", err)
		}
	}()

	received, err := ReadTCPFrame(server)
	if err != nil {
		t.Fatalf("ReadTCPFrame failed: %v", err)
	}
	if received.MsgType != frame.MsgType || received.Flags != frame.Flags || received.SeqNo != frame.SeqNo {
		t.Fatalf("unexpected tcp frame header: got %+v want %+v", received, frame)
	}
	if string(received.Payload) != string(frame.Payload) {
		t.Fatalf("unexpected tcp payload: got %q want %q", received.Payload, frame.Payload)
	}
}

func TestUDPReadWritePacket(t *testing.T) {
	serverAddr, err := net.ResolveUDPAddr("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}

	serverConn, err := net.ListenUDP("udp", serverAddr)
	if err != nil {
		t.Fatal(err)
	}
	defer serverConn.Close()

	clientConn, err := net.ListenUDP("udp", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer clientConn.Close()

	packet := UDPFrame{
		MsgType: 0x03,
		Flags:   0x0000,
		Payload: []byte("heartbeat"),
	}

	go func() {
		if err := WriteUDPPacket(clientConn, serverConn.LocalAddr().(*net.UDPAddr), packet); err != nil {
			t.Errorf("WriteUDPPacket failed: %v", err)
		}
	}()

	received, _, err := ReadUDPPacket(serverConn)
	if err != nil {
		t.Fatalf("ReadUDPPacket failed: %v", err)
	}

	if received.MsgType != packet.MsgType || received.Flags != packet.Flags {
		t.Fatalf("unexpected udp packet header: got %+v want %+v", received, packet)
	}
	if string(received.Payload) != string(packet.Payload) {
		t.Fatalf("unexpected udp payload: got %q want %q", received.Payload, packet.Payload)
	}
}
