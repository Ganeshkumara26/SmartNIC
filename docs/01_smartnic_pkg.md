# SmartNIC Global Parameters (`smartnic_pkg.vh`)

## 1. Purpose of the File
`rtl/common/smartnic_pkg.vh` defines the foundational constants, bus widths, and protocol offsets for the entire SmartNIC architecture. It acts as the single source of truth for the hardware configuration.

## 2. AXI-Stream Data Bus Configuration
The SmartNIC uses a massive 512-bit datapath (`AXIS_DATA_WIDTH = 512`) to achieve 100 Gbps line-rate processing at 250 MHz.
- `AXIS_KEEP_WIDTH = 64`: Specifies which of the 64 bytes in the 512-bit data beat are valid.
- `AXIS_USER_WIDTH = 128`: Sideband metadata passed alongside the packet (e.g., routing decisions, valid bits).

## 3. Protocol Header Offsets
Packet parsing in hardware is accomplished via static bit-slicing.
- The MAC header is 14 bytes (112 bits). 
- To locate the IP header, the hardware indexes exactly at bit 112: `ETH_HEADER_SIZE = 112`.
- Subsequent fields (Source IP, Dest IP, Protocol) are extracted using fixed bit-offsets defined in this package, allowing combinatorial extraction in a single clock cycle.

## 4. Architectural Scaling
The memory and routing capabilities are parameterized:
- `NUM_QUEUES = 4`: Maps directly to the four 5G Network Slices (URLLC, Voice, eMBB, IoT).
- `MAX_RULES = 16`: Defines the size of the TCAM-emulating Flow Classifier. Modifying this parameter directly alters the FPGA LUT and register utilization during synthesis.
