# SmartNIC 5G Hardware Datapath

Welcome to the **SmartNIC 5G Hardware Datapath** repository. 

This documentation explains the underlying networking concepts, FPGA architecture, and AXI-Stream implementation of the SmartNIC.

## 📚 Documentation

The documentation is structured to follow the life of a 5G packet through the silicon:

* **[1. Foundational Definitions](docs/01_smartnic_pkg.md)**
  * Details AXI-Stream bus widths, Ethernet/IPv4 offsets, and Verilog preprocessor parameters.
* **[2. The Fast Path Ingress](docs/02_packet_parser.md)**
  * Explains 512-bit line-rate packet parsing, combinatorial extraction, and hardware pipelining.
* **[3. The Core Datapath Routing](docs/03_flow_classifier.md)**
  * Covers TCAM emulation, subnet wildcard matching, and Priority Encoders.
* **[4. Traffic Queuing & Buffering](docs/04_axi_stream_fifo.md)**
  * Explains synchronous circular buffers, N+1 pointer math, and AXI-Stream FWFT handshaking.
* **[5. Multi-Tenant Traffic Storage](docs/05_queue_manager.md)**
  * Covers 5G QoS Multi-Tenant queuing, Head-of-Line blocking, and BRAM partitioning.
* **[6. The Hardware QoS Egress](docs/06_priority_scheduler.md)**
  * Details Strict Priority QoS algorithms and nested combinatorial unrolling.
* **[7. Defeating Starvation](docs/07_token_bucket.md)**
  * Explains the Token Bucket algorithm (CIR/CBS) and hardware rate limiting.
* **[8. The Software Control Plane](docs/08_axilite_csr.md)**
  * Covers Memory-Mapped I/O (MMIO), AXI4-Lite slave state machines, and the commit trigger architecture.

## 🛠️ Simulating the Hardware

This repository includes Icarus Verilog testbenches to verify the hardware modules.

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
