# Multi-Tenant Traffic Storage (`queue_manager.v`)

---

## 1. Purpose of the File

---

The file `rtl/queue/queue_manager.v` is the central storage repository of the SmartNIC datapath. When packets exit the Flow Classifier (Chapter 3), they have been successfully assigned a 5G Network Slice ID (e.g., 0 for URLLC, 1 for eMBB). 

### Why this file exists
If the SmartNIC simply had one massive FIFO buffer, all traffic would be mixed together. If an eMBB user initiates a massive 100 GB file download, they would fill the entire FIFO. If a URLLC packet for autonomous driving arrived a millisecond later, it would be forced to wait at the very back of the line behind the massive file transfer. This phenomenon is known as **Head-of-Line (HoL) Blocking**, and it completely destroys the concept of Quality of Service (QoS).

### What problem it solves
This file implements **Multi-Tenant Queuing**. It physically isolates the packets into distinct, independent circular buffers based on their Slice ID. The autonomous driving packet goes into Queue 0. The file download goes into Queue 1. They never mix, eliminating HoL blocking.

### Where it fits in the architecture
It sits directly behind the `flow_classifier.v` and directly in front of the `priority_scheduler.v`. It accepts packets passively via AXI-Stream, but it only outputs packets when the downstream Scheduler actively *commands* it to via the `deq_request` interface.

---

## 2. Background Theory

---

### A. Memory Partitioning vs. Instantiation
There are two ways to build 4 independent hardware queues:
1. **Instantiation:** Use the `axi_stream_fifo.v` module from Chapter 4 and physically copy-paste it 4 times (`fifo_0`, `fifo_1`, etc.). Use a large demultiplexer to route the incoming packet to the correct FIFO.
2. **Partitioning:** Create one massive, continuous memory array. Mathematically slice the array into distinct regions. Queue 0 is strictly allowed to use memory addresses `0 to 63`. Queue 1 uses addresses `64 to 127`, and so on.

This module utilizes the **Partitioning** architecture. 

### B. The 5G Core Network Constraint
The 3GPP 5G specification allows for up to 16 Network Slices to be active on a UE simultaneously. However, most commercial deployments utilize 3 or 4 primary slices (eMBB, URLLC, MIoT, V2X). This file parameterizes the queue count (`NUM_QUEUES = 4`) to balance isolation with FPGA memory constraints.

---

## 3. File Structure Walkthrough

---

1. **Parameters:** Calculates the total depth and address bit-widths for the unified memory array.
2. **Storage Array:** The massive `mem` register array holding the 705-bit words.
3. **Pointer Arrays:** Two-dimensional arrays maintaining the independent `head` and `tail` pointers for every queue.
4. **Status Generation:** A `generate` block computing the `full`, `empty`, and `fill_level` status for all queues simultaneously.
5. **Enqueue Logic:** Synchronous logic that extracts the Slice ID, calculates the mathematical offset into the massive array, and writes the packet.
6. **Dequeue Logic:** A State Machine (`DEQ_IDLE`, `DEQ_READ`, `DEQ_OUTPUT`) that responds to the Scheduler's commands to extract a packet from a specific queue.

---

## 4. Line-by-Line Code Explanation

---

### Total Memory Calculation
```verilog
    localparam DEPTH      = `QUEUE_DEPTH;                        // 64
    localparam ADDR_BITS  = $clog2(DEPTH);                       // 6
    localparam TOTAL_DEPTH = `NUM_QUEUES * DEPTH;                // 4 * 64 = 256
    localparam TOTAL_ADDR  = $clog2(TOTAL_DEPTH);                // 8
...
    reg [ENTRY_WIDTH-1:0] mem [0:TOTAL_DEPTH-1];
```
**What it does:** Sizes the partitioned memory bank.
**How it works:** Instead of 4 separate arrays of 64, it builds one massive array of 256 entries. 

### Array of Pointers
```verilog
    reg [ADDR_BITS:0] head [`NUM_QUEUES-1:0]; 
    reg [ADDR_BITS:0] tail [`NUM_QUEUES-1:0]; 
```
**What it does:** Creates independent tracking variables.
**Engineering Reasoning:** Because the memory is partitioned into 4 zones, we need 4 independent read pointers and 4 independent write pointers. The syntax creates an array of 4 registers, each 7 bits wide (`ADDR_BITS+1` for the N+1 MSB lap trick discussed in Chapter 4).

### Mathematical Address Translation (Enqueue)
```verilog
    wire [`TUSER_SLICE_ID_WIDTH-1:0] enq_queue_id =
        s_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO];

    wire [TOTAL_ADDR-1:0] enq_addr = (enq_qid * DEPTH) + tail[enq_qid][ADDR_BITS-1:0];
```
**What it does:** Calculates the exact physical memory address to write the packet to.
**How data flows:** 
1. The packet arrives with `Slice ID = 2`.
2. The Base Address calculation: `2 * 64 = 128`.
3. The Offset calculation: Assume the `tail` pointer for Queue 2 is currently at `5`.
4. The Final Address: `128 + 5 = 133`.
5. The packet is securely written to `mem[133]`. It is mathematically impossible for Queue 2 to accidentally overwrite Queue 0's data because Queue 2's `tail` pointer will wrap back to `0` upon hitting `63`.

### The Dequeue State Machine
```verilog
                DEQ_IDLE: begin
                    if (deq_request && !queue_empty[deq_queue_id]) begin
                        deq_data    <= mem[deq_addr];
                        deq_qid_reg <= deq_queue_id;
                        deq_state   <= DEQ_READ;
                    end
                end
```
**What it does:** Fetches packets only when explicitly commanded.
**How it works:** Unlike the FWFT FIFO in Chapter 4 which permanently exposes data on its output, this module waits in `DEQ_IDLE`. When the Scheduler asserts `deq_request` and provides a target `deq_queue_id` (e.g., "Give me the next packet from Queue 0"), the module calculates the address, reads the memory into `deq_data`, and transitions to `DEQ_READ`.

```verilog
                DEQ_OUTPUT: begin
                    if (deq_output_handshake) begin
                        head[deq_qid_reg] <= head[deq_qid_reg] + 1'b1;
                        if (!m_axis_tlast) begin
                            deq_data  <= mem[(deq_qid_reg * DEPTH) + (head[deq_qid_reg][ADDR_BITS-1:0] + 1'b1)];
                            deq_state <= DEQ_READ;
```
**What it does:** Handles multi-beat packets.
**Engineering Reasoning:** A jumbo frame requires multiple 512-bit beats. The Scheduler only requests the *first* beat of the packet. Once the dequeue process begins, this state machine looks at `TLAST`. If `TLAST` is 0, it means the packet is not finished. It automatically increments the internal pointer, fetches the next beat, and stays in the `DEQ_READ` / `DEQ_OUTPUT` loop until the entire packet is successfully transmitted. Only then does it return to `DEQ_IDLE` to accept a new command.

---

## 5. Architecture Context

---

### What inputs arrive here
* `s_axis`: Line-rate packets from the Flow Classifier.
* `deq_request` / `deq_queue_id`: Control signals from the Priority Scheduler commanding a read.

### What outputs leave here
* `m_axis`: Packets dispatched exactly when the Scheduler demands them.
* `queue_empty` / `queue_full` / `queue_fill_levels`: Telemetry vectors sent continuously to the Scheduler so it knows which queues contain data.

---

## 6. Hardware Interpretation

---

### The True Dual-Port (TDP) BRAM Bottleneck
This module defines `mem` as a single, unified 2D register array. If synthesized to an FPGA, the compiler will attempt to map this into a True Dual-Port (TDP) Block RAM.

A TDP BRAM has exactly 2 ports. Port A can be used for Writing (Enqueue). Port B can be used for Reading (Dequeue).
* **The Good:** We can enqueue a packet from the CMAC and dequeue a packet to the PCIe bus simultaneously.
* **The Bad:** Because all 4 queues share the *same* physical BRAM, we can only enqueue ONE packet at a time, and dequeue ONE packet at a time. If the architecture was modified to support multiple ingress parsers (e.g., 2x 100G ports), this shared memory would become a violent collision bottleneck.

### Array Reset `for` Loop
```verilog
        if (!rst_n) begin
            for (m = 0; m < `NUM_QUEUES; m = m + 1) begin
                tail[m] <= {(ADDR_BITS+1){1'b0}};
            end
```
**Hardware translation:** The synthesizer unrolls this `for` loop and physically connects the `rst_n` pin to the asynchronous clear (CLR) port of all 28 flip-flops (4 queues * 7 bits) simultaneously. It executes instantly in hardware.

---

## 7. Design Decisions

---

### Why not physically instantiate 4 separate FIFOs?
If the author instantiated 4 distinct `axi_stream_fifo` modules, they would need a massive 1-to-4 AXI-Stream Demultiplexer on the input, and a massive 4-to-1 AXI-Stream Multiplexer on the output. A 512-bit wide 4-to-1 MUX consumes immense logic area and creates severe routing congestion.

By partitioning a single memory array, the address calculation `(enq_qid * DEPTH)` acts as a "virtual demultiplexer." It routes the data to the correct slot mathematically, requiring significantly less combinatorial logic and achieving higher clock frequencies.

---

## 8. Example Execution

---

**Scenario:** The network is completely quiet. Suddenly, the Parser extracts a URLLC packet (assigned Slice 0) and an eMBB packet (assigned Slice 1).

1. **Cycle 1:** URLLC packet arrives. `enq_qid = 0`. Base address is `0 * 64 = 0`. Packet is written to `mem[0]`. `tail[0]` increments to 1. `queue_empty[0]` becomes 0.
2. **Cycle 2:** eMBB packet arrives. `enq_qid = 1`. Base address is `1 * 64 = 64`. Packet is written to `mem[64]`. `tail[1]` increments to 1. `queue_empty[1]` becomes 0.
3. **Cycle 3:** The downstream Scheduler sees that `queue_empty[0]` is false. Because URLLC has strict priority over eMBB, it asserts `deq_request = 1` and `deq_queue_id = 0`.
4. **Cycle 4:** The state machine transitions to `DEQ_READ`, fetches `mem[0]`, and outputs the URLLC packet.
5. **Cycle 5:** The state machine returns to `DEQ_IDLE`. The Scheduler now sees `queue_empty[0]` is true, but `queue_empty[1]` is false. It asserts `deq_request = 1` and `deq_queue_id = 1` to fetch the eMBB packet.

This perfectly demonstrates QoS isolation!

---
