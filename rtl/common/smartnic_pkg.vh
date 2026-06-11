//============================================================================
// SmartNIC Global Parameters & Constants
//============================================================================
// This file defines all shared parameters, field offsets, and constants used
// across the SmartNIC pipeline. Include this file in every module using:
//   `include "smartnic_pkg.vh"
//
// LEARNING NOTES:
// - `define creates text-substitution macros (like #define in C)
// - Parameters are typed constants scoped to a module
// - We use `define here for project-wide constants shared across modules
//============================================================================

`ifndef SMARTNIC_PKG_VH
`define SMARTNIC_PKG_VH

//----------------------------------------------------------------------------
// AXI-Stream Bus Widths
//----------------------------------------------------------------------------
// OpenNIC's 250MHz user role box uses a 512-bit wide data bus.
// At 250MHz, 512 bits/cycle = 128 Gbps raw throughput (plenty for 100GbE).
// TKEEP has one bit per byte (512/8 = 64 bits).
// TUSER carries our custom metadata alongside each packet beat.

`define AXIS_DATA_WIDTH     512
`define AXIS_KEEP_WIDTH     (`AXIS_DATA_WIDTH / 8)   // 64
`define AXIS_USER_WIDTH     256

//----------------------------------------------------------------------------
// Ethernet Header Field Offsets (byte offsets within the first 512-bit beat)
//----------------------------------------------------------------------------
// An Ethernet frame starts with:
//   [0:5]   Destination MAC   (6 bytes)
//   [6:11]  Source MAC         (6 bytes)
//   [12:13] EtherType          (2 bytes)  ← We check this for IPv4 (0x0800)
//   [14...] Payload begins
//
// LEARNING NOTE: In AXI-Stream, byte 0 is in TDATA[7:0], byte 1 in
// TDATA[15:8], etc. We define byte offsets here and convert to bit
// positions in the RTL using: bit_offset = byte_offset * 8.

`define ETH_DST_MAC_OFFSET      0
`define ETH_SRC_MAC_OFFSET      6
`define ETH_ETHERTYPE_OFFSET    12
`define ETH_HEADER_LEN          14

// EtherType values
`define ETHERTYPE_IPV4          16'h0800
`define ETHERTYPE_IPV6          16'h86DD
`define ETHERTYPE_ARP           16'h0806

//----------------------------------------------------------------------------
// IPv4 Header Field Offsets (byte offsets from start of IPv4 header)
//----------------------------------------------------------------------------
// IPv4 header (minimum 20 bytes, starting at byte 14 of the frame):
//   [0]     Version(4b) + IHL(4b)    ← IHL = header length in 32-bit words
//   [1]     DSCP(6b) + ECN(2b)
//   [2:3]   Total Length
//   [4:5]   Identification
//   [6:7]   Flags(3b) + Fragment Offset(13b)
//   [8]     TTL
//   [9]     Protocol                 ← 0x11 = UDP, 0x06 = TCP
//   [10:11] Header Checksum
//   [12:15] Source IP Address
//   [16:19] Destination IP Address
//
// These offsets are RELATIVE to the IPv4 header start (byte 14 of frame).

`define IPV4_VER_IHL_OFFSET     0
`define IPV4_TOTAL_LEN_OFFSET   2
`define IPV4_PROTOCOL_OFFSET    9
`define IPV4_SRC_IP_OFFSET      12
`define IPV4_DST_IP_OFFSET      16
`define IPV4_HEADER_MIN_LEN     20

// IPv4 header starts at this byte offset within the Ethernet frame
`define IPV4_START              `ETH_HEADER_LEN      // 14

// Protocol numbers
`define IP_PROTO_TCP            8'd6
`define IP_PROTO_UDP            8'd17

//----------------------------------------------------------------------------
// UDP Header Field Offsets (byte offsets from start of UDP header)
//----------------------------------------------------------------------------
// UDP header (always 8 bytes, starting at byte 34 of the frame for min IPv4):
//   [0:1]   Source Port
//   [2:3]   Destination Port
//   [4:5]   Length
//   [6:7]   Checksum

`define UDP_SRC_PORT_OFFSET     0
`define UDP_DST_PORT_OFFSET     2
`define UDP_HEADER_LEN          8

// UDP header starts at this byte offset (assuming minimum IPv4 header)
`define UDP_START               (`IPV4_START + `IPV4_HEADER_MIN_LEN)  // 34

//----------------------------------------------------------------------------
// TUSER Metadata Format (128 bits)
//----------------------------------------------------------------------------
// The TUSER sideband carries parsed header metadata alongside each packet.
// This avoids re-parsing headers in downstream modules.
//
// Bit layout:
//   [0]       valid        - 1 if metadata is valid (parser successfully decoded)
//   [1]       is_ipv4      - 1 if EtherType == 0x0800
//   [2]       is_udp       - 1 if IPv4 Protocol == 0x11
//   [3]       is_tcp       - 1 if IPv4 Protocol == 0x06
//   [7:4]     slice_id     - Assigned by the Flow Classifier (0-15)
//   [15:8]    ip_protocol  - Raw IP protocol field
//   [31:16]   dst_port     - UDP/TCP destination port
//   [47:32]   src_port     - UDP/TCP source port
//   [79:48]   dst_ip       - IPv4 destination address
//   [111:80]  src_ip       - IPv4 source address
//   [127:112] reserved     - For future use (e.g., GTP-U TEID in Tier 3)

`define TUSER_VALID_BIT         0
`define TUSER_IS_IPV4_BIT       1
`define TUSER_IS_UDP_BIT        2
`define TUSER_IS_TCP_BIT        3

`define TUSER_SLICE_ID_HI       7
`define TUSER_SLICE_ID_LO       4
`define TUSER_SLICE_ID_WIDTH    4

`define TUSER_IP_PROTO_HI       15
`define TUSER_IP_PROTO_LO       8

`define TUSER_DST_PORT_HI       31
`define TUSER_DST_PORT_LO       16

`define TUSER_SRC_PORT_HI       47
`define TUSER_SRC_PORT_LO       32

`define TUSER_DST_IP_HI         79
`define TUSER_DST_IP_LO         48

`define TUSER_SRC_IP_HI         111
`define TUSER_SRC_IP_LO         80

`define TUSER_RSS_HASH_HI       159
`define TUSER_RSS_HASH_LO       128

`define TUSER_RSS_ELIGIBLE_BIT  160

`define TUSER_RESERVED_HI       255
`define TUSER_RESERVED_LO       161

//----------------------------------------------------------------------------
// Queue & Scheduler Parameters
//----------------------------------------------------------------------------
`define NUM_QUEUES              4       // Number of hardware queues (one per slice)
`define QUEUE_DEPTH             64      // Entries per queue (in simulation; real = deeper)
`define QUEUE_ID_WIDTH          2       // log2(NUM_QUEUES)
`define NUM_PRIORITIES          4       // Priority levels (0 = highest)

//----------------------------------------------------------------------------
// Classifier Parameters
//----------------------------------------------------------------------------
`define NUM_RULES               16      // Max classifier rules
`define RULE_ID_WIDTH           4       // log2(NUM_RULES)
`define DEFAULT_SLICE_ID        4'd0    // Default slice when no rule matches

//----------------------------------------------------------------------------
// Clock & Reset Convention
//----------------------------------------------------------------------------
// All modules use:
//   - clk:    positive-edge triggered clock
//   - rst_n:  active-low synchronous reset (standard in FPGA designs)
//
// LEARNING NOTE: Active-low reset means the circuit is in reset when
// rst_n == 0, and operates normally when rst_n == 1. This is an industry
// convention because it allows reset assertion even when clock is unstable.

`endif // SMARTNIC_PKG_VH
