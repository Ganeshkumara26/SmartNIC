# Chapter 6: The Slow Path — RISC-V Control Plane Integration

## 6.1 Introduction: The Limits of the Fast Path
Chapters 2 through 5 meticulously defined the architectural synthesis of the SmartNIC **Fast Path** (the pure Verilog datapath comprising the Parser, Classifier, Queue Manager, and Priority Arbiter). Operating at an internal clock frequency of 250 MHz across a 512-bit AXI4-Stream bus, this silicon-level pipeline achieves the 100 Gbps line-rate throughput demanded by 5G Enhanced Mobile Broadband (eMBB) while mathematically guaranteeing the sub-millisecond latency required for Ultra-Reliable Low-Latency Communication (URLLC).

However, pure hardware dataplanes suffer from a critical deficiency: **inflexibility**. 

The parameters governing the Fast Path—such as the IP addresses assigned to specific 5G Network Slices, the capacity bounds of the Token Buckets, and the strict priority rankings of the queues—are fundamentally dynamic in a real-world 5G ecosystem. If a network administrator (via an orchestrator like ONAP or MOSAIC5G) issues a command to instantiate a new network slice or modify the bandwidth allocation of an existing eMBB slice, the underlying hardware cannot be physically re-synthesized and flashed while live traffic is flowing. 

To bridge the gap between the dynamic 5G Control Plane and the rigid Verilog Fast Path, the SmartNIC architecture introduces the **Slow Path**: a fully functional Central Processing Unit (CPU) embedded directly within the FPGA fabric.

---

## 6.2 System-on-Chip (SoC) Architecture: The RISC-V Subsystem

Rather than relying on the host server's CPU to manage the Fast Path (which would incur massive latency penalties across the PCIe bus), this architecture instantiates a **Soft-Core Processor** directly onto the AMD Alveo FPGA.

### 6.2.1 The RISC-V RocketChip Generator
To provide the computational logic for the Slow Path, we leverage the **RISC-V** Instruction Set Architecture (ISA), an open-standard architecture highly favored in modern academic and industrial VLSI research. Specifically, the SmartNIC utilizes the **RocketChip** generator (developed via the UC Berkeley Chipyard framework) to instantiate a 32-bit, in-order, single-issue CPU core.

This RISC-V core is synthesized within the OpenNIC shell alongside the custom Verilog datapath, creating a true **System-on-Chip (SoC)**.

### 6.2.2 The AXI4-Lite Memory Map
The communication bridge between the RISC-V CPU (the Slow Path) and the Verilog modules (the Fast Path) is realized through the **AMBA AXI4-Lite** protocol. 

Unlike the massive 512-bit AXI4-Stream bus—which is designed for continuous, address-less rivers of packet data—AXI4-Lite is a 32-bit, memory-mapped interface designed for precise read/write operations to specific hardware registers.

```mermaid
graph TD
    subgraph "The Slow Path (Control Plane)"
        CPU[RISC-V RocketChip Core<br>32-bit ISA]
        BRAM[Instruction/Data Memory]
        CPU <--> BRAM
    end

    subgraph "The Interconnect"
        AXI((AXI4-Lite Crossbar))
    end

    subgraph "The Fast Path (Data Plane)"
        P[Packet Parser]
        C[Flow Classifier (SR-TCAM)]
        Q[Queue Manager]
        S[Priority Arbiter (Token Buckets)]
    end

    CPU -->|Memory-Mapped IO| AXI
    
    AXI -.->|Address: 0x4000_1000| P
    AXI -.->|Address: 0x4000_2000| C
    AXI -.->|Address: 0x4000_3000| Q
    AXI -.->|Address: 0x4000_4000| S
```

As specified in the *OpenNIC Technical Reference Guide*, the Control Interface provided to the User Logic Box runs at **125 MHz**. The RISC-V core initiates a transaction by asserting a physical memory address (e.g., `0x4000_2004`) on the AXI-Lite bus. The AXI Crossbar decodes this address and routes the 32-bit data payload precisely to the configuration registers inside the Flow Classifier.

---

## 6.3 Firmware Operations and Network Orchestration

With the physical SoC architecture established, the RISC-V core is flashed with **Bare-Metal C Firmware**. This firmware executes an infinite loop, acting as the localized brain of the SmartNIC. It communicates asynchronously with the host server's 5G Core Network software (e.g., the Session Management Function - SMF) via a PCIe Mailbox or designated control queues, translating high-level 5G policies into raw hardware register writes.

The firmware performs three mission-critical orchestration functions:

### 6.3.1 Dynamic Flow Classification (TCAM Updates)
When the 5G Core Network establishes a new PDU Session and maps an IP flow to a specific QoS Flow Identifier (QFI), the host server sends the Packet Detection Rules (PDRs) to the RISC-V core. 
The RISC-V firmware calculates the required bit-masks for the SR-TCAM (as detailed in Chapter 3). It then performs AXI-Lite writes to the base address of the Flow Classifier (e.g., `0x4000_2000`), dynamically updating the BRAM partition tables. The Verilog hardware instantaneously begins routing the new IP flow to the correct Network Slice (e.g., URLLC) without dropping a single packet.

### 6.3.2 QoS Parameter Tuning (Token Bucket Updates)
The Session Management Function (SMF) strictly regulates the Aggregate Maximum Bit Rate (Session-AMBR) for non-guaranteed (Non-GBR) slices like eMBB. If the orchestrator commands a bandwidth throttle (e.g., reducing the eMBB slice from 50 Gbps to 20 Gbps due to network congestion), the RISC-V firmware calculates the new Token Bucket mathematical parameters (the `Token_Step`). 
It writes these new parameters via AXI-Lite to the Priority Arbiter (e.g., `0x4000_4010`). The hardware rate limiter immediately restricts the flow of tokens to the eMBB queue, enforcing the new QoS policy in real-time.

### 6.3.3 Telemetry and Observability Reporting
To satisfy the requirements of advanced orchestration platforms like ONAP and MOSAIC5G, the SmartNIC must provide continuous, high-fidelity telemetry data. 
Every Verilog module in the Fast Path is equipped with hardware counters (e.g., *Packets Received*, *Bytes Dropped due to Backpressure*, *Tokens Exhausted*). The RISC-V core periodically reads these counters via AXI-Lite, aggregates the statistics, and dispatches a comprehensive health report up the PCIe bus to the host server. This closed-loop feedback mechanism enables the 5G network administrators to achieve complete observability over the physical slice infrastructure.

---

## 6.4 Conclusion
The integration of a RISC-V Soft-Core processor with a highly optimized, 512-bit Verilog datapath yields a robust, academically rigorous 5G SmartNIC architecture. By delegating static, line-rate tasks to the silicon "Fast Path" and complex, dynamic policy enforcement to the CPU "Slow Path," this design unequivocally satisfies the extreme throughput, latency, and isolation requirements inherent to 5G Network Slicing and Hardware QoS.
