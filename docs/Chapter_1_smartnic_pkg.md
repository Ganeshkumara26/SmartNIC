# Chapter 1: Foundational Definitions (`smartnic_pkg.vh`)

---

## 1. Purpose of the File

---

The file `rtl/common/smartnic_pkg.vh` is the absolute foundation of the SmartNIC hardware design. It is a Verilog Header (`.vh`) file that contains the global constants, bus widths, network protocol offsets, and metadata structures used by every single module in the repository.

### Why this file exists
In a large SystemVerilog or Verilog design, hardcoding numbers like `512` (for bus width) or `14` (for the start of an IPv4 header) directly into the behavioral modules is an anti-pattern. It leads to "magic numbers" that make the code impossible to maintain. If the architecture upgrades from a 512-bit bus to a 1024-bit bus, searching and replacing every instance of `512` would undoubtedly introduce fatal bugs. This file exists to centralize all absolute parameters.

### What problem it solves
It solves the problem of synchronization across the hardware pipeline. The Packet Parser, Flow Classifier, Queue Manager, and Priority Scheduler all agree on exactly how data is structured because they all `include` this single source of truth.

### Where it fits in the architecture
It sits at the very bottom of the dependency graph. It is purely declarative and does not generate physical logic gates on its own. Instead, it informs the synthesis tool how to size the logic gates for the active modules.

### What would break if this file disappeared
The entire repository would fail to compile. Every module depends on the macros defined here to declare their input/output ports and slice their internal registers.

---

## 2. Background Theory

---

Before diving into the code, a student must understand the core concepts this file represents.

### A. The AXI4-Stream Protocol
Advanced eXtensible Interface 4 (AXI4) Stream is an ARM AMBA protocol used heavily in modern FPGA designs (specifically Xilinx/AMD architectures like the OpenNIC shell). It is designed to move massive amounts of data from a Master to a Slave continuously without needing memory addresses.
* `TDATA`: The actual data payload.
* `TVALID`: The Master asserts this to `1` when the data on `TDATA` is valid.
* `TREADY`: The Slave asserts this to `1` when it is ready to accept data (used for hardware backpressure).
* `TKEEP`: A byte-qualifier. If `TDATA` is 64 bytes wide, `TKEEP` is 64 bits wide. A `1` means the corresponding byte is valid data; a `0` means it is padding (null data).
* `TLAST`: Asserts on the final beat of a packet.
* **`TUSER`**: A sideband signal. The protocol allows designers to attach custom metadata to the packet. This is crucial for our SmartNIC.

### B. Network Protocol Offsets
Network packets (like a web request) are nested dolls of headers. 
* The **Ethernet Header** comes first (14 bytes), containing physical MAC addresses.
* Inside the Ethernet payload is the **IPv4 Header** (typically 20 bytes), containing IP addresses.
* Inside the IPv4 payload is the **UDP or TCP Header**, containing port numbers.
Hardware must know exactly how many bytes into the packet it must look to find a specific piece of information.

### C. Verilog Macros (`define)
In Verilog, ``` `define NAME VALUE ``` creates a text-substitution macro. Before the hardware is synthesized, a preprocessor scans the code and physically replaces every instance of ``` `NAME ``` with `VALUE`. This is identical to `#define` in C/C++.

---

## 3. File Structure Walkthrough

---

The file is divided into five distinct logical sections:
1. **AXI-Stream Bus Widths**: Defines the physical size of the data pipes (`TDATA`, `TKEEP`, `TUSER`).
2. **Ethernet Header Offsets**: Defines where MAC addresses and the EtherType live.
3. **IPv4 Header Offsets**: Defines where IP addresses and protocol numbers live.
4. **UDP Header Offsets**: Defines where source/destination ports live.
5. **TUSER Metadata Format**: Defines the bit-level structure of our custom sideband channel.
6. **Hardware Limits**: Defines the number of queues, queue depths, and classification rules.

Do not skip any of these sections, as they dictate the mathematical limits of the entire SmartNIC.

---

## 4. Line-by-Line Code Explanation

---

### The Header Guard
```verilog
`ifndef SMARTNIC_PKG_VH
`define SMARTNIC_PKG_VH
...
`endif // SMARTNIC_PKG_VH
```
**What it does:** Prevents the file from being included multiple times in the same compilation unit.
**Why it exists:** If `module A` includes the package, and `module B` includes the package, and a top-level module includes both `A` and `B`, the compiler would see duplicate macro definitions and throw an error. The `ifndef` (If Not Defined) guard prevents this.

### AXI-Stream Bus Widths
```verilog
`define AXIS_DATA_WIDTH     512
`define AXIS_KEEP_WIDTH     (`AXIS_DATA_WIDTH / 8)   // 64
`define AXIS_USER_WIDTH     128
```
**What it does:** Defines the fundamental width of the datapath. 
**How it works internally:** The OpenNIC architecture runs the user logic at 250 MHz. To achieve 100 Gbps: `100 Gbps / 250 MHz = 400 bits`. Therefore, a `512-bit` bus guarantees we exceed the line rate. `TKEEP` is mathematically linked to `TDATA`: there is 1 keep bit for every 8 data bits (1 byte). `TUSER` is custom-sized to 128 bits to hold our metadata.

### Ethernet Offsets
```verilog
`define ETH_DST_MAC_OFFSET      0
`define ETH_SRC_MAC_OFFSET      6
`define ETH_ETHERTYPE_OFFSET    12
`define ETH_HEADER_LEN          14

`define ETHERTYPE_IPV4          16'h0800
```
**What it does:** Maps the structure of an IEEE 802.3 Ethernet frame.
**How data flows:** When the very first 512-bit beat of a packet arrives, the Parser knows that bytes 0-5 are the Destination MAC. The `ETHERTYPE_IPV4` is a specific hex value (`0x0800`) used to verify that the encapsulated payload is actually an IPv4 packet.

### IPv4 & UDP Offsets
```verilog
`define IPV4_SRC_IP_OFFSET      12
`define IPV4_DST_IP_OFFSET      16
`define IPV4_HEADER_MIN_LEN     20
`define IPV4_START              `ETH_HEADER_LEN      // 14

`define UDP_START               (`IPV4_START + `IPV4_HEADER_MIN_LEN)  // 34
```
**What it does:** Uses relative and absolute mathematics to locate deep packet fields.
**Engineering Reasoning:** The IPv4 Source IP is located 12 bytes into the IPv4 header. However, the hardware parser sees the *entire* raw packet. Therefore, the absolute physical byte offset in the 512-bit bus for the Source IP is `IPV4_START` (14) + `IPV4_SRC_IP_OFFSET` (12) = Byte 26.

### TUSER Metadata Format
```verilog
`define TUSER_VALID_BIT         0
`define TUSER_IS_IPV4_BIT       1
`define TUSER_IS_UDP_BIT        2
`define TUSER_IS_TCP_BIT        3

`define TUSER_SLICE_ID_HI       7
`define TUSER_SLICE_ID_LO       4
...
`define TUSER_DST_IP_HI         79
`define TUSER_DST_IP_LO         48
```
**What it does:** Defines a proprietary 128-bit structure that travels alongside the packet.
**Why it exists:** If the Parser extracts the Destination IP, the Classifier shouldn't have to extract it again. The Parser writes the Destination IP into bits `[79:48]` of the `TUSER` bus. The Classifier simply reads `TUSER[79:48]`. This saves massive amounts of silicon area (LUTs) because we only parse the packet once.
Bits `[7:4]` are reserved for the `slice_id` (e.g., eMBB vs URLLC), which will be populated by the Flow Classifier.

### Hardware Architectural Limits
```verilog
`define NUM_QUEUES              4       // Number of hardware queues (one per slice)
`define QUEUE_DEPTH             64      // Entries per queue (in simulation; real = deeper)
`define NUM_RULES               16      // Max classifier rules
```
**What it does:** Bounds the physical size of the SmartNIC.
**Engineering Reasoning:** FPGAs have finite resources. A hardware array cannot be dynamically resized at runtime like a `malloc` in C. We must declare exactly how many BRAM queues and TCAM rules the hardware will physically instantiate during synthesis.

---

## 5. Architecture Context

---

### Which files call this file
Every single RTL module in this repository includes this file.
```verilog
`include "smartnic_pkg.vh"
```
### Data Flow
This file does not process data. Instead, it provides the "map" that allows data to flow. The Parser uses the `OFFSET` macros to extract data from `TDATA` and uses the `TUSER_*` macros to write that data into the `TUSER` bus. Downstream, the Queue Manager uses `NUM_QUEUES` to generate the physical BRAMs.

---

## 6. Hardware Interpretation

---

### Resulting Hardware
Because this file contains `define macros, it results in **zero physical logic gates**. 

When the synthesis tool (e.g., Xilinx Vivado) processes a module that uses ``` `AXIS_DATA_WIDTH ```, the preprocessor simply pastes the number `512` into the code. The synthesizer then builds a 512-bit wide wire or register. 

### Timing Implications
There are no direct timing implications from this file. However, setting parameters like `NUM_RULES` excessively high (e.g., `4096`) will force the synthesizer to build a massive TCAM array in `flow_classifier.v`, which will severely degrade the maximum operating frequency (Fmax) and likely cause the design to fail timing closure at 250 MHz.

---

## 7. Design Decisions

---

### Why did the author use `define instead of localparam?
In Verilog, a `localparam` is scoped exclusively to the module it is declared in. A `parameter` can be passed down from a parent module to a child module.
However, for global constants that apply to the *entire architecture* (like the definition of an Ethernet header), passing a `parameter` through every single module hierarchy is extremely tedious and error-prone. 

The author chose ``` `define ``` because it acts globally across the compilation unit, ensuring that if `AXIS_DATA_WIDTH` changes, every module is instantly updated without altering port maps.

### Could they have used a SystemVerilog `package`?
Yes. In modern SystemVerilog, a `package` is preferred over `define macros because packages provide strong type-safety and avoid global namespace pollution. The author likely chose `define macros to maintain strict compatibility with older Verilog-2001 toolchains or because it is a very common legacy pattern in open-source FPGA IP.

---

## 8. Example Execution

---

**Scenario:** The Packet Parser needs to extract the UDP Source Port.

**Input:** A raw 512-bit `TDATA` vector arrives.
**Internal Processing (Conceptual):**
1. The developer wrote: `TDATA[ ( ``UDP_START`` + ``UDP_SRC_PORT_OFFSET`` ) * 8 +: 16 ]`
2. The preprocessor resolves this to: `TDATA[ ( 34 + 0 ) * 8 +: 16 ]`
3. The preprocessor resolves this to: `TDATA[ 272 +: 16 ]` (Bits 272 to 287)
**Output:** The hardware wires bits 272-287 directly into the `TUSER` bus using the `TUSER_SRC_PORT_HI` and `TUSER_SRC_PORT_LO` macros.

---

## 9. Common Beginner Confusions

---

### A. Byte Offsets vs. Bit Offsets
**Confusion:** Beginners often wonder why `ETH_DST_MAC_OFFSET` is `0` but the hardware uses `[47:0]`. 
**Explanation:** Networking standards document packet structures in **Bytes** (Octets). Hardware wires operate in **Bits**. The macros in this file define *Byte* offsets. Whenever these macros are used in the RTL, you will always see them multiplied by 8 to convert them into physical bit indices.

### B. Endianness (Big-Endian vs Little-Endian)
Network protocols transmit data in "Network Byte Order," which is Big-Endian (Most Significant Byte first). AXI-Stream is typically treated as Little-Endian on FPGAs. 
**Explanation:** This file does not handle endian swapping. Downstream modules must be careful when comparing extracted IP addresses to ensure the bytes are not evaluated backward.

---

## 10. Exercises

---

### 1. Questions to Answer
* If you wanted to update the SmartNIC to support 400 Gigabit Ethernet (400GbE) while maintaining the 250 MHz clock speed, what value would you change `AXIS_DATA_WIDTH` to? Calculate it.
* If a new 5G Network Slice specification requires 32 slices instead of 16, which macros in this file must be altered? Would the `TUSER` width need to change?

### 2. Things to Modify
* **Add VLAN Support:** An IEEE 802.1Q VLAN tag adds 4 bytes to the Ethernet header. Modify `ETH_HEADER_LEN` and observe how it shifts the `IPV4_START` and `UDP_START` calculations.
* **Expand TUSER:** Add a new macro `TUSER_TIMESTAMP_HI` and `TUSER_TIMESTAMP_LO` utilizing the `reserved` bits to allow the SmartNIC to stamp packets with a hardware timestamp for latency measurement.
