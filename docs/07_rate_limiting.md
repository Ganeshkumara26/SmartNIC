# 7. Future Scope: Token Bucket Rate Limiting (Tier 2)

## Theoretical Background

Our MVP uses **Strict Priority (SP)** scheduling. The flaw with SP is that if the High Priority (URLLC) queue is constantly flooded with traffic, the Low Priority queues will *never* get serviced. This is called **Starvation**.

To prevent starvation while still guaranteeing low latency for URLLC, we use a **Token Bucket** algorithm to apply a bandwidth cap (Rate Limit) to the high-priority queues.

### How a Token Bucket Works
Imagine a bucket that holds "tokens" (representing bytes allowed to be sent).
1. **Replenishment:** Tokens are added to the bucket at a constant rate (e.g., 1 Gbps).
2. **Capacity:** The bucket has a maximum size. If it overflows, tokens are discarded.
3. **Consumption:** When a packet wants to transmit, it must remove tokens equal to its size.
4. **Rate Limiting:** If the bucket doesn't have enough tokens, the packet cannot be sent until more tokens arrive.

## Planned RTL Architecture

In Tier 2, we will integrate a Token Bucket into the Priority Scheduler.

```mermaid
flowchart TD
    subgraph Token Bucket Updater (Background)
        T[Timer] -->|Tick| Add[Add Tokens to Bucket]
        Add --> Max{Bucket Full?}
        Max -->|No| Store[Save Tokens]
        Max -->|Yes| Drop[Discard Excess Tokens]
    end

    subgraph Scheduler FSM
        Req[Packet Ready to Send] --> Size[Check Packet Size]
        Size --> Tokens{Enough Tokens?}
        Tokens -->|Yes| Send[Send Packet & Subtract Tokens]
        Tokens -->|No| Wait[Skip Queue, Try Lower Priority]
    end
    
    Store -.-> Tokens
```

By adding this, we guarantee that URLLC traffic gets absolute priority *up to its allocated bandwidth limit*. If a malicious user tries to flood the URLLC queue past its limit, the scheduler will skip it and service the eMBB and IoT queues, ensuring the entire network stays healthy.
