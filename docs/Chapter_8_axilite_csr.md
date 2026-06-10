# Chapter 8: The Software Control Plane (`axilite_csr.v`)

---

## 1. Purpose of the File

---

The file `rtl/control/axilite_csr.v` is the bridge between the high-speed networking world and the standard computing world.

In Chapters 1 through 7, we built the **Datapath (Fast Path)**. This path runs at 250 MHz, processes 512 bits per clock cycle, and routes massive amounts of data without ever talking to a CPU. However, if the network administrator wants to change a routing rule (e.g., adding a new IP subnet to the eMBB slice), how do they do it?

### What problem it solves
Hardware cannot be easily re-compiled on the fly. This file solves the **Configuration Problem** by providing an AXI4-Lite slave interface. It allows a standard CPU (like an embedded RISC-V core or a host server via PCIe) to write new rules into the hardware registers using standard C pointers and memory addresses.

---

## 2. Background Theory

---

### A. Memory-Mapped I/O (MMIO)
When a CPU executes `*ptr = 0x1234;`, it assumes it is writing data to physical RAM. 
In a System-on-Chip (SoC), we can assign specific memory addresses to physical hardware peripherals instead of RAM. This is called **Memory-Mapped I/O (MMIO)**.
For example, if the SoC memory map decrees that addresses starting at `0x4000_0000` belong to the SmartNIC, any CPU write to that address will bypass the RAM and travel down the AXI bus directly into our `axilite_csr.v` module.

### B. The Commit Trigger Architecture
Setting a 128-bit routing rule requires multiple 32-bit CPU writes. 
If the CPU writes the new IP address, and then takes 50 clock cycles to write the new Port, the hardware might accidentally process a packet using a "half-updated" rule, causing catastrophic misrouting.
**The Solution:** The CSR block caches the IP, Port, and Mask in temporary registers. The hardware does *not* apply them to the Datapath until the CPU writes to a specific **Trigger Address** (e.g., `0x000`). This Trigger Address generates a single-cycle `wr_en` (Write Enable) pulse, committing the entire 128-bit rule into the Flow Classifier's TCAM simultaneously.

---

## 3. File Structure Walkthrough

---

1. **AXI-Lite Slave Interface:** The standard 5-channel AXI-Lite ports (Write Address, Write Data, Write Response, Read Address, Read Data).
2. **Datapath Configuration Wires:** The massive bundle of output wires connecting to `flow_classifier.v` and `priority_scheduler.v`.
3. **Write State Machine:** The handshake logic ensuring safe data transfer from the CPU.
4. **Memory-Mapped Address Decoding:** A giant `case` statement translating physical hex addresses into specific Verilog registers.
5. **Read State Machine:** The logic to respond to CPU read requests (currently stubbed to return `0xCAFEBABE` for MVP validation).

---

## 4. Line-by-Line Code Explanation

---

### The Address Decoder
```verilog
    wire slv_reg_wren = s_axi_wready && s_axi_wvalid && s_axi_awready && s_axi_awvalid;
    wire [11:0] write_offset = waddr_reg[11:0]; // Look at lower 12 bits
```
**What it does:** Identifies when a valid write is occurring and isolates the specific destination register.
**How it works:** `slv_reg_wren` mathematically guarantees that both the Address Channel and Data Channel handshakes have successfully completed. It extracts the lower 12 bits of the address (the offset) to determine exactly what the CPU is trying to configure.

### The Trigger Pulse
```verilog
        } else begin
            // Default to no write pulse
            fc_cfg_wr_en  <= 1'b0;
            sch_cfg_wr_en <= 1'b0;

            if (slv_reg_wren) begin
                case (write_offset)
                    // ── Classifier Offsets ──
                    12'h000: fc_cfg_wr_en         <= 1'b1; // Trigger Commit!
```
**What it does:** Generates the single-cycle commit pulse.
**Engineering Reasoning:** Because the default `else` block permanently forces `fc_cfg_wr_en` to `0`, the trigger signal can only ever equal `1` for the exact clock cycle that `slv_reg_wren` is active and the offset is `0x000`. On the very next clock cycle, it immediately snaps back to `0`, ensuring the Flow Classifier TCAM only writes the rule exactly once.

### Packing Configuration Registers
```verilog
                    12'h104: begin
                        sch_cfg_queue_id     <= s_axi_wdata[`QUEUE_ID_WIDTH-1:0];
                        sch_cfg_priority     <= s_axi_wdata[5:4];
                        sch_cfg_queue_enable <= s_axi_wdata[31];
                    end
```
**What it does:** Packs multiple hardware parameters into a single 32-bit software word.
**Why it matters:** Software is 32-bit or 64-bit aligned. Hardware queues are often tiny (2 bits for Priority, 4 bits for Queue ID). Instead of wasting three separate 32-bit AXI transactions to configure these small values, the Verilog extracts specific bit-slices from `s_axi_wdata`. A C-programmer would interact with this using bitwise shifts:
`*ptr = (1 << 31) | (priority << 4) | (queue_id);`

---

## 5. Architecture Context

---

### What inputs arrive here
AXI4-Lite read/write requests initiated by the RISC-V SoC Control Plane.

### What outputs leave here
Direct configuration wires connecting directly to the Flow Classifier and Priority Scheduler.

### The Clock Domain Crossing (CDC) Assumption
This module assumes the RISC-V AXI-Lite bus operates on the exact same 250 MHz clock as the datapath. In reality, a RISC-V core might run at 1 GHz, or a PCIe host might run at 125 MHz. In a production SmartNIC, this module would require asynchronous FIFOs or Gray-code synchronizers to safely cross the Clock Domain Boundary between the CPU and the Datapath.

---

## 6. Example Execution

---

**Scenario:** The network administrator wants to set Queue 2's Token Bucket Rate to `5000` and its Burst to `10000`, and then commit the change.

1. **CPU C Code:**
```c
volatile uint32_t* CSR_BASE = (uint32_t*)0x40000000;
CSR_BASE[0x108 / 4] = 5000;  // Write Rate
CSR_BASE[0x10C / 4] = 10000; // Write Burst
CSR_BASE[0x104 / 4] = (1<<31) | 2; // Write Queue ID (2) and Enable
CSR_BASE[0x100 / 4] = 1;     // Trigger Commit!
```
2. **Hardware Response (Transaction 1):** The AXI-Lite slave receives offset `0x108`. It latches `5000` into `sch_cfg_tb_rate`.
3. **Hardware Response (Transaction 2):** It receives offset `0x10C`. It latches `10000` into `sch_cfg_tb_burst`.
4. **Hardware Response (Transaction 3):** It receives offset `0x104`. It strips out `Queue ID = 2` and `Enable = 1`.
5. **Hardware Response (Transaction 4):** It receives offset `0x100`. It pulses `sch_cfg_wr_en = 1`.
6. **Execution:** The Priority Scheduler sees the pulse and physically copies the `5000` and `10000` values into Queue 2's Token Bucket flip-flops.

---

## 7. Exercises

---

### 1. Questions to Answer
* If the CPU reads from offset `0x108` right now, the module will return `0xCAFEBABE`. Why doesn't it return the actual `cfg_tb_rate`? What changes would you need to make to the Read State Machine to support this?
* What happens if the CPU accidentally writes to offset `0x100` before writing the Queue ID to `0x104`?

### 2. Things to Modify
* **Add Telemetry Reads:** Modify the AXI-Lite Read logic. Expose the `stat_total_packets` and `stat_queue_packets` arrays from the Priority Scheduler. Create a new memory map offset (e.g., `0x200` to `0x2FF`). When the CPU requests a read from these offsets, use a multiplexer to route the correct 32-bit hardware statistic into `s_axi_rdata`. This enables the software driver to monitor network bandwidth in real-time!
