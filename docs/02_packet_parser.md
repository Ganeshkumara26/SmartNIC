# Packet Parser (`packet_parser.v`)

## 1. Purpose of the File
`rtl/parser/packet_parser.v` forms the entry point of the SmartNIC Fast Path. It receives raw 512-bit AXI-Stream data from the MAC, identifies Ethernet frames containing IPv4/UDP packets, and extracts the routing headers.

## 2. Pipeline Architecture
The parser implements a two-stage pipelined state machine to sustain 100 Gbps throughput.
- **Stage 1 (Alignment & Capture):** Captures the first 512-bit beat of a new packet. The first 64 bytes of an Ethernet frame are guaranteed to contain the MAC, IP, and UDP headers.
- **Stage 2 (Extraction):** Applies combinatorial bit-masks to slice out the Source/Destination IPs and Ports. 

## 3. AXI-Stream TUSER Sideband
Instead of physically altering the packet data, the parser appends the extracted metadata into the `m_axis_tuser` bus.
- `TUSER[0]`: Valid bit (1 if the packet is IPv4).
- `TUSER[105:10]`: Contains the 96-bit extracted tuple (Source IP, Dest IP, Source Port, Dest Port).
This sideband data travels parallel to the main data stream, allowing downstream modules to make routing decisions without re-parsing the packet.

## 4. Backpressure Handling
The parser maintains the AXI-Stream handshake (`tvalid` and `tready`). If a downstream module exerts backpressure by deasserting `tready`, the parser halts its internal state machine and holds the current beat, ensuring zero data loss.
