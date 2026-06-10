# The Hardware QoS Egress (`priority_scheduler.v`)

---

## 1. Purpose of the File

---

The file `rtl/scheduler/priority_scheduler.v` represents the absolute final stage of the SmartNIC datapath. Up until this point, the datapath has been successfully isolating traffic. The Queue Manager (Chapter 5) securely segregated the network slices into distinct, independent memory buffers. 

However, all of these isolated queues eventually need to be funneled back onto a single physical wireâ€”either the 100G fiber optic Ethernet link (via the CMAC) or the PCIe bus to the host server. 

### Why this file exists
If 4 queues are all holding packets and attempting to transmit onto a single 100G link simultaneously, there will be a collision. This module acts as the "Traffic Cop." It stands at the exit of the Queue Manager, looks at which queues have data, and mathematically decides which queue is granted permission to transmit next.

### What problem it solves
It implements **Quality of Service (QoS)** through a Strict Priority (SP) arbitration algorithm. It mathematically guarantees that a latency-critical URLLC packet will always be transmitted before a bulk-data eMBB packet.

---

## 2. Background Theory

---

### A. Strict Priority (SP) Scheduling
In Strict Priority scheduling, queues are rigidly ranked (e.g., Priority 0, 1, 2, 3). The scheduler adheres to an absolute rule: **Always service the highest-priority non-empty queue.**
If Queue 0 (Priority 0) has data, the scheduler will transmit it. It will *only* check Queue 1 if Queue 0 is completely empty.

### B. The Starvation Problem
While SP guarantees the lowest possible latency for Priority 0 (which is mandatory for 5G URLLC autonomous driving use-cases), it introduces a catastrophic vulnerability: **Starvation**.
If a malicious actor floods the URLLC queue with an infinite stream of traffic, the scheduler will perpetually service Queue 0. Queues 1, 2, and 3 will literally never be granted a transmission cycle, effectively severing their network connectivity. 

### C. Advanced Solutions (WFQ & Token Buckets)
To solve starvation in production networks, engineers use **Weighted Fair Queuing (WFQ)** or implement **Token Buckets** (Rate Limiters). A Token Bucket places a hard bandwidth limit (e.g., 10 Gbps) on the URLLC queue. Once the URLLC queue consumes its 10 Gbps allowance, it is temporarily mathematically disqualified, allowing the lower-priority queues to transmit. *This MVP SmartNIC uses basic Strict Priority to demonstrate the fundamental routing mechanics, with Token Buckets slated for Tier 2.*

---

## 3. File Structure Walkthrough

---

1. **Queue Manager Interfaces:** `queue_empty` status flags (inputs) and the `deq_request` / `deq_queue_id` control signals (outputs).
2. **AXI-Stream Interfaces:** Receives the dequeued packet from the Queue Manager and forwards it to the final output.
3. **RISC-V Configuration Port:** AXI-Lite style ports allowing the Slow Path CPU to dynamically assign Priority levels to physical queues.
4. **Configuration Registers:** Flip-flops holding the dynamically assigned priorities.
5. **Priority Selection Logic:** A deep combinatorial priority encoder using nested `for` loops.
6. **State Machine:** A 5-stage FSM (`IDLE`, `REQUEST`, `WAIT`, `FORWARD`, `NEXT`) that manages the latency of querying the Queue Manager.

---

## 4. Line-by-Line Code Explanation

---

### Dynamic Priority Configuration
```verilog
    reg [1:0] queue_priority [`NUM_QUEUES-1:0]; 
...
        } else if (cfg_wr_en) begin
            queue_priority[cfg_queue_id] <= cfg_priority;
```
**What it does:** Allows software to change hardware rules on the fly.
**Engineering Reasoning:** We do not hardcode Queue 0 as Priority 0. By storing the priority mapping in registers, a network administrator can send a command from the 5G Core Network to instantly swap the priorities of the eMBB and mMTC slices without re-synthesizing the FPGA.

### The Nested Priority Encoder
```verilog
        // Scan from highest priority (0) to lowest (NUM_PRIORITIES-1)
        for (p = 0; p < `NUM_PRIORITIES; p = p + 1) begin
            if (!any_queue_ready) begin
                // Check all queues at this priority level
                for (q = 0; q < `NUM_QUEUES; q = q + 1) begin
                    if (!any_queue_ready &&
                        queue_enable[q] &&
                        (queue_priority[q] == p[1:0]) &&
                        !queue_empty[q]) begin
                        selected_queue = q[`QUEUE_ID_WIDTH-1:0];
                        any_queue_ready = 1'b1;
                    end
                end
            end
        end
```
**What it does:** Mathematically selects the winning queue in zero clock cycles.
**How it works internally:** 
1. The outer loop `p` iterates through the abstract *Priority Levels* (0, then 1, then 2).
2. The inner loop `q` iterates through the physical *Queues* (0, 1, 2, 3).
3. If it is looking for Priority 0 (`p=0`), it checks every queue. If it finds a queue configured for Priority 0 that is *not empty*, it latches the Queue ID and sets `any_queue_ready = 1`.
4. Because of the `if (!any_queue_ready)` gate, the instant a winner is found, all subsequent loops are bypassed. Priority 0 is guaranteed to win over Priority 1.

### The Scheduler State Machine
```verilog
                SCH_IDLE: begin
                    if (any_queue_ready) begin
                        active_queue <= selected_queue;
                        sch_state    <= SCH_REQUEST;
                    end
                end

                SCH_REQUEST: begin
                    deq_request  <= 1'b1;
                    deq_queue_id <= active_queue;
                    sch_state    <= SCH_WAIT;
                end
```
**What it does:** Orchestrates the multi-cycle fetch process.
**Engineering Reasoning:** Why can't we just output the data immediately when `any_queue_ready` is high? Because the data is locked inside the Queue Manager's BRAM. 
1. The Scheduler must assert `deq_request`. 
2. It takes 1 clock cycle for the Queue Manager to receive the request.
3. It takes another clock cycle for the Queue Manager to read the BRAM and present the data on `qm_axis_tdata`.
The `SCH_WAIT` state absorbs this inherent pipeline latency.

### Egress Statistics
```verilog
                        if (qm_axis_tlast) begin
                            // End of packet â€” update stats
                            stat_total_packets <= stat_total_packets + 1'b1;
                            stat_queue_packets[active_queue] <=
                                stat_queue_packets[active_queue] + 1'b1;
```
**What it does:** Generates hardware telemetry.
**Why it exists:** Network operators require visibility into the physical hardware. By maintaining 32-bit counters for every packet that successfully exits a specific queue, the RISC-V control plane can periodically read these registers via AXI-Lite and report the exact bandwidth utilization of each 5G Network Slice to the ONAP orchestrator.

---

## 5. Architecture Context

---

### What inputs arrive here
* `queue_empty`: Combinatorial flags from the Queue Manager indicating which slices have pending traffic.
* `qm_axis`: The physical packets being read out of the Queue Manager BRAM.

### What outputs leave here
* `m_axis`: The final, scheduled AXI-Stream packets leaving the custom User Logic and entering the OpenNIC standard subsystems (CMAC or QDMA).
* `deq_request`: The command wires instructing the Queue Manager to release a packet.

---

## 6. Hardware Interpretation

---

### The Massive Multiplexer Tree
The nested `for` loops (`p` and `q`) reside inside an `always @(*)` block. As established in Chapter 3, `generate` blocks and combinational `for` loops do not execute in time; they are unrolled in space.
The synthesizer translates this 4x4 nested loop into a massive **16-input cascading logic tree** comprised of hundreds of Look-Up Tables (LUTs). 

If `NUM_QUEUES` was increased to `128` (a realistic number for massive data center switches), this nested loop would generate `128 x 128 = 16,384` combinations. The logic depth would be catastrophic, and the FPGA would fail timing closure. In those architectures, the Priority Encoder is heavily pipelined across multiple clock cycles.

---

## 7. Design Decisions

---

### The `SCH_NEXT` State
```verilog
                SCH_NEXT: begin
                    if (output_handshake || !m_axis_tvalid) begin
                        m_axis_tvalid <= 1'b0;
                        sch_state     <= SCH_IDLE;
                    end
                end
```
**Why did the author include this state?**
After a packet is fully transmitted (`TLAST` goes high), the Scheduler could theoretically transition directly from `SCH_FORWARD` back to `SCH_IDLE` on the exact same cycle.
However, AXI-Stream defines a strict handshake. If `m_axis_tready` from the downstream CMAC is low on the final cycle, the transmission is technically blocked. The `SCH_NEXT` state ensures the state machine safely waits for the final output handshake to fully complete before it abandons the current packet and begins hunting for a new one in `SCH_IDLE`.

---

## 8. Example Execution

---

**Scenario:** The RISC-V CPU writes to the configuration port, assigning Queue 1 to Priority 0, and Queue 0 to Priority 1. Both Queue 0 and Queue 1 have packets waiting.

1. **Cycle 1:** The `always @(*)` Priority Encoder evaluates. It scans for Priority 0. It checks Queue 1. Queue 1 is assigned Priority 0 and is not empty. `selected_queue` becomes `1`. 
2. **Cycle 2:** The state machine transitions to `SCH_REQUEST`. It asserts `deq_request = 1` and `deq_queue_id = 1`. 
3. **Cycle 3:** The state machine transitions to `SCH_WAIT`. The Queue Manager is simultaneously fetching Queue 1's packet from BRAM.
4. **Cycle 4:** The Queue Manager asserts `qm_axis_tvalid = 1`. The Scheduler transitions to `SCH_FORWARD` and begins streaming the packet to the output.
5. **Cycle 5+:** The packet completes. The state machine returns to `SCH_IDLE`. Now, only Queue 0 has data. The Priority Encoder selects Queue 0, and the process repeats.

---
