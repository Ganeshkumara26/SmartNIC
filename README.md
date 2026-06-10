# SmartNIC 5G Hardware Datapath

Welcome to the **SmartNIC 5G Hardware Datapath** repository. 

Unlike traditional open-source projects, the documentation in this repository is designed to act as a **university-grade textbook**. It does not merely summarize the code; it teaches the underlying theoretical networking concepts, FPGA architectures, and AXI-Stream physics necessary to understand *why* the hardware was designed this way from first principles.

## 📚 The Curriculum

Please read the chapters in the following order to trace the life of a 5G packet as it travels through the silicon:

* **[Chapter 1: Foundational Definitions](docs/Chapter_1_smartnic_pkg.md)**
  * Teaches AXI-Stream bus widths, Ethernet/IPv4 offset math, and how Verilog preprocessors map global parameters to silicon logic gates.
* **[Chapter 2: The Fast Path Ingress](docs/Chapter_2_packet_parser.md)**
  * Teaches 512-bit line-rate packet parsing limits, combinatorial extraction matrices, and hardware pipelining.
* **[Chapter 3: The Core Datapath Routing](docs/Chapter_3_flow_classifier.md)**
  * Teaches TCAM emulation, subnet wildcard matching, and the spatial unrolling of Priority Encoders into massive FPGA logic trees.
* **[Chapter 4: Traffic Queuing & Buffering](docs/Chapter_4_axi_stream_fifo.md)**
  * Teaches Synchronous circular buffers, the N+1 pointer math to distinguish full/empty states, and AXI-Stream FWFT handshaking.
* **[Chapter 5: Multi-Tenant Traffic Storage](docs/Chapter_5_queue_manager.md)**
  * Teaches 5G QoS Multi-Tenant queuing, the catastrophic effects of Head-of-Line blocking, and BRAM partitioning strategies.
* **[Chapter 6: The Hardware QoS Egress](docs/Chapter_6_priority_scheduler.md)**
  * Teaches Strict Priority QoS algorithms, the Starvation problem, and nested combinatorial unrolling.
* **[Chapter 7: Defeating Starvation](docs/Chapter_7_token_bucket.md)**
  * Teaches the Token Bucket algorithm (CIR/CBS), hardware rate limiting, and mathematical network shaping.
* **[Chapter 8: The Software Control Plane](docs/Chapter_8_axilite_csr.md)**
  * Teaches Memory-Mapped I/O (MMIO), AXI4-Lite slave state machines, and the hardware/software boundary commit trigger architecture.

## 🛠️ Simulating the Hardware

This repository includes a full suite of Icarus Verilog testbenches to mathematically prove the assertions made in the textbook.

**Prerequisites:**
You must have [Icarus Verilog](https://bleyer.org/icarus/) installed and added to your system `PATH`.

**Execution:**
A PowerShell script is provided to automatically compile and run the simulations.
```powershell
# Run the complete test suite
.\build.ps1 all

# Run specific modules
.\build.ps1 parser
.\build.ps1 classifier
.\build.ps1 queue
.\build.ps1 scheduler
```

The resulting `*.vcd` waveform files will be deposited in the `sim/` directory and can be analyzed using GTKWave.
