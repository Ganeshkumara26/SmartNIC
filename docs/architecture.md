# SmartNIC Architecture — Simulation-First Design

## Overview

A modular FPGA packet processing accelerator for 5G network slicing QoS enforcement.
Designed for simulation-first development, with all interfaces matching the OpenNIC 250MHz
user role box for future FPGA deployment.

## Block Diagram

```
                    ┌─────────────────────────────────────────────────────────┐
                    │              SmartNIC Datapath Pipeline                 │
                    │                                                         │
  Raw Ethernet      │  ┌──────────┐   ┌────────────┐   ┌───────────┐         │   Scheduled
  Packets           │  │  Packet  │   │    Flow    │   │   Queue   │         │   Packets
  ──────────────────┼─►│  Parser  ├──►│ Classifier ├──►│  Manager  │         ├──────────────►
  512b AXI-Stream   │  │          │   │            │   │ (4 queues)│         │   512b AXI-Stream
                    │  └──────────┘   └────────────┘   └─────┬─────┘         │
                    │   Extracts:      Assigns:              │               │
                    │   - EtherType    - Slice ID            │ deq_request   │
                    │   - IP src/dst   (via rule table)      │ deq_queue_id  │
                    │   - Protocol                           ▼               │
                    │   - UDP ports                    ┌───────────┐         │
                    │                                  │ Priority  │         │
                    │                                  │ Scheduler │─────────┘
                    │                                  └───────────┘
                    │                                    HP first!
                    └─────────────────────────────────────────────────────────┘
```

## AXI-Stream Interface Convention

All inter-module interfaces use AXI4-Stream with the following signals:

| Signal   | Width  | Direction | Description                       |
|----------|--------|-----------|-----------------------------------|
| TDATA    | 512    | Source→Sink | Packet data (64 bytes per beat) |
| TKEEP    | 64     | Source→Sink | Valid byte enables              |
| TUSER    | 128    | Source→Sink | Parsed metadata sideband        |
| TVALID   | 1      | Source→Sink | Data valid                      |
| TREADY   | 1      | Sink→Source | Backpressure (sink can accept)  |
| TLAST    | 1      | Source→Sink | Last beat of packet             |

**Handshake Rule**: A data transfer occurs when TVALID && TREADY are both high on the rising clock edge.

## TUSER Metadata Format (128 bits)

```
Bit(s)    Field          Set By          Description
───────   ─────          ──────          ───────────
[0]       valid          Parser          1 = metadata fields are valid
[1]       is_ipv4        Parser          1 = EtherType is 0x0800
[2]       is_udp         Parser          1 = IP Protocol is 0x11
[3]       is_tcp         Parser          1 = IP Protocol is 0x06
[7:4]     slice_id       Classifier      4-bit Slice ID (0-15)
[15:8]    ip_protocol    Parser          Raw IP protocol number
[31:16]   dst_port       Parser          UDP/TCP destination port
[47:32]   src_port       Parser          UDP/TCP source port
[79:48]   dst_ip         Parser          IPv4 destination address
[111:80]  src_ip         Parser          IPv4 source address
[127:112] reserved       —               Future: GTP-U TEID (Tier 3)
```

## Classifier Rule Table

16 rules, each with masked match fields + action:

| Field         | Width | Mask Support | Description                    |
|---------------|-------|-------------|--------------------------------|
| dst_ip        | 32    | Yes         | Destination IP (subnet match)  |
| dst_port      | 16    | Yes         | Destination port               |
| protocol      | 8     | Yes         | IP protocol number             |
| slice_id      | 4     | —           | Action: assigned slice         |
| enable        | 1     | —           | Rule active flag               |

**Match logic**: `(packet_field & mask) == (rule_field & mask)`
**Priority**: First matching rule wins (Rule 0 = highest priority)

### Default Rules (4 slices for 5G traffic classes)

| Rule | Dst IP Subnet | Dst Port | Protocol | Slice | Traffic Class |
|------|--------------|----------|----------|-------|---------------|
| 0    | 10.0.1.0/24  | 5001     | UDP      | 0     | URLLC         |
| 1    | 10.0.2.0/24  | 5060     | UDP      | 1     | Voice/VoIP    |
| 2    | 10.0.3.0/24  | 8080     | Any      | 2     | eMBB          |
| 3    | 10.0.4.0/24  | Any      | Any      | 3     | IoT/Best-Effort|

## Queue Manager Memory Layout

4 queues × 64 entries each = 256 total entries in shared BRAM.

```
Address    Queue    Entry
──────     ─────    ─────
0-63       Q0       URLLC (Highest Priority)
64-127     Q1       Voice
128-191    Q2       eMBB
192-255    Q3       IoT (Lowest Priority)
```

Each entry stores: TDATA(512b) + TKEEP(64b) + TUSER(128b) + TLAST(1b) = 705 bits

## Priority Scheduler

**Algorithm**: Strict Priority
- Queue 0 (Priority 0) = ALWAYS serviced first if non-empty
- Queue 3 (Priority 3) = Only serviced when all higher queues are empty

**State Machine**: IDLE → REQUEST → WAIT → FORWARD → NEXT → IDLE

## File Organization

```
rtl/
├── common/
│   ├── smartnic_pkg.vh      — Global constants & TUSER format
│   └── axi_stream_fifo.v   — Reusable AXI-Stream FIFO
├── parser/
│   └── packet_parser.v     — Ethernet/IPv4/UDP header extraction
├── classifier/
│   └── flow_classifier.v   — CAM-style rule lookup → Slice ID
├── queue/
│   └── queue_manager.v     — BRAM multi-queue with head/tail pointers
└── scheduler/
    └── priority_scheduler.v — Strict Priority drain with stats
```
