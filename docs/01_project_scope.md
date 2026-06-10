# 1. Project Scope & Architecture Overview

## The Evolution of the SmartNIC
Traditional Network Interface Cards (NICs) simply pass Ethernet frames between the wire and the host CPU memory. In modern 5G networks and hyper-scale datacenters, the sheer volume of packets (millions per second) overwhelms the host CPU if it has to classify, route, or drop every packet in software.

A **SmartNIC** offloads this packet processing into dedicated hardware (an FPGA or ASIC). By doing so, the SmartNIC handles the "Fast Path" (routine data movement) at line-rate, freeing the CPU to focus entirely on application logic.

## 5G Network Slicing & Quality of Service (QoS)
5G introduces the concept of **Network Slicing**—creating isolated virtual networks over the same physical infrastructure. Two major 5G slices are:
1. **URLLC (Ultra-Reliable Low-Latency Communication):** Used for autonomous driving and remote surgery. Packets must experience absolutely minimal queuing delay.
2. **eMBB (Enhanced Mobile Broadband):** Used for 4K video streaming. Requires high bandwidth but can tolerate higher latency.

The goal of this SmartNIC is to implement **hardware-accelerated QoS**. When a mix of URLLC and eMBB packets arrive simultaneously, the SmartNIC must identify them in hardware and guarantee that the URLLC packets bypass the eMBB queue, proving a measurable latency reduction.

---

## High-Level Architecture

The SmartNIC is logically split into two domains: the **Fast Path (Datapath)** and the **Slow Path (Control Plane)**.

```mermaid
graph TD
    subgraph Host [Host Server (PCIe)]
        A[Network Stack]
        B[Application Software]
        A <--> B
    end

    subgraph FPGA [FPGA SmartNIC]
        subgraph Datapath [Hardware Datapath / Fast Path]
            P[Packet Parser] --> C[Flow Classifier]
            C --> Q[Queue Manager]
            Q --> S[Priority Scheduler]
        end

        subgraph Control [RISC-V Control Plane / Slow Path]
            R[RocketChip Core]
            FW[C Firmware]
            R --> FW
        end
        
        Control -.->|AXI-Lite| Datapath
        Host <-->|QDMA PCIe| Q
    end

    subgraph Network [Physical Network]
        MAC[100G Ethernet MAC]
    end

    MAC --> P
    S --> MAC
    
    classDef hardware fill:#f9f,stroke:#333,stroke-width:2px;
    classDef software fill:#bbf,stroke:#333,stroke-width:2px;
    class P,C,Q,S hardware;
    class R,FW,A,B software;
```

### The 3-Tier Development Roadmap

1. **Tier 1: Simulation-First MVP (Current Status)**
   - Pure Verilog RTL implementation of the datapath (Parser → Classifier → Queue → Scheduler).
   - Validation via Python packet generation and Icarus Verilog testbenches.
   - Proof that Strict Priority scheduling reduces URLLC latency.

2. **Tier 2: Control Plane & Advanced QoS**
   - Integration of a RISC-V soft-core (e.g., RocketChip) running C firmware.
   - Adding a Token Bucket rate limiter to prevent the URLLC queue from starving the Best-Effort queue.
   - Dynamic updating of classifier rules via AXI4-Lite.

3. **Tier 3: OpenNIC Physical Deployment**
   - Porting the design into the "User Role" partition of the AMD OpenNIC shell.
   - Deploying onto an AMD Alveo U200/U250 FPGA.
   - 100 Gbps line-rate validation.
