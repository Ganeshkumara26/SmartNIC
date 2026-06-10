# Priority Scheduler (`priority_scheduler.v`)

## 1. Purpose of the File
`rtl/scheduler/priority_scheduler.v` acts as the traffic cop for the egress link. It analyzes the fill levels of all physical queues and decides which packet is allowed to transmit next onto the wire.

## 2. Strict Priority Algorithm
The scheduler implements a Strict Priority (SP) algorithm to ensure 5G QoS latency guarantees.
- Every queue is assigned a priority level (0 = Highest, 3 = Lowest).
- The scheduler always selects the queue with data that has the highest priority. 
- Lower-priority queues are entirely blocked from transmitting as long as higher-priority queues possess data.

## 3. Combinatorial Unrolling
The hardware identifies the highest-priority active queue using nested `for` loops in an `always @(*)` block.
- The outer loop iterates through Priority levels (0 to 3).
- The inner loop iterates through Queue IDs (0 to 3).
During FPGA synthesis, this nested loop is unrolled into a massively parallel priority encoder tree, allowing the decision to be made in a fraction of a clock cycle.

## 4. Packet Boundary Integrity
Once the scheduler selects a queue and begins dequeuing a packet, it locks into the `SCH_FORWARD` state. It will not preempt the current transmission, even if a higher-priority packet arrives mid-stream. It remains locked until it detects the `tlast` signal (End of Frame), ensuring that packets are transmitted continuously without fragmentation.
