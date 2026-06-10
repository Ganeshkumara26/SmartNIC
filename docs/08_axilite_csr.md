# AXI-Lite Control and Status Registers (`axilite_csr.v`)

## 1. Purpose of the File
`rtl/control/axilite_csr.v` bridges the high-speed 250 MHz Datapath with the software Control Plane. It provides an AXI4-Lite slave interface, allowing a CPU (like an embedded RISC-V core or a PCIe host) to dynamically configure the routing rules and QoS parameters using standard memory writes.

## 2. Memory-Mapped I/O (MMIO)
The module translates 32-bit Memory-Mapped I/O addresses into physical hardware configurations.
- The base address (e.g., `0x4000_0000`) is routed to the module by the SoC interconnect.
- The address decoder extracts the lower 12 bits (the offset) and maps it to specific hardware configuration wires.
- Multiple sub-byte parameters (like Priority and Queue ID) are bit-packed into a single 32-bit CPU write to conserve AXI bus bandwidth.

## 3. The Commit Trigger Architecture
Setting a 128-bit routing rule requires multiple sequential 32-bit CPU writes. If the hardware applied these writes instantly, it could misroute a packet using a "half-updated" rule.
To prevent this, the CSR block caches the writes in temporary registers. The hardware does not apply them to the Datapath until the CPU writes to a specific Trigger Address (Offset `0x000` or `0x100`). This generates a single-cycle `wr_en` pulse, atomically committing the entire configuration block simultaneously.

## 4. AXI4-Lite Handshaking
The state machine implements the standard AXI-Lite 5-channel handshake, safely synchronizing the Write Address (`AW`), Write Data (`W`), and Write Response (`B`) channels to ensure data integrity across the system bus.
