# Chapter 4: Traffic Queuing & Buffering (`axi_stream_fifo.v`)

---

## 1. Purpose of the File

---

The file `rtl/common/axi_stream_fifo.v` implements a **Synchronous First-In-First-Out (FIFO)** buffer. It serves as the fundamental shock-absorber for the SmartNIC. 

### Why this file exists
In high-speed networking, data generation and data consumption are rarely perfectly synchronized. If the Packet Parser extracts metadata faster than the Priority Scheduler can transmit the packets onto the wire, those packets will violently collide and be destroyed. This file provides the temporary holding pens necessary to prevent catastrophic packet loss during micro-bursts of traffic.

### What problem it solves
It solves the problem of **Hardware Backpressure and Storage**. It safely stores a 512-bit data beat and its metadata, remembers the exact order it was received, and seamlessly halts the upstream modules (`TREADY = 0`) if the memory banks are filled to capacity.

### Where it fits in the architecture
This is an *infrastructure* file. It is not instantiated directly in the top-level design. Instead, the `queue_manager.v` (Chapter 5) will instantiate multiple copies of this FIFO module to physically isolate the 5G Network Slices.

---

## 2. Background Theory

---

### A. The Circular Buffer
Hardware FIFOs are implemented as Circular Buffers. Imagine an array of memory slots numbered 0 to 15. The hardware maintains two variables:
* **Write Pointer (`wr_ptr`):** Where to place the *next* arriving packet.
* **Read Pointer (`rd_ptr`):** Where to take the *oldest* packet from.

When a pointer reaches slot 15, the next increment wraps it back around to slot 0.

### B. The Full / Empty Conundrum
If `wr_ptr == rd_ptr`, what does it mean?
* Scenario 1: The system just started. No data is written. `wr_ptr` is 0, `rd_ptr` is 0. **The FIFO is Empty.**
* Scenario 2: We write 16 packets. The `wr_ptr` wraps around the circle and catches up to the `rd_ptr` from behind. Both are at 0. **The FIFO is Full.**

To differentiate between these states in hardware without complex mathematical division, engineers use the **N+1 Pointer Trick**, which we will explore in the code section.

### C. First-Word Fall-Through (FWFT)
Standard FIFOs require you to assert a `read_enable` signal, and the data appears on the output pins exactly one clock cycle *later*.
**FWFT FIFOs** are different. The data at the head of the queue is *permanently* visible on the output pins. When you assert `read_enable`, it simply throws away the current data and replaces it with the next data on the following clock cycle. AXI-Stream requires FWFT logic.

---

## 3. File Structure Walkthrough

---

1. **Parameters:** Defines generic widths allowing the FIFO to be resized (e.g., 512-bit vs 256-bit) during instantiation.
2. **Internal Storage:** The 2D register array representing the physical memory bank.
3. **Pointers & Counters:** The `wr_ptr` and `rd_ptr` definitions.
4. **Status Signals:** Combinational logic calculating `full`, `empty`, and `fill_level`.
5. **AXI Handshaking:** Linking the internal status signals to the `TVALID` and `TREADY` AXI-Stream pins.
6. **Write Logic:** The synchronous block handling incoming enqueue requests.
7. **Read Logic:** The continuous assignment (FWFT) and synchronous dequeue mechanism.

---

## 4. Line-by-Line Code Explanation

---

### The N+1 Pointer Trick
```verilog
    parameter FIFO_DEPTH = 16,                 
    parameter ADDR_WIDTH = $clog2(FIFO_DEPTH)  // e.g., 4

    reg [ADDR_WIDTH:0] wr_ptr;  // 5 bits: [4:0]
    reg [ADDR_WIDTH:0] rd_ptr;  // 5 bits: [4:0]

    wire [ADDR_WIDTH-1:0] wr_addr = wr_ptr[ADDR_WIDTH-1:0]; // 4 bits: [3:0]
```
**What it does:** Solves the Full/Empty conundrum.
**Engineering Reasoning:** A depth of 16 requires a 4-bit address (`0000` to `1111`). However, the pointers are declared as `ADDR_WIDTH+1` (5 bits). 
The 5th bit (the MSB) acts as a "lap counter". 
* The actual memory address used is just the lower 4 bits (`wr_addr`).
* When the pointer reaches 15 (`01111`) and increments, it becomes 16 (`10000`). The lap counter toggled from 0 to 1, but the physical address wrapped cleanly back to `0000`!

```verilog
    assign full  = (wr_ptr[ADDR_WIDTH] != rd_ptr[ADDR_WIDTH]) &&
                   (wr_addr == rd_addr);
    assign empty = (wr_ptr == rd_ptr);
```
**How it works:**
* **Empty:** If all 5 bits match exactly, the pointers are in the exact same spot on the exact same lap.
* **Full:** If the lower 4 bits match (same physical slot), but the 5th bit differs, it means the `wr_ptr` has mathematically "lapped" the `rd_ptr`. The FIFO is saturated.

### Entry Packing
```verilog
    localparam ENTRY_WIDTH = DATA_WIDTH + KEEP_WIDTH + USER_WIDTH + 1;
...
            mem[wr_addr] <= {s_axis_tlast, s_axis_tuser, s_axis_tkeep, s_axis_tdata};
```
**What it does:** Consolidates 4 separate AXI signals into a single monolithic block of memory.
**Why it exists:** Instead of creating 4 separate memory arrays (one for data, one for user, etc.), the author concatenates them. `{TLAST, TUSER, TKEEP, TDATA}` forms a massive 705-bit wide word. This ensures that metadata and data are perfectly synchronized and can never be misaligned.

### The FWFT Read Logic
```verilog
    wire [ENTRY_WIDTH-1:0] rd_data = mem[rd_addr];

    assign m_axis_tdata = rd_data[DATA_WIDTH-1:0];
...
    assign m_axis_tvalid = ~empty;
```
**What it does:** Instantly exposes the oldest data to the downstream module.
**How it works internally:** Because `rd_data` is a `wire` assigned continuously to `mem[rd_addr]`, whatever data resides at the current Read Pointer is *always* physically driven onto the `m_axis` pins. The downstream module sees it immediately. If `empty` is false, `m_axis_tvalid` is driven high, telling the downstream module "The data you see on the pins right now is valid and ready."

---

## 5. Architecture Context

---

### What inputs arrive here
Raw AXI-Stream data from the upstream `flow_classifier.v`.
### What outputs leave here
Delayed, buffered AXI-Stream data feeding into the `queue_manager.v`.
### Dependencies
This module only depends on `smartnic_pkg.vh` for default parameter sizing.

---

## 6. Hardware Interpretation

---

### Distributed RAM vs. Block RAM (BRAM)
The code declares `reg [ENTRY_WIDTH-1:0] mem [0:FIFO_DEPTH-1];`. 
How does the FPGA synthesizer translate this?
* If `FIFO_DEPTH` is very small (e.g., 16), the synthesizer will likely build this array out of **Distributed RAM** (using the LUTs inside the logic slices).
* If `FIFO_DEPTH` is large (e.g., 512 or 1024), utilizing LUTs would destroy the FPGA's routing resources. The synthesizer will infer a **BRAM (Block RAM)** primitive. 

**WARNING:** The continuous assignment read `wire [...] rd_data = mem[rd_addr];` is completely asynchronous. True FPGA BRAMs *require* synchronous (clocked) reads. If a synthesis tool forces this array into a BRAM block, it will automatically insert a hidden pipeline register to satisfy the BRAM physics, which will break the AXI-Stream FWFT timing! In a production SmartNIC, this module would be replaced by the hardened Xilinx FIFO Generator IP core (as noted in the Implementation Plan). This Verilog code exists primarily for Behavioral Simulation and small distributed arrays.

---

## 7. Design Decisions

---

### Why a Synchronous FIFO?
FPGAs often deal with multiple clock domains (e.g., a 156.25 MHz MAC clock and a 250 MHz PCIe clock). Crossing data between these domains requires an **Asynchronous FIFO** utilizing Gray-code pointers to prevent metastable states.

The author explicitly designed a **Synchronous FIFO** (single `clk` pin).
**Reasoning:** The entire OpenNIC "User Logic Box" operates on a single, synchronized 250 MHz clock domain. Utilizing an Asynchronous FIFO here would waste thousands of logic gates on unnecessary Gray-code converters and multi-flop synchronizers. 

---

## 8. Example Execution

---

**Initial State:** `wr_ptr = 0`, `rd_ptr = 0`. FIFO is Empty.

**Cycle 1:**
* Upstream Parser sends a valid packet beat (`s_axis_tvalid = 1`).
* FIFO is empty, so `s_axis_tready = 1`.
* Handshake succeeds. The 705-bit word is written to `mem[0]`.
* `wr_ptr` increments to `1`.

**Cycle 2:**
* `wr_ptr = 1`, `rd_ptr = 0`. The FIFO is no longer empty.
* `m_axis_tvalid` goes high. `mem[0]` is instantly visible on the output pins.
* Downstream Scheduler is ready (`m_axis_tready = 1`). Handshake succeeds.
* `rd_ptr` increments to `1`.
* The FIFO is empty again.

---

## 9. Common Beginner Confusions

---

### $clog2 Function
**Confusion:** Beginners often wonder what `$clog2` is and if it can be synthesized to silicon.
**Explanation:** `$clog2(N)` is a SystemVerilog mathematical function calculating the "ceiling of the base-2 logarithm". It calculates exactly how many bits are required to address an array of size `N`. It is **completely synthesizable** because it is evaluated by the compiler *before* physical synthesis. If `FIFO_DEPTH = 16`, the compiler replaces `$clog2(16)` with the integer `4` before touching the logic gates.

---

## 10. Exercises

---

### 1. Questions to Answer
* If `FIFO_DEPTH` was set to `17`, what would happen to the pointer logic, and why would the N+1 MSB trick mathematically fail?
* If the FIFO is full (`s_axis_tready = 0`) but the upstream module ignores the backpressure and transmits data anyway, what does the Verilog code currently do? Does it overwrite the oldest data, or drop the newest data?

### 2. Things to Modify
* **Programmable Almost-Full Flag:** In high-speed pipelines, stopping exactly at "Full" can sometimes cause timing collisions due to pipeline latency. Modify the module ports to add an `output wire almost_full`. Write logic to assert `almost_full` when the `fill_level` reaches `FIFO_DEPTH - 2`.
* **Telemetry Counters:** Add a 32-bit register `overflow_drops` that increments by 1 if `s_axis_tvalid` is high while `full` is high.
