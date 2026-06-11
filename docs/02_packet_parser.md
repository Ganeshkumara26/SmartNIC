# Module Documentation: Packet Parser (`packet_parser.v`)

---

## 1. Module Overview & Mathematical Theory

The `packet_parser.v` module acts as the physical ingress point of the SmartNIC Fast Path. Its primary responsibility is to consume raw 512-bit wide AXI-Stream beats arriving directly from the 100G Ethernet MAC (CMAC Subsystem), identify the presence of specific networking protocols (specifically Ethernet, IPv4, and UDP), extract the relevant routing tuples, and forward the data payload while appending a sideband metadata bus (`m_axis_tuser`).

Operating at 250 MHz with a 512-bit data bus, the module is designed to process 128 Gigabits per second (Gbps) of raw throughput. Because the physical parsing constraints require analyzing up to 64 bytes of headers simultaneously, the parser implements a single-stage, full-width combinatorial extraction matrix backed by a high-fanout pipeline register array.

### The Parsing Bottleneck Problem
In traditional software-based networking stacks (e.g., DPDK), packets are parsed sequentially. A CPU reads the Ethernet MAC, increments a memory pointer by 14 bytes to locate the IP header, reads the Internet Header Length (IHL) field to calculate the start of the TCP/UDP header, and increments the pointer again. This sequential pointer-chasing introduces massive latency and cannot scale to 100 Gbps.

### The Hardware Extraction Solution
In this hardware architecture, packet parsing is fundamentally transformed from a sequential memory access problem into a parallel combinatorial logic problem. The OpenNIC shell guarantees that the first beat of any packet will contain up to 64 valid bytes. Because the Ethernet header (14 bytes), standard IPv4 header (20 bytes), and UDP header (8 bytes) sum to 42 bytes, the entirety of the necessary routing headers are mathematically guaranteed to be physically present on the 512-bit wire during the exact clock cycle that `s_axis_tvalid` is asserted for the first beat of a packet.

This allows the parser to extract the routing tuple in exactly zero clock cycles of logical delay by using hardcoded wire slices (e.g., `s_axis_tdata[255:224]` for the Source IP).

---

## 2. Architectural Diagrams

### 2.1 Block Architecture

```mermaid
block-beta
  columns 3
  
  s_axis["s_axis (From CMAC)\nIngress Interface\n512-bit Payload Data\n64-bit Byte Valid Mask"]
  parser["packet_parser.v\nCore Hardware Logic\nZero-Cycle Combinatorial Slicer\n1-Cycle Latch Pipeline"]
  m_axis["m_axis (To Classifier)\nEgress Interface\n512-bit Payload Data\n128-bit TUSER Routing Metadata"]
  
  s_axis --> parser
  parser --> m_axis
```

### 2.2 State Machine

The parser implements a Mealy/Moore hybrid Finite State Machine (FSM) to track packet boundaries and handle variable-length frames.

```mermaid
stateDiagram-v2
    [*] --> ST_IDLE
    
    note left of ST_IDLE: Waiting for new packet arrival
    
    ST_IDLE --> ST_FIRST_BEAT: s_axis_tvalid == 1
    
    note right of ST_FIRST_BEAT: Extracts headers (IP/UDP).\nIf packet is <= 64 bytes,\nreturn immediately to IDLE.
    
    ST_FIRST_BEAT --> ST_IDLE: m_axis_tvalid == 1 &&\n m_axis_tready == 1 &&\n first_beat_last == 1
    
    ST_FIRST_BEAT --> ST_FORWARDING: m_axis_tvalid == 1 &&\n m_axis_tready == 1 &&\n first_beat_last == 0
    
    note right of ST_FORWARDING: Packet > 64 bytes.\nContinuously forward payload beats\nuntil tlast is detected.
    
    ST_FORWARDING --> ST_IDLE: s_axis_tvalid == 1 &&\n s_axis_tready == 1 &&\n s_axis_tlast == 1
    ST_FORWARDING --> ST_FORWARDING: s_axis_tvalid == 1 &&\n s_axis_tready == 1 &&\n s_axis_tlast == 0
```

---

## 3. Interface Specifications

The module adheres to the AMBA 4 AXI4-Stream Protocol Specification.

| Port Name | Direction | Width | Description |
| :--- | :--- | :--- | :--- |
| `clk` | Input | 1 | 250 MHz core clock. |
| `rst_n` | Input | 1 | Active-low synchronous reset. |
| `s_axis_tdata` | Input | 512 | Raw ingress packet data from the CMAC subsystem. Byte 0 is `[7:0]`. |
| `s_axis_tkeep` | Input | 64 | Byte qualifier. `tkeep[i]` corresponds to `tdata[(i*8)+7 : i*8]`. |
| `s_axis_tuser` | Input | 128 | Ingress sideband metadata. Reserved by OpenNIC shell for physical port ID. |
| `s_axis_tvalid` | Input | 1 | Indicates `tdata`, `tkeep`, `tuser`, and `tlast` are valid. |
| `s_axis_tready` | Output | 1 | Indicates the parser can accept data. Handles upstream backpressure. |
| `s_axis_tlast` | Input | 1 | Indicates the final beat of the current packet frame. |
| `m_axis_tdata` | Output | 512 | Unmodified egress packet data. |
| `m_axis_tkeep` | Output | 64 | Unmodified egress byte qualifier. |
| `m_axis_tuser` | Output | 128 | **Modified metadata**. Contains the extracted 96-bit IP/Port tuple. |
| `m_axis_tvalid` | Output | 1 | Indicates egress signals are valid. |
| `m_axis_tready` | Input | 1 | Backpressure from the Flow Classifier. |
| `m_axis_tlast` | Output | 1 | Unmodified egress packet boundary flag. |

### The `m_axis_tuser` Specification
The outgoing `TUSER` bus acts as the sideband routing context.
- **Bit [0]**: Valid Flag. `1` if the packet is IPv4. `0` if IPv6, ARP, or non-IP.
- **Bits [9:1]**: Reserved.
- **Bits [41:10]**: Extracted Destination IP (32 bits).
- **Bits [73:42]**: Extracted Source IP (32 bits).
- **Bits [89:74]**: Extracted Destination UDP Port (16 bits).
- **Bits [105:90]**: Extracted Source UDP Port (16 bits).
- **Bits [127:106]**: Reserved.

---

## 4. Internal Architecture & Combinatorial Unrolling

### 4.1 Header Identification Logic
The module uses static offsets defined in `smartnic_pkg.vh` to implement concurrent verification logic. Instead of reading fields sequentially, the FPGA synthesizes parallel equality comparators.

```verilog
wire is_ipv4 = (s_axis_tdata[`ETH_TYPE_HI:`ETH_TYPE_LO] == 16'h0800) &&
               (s_axis_tdata[`IPV4_VER_HI:`IPV4_VER_LO] == 4'h4);

wire is_udp  = (s_axis_tdata[`IPV4_PROTO_HI:`IPV4_PROTO_LO] == 8'h11);
```
During synthesis, `is_ipv4` becomes a 20-input AND gate array comparing `tdata[111:96]` against `0x0800` and `tdata[119:116]` against `0x4`. Because this logic is purely combinational, the identification completes within picoseconds of the `tdata` signals propagating into the LUTs.

### 4.2 Pipeline Register Array
To prevent timing closure failures, the parser does not forward data combinatorially. Extracting 96 bits of metadata from a 512-bit bus requires routing high-fanout signals across the silicon die. If the module attempted to assert `m_axis_tvalid` and `m_axis_tdata` on the same cycle it received the data, the combinatorial propagation delay would exceed the 4.0 nanosecond clock period constraint of 250 MHz.

To solve this, the parser implements a massive 705-bit wide D-Type Flip-Flop (DFF) array:
- `first_beat_data` (512 DFFs)
- `first_beat_keep` (64 DFFs)
- `parsed_metadata` (128 DFFs)
- `first_beat_last` (1 DFF)

When `s_axis_tvalid` goes high, the combinatorial logic stabilizes, and on the next rising clock edge, the entire 705-bit context is physically latched into the silicon. This introduces exactly 1 clock cycle (4 ns) of latency but guarantees timing closure.

---

## 5. Timing & Area Considerations

### 5.1 Critical Path Analysis
The most aggressive timing path in the module is the generation of `parsed_metadata`. 
The path begins at the `s_axis_tdata` input pins (from the CMAC). The signals must travel through the IP/UDP equality comparators (LUTs), propagate through the ternary operators routing the IP addresses into the `metadata` wire, and arrive at the `D` pins of the `parsed_metadata` register array before the next clock edge.
Estimated logic levels: 2-3 LUTs. This easily meets the 250 MHz (4.0 ns) requirement.

### 5.2 Resource Utilization Estimates (Xilinx UltraScale+)
- **LUTs**: ~200 (Primarily for equality comparators and multiplexing the `is_ipv4` ternary operator).
- **Flip-Flops**: 705 (The pipeline register array) + 2 (FSM state) = 707 FF.
- **BRAM/URAM**: 0.
- **DSPs**: 0.

---

## 6. Execution Walkthrough (Cycle-by-Cycle Trace)

**Scenario**: A 1500-byte IPv4/UDP packet arrives from the CMAC, followed immediately by a 64-byte TCP packet.

**Clock Cycle 1 (Packet 1 Start):**
- `s_axis_tvalid` = 1, `s_axis_tlast` = 0. Data contains Ethernet, IP, and UDP headers.
- FSM is in `ST_IDLE`. `s_axis_tready` is asserted.
- Combinatorial logic identifies `is_ipv4 = 1` and `is_udp = 1`. The `metadata` wire populates.
- Rising Edge: Data and metadata are latched. FSM transitions to `ST_FIRST_BEAT`.

**Clock Cycle 2 (Packet 1 Forwarding):**
- FSM is in `ST_FIRST_BEAT`.
- `m_axis_tvalid` = 1. Egress data is driven from the latches.
- Assuming `m_axis_tready` = 1, the handshake completes.
- Because `first_beat_last` = 0 (1500 bytes is > 64 bytes), FSM transitions to `ST_FORWARDING`.
- Rising Edge: Next 64 bytes of the packet arrive from CMAC.

**Clock Cycles 3 through 24 (Payload Stream):**
- FSM is in `ST_FORWARDING`.
- The parser acts as a transparent wire. `m_axis_tdata` is driven directly by `s_axis_tdata`. 
- `m_axis_tuser` remains locked to the latched `parsed_metadata`. This ensures the downstream Flow Classifier sees the exact same routing tuple for the entire duration of the packet, eliminating the need for the classifier to maintain its own state.

**Clock Cycle 25 (Packet 1 End):**
- CMAC asserts `s_axis_tlast` = 1 for the final 24 bytes of the 1500-byte payload.
- `m_axis_tlast` is driven high.
- Handshake completes. FSM transitions back to `ST_IDLE`.

---

## 7. Test Cases & Coverage

The parser must be verified against severe edge cases to ensure network resilience. 

### 7.1 Required Testbench Assertions
1. **Assertion: Backpressure Immunity**
   - **Condition**: Downstream module deasserts `m_axis_tready` for a random number of clock cycles between 1 and 100.
   - **Check**: The parser must instantly deassert `s_axis_tready` and halt the FSM. No data beats may be lost or duplicated when `tready` resumes.
2. **Assertion: Protocol Masking**
   - **Condition**: An IPv6 packet is injected into `s_axis_tdata`.
   - **Check**: `m_axis_tuser[0]` must be explicitly 0. The IP and Port fields in `tuser` must be `32'd0` to prevent downstream classifier corruption.
3. **Assertion: Micro-Packet Handling**
   - **Condition**: A 64-byte packet (`tvalid` and `tlast` asserted on the exact same cycle) arrives.
   - **Check**: The FSM must transition `ST_IDLE` -> `ST_FIRST_BEAT` -> `ST_IDLE` without ever entering `ST_FORWARDING`.

---

## 8. Deep Dive: IP Fragmentation Handling

A critical vulnerability in all hardware-based stateless packet parsers is handling IP Fragmentation. In 5G networks, if an encapsulation layer (like IPsec or GTP-U) causes a packet to exceed the Maximum Transmission Unit (MTU), the transmitting router will slice the packet into fragments.

### The Parsing Challenge

```mermaid
block-beta
  columns 3
  
  Title1["Fragment 1 (Correct)\nContains complete headers\nCan be parsed flawlessly"] space Title2["Fragment 2 (Vulnerable)\nMissing Layer 4 headers\nCauses port extraction corruption"]
  
  Eth1["Ethernet Header (14 Bytes)"] space Eth2["Ethernet Header (14 Bytes)"]
  IP1["IPv4 Header (20 Bytes)"] space IP2["IPv4 Header (20 Bytes)"]
  UDP1["UDP Header (8 Bytes)\nContains Source/Dest Ports"] space Payload2["User Payload Data\n(Overlaps into Port extraction zone)"]
  Payload1["User Payload Data"] space Missing["(No UDP Header Present)"]
  
  style UDP1 fill:#bbf,stroke:#f66,stroke-width:2px,color:#000,stroke-dasharray: 5 5
  style Payload2 fill:#f99,stroke:#333,stroke-width:2px,color:#000
```

When an IPv4 packet is fragmented:
1. **Fragment 1:** Contains the Ethernet Header, IPv4 Header, UDP Header, and the first chunk of payload.
2. **Fragment 2:** Contains the Ethernet Header, IPv4 Header, and the *second chunk of payload*. **Crucially, it does NOT contain the UDP header.**

Because our `packet_parser.v` is completely stateless, it evaluates every packet independently. When Fragment 2 arrives, the combinatorial slice attempting to extract the UDP destination port will actually be slicing into the middle of the user's data payload. This will yield a garbage port number, causing the downstream `flow_classifier.v` to misroute the packet.

### The `MF` and `Fragment Offset` Solution
To protect the classifier, the parser must actively inspect the IPv4 Flags and Fragment Offset fields (located at byte offset 20 in the Ethernet frame).
- **MF (More Fragments) Flag:** Bit 13 of the IPv4 Flags field.
- **Fragment Offset:** Bits 0-12.

**Hardware Implementation Requirements:**
The combinatorial logic must be updated to check:
```verilog
wire is_fragmented = (s_axis_tdata[`IPV4_FLAGS_MF] == 1'b1) || (s_axis_tdata[`IPV4_FRAG_OFFSET_HI:`IPV4_FRAG_OFFSET_LO] != 13'd0);
```
If `is_fragmented` is true, the hardware *must* zero out the UDP extraction fields in `parsed_metadata`. The downstream `flow_classifier.v` must be designed to route fragmented packets based solely on the Destination IP address, ignoring the ports, to ensure all fragments of the same original packet are forwarded to the exact same CPU queue for reassembly.

---

## 9. Advanced Parsing: P4-to-Verilog Translation Theory

While this parser is hardcoded for IPv4/UDP, the telecommunications industry is rapidly adopting **P4 (Programming Protocol-independent Packet Processors)**. P4 is a domain-specific language that allows network engineers to define parse graphs. A P4 compiler translates these graphs into actual Verilog RTL.

### How P4 Compilers Generate Parser RTL

```mermaid
stateDiagram-v2
    direction LR
    
    state Stage1 {
        Extract_Ethernet --> Check_EtherType
        note right of Check_EtherType: Evaluates EtherType = 0x0800
    }
    
    state Stage2 {
        Align_to_Bit0 --> Extract_IPv4
        Extract_IPv4 --> Check_Protocol
        note right of Align_to_Bit0: Massive Barrel Shifter logic\nconsumes excessive LUTs to align data
    }
    
    state Stage3 {
        Shift_Payload_by_IHL --> Extract_UDP
        note right of Extract_UDP: Finally extracts Destination Port
    }
    
    Stage1 --> Stage2: 0x0800 (IPv4)
    Stage2 --> Stage3: 0x11 (UDP)
```

If you were to write this parser in P4, it would look like a state machine:
```p4
state start {
    packet.extract(ethernet);
    transition select(ethernet.etherType) {
        0x0800: parse_ipv4;
        default: accept;
    }
}
```

A compiler (like Xilinx SDNet or Vitis Networking P4) converts this into a **TCAM-based Shift Register**. 
Instead of a single monolithic 512-bit slice, the P4-generated Verilog operates as a pipeline:
1. **Stage 1 (Ethernet):** Extracts 14 bytes. Reads the `EtherType`. The remaining 512-14 = 498 bits are physically shifted to align the IP header to bit 0.
2. **Stage 2 (IPv4):** Reads the IP header. The IP header length (IHL) is dynamic (20 to 60 bytes). The hardware uses a massive barrel shifter to shift the remaining payload by `IHL * 4` bytes to align the UDP header to bit 0.
3. **Stage 3 (UDP):** Extracts the UDP header.

**The Tradeoff:**
The P4-generated shift-register parser is infinitely flexible (it can parse infinite layers of MPLS or VLAN tags). However, the massive barrel shifters required to dynamically shift 512-bit buses consume thousands of LUTs and frequently fail timing closure at 250 MHz. Our static combinatorial approach uses < 1% of the logic of a P4 parser, sacrificing flexibility for absolute deterministic timing and silicon efficiency.

---

## 10. Industry Verification: SystemVerilog UVM Driver Architecture

In a production ASIC or high-end FPGA environment, basic Verilog testbenches (using `$display` and `#10` delays) are completely insufficient. To guarantee 0 dropped packets at 100 Gbps, verification engineers use the **Universal Verification Methodology (UVM)** written in SystemVerilog.

### Building the UVM Environment for the Parser

```mermaid
block-beta
  columns 4
  
  Seq["UVM Sequence\n(Generates dynamic, random OOP Packets\nusing SystemVerilog constrained randoms)"]
  Drv["UVM Driver / BFM\n(Translates software objects into\nphysical AXI-Stream wire toggles)"]
  DUT["packet_parser.v\n(Device Under Test\nThe actual Verilog module being stressed)"]
  Score["UVM Scoreboard\n(Evaluates coverage and asserts FATAL\nif parsed metadata mismatches C++ Model)"]
  
  MonIn["Ingress Monitor\n(Sniffs 512-bit s_axis_tdata)"]
  MonOut["Egress Monitor\n(Sniffs 128-bit m_axis_tuser)"]
  
  Seq --> Drv
  Drv --> DUT
  
  Drv --> MonIn
  MonIn --> Score
  
  DUT --> MonOut
  MonOut --> Score
```

1. **UVM Sequence Item (The Packet):**
   Instead of manipulating 512-bit vectors, the testbench defines a high-level software class representing a network packet.
   ```systemverilog
   class ethernet_packet extends uvm_sequence_item;
       rand bit [47:0] dest_mac;
       rand bit [47:0] src_mac;
       rand bit [15:0] eth_type;
       rand bit [7:0]  payload[]; // Dynamic array for IP/UDP data
       
       constraint valid_eth_type { eth_type inside {16'h0800, 16'h86DD}; }
   endclass
   ```

2. **The UVM Driver (The BFM - Bus Functional Model):**
   The Driver receives the abstract `ethernet_packet` class and translates it into cycle-accurate AXI4-Stream toggles on the `s_axis_tdata` pins. It mathematically chunks the `payload[]` array into 64-byte blocks, drives `tvalid` high, computes the exact `tkeep` mask for the final beat, and drives `tlast`.

3. **The UVM Monitor & Scoreboard:**
   A Monitor observes the `m_axis_tuser` pins. It reconstructs the extracted metadata. The Scoreboard compares the Monitor's output against a "Golden Reference Model" (usually a C++ or Python script). If the C++ model parsed `192.168.1.1` from the payload array, but the Verilog parser output `192.168.1.2` on the `TUSER` pins, the Scoreboard immediately throws a `UVM_FATAL` error, halting the simulation.

### Coverage Driven Verification (CDV)
To prove the parser is production-ready, verification engineers use SystemVerilog Covergroups to prove they have stimulated every possible edge case.
```systemverilog
covergroup parser_cg @(posedge clk);
    cp_packet_size: coverpoint payload.size() {
        bins micro = {64};
        bins standard = {[65:1500]};
        bins jumbo = {[1501:9000]};
    }
    cp_backpressure: coverpoint m_axis_tready {
        bins stall = {0};
        bins flow  = {1};
    }
    cross cp_packet_size, cp_backpressure;
endgroup
```
This guarantees the parser has been mathematically proven to handle Jumbo frames while simultaneously experiencing downstream backpressure.

---

## 11. Production Hardening: ECC and Parity Protection

In telecom and aerospace applications, FPGAs are subjected to high altitudes and cosmic radiation. High-energy neutrons can strike the silicon die, flipping the electrical charge of a Flip-Flop from a `0` to a `1`. This is known as a **Single Event Upset (SEU)**.

### The Danger to the Parser
Our parser relies heavily on the 705-bit pipeline register array (`first_beat_data`, `parsed_metadata`). If an SEU flips a bit in the `parsed_metadata` register, a packet destined for Queue 0 (URLLC) could instantly be misclassified as Queue 3 (Best-Effort). Even worse, if the `first_beat_last` register flips, the state machine will permanently hang, destroying the entire 100 Gbps link until the server is rebooted.

### The ECC Parity Solution
To harden the design, production variants of this parser must implement Error Correcting Codes (ECC) on the state machine and metadata registers.
1. **Triple Modular Redundancy (TMR) for the FSM:**
   The `state` register is physically instantiated three times in parallel. A voter circuit compares the three states. If one state is `ST_IDLE` but the other two are `ST_FORWARDING`, the voter assumes a radiation strike occurred, mathematically overrides the flipped bit, and outputs `ST_FORWARDING`.
2. **Parity Bits for Metadata:**
   The 128-bit `parsed_metadata` register is expanded to include parity bits. Before the Flow Classifier accepts the `TUSER` bus, it computes the XOR parity of the metadata. If it detects a mismatch, the classifier can intelligently drop the corrupted packet rather than routing it to the wrong queue.
