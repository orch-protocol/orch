package transport

const (
	MsgTypeHello                = 0x01
	MsgTypeHelloAck             = 0x02
	MsgTypeHeartbeat            = 0x03
	MsgTypeHeartbeatAck         = 0x04
	MsgTypePing                 = 0x05
	MsgTypePingReq              = 0x06
	MsgTypePingAck              = 0x07
	MsgTypePingReqAck           = 0x08
	MsgTypeNodeJoin             = 0x10
	MsgTypeNodeLeave            = 0x11
	MsgTypeNodeDead             = 0x12
	MsgTypeNodeSuspect          = 0x13
	MsgTypeScaleOut             = 0x20
	MsgTypeScaleIn              = 0x21
	MsgTypeServiceInfo          = 0x30
	MsgTypeRaftRequestVote      = 0x40
	MsgTypeRaftRequestVoteAck   = 0x41
	MsgTypeRaftAppendEntries    = 0x42
	MsgTypeRaftAppendEntriesAck = 0x43
	MsgTypeError                = 0xFF
)

const (
	FlagCompressed  = 1 << 0
	FlagEncrypted   = 1 << 1
	FlagRequiresAck = 1 << 2
)
