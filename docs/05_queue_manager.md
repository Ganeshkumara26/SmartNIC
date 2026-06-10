# Queue Manager (`queue_manager.v`)

## 1. Purpose of the File
`rtl/queue/queue_manager.v` provides Multi-Tenant isolated buffering. It takes packets sorted by the Flow Classifier and routes them into physical hardware queues corresponding to their 5G Network Slice.

## 2. Preventing Head-of-Line (HoL) Blocking
If all 5G network slices shared a single massive FIFO, a low-priority bulk download could fill the entire buffer, permanently blocking ultra-low latency (URLLC) packets from entering the hardware. 
To solve this, the Queue Manager partitions the memory into `NUM_QUEUES` (4) discrete, isolated FIFOs. A traffic jam in Queue 3 (IoT) has zero physical impact on the memory available to Queue 0 (URLLC).

## 3. Demultiplexing Architecture
When a packet arrives, the `m_axis_tuser` sideband provides the assigned `Slice ID`. The demultiplexer uses this ID to route the `tvalid` and `tdata` signals directly to the corresponding FIFO's input port. 
If the target queue is full, backpressure is applied to the ingress pipeline.

## 4. Scheduler Interface
Unlike the ingress AXI-Stream interface, the output side is controlled directly by the Priority Scheduler. The scheduler supplies a `deq_queue_id` and pulses `deq_request`. The Queue Manager acts as an internal multiplexer, selecting the specified FIFO and routing its output data to the egress pipeline.
