# AXI-Stream FIFO (`axi_stream_fifo.v`)

## 1. Purpose of the File
`rtl/common/axi_stream_fifo.v` implements a high-performance synchronous circular buffer. It absorbs instantaneous traffic bursts and facilitates smooth handshaking between pipeline stages.

## 2. First-Word Fall-Through (FWFT)
Standard FIFOs incur a 1-cycle latency when reading data. This FIFO implements First-Word Fall-Through (FWFT) behavior, meaning the oldest data in the buffer is immediately exposed on the output bus `m_axis_tdata` without requiring a read request. The downstream module consumes the data simply by asserting `m_axis_tready`.

## 3. Circular Buffer Mechanics
The FIFO uses a Dual-Port RAM paired with read and write pointers.
- When data is written, the write pointer increments.
- When data is read, the read pointer increments.
- When a pointer reaches `DEPTH - 1`, it rolls over to `0`.

## 4. The N+1 Pointer Strategy
To distinguish between an completely Full FIFO and a completely Empty FIFO (since both conditions result in the read and write pointers being identical), the internal pointers are 1 bit wider than required to address the memory (N+1 bits).
- **Empty:** Pointers are identical in all bits.
- **Full:** Pointers are identical in the lower N bits, but their Most Significant Bits (MSBs) differ.
