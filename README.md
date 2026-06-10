# 5G SmartNIC with Hardware QoS

A simulation-first FPGA SmartNIC packet processing accelerator for 5G network slicing, featuring hardware-accelerated Quality of Service (QoS) and designed for future integration with the OpenNIC shell and a RISC-V control plane.

## Documentation Reference Guide
This repository contains a comprehensive academic-grade documentation suite. If you are learning about SmartNIC architecture, start here:

1. **[Project Scope & Architecture](docs/01_project_scope.md)** - 5G slicing, Fast Path vs. Slow Path.
2. **[Datapath Interfaces](docs/02_datapath_interfaces.md)** - 512-bit AXI-Stream and `TUSER` metadata.
3. **[Packet Parser](docs/03_packet_parser.md)** - Line-rate header extraction state machine.
4. **[Flow Classifier](docs/04_flow_classifier.md)** - TCAM rule matching and Network Slice assignment.
5. **[Queue Manager](docs/05_queue_manager.md)** - Circular buffer BRAM mechanics.
6. **[Priority Scheduler](docs/06_priority_scheduler.md)** - Strict priority QoS and latency reduction.
7. **[Rate Limiting (Future)](docs/07_rate_limiting.md)** - Token Bucket traffic shaping theory.
8. **[RISC-V Control Plane (Future)](docs/08_riscv_control_plane.md)** - AXI-Lite memory mapping the Fast Path.
9. **[Verification Framework](docs/09_verification_framework.md)** - Python packet generation and Verilog testing.

## Prerequisites

To run the simulations, you need the **OSS CAD Suite** (Icarus Verilog, GTKWave, Yosys).
We have provided an automated installer for Windows:
```powershell
.\install_eda_tools.ps1
```

## Running Simulations

We use a custom PowerShell build script (`build.ps1`) to compile and run the testbenches.

```powershell
# 1. Generate random 5G test packets
.\build.ps1 genpackets

# 2. Run all module testbenches
.\build.ps1 all

# Or run modules individually:
.\build.ps1 parser
.\build.ps1 classifier
.\build.ps1 queue
.\build.ps1 scheduler  # This is the master QoS latency test
```

## Directory Structure
```
├── docs/                 # Detailed architectural documentation
├── rtl/                  # Synthesizable Verilog hardware source code
│   ├── common/           # Shared AXI-Stream FIFOs and Headers
│   ├── parser/           # Header extraction
│   ├── classifier/       # TCAM routing rules
│   ├── queue/            # Multi-queue BRAM buffers
│   └── scheduler/        # QoS transmission scheduling
├── tb/                   # Verilog Testbenches for each module
├── scripts/              # Python packet generator
├── sim/                  # Generated simulation waveforms (.vcd) and logs
├── build.ps1             # Windows simulation runner
└── Makefile              # Linux simulation runner
```
