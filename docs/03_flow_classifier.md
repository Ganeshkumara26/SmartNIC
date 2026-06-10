# The Core Datapath Routing (`flow_classifier.v`)

---

## 1. Purpose of the File

---

The file `rtl/classifier/flow_classifier.v` serves as the centralized routing brain of the SmartNIC datapath. When a packet arrives from the Packet Parser (Chapter 2), it possesses a fully populated `TUSER` sideband containing extracted IP addresses and ports. However, the packet does not yet know *where* it is supposed to go.

### Why this file exists
In a 5G Network Slicing environment, traffic must be mapped to distinct hardware queues (e.g., Queue 0 for URLLC, Queue 1 for eMBB) based on routing policies issued by the 5G Core Network. This file implements those policies.

### What problem it solves
It solves the problem of **Line-Rate Rule Matching**. The hardware must evaluate the packet's metadata against a table of rules (Packet Detection Rules) and determine the correct 5G Network Slice. It must do this in exactly one clock cycle, matching against all rules simultaneously.

### Where it fits in the architecture
It sits directly behind the `packet_parser.v`. It reads the extracted IP/Ports, calculates the destination Slice ID, overwrites the `slice_id` bits in the `TUSER` bus, and forwards the packet downstream to the `queue_manager.v`. It also exposes a configuration port for the RISC-V Control Plane (Slow Path) to dynamically update the routing rules.

---

## 2. Background Theory

---

### A. TCAM (Ternary Content-Addressable Memory)
Standard RAM takes an *address* (e.g., `0x04`) and returns *data*. 
A CAM takes *data* (e.g., a Destination IP) and returns the *address* where it matched. 
A **Ternary CAM (TCAM)** introduces a third state: `X` (Don't Care).

In networking, the "Don't Care" state allows for **Subnet Masking**. If a routing rule is `192.168.1.0/24`, the TCAM evaluates the first 24 bits and marks the last 8 bits as `X`. If an incoming packet is `192.168.1.55`, it matches. FPGAs do not have hard silicon TCAMs, so we must emulate this behavior using standard logic gates.

### B. Priority Encoding
Because of wildcards (Don't Cares), a single packet might match multiple rules simultaneously. For example:
* Rule 0: Match *all* traffic (Default Route).
* Rule 1: Match Subnet `192.168.1.0/24`.
* Rule 2: Match exact IP `192.168.1.55`.

If a packet arrives for `192.168.1.55`, it technically matches all three rules! To resolve this, TCAMs use a **Priority Encoder**. The rules are physically wired in order of strict priority (Rule 0 > Rule 1 > Rule 2). The encoder outputs the result of the highest-priority matching rule and ignores the rest.

---

## 3. File Structure Walkthrough

---

1. **Interfaces:** The AXI-Stream datapath and the custom `cfg_*` rule configuration ports.
2. **Rule Table Storage:** The physical register arrays holding the IP/Port values and their corresponding Subnet Masks.
3. **Rule Write Logic:** A synchronous block allowing the RISC-V CPU to update the rule table.
4. **Parallel Rule Matching:** A `generate` block that physically stamps out identical match-logic circuits for every rule.
5. **Priority Encoder:** A combinatorial block that selects the winning rule.
6. **Packet Tracking & Forwarding:** A pipelined AXI-Stream block that calculates the slice on the first beat and remembers it for the rest of the payload.

---

## 4. Line-by-Line Code Explanation

---

### The Emulated TCAM Storage
```verilog
    reg [31:0] rule_dst_ip       [`NUM_RULES-1:0];
    reg [31:0] rule_dst_ip_mask  [`NUM_RULES-1:0];
...
    reg [`TUSER_SLICE_ID_WIDTH-1:0] rule_slice_id [`NUM_RULES-1:0];
```
**What it does:** Defines a 2-Dimensional array of registers.
**Engineering Reasoning:** `NUM_RULES` is defined as 16. This creates a table with 16 rows. Each row stores the target IP, the subnet mask, and the resulting action (`rule_slice_id`).

### The Configuration Interface
```verilog
        } else if (cfg_wr_en) begin
            rule_dst_ip[cfg_rule_id]        <= cfg_dst_ip;
            rule_dst_ip_mask[cfg_rule_id]   <= cfg_dst_ip_mask;
```
**What it does:** Allows dynamic updates. When the RISC-V asserts `cfg_wr_en`, it writes the provided data into the specific row denoted by `cfg_rule_id`.

### The Parallel Match Generator
```verilog
    genvar i;
    generate
        for (i = 0; i < `NUM_RULES; i = i + 1) begin : gen_match
            wire ip_match   = ((pkt_dst_ip   & rule_dst_ip_mask[i])   ==
                               (rule_dst_ip[i] & rule_dst_ip_mask[i]));
...
            assign rule_match[i] = rule_enable[i] && ip_match && port_match && proto_match;
        end
    endgenerate
```
**What it does:** Emulates the physical TCAM matching matrix.
**How it works internally:** The syntax `(pkt_ip & mask) == (rule_ip & mask)` is the mathematical definition of a Subnet Mask. By performing a bitwise AND on both sides, the "Don't Care" bits are forced to 0, ensuring they are evaluated as mathematically equal.
**Why it exists:** The `generate` block is uniquely powerful. It tells the synthesizer to physically copy and paste this logic 16 times in hardware, wiring each copy to a different row in the rule table. This allows the packet to be evaluated against all 16 rules at the exact same physical instant.

### The Priority Encoder
```verilog
    always @(*) begin
        matched_slice_id = `DEFAULT_SLICE_ID;
        match_found = 1'b0;
        for (j = 0; j < `NUM_RULES; j = j + 1) begin
            if (rule_match[j] && !match_found) begin
                matched_slice_id = rule_slice_id[j];
                match_found = 1'b1;
            end
        end
    end
```
**What it does:** Resolves multiple simultaneous matches.
**How it works:** This is an `always @(*)` block, meaning it generates pure combinational logic (no flip-flops). The `for` loop evaluates starting from index 0. If Rule 0 matches, `match_found` becomes true, and the `if` condition evaluates to false for all subsequent iterations. Thus, Rule 0 wins.

### Slice ID Insertion
```verilog
                    m_axis_tuser <= s_axis_tuser;
                    m_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO] <=
                        (pkt_valid && match_found) ? matched_slice_id : `DEFAULT_SLICE_ID;
```
**What it does:** Overwrites the specific 4 bits in the `TUSER` sideband.
**Engineering Reasoning:** It passes the rest of the 128-bit `TUSER` exactly as it arrived from the Parser, but surgically replaces bits `[7:4]` with the newly calculated `matched_slice_id`. 

---

## 5. Architecture Context

---

### What inputs arrive here
* `s_axis`: Packet data and extracted metadata from `packet_parser.v`.
* `cfg_*`: Dynamic configuration signals from the RISC-V SoC (Slow Path).

### What outputs leave here
* `m_axis`: Identical packets, but the `TUSER.slice_id` is now permanently stamped with the destination hardware queue.

### Why is it separated from the Parser?
The Parser is structurally staticâ€”the definition of an IPv4 header does not change. The Classifier is structurally dynamicâ€”routing rules change constantly. Keeping them in separate Verilog modules adheres to the Single Responsibility Principle, allowing the routing logic to be re-synthesized or expanded without touching the parsing logic.

---

## 6. Hardware Interpretation

---

### Why use Flip-Flops instead of Block RAM (BRAM)?
In Chapter 4, the architecture will learn that FIFOs use BRAM. Why doesn't the rule table use BRAM? 
* **The Constraint:** BRAMs in AMD FPGAs only have **2 Read Ports**. 
* **The Requirement:** The `generate` block must read ALL 16 rules *simultaneously* on the exact same clock cycle. 
If we used BRAM, it would take 8 clock cycles (2 reads per cycle) to evaluate 16 rules. By using massive arrays of distributed logic (`reg`), we expose all 16 rows to the matching logic permanently, achieving line-rate classification at the cost of LUT area.

### The Timing Implication of the Priority Encoder
The Priority Encoder uses a `for` loop inside an `always @(*)` block. The synthesizer unrolls this loop into a long, cascading chain of multiplexers.
`Result = MUX(Rule 15, MUX(Rule 14, ... MUX(Rule 0, Default)))`
This creates a very deep logic path. If `NUM_RULES` was increased to `1024`, this combinatorial chain would be so long that the electrical signal could not propagate through the silicon before the 4ns clock period ends, resulting in a timing failure.

---

## 7. Design Decisions

---

### Tradeoff: Array Size vs Pipelining
The architecture uses `NUM_RULES = 16`. This is small enough that the parallel matching logic and the priority encoder can resolve inside a single clock cycle without violating 250 MHz timing constraints.

If the author wanted to support `100,000` rules, this architecture would collapse. They would be forced to use **Vertical BRAM Partitioning** (SR-TCAM) or **Software Hash Trees**, both of which require deep, multi-cycle pipelines to evaluate. For the scope of an MVP SmartNIC, 16 hard-coded hardware rules is sufficient for mapping general traffic to 4 Network Slices.

---

## 8. Example Execution

---

**Scenario:** The RISC-V Control Plane configures Rule 0 and Rule 1.
* **Rule 0:** Dst IP: `10.0.0.0`, Mask: `255.255.255.0` (Subnet), Slice ID: `1` (eMBB)
* **Rule 1:** Dst IP: `10.0.0.55`, Mask: `255.255.255.255` (Exact), Slice ID: `2` (URLLC)

**Packet Arrives:** Destination IP is `10.0.0.55`. 
1. The `generate` block parallel match occurs.
2. Rule 0 evaluates: `(10.0.0.55 & 255.255.255.0) == 10.0.0.0`. This is **True**.
3. Rule 1 evaluates: `(10.0.0.55 & 255.255.255.255) == 10.0.0.55`. This is **True**.
4. Both `rule_match[0]` and `rule_match[1]` are high.
5. The Priority Encoder scans from index 0. It finds `rule_match[0]` is true first. It assigns `matched_slice_id = 1`.

**Wait, this is a bug in configuration!** The network admin put the generic subnet mask at a higher priority (Rule 0) than the specific IP rule (Rule 1). The specific URLLC packet was incorrectly routed to eMBB. *In TCAM design, the control plane software must always sort rules with the most specific masks (longest prefix) at the lowest index (highest priority).*

---
