# SmartNIC Project

This is a hardware project for a 5G Datapath implementation on an FPGA. 

We used Verilog to design the networking logic and AXI-Stream for the bus interfaces. The goal was to route and manage 5G packets through the silicon efficiently.

## Modules Overview
* **Packet Parser:** Extracts the packet headers and uses combinatorial logic.
* **Flow Classifier:** Emulates TCAM for subnet matching.
* **Queuing:** Uses AXI-Stream FIFOs with circular buffers.
* **Queue Manager:** Handles multi-tenant traffic and BRAM partitioning.
* **Scheduler:** Implements strict priority QoS.
* **Token Bucket:** Implements rate limiting.
* **Control Plane:** Uses Memory-Mapped I/O (MMIO) and AXI4-Lite for configuration.

## Simulation
We used Icarus Verilog for testing the modules.

To run the tests, use the powershell script:
`
.\build.ps1 all
`
The waveform files are saved in the sim/ folder.
