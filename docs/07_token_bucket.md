# Token Bucket Rate Limiter (`token_bucket.v`)

## 1. Purpose of the File
`rtl/scheduler/token_bucket.v` acts as a bandwidth rate limiter. It solves the "Starvation" vulnerability inherent in Strict Priority scheduling by restricting high-priority queues to a specific bandwidth quota.

## 2. The Token Bucket Algorithm
The logic models a bucket of tokens used for traffic policing:
- **CIR (Committed Information Rate):** A timer adds a set number of tokens (`cfg_rate`) to the bucket every `REFRESH_PERIOD` clock cycles.
- **CBS (Committed Burst Size):** The bucket caps at a maximum depth (`cfg_burst`).
- **Consumption:** Transmitting a 512-bit beat (64 bytes) consumes exactly 1 token.
- **Throttling:** If the bucket reaches 0 tokens, the `has_tokens` signal is deasserted.

## 3. Priority Scheduler Integration
Four instances of the Token Bucket are generated inside the `priority_scheduler.v`. The priority encoder logic is modified to require `tb_has_tokens[q]` to be true. If a queue exhausts its token quota, it is temporarily disqualified from arbitration, allowing lower-priority queues their fair turn to transmit.

## 4. Simultaneous Operations
Because new tokens can be added on the exact same clock cycle that a token is consumed, the logic explicitly handles simultaneous addition and subtraction to prevent accidental token deletion when operating at the `cfg_burst` limit.
