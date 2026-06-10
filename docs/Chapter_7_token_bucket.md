# Chapter 7: Defeating Starvation (`token_bucket.v`)

---

## 1. Purpose of the File

---

The file `rtl/scheduler/token_bucket.v` acts as a mathematical speed-limit governor.

In Chapter 6, we designed the `priority_scheduler.v` using a **Strict Priority** algorithm. While excellent for ensuring 5G URLLC (Ultra-Reliable Low-Latency Communication) packets are transmitted immediately, it creates a fatal vulnerability: **Starvation**. If Queue 0 receives an infinite flood of traffic, it will permanently monopolize the output link, and Queues 1, 2, and 3 will never be allowed to transmit.

### What problem it solves
It solves starvation by implementing **Hardware Rate Limiting**. Instead of allowing Queue 0 to consume 100% of the 100Gbps pipe, the network administrator can assign Queue 0 a strict bandwidth quota (e.g., 10 Gbps). If Queue 0 exceeds this quota, it is temporarily disqualified from the priority arbitration, allowing the lower-priority queues their fair turn to transmit.

---

## 2. Background Theory

---

### A. The Token Bucket Algorithm
Networking theory relies on the "Token Bucket" algorithm for traffic policing and shaping (as detailed in your `references/Design_and_implementation_of_high-speed_token_buck.pdf`).
Imagine a physical bucket that holds casino chips (Tokens).
1. **The Generator:** A timer drops $R$ new tokens into the bucket every $T$ microseconds.
2. **The Capacity:** The bucket has a maximum depth of $B$ tokens. If it overflows, the excess tokens are permanently lost.
3. **The Toll Booth:** When a packet wants to leave the queue, it must "pay" the toll booth by removing tokens from the bucket equal to its byte size. 
4. **The Limiter:** If the bucket is empty, the packet must wait.

### B. Two-Color / Single-Rate Parameters
In industry standard QoS (like IETF RFC 3290), this is parameterized as:
* **CIR (Committed Information Rate):** The speed at which tokens are added (`cfg_rate`).
* **CBS (Committed Burst Size):** The maximum depth of the bucket (`cfg_burst`). Allows temporary micro-bursts of line-rate traffic if the bucket has been storing up tokens during a quiet period.

---

## 3. File Structure Walkthrough

---

1. **Parameters:** `REFRESH_PERIOD` defines the baseline time tick (e.g., 100 clock cycles = 1 microsecond).
2. **Configuration Interfaces:** `cfg_rate` and `cfg_burst` to dynamically adjust the CIR and CBS.
3. **Datapath Interfaces:** `has_tokens` (output flag to tell the Scheduler it's allowed to transmit) and `consume` (input flag from the Scheduler telling the bucket a packet was just sent).
4. **The Core Logic Block:** A single synchronous block that handles both the periodic addition of tokens and the instantaneous consumption of tokens simultaneously.

---

## 4. Line-by-Line Code Explanation

---

### The Refresh Timer
```verilog
            // 1. Handle Refresh Timer
            if (refresh_timer >= REFRESH_PERIOD - 1) begin
                refresh_timer <= 32'd0;
```
**What it does:** Creates the fundamental "tick" of the rate limiter.
**Engineering Reasoning:** Rather than adding fractional tokens every single 4ns clock cycle (which requires complex floating-point math), we wait 100 clock cycles and then add a massive chunk of tokens all at once. This `REFRESH_PERIOD` serves as the `Time_GRN` (Time Granularity) parameter mentioned in the NUDT research paper.

### Burst Capping & Simultaneous Operations
```verilog
                } else if ((token_count + cfg_rate) > cfg_burst) begin
                    // If consuming on the exact same cycle it fills
                    if (consume) begin
                        token_count <= cfg_burst - 1'b1;
                    end else begin
                        token_count <= cfg_burst;
                    end
```
**What it does:** Prevents the token counter from overflowing the bucket, while safely handling edge cases.
**How it works internally:** Hardware doesn't execute line-by-line sequentially like software. The addition of new tokens and the consumption of an old token might happen on the *exact same clock cycle*. 
If we just blindly set `token_count <= cfg_burst`, we would accidentally "delete" the token that the Scheduler just paid for the current packet. By explicitly checking `if (consume)`, we deduct `1'b1` from the capped `cfg_burst` to ensure the math remains perfectly balanced.

### Priority Scheduler Integration
*(Added to `priority_scheduler.v`)*
```verilog
                        !queue_empty[q] &&
                        tb_has_tokens[q]) begin
```
**What it does:** Integrates the Token Bucket into the Priority Encoder.
**Why it matters:** Even if Queue 0 is Priority 0, and even if it has packets waiting (`!queue_empty`), if `tb_has_tokens` drops to 0, the Priority Encoder will skip Queue 0 and look at Queue 1 instead. This single line of Verilog physically defeats Starvation.

---

## 5. Hardware Interpretation

---

### 1 Token = 1 Beat
In advanced software implementations, packets pay tokens based on their exact byte length (e.g., a 1500-byte packet pays 1500 tokens). 
In our high-speed hardware datapath, reading the length of a packet before it's transmitted requires complex look-ahead FIFO parsing. Because the OpenNIC datapath operates on a 512-bit (64-byte) AXI-Stream bus, we simplified the math:
**1 Token = 1 AXI-Stream Beat (64 Bytes)**.
When the Priority Scheduler transmits a beat, it asserts `m_axis_tvalid && m_axis_tready`. We tied this wire directly to the `consume` pin of the Token Bucket.

### Area Efficiency
By utilizing an array of `token_bucket` modules generated via a `for` loop in `priority_scheduler.v`, we instantiate 4 independent buckets. Each bucket requires two 32-bit registers (Count and Timer) plus a few LUTs for the adders. This consumes virtually no FPGA logic area while providing immensely powerful QoS guarantees.

---

## 6. Example Execution

---

**Scenario:** 
* `REFRESH_PERIOD = 100` cycles (1 microsecond at 100MHz).
* `cfg_rate = 5` tokens per microsecond.
* `cfg_burst = 20` tokens maximum.
* `cfg_enable = 1`.
A malicious user floods Queue 0 with infinite traffic.

1. **Microsecond 0:** Bucket fills to 20 tokens.
2. **Microsecond 1-20:** Scheduler blasts out 20 beats (1280 bytes) on back-to-back clock cycles. The bucket drops by 1 token every cycle.
3. **Cycle 20:** `token_count` hits 0. `has_tokens` goes low.
4. **Cycle 21 to 99:** The Priority Encoder sees `tb_has_tokens[0] == 0`. It completely ignores Queue 0. It services Queues 1, 2, and 3 instead.
5. **Microsecond 100:** The refresh timer fires. It adds 5 tokens to Queue 0.
6. **Cycle 101 to 105:** Queue 0 is allowed to transmit exactly 5 beats.
7. **Cycle 106:** Queue 0 runs out of tokens again. It is blocked.

The rate limiter works! Queue 0 is successfully throttled to exactly 5 beats per microsecond (2.56 Gbps bandwidth limit).

---

## 7. Exercises

---

### 1. Questions to Answer
* If `cfg_burst` is set to a very small number like `1`, what happens to the packet transmission latency? Does it become smooth, or highly erratic?
* The paper notes that high-speed implementations can fail timing if the token adder is too deep. Does our 32-bit adder `token_count + cfg_rate` pose a risk at 250MHz?

### 2. Things to Modify
* **Color-Aware Policing (Dual-Rate Three-Color):** Modify the Token Bucket to implement RFC 2698 (srTCM). Create a second bucket for the Peak Information Rate (PIR). Add an output flag `tb_exceeds_pir`. If the packet exceeds the PIR, drop it. If it exceeds CIR but is within PIR, transmit it but modify the `TUSER` sideband to mark the packet "Yellow" (eligible for dropping downstream if congested).
