# Chapter 1: Comprehensive Theoretical Foundations and Project Scope

## 1.1 Introduction to the 5G Era
Due to the huge success of the 4th generation of cellular communication systems based on LTE technologies, 5G is designed to not only provide higher data rates but also to support a diverse set of new services originating from vertical industries. The International Telecommunication Union (ITU) has established diverse, application-specific requirements to be supported by the 5th Generation Mobile Network. 

Compared to well-established 4G communication systems, the requirements for these new services are radically higher: sub-millisecond latency (e.g., 1ms for cellular communication support of autonomous driving, remote surgery, and industrial automation) and massive bit rates in the realm of Gigabits per second (Gbps). Despite the enhancements introduced for 5G NR (New Radio) with Release 15 by 3GPP, it is exceptionally challenging and highly inefficient to meet all service requirements within a single monolithic network infrastructure. To fulfill the requirements set by the ITU, **Network Slicing** has been proposed as the primary mechanism to configure logically isolated networks tailored to each specific use case.

Three main service categories have been defined as the foundational 5G Use-Cases:
1. **Enhanced Mobile Broadband (eMBB):** A data-driven use case for serving mobile users requiring extreme data rates (e.g., 10 Gbps peak). Applications include 3D video streaming, UHD screens, and augmented reality.
2. **Ultra Reliable Low Latency Communication (URLLC):** Designed to serve mission-critical communications with exceptionally strict latency and reliability requirements. The target is 1ms end-to-end latency with 99.999% reliability.
3. **Massive Machine Type Communication (mMTC):** Engineered to serve a massive density of devices (up to 1,000,000 devices per square kilometer), such as Internet of Things (IoT) sensors, which send data sporadically and require battery lives extending to several years.

---

## 1.2 5G System Overview and Service-Based Architecture (SBA)

The static, point-to-point architecture utilized in 4G LTE is fundamentally insufficient to fulfill the diverse requirements of the 5G era. This deficiency catalyzed a redesign of the network architecture to be profoundly more flexible. This flexibility is achieved by separating Control Plane Functionalities from User Plane Functionalities—a paradigm shift enabled by network virtualization techniques including Network Function Virtualization (NFV) and Software Defined Networking (SDN). 

### 1.2.1 Core Network Functions (CNFs)
The 5G Core Network (5GC) abandons legacy point-to-point interfaces in favor of a cloud-native **Service-Based Architecture (SBA)**. In the SBA, Core Network Functions (CNFs) residing in the Control Plane (CP) communicate through a service model interface using RESTful HTTP/2 JSON APIs. Each Network Function (NF) can behave as a service producer by offering services to other NFs, or as a service consumer by requesting services.

The most critical CNFs defined by 3GPP include:
* **Access and Mobility Management Function (AMF):** Manages the registration procedure of UEs, mobility procedures, access authentication, and authorization. It terminates the N1 and N2 interfaces from the UE and NG-RAN, acting as the communication bridge between the Access Stratum and Non-Access Stratum.
* **Session Management Function (SMF):** Provides Session Management (e.g., Session Establishment, Modification, and Release). It allocates IP addresses to UEs and terminates the N4 interface with the UPF.
* **User Plane Function (UPF):** The foundational element of the datapath. It is in charge of handling packet inspection, routing, and forwarding. Furthermore, it supports QoS rules per flow and reports traffic usage to the SMF.
* **Network Repository Function (NRF):** A newly introduced element in 5G that acts as the central registry. NFs register their services on the NRF and query the NRF to discover the services of other network components.
* **Policy Control Function (PCF):** Provides policy rules to Control Plane functions, ensuring that QoS and charging rules are enforced across the network.
* **Unified Data Management (UDM):** Interacts with control plane functions to provide subscribed user data, handling user identification and access authorization.

---

## 1.3 The Cloud-RAN (C-RAN) Architecture

The Radio Access Network (NG-RAN) has undergone a fundamental architectural evolution to support cloud deployment. The Next Generation NodeB (gNB) is no longer a monolithic hardware appliance but is split into distinct functional entities.

### 1.3.1 Centralized Unit (CU) and Distributed Unit (DU)
3GPP has proposed several RAN protocol split options. The most prominent is **Split Option 2** (the PDCP-RLC split). In this architecture, the gNB is decomposed into:
1. **Centralized Unit (CU):** Hosts the higher-layer, non-time-sensitive functionalities of the radio protocol stack, specifically the Radio Resource Control (RRC), Service Data Adaptation Protocol (SDAP), and Packet Data Convergence Protocol (PDCP).
2. **Distributed Unit (DU):** Hosts the time-sensitive functionalities: Radio Link Control (RLC), Media Access Control (MAC), and the high Physical (PHY) layer.

To connect these entities, 3GPP defined the **F1 interface**. The CU itself can be further decomposed to strictly enforce Control and User Plane Separation (CUPS):
* **CU-CP (Control Plane):** Hosts the RRC and the control plane part of the PDCP. It communicates with the DU via the F1-C interface.
* **CU-UP (User Plane):** Hosts the SDAP and the user plane part of the PDCP. It communicates with the DU via the F1-U interface.

The interface bridging the CU-CP and CU-UP is defined as the **E1 interface**. This extreme disaggregation allows the CU to be deployed in centralized datacenters as Virtual Network Functions (VNFs) running on Commercial Off-The-Shelf (COTS) x86 servers, while the DU is deployed closer to the cell site to meet the rigid latency constraints of the MAC scheduler and HARQ retransmissions.

### 1.3.2 The O-RAN Alliance Architecture
While 3GPP standardized the CU/DU split, they did not standardize the split between the DU and the actual Radio Unit (RU), leaving the "Fronthaul" interface entirely vendor-proprietary (e.g., CPRI). 

To prevent vendor lock-in, the **O-RAN Alliance** (driven by major operators like AT&T and China Mobile) established an open architecture. O-RAN introduces the **O-RU (O-RAN Radio Unit)**, which houses the RF module, power amplifiers, and low-PHY digital-to-analog converters. O-RAN specifically standardizes the Open Fronthaul Interface connecting the O-DU to the O-RU, typically utilizing eCPRI over Ethernet. O-RAN also introduces the **RAN Intelligent Controller (RIC)** for AI-driven radio resource management.

---

## 1.4 Radio Protocol Stack Analysis

Understanding the impact of Network Slicing and QoS requires a deep analysis of the 5G NR Radio Protocol Layers.

### 1.4.1 Service Data Adaptation Protocol (SDAP)
A completely new protocol introduced in 5G specifically to handle QoS traffic. SDAP performs the mapping of incoming IP traffic (from the UPF) into 5G QoS Flows based on QoS Rules signaled by the SMF. It subsequently maps these QoS Flows into physical Access Network resources (Data Radio Bearers - DRBs). SDAP inserts a header containing the 6-bit **QoS Flow Identifier (QFI)**, ensuring that traffic is distinctly marked as it traverses the air interface.

### 1.4.2 Packet Data Convergence Protocol (PDCP)
The PDCP sublayer performs header compression (RoHC), ciphering, deciphering, and integrity protection. Crucially for URLLC slices, the PDCP layer supports **Packet Duplication**. When configured by the RRC, PDCP submits the exact same PDCP PDU twice to two independent RLC entities (Primary and Secondary). This utilizes dual transmission paths (e.g., across different carrier frequencies) to massively increase reliability and reduce latency, directly supporting the 99.999% reliability requirement of URLLC.

### 1.4.3 Radio Link Control (RLC)
The RLC handles data transmission modes: Transparent Mode (TM), Unacknowledged Mode (UM), and Acknowledged Mode (AM). RLC AM provides error correction through Automatic Repeat Request (ARQ). Unlike LTE, 5G RLC does not provide in-order delivery to higher layers; this responsibility was moved exclusively to the PDCP layer to reduce processing delays.

### 1.4.4 Media Access Control (MAC)
The MAC layer is the brain of the Distributed Unit (DU). It multiplexes logical channels into transport blocks, handles HARQ error correction, and performs **Logical Channel Prioritization (LCP)**. The scheduling algorithm—which assigns Physical Resource Blocks (PRBs) and Modulation and Coding Schemes (MCS) to UEs—resides here. 3GPP does not standardize the MAC scheduler algorithm; it is entirely left to vendor implementation. 

For URLLC traffic, the MAC layer supports **Configured Grants** (SPS - Semi-Persistent Scheduling) in the Uplink, allowing UEs to transmit without enduring the latency overhead of requesting a scheduling grant via the PDCCH. In the Downlink, the MAC supports **Pre-emptive Scheduling**, allowing the gNB to instantaneously interrupt a massive eMBB transmission to punch through a latency-critical URLLC packet.

---

## 1.5 Network Slicing Orchestration and Identification

A network slice is an End-to-End (E2E) logical network running on a shared underlying infrastructure, offering specific network capabilities.

### 1.5.1 S-NSSAI and Slice Selection
Network Slices are globally identified using a 32-bit variable known as the **Single-Network Slice Selection Assistance Information (S-NSSAI)**, which comprises:
* **Slice/Service Type (SST):** An 8-bit identifier defining the expected behavior. Standardized values include SST 1 (eMBB), SST 2 (URLLC), SST 3 (MIoT), and SST 4 (V2X).
* **Slice Differentiator (SD):** A 24-bit optional field allowing operators to distinguish among multiple slices of the same SST (e.g., distinguishing a BMW URLLC slice from an Audi URLLC slice).

During the Initial Access procedure, the UE transmits a "Requested NSSAI" to the gNB. The gNB utilizes this identifier to route the UE's signaling traffic to the specific AMF instance equipped to handle that slice.

### 1.5.2 Orchestration Platforms: ONAP vs. MOSAIC5G
To manage the lifecycle of these slices (instantiation, maintenance, and teardown), a comprehensive orchestrator is required.
* **ONAP (Open Networking Automation Platform):** A massive, comprehensive orchestration platform providing policy-driven automation of physical and virtual network functions. It utilizes the Service Design and Creation (SDC) component for modeling and the Service Orchestrator (SO) based on BPMN workflows. However, ONAP's immense computational overhead (requiring dozens of cloud VMs) makes it highly resource-intensive.
* **MOSAIC5G:** A lighter-weight orchestration and management framework focusing specifically on agile RAN and CN deployments. It utilizes the Trirematics orchestrator and FlexRIC platforms, leveraging Kubernetes CRDs (Custom Resource Definitions) and Operators to deploy network slices rapidly with significantly lower computational overhead than ONAP.

---

## 1.6 The Hardware Datapath: Target Architecture (OpenNIC)

While SDN orchestrators (like ONAP) handle the control plane, the actual User Plane Function (UPF) data must be processed at immense speeds. At 100 Gbps, CPUs executing software virtual switches are overwhelmed, resulting in latency spikes that inherently violate URLLC constraints.

Therefore, the routing, QoS scheduling, and flow classification must be pushed down into silicon. This project utilizes the **AMD OpenNIC Shell** to deploy a custom hardware datapath onto an Alveo FPGA.

The OpenNIC architecture enforces rigid constraints:
1. **CMAC Subsystem:** A hard IP block handling the 100G Ethernet MAC layer, operating at **322 MHz**.
2. **QDMA Subsystem:** A hard IP block managing PCIe DMA queues to the host server, operating at **250 MHz**.
3. **The User Logic Box:** The target deployment zone for our custom Verilog datapath. It sits between the CMAC and QDMA, operating synchronously at **250 MHz**.

### 1.6.1 The 512-bit AXI4-Stream Interface
To process 100 Gbps at a conservative FPGA clock speed of 250 MHz, the datapath bus must be extremely wide.
* Formula: `100 Gbps / 250 MHz = 400 bits per cycle.`
* Standard Design: OpenNIC utilizes an industry-standard **512-bit wide AXI4-Stream bus**.

This architecture means that every single clock cycle, exactly **64 bytes** of packet data are presented to our Verilog logic. The hardware modules we design (Packet Parser, Flow Classifier, Priority Scheduler) must be capable of processing this massive 512-bit vector entirely in combinatorial logic, ensuring line-rate performance without dropping a single packet.

In the subsequent chapters, we will detail the precise mathematical models and RTL synthesis strategies required to parse these 512-bit vectors, emulate SRAM-based TCAMs for classification, and enforce Strict Priority Hardware QoS.
