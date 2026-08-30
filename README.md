# 5G SmartNIC Datapath

## Overview

The SmartNIC project is a highly modular, FPGA-accelerated datapath designed for 5G network environments. Built natively in hardware using AXI-Stream interfaces, it provides ultra-low-latency packet parsing, flow classification, traffic shaping, and host DMA integration. 

By pushing networking logic directly into the silicon fabric, this architecture effectively offloads CPU polling and software networking stacks, isolating multi-tenant traffic securely at line-rate.

## Architecture Pipeline

The system is composed of several rigorously partitioned hardware engines:

1. **Packet Parser (`packet_parser.v`)**
   - Ingests raw network frames via AXI-Stream.
   - Extracts L2/L3/L4 packet headers natively in combinatorial logic.
   - Generates and forwards metadata alongside the payload.

2. **Flow Classifier (`flow_classifier.v`, `rss_hash.v`, `rss_steer.v`)**
   - Matches incoming flows against hardware TCAM rules for subnet filtering.
   - Applies Receive-Side Scaling (RSS) hashing to uniformly distribute traffic.
   - Assigns unique Slice IDs to packets for multi-tenant isolation.

3. **Multi-Queue Manager (`queue_manager.v`)**
   - Maintains dedicated circular-buffer queues for each network slice.
   - Buffers packet beats while tracking fill levels and full/empty flags.

4. **QoS Scheduler (`qos_scheduler.v`, `priority_scheduler.v`, `token_bucket.v`)**
   - Applies Token Bucket algorithms for precise ingress/egress rate limiting.
   - Enforces Strict Priority scheduling across multiple queues.
   - Dequeues traffic strictly based on SLA guarantees.

5. **Control Plane (`axilite_csr.v`, `stats_engine.v`)**
   - Exposes memory-mapped Control and Status Registers (CSR) via an AXI4-Lite bus.
   - Allows a host processor to dynamically update TCAM rules, Token Bucket rates, and monitor real-time traffic statistics.

6. **Host DMA Bridges (`qdma_c2h_bridge.v`, `qdma_h2c_bridge.v`)**
   - Bridges the internal datapath to the host system via standardized QDMA (Card-to-Host and Host-to-Card) data streams.

## Resource Utilization & Timing

Target Device: **Xilinx Artix-7 (xc7a100tcsg324-1)**
Target Clock: **100 MHz (10ns period)**

The hardware is deeply pipelined to guarantee deterministic line-rate processing:
- **Slice LUTs:** 10,831 (17.08%)
- **Slice Registers:** 7,982 (6.29%)
- **BRAM:** 0 (Queues configured to use Distributed RAM for synthesis validation)
- **Worst Negative Slack (WNS):** +0.078ns (Setup) / +0.040ns (Hold)

The design successfully closes timing at 100MHz, with the critical path residing primarily within the header parser logic.
