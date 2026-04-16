package transport

import (
	"encoding/binary"
	"errors"
	"hash/crc32"
	"io"
)

const (
	Magic            = 0x4F524348
	Version          = 0x01
	TCPHeaderLength  = 24
	UDPHeaderLength  = 12
	MaxPayloadLength = 4 * 1024 * 1024
)

var (
	ErrInvalidMagic     = errors.New("invalid magic")
	ErrVersionMismatch  = errors.New("unsupported version")
	ErrPayloadTooLarge  = errors.New("payload too large")
	ErrChecksumMismatch = errors.New("checksum mismatch")
	ErrFrameTooSmall    = errors.New("frame too small")
)

type Frame struct {
	MsgType byte
	Flags   uint16
	SeqNo   uint64
	Payload []byte
}

type UDPFrame struct {
	MsgType byte
	Flags   uint16
	Payload []byte
}

func checksum(data []byte) uint32 {
	return crc32.Checksum(data, crc32.MakeTable(crc32.Castagnoli))
}

func MarshalFrame(frame Frame) ([]byte, error) {
	if len(frame.Payload) > MaxPayloadLength {
		return nil, ErrPayloadTooLarge
	}

	buf := make([]byte, TCPHeaderLength+len(frame.Payload))
	binary.BigEndian.PutUint32(buf[0:4], Magic)
	buf[4] = Version
	buf[5] = frame.MsgType
	binary.BigEndian.PutUint16(buf[6:8], frame.Flags)
	binary.BigEndian.PutUint32(buf[8:12], uint32(len(frame.Payload)))
	binary.BigEndian.PutUint64(buf[12:20], frame.SeqNo)
	copy(buf[TCPHeaderLength:], frame.Payload)

	// Checksum covers the entire frame with the checksum field zeroed.
	binary.BigEndian.PutUint32(buf[20:24], 0)
	binary.BigEndian.PutUint32(buf[20:24], checksum(buf))
	return buf, nil
}

func UnmarshalFrame(data []byte) (Frame, error) {
	if len(data) < TCPHeaderLength {
		return Frame{}, ErrFrameTooSmall
	}

	if binary.BigEndian.Uint32(data[0:4]) != Magic {
		return Frame{}, ErrInvalidMagic
	}
	if data[4] != Version {
		return Frame{}, ErrVersionMismatch
	}

	payloadLen := binary.BigEndian.Uint32(data[8:12])
	if payloadLen > MaxPayloadLength {
		return Frame{}, ErrPayloadTooLarge
	}
	if uint32(len(data)-TCPHeaderLength) != payloadLen {
		return Frame{}, io.ErrUnexpectedEOF
	}

	expected := binary.BigEndian.Uint32(data[20:24])
	binary.BigEndian.PutUint32(data[20:24], 0)
	if checksum(data) != expected {
		return Frame{}, ErrChecksumMismatch
	}
	binary.BigEndian.PutUint32(data[20:24], expected)

	return Frame{
		MsgType: data[5],
		Flags:   binary.BigEndian.Uint16(data[6:8]),
		SeqNo:   binary.BigEndian.Uint64(data[12:20]),
		Payload: append([]byte(nil), data[TCPHeaderLength:]...),
	}, nil
}

func ReadFrame(r io.Reader) (Frame, error) {
	header := make([]byte, TCPHeaderLength)
	if _, err := io.ReadFull(r, header); err != nil {
		return Frame{}, err
	}

	payloadLen := binary.BigEndian.Uint32(header[8:12])
	if payloadLen > MaxPayloadLength {
		return Frame{}, ErrPayloadTooLarge
	}

	frameData := make([]byte, TCPHeaderLength+payloadLen)
	copy(frameData[:TCPHeaderLength], header)
	if payloadLen > 0 {
		if _, err := io.ReadFull(r, frameData[TCPHeaderLength:]); err != nil {
			return Frame{}, err
		}
	}

	return UnmarshalFrame(frameData)
}

func WriteFrame(w io.Writer, frame Frame) error {
	data, err := MarshalFrame(frame)
	if err != nil {
		return err
	}
	_, err = w.Write(data)
	return err
}

func MarshalUDPFrame(frame UDPFrame) ([]byte, error) {
	if len(frame.Payload) > MaxPayloadLength {
		return nil, ErrPayloadTooLarge
	}

	buf := make([]byte, UDPHeaderLength+len(frame.Payload))
	binary.BigEndian.PutUint32(buf[0:4], Magic)
	buf[4] = Version
	buf[5] = frame.MsgType
	binary.BigEndian.PutUint16(buf[6:8], frame.Flags)
	binary.BigEndian.PutUint32(buf[8:12], uint32(len(frame.Payload)))
	copy(buf[UDPHeaderLength:], frame.Payload)
	return buf, nil
}

func UnmarshalUDPFrame(data []byte) (UDPFrame, error) {
	if len(data) < UDPHeaderLength {
		return UDPFrame{}, ErrFrameTooSmall
	}
	if binary.BigEndian.Uint32(data[0:4]) != Magic {
		return UDPFrame{}, ErrInvalidMagic
	}
	if data[4] != Version {
		return UDPFrame{}, ErrVersionMismatch
	}

	payloadLen := binary.BigEndian.Uint32(data[8:12])
	if payloadLen > MaxPayloadLength {
		return UDPFrame{}, ErrPayloadTooLarge
	}
	if uint32(len(data)-UDPHeaderLength) != payloadLen {
		return UDPFrame{}, io.ErrUnexpectedEOF
	}

	return UDPFrame{
		MsgType: data[5],
		Flags:   binary.BigEndian.Uint16(data[6:8]),
		Payload: append([]byte(nil), data[UDPHeaderLength:]...),
	}, nil
}
