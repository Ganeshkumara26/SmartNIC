//============================================================================
// Multi-Queue Manager — BRAM-based Per-Slice Packet Storage
//============================================================================
// Maintains N independent circular-buffer queues (one per network slice).
// Packets are enqueued based on the Slice ID in TUSER metadata. The
// scheduler requests dequeue from a specific queue.
//
// ARCHITECTURE:
// ─────────────────────────────────────────────────────────────────────────
// For the MVP, we simplify by storing ONE 512-bit beat per queue entry.
// Multi-beat packets are stored as consecutive entries. This makes the
// queue management straightforward while still demonstrating the concept.
//
// Each queue has:
//   - A region in the shared BRAM (partitioned by queue ID)
//   - Head pointer (read) and Tail pointer (write)
//   - Fill level counter
//   - Full and Empty flags
//
// Memory Layout (FIFO_DEPTH entries per queue):
//   Queue 0: addresses [0 .. FIFO_DEPTH-1]
//   Queue 1: addresses [FIFO_DEPTH .. 2*FIFO_DEPTH-1]
//   Queue 2: addresses [2*FIFO_DEPTH .. 3*FIFO_DEPTH-1]
//   Queue 3: addresses [3*FIFO_DEPTH .. 4*FIFO_DEPTH-1]
//
// LEARNING NOTES:
// ─────────────────────────────────────────────────────────────────────────
// In real FPGA designs (like Corundum), queue managers use Block RAM
// (BRAM) which provides dual-port access — one port for writing, one for
// reading — allowing simultaneous enqueue and dequeue. Our simulation
// uses a register array that mimics this behavior.
//============================================================================

`include "smartnic_pkg.vh"

module queue_manager (
    input  wire                             clk,
    input  wire                             rst_n,

    // ── Enqueue Port (AXI-Stream Slave from Classifier) ───────────────
    input  wire [`AXIS_DATA_WIDTH-1:0]      s_axis_tdata,
    input  wire [`AXIS_KEEP_WIDTH-1:0]      s_axis_tkeep,
    input  wire [`AXIS_USER_WIDTH-1:0]      s_axis_tuser,
    input  wire                             s_axis_tvalid,
    output wire                             s_axis_tready,
    input  wire                             s_axis_tlast,

    // ── Dequeue Port (AXI-Stream Master to Scheduler) ─────────────────
    output reg  [`AXIS_DATA_WIDTH-1:0]      m_axis_tdata,
    output reg  [`AXIS_KEEP_WIDTH-1:0]      m_axis_tkeep,
    output reg  [`AXIS_USER_WIDTH-1:0]      m_axis_tuser,
    output reg                              m_axis_tvalid,
    input  wire                             m_axis_tready,
    output reg                              m_axis_tlast,

    // ── Scheduler Interface ───────────────────────────────────────────
    // The scheduler selects which queue to dequeue from
    input  wire                             deq_request,        // Pulse: request dequeue
    input  wire [`QUEUE_ID_WIDTH-1:0]       deq_queue_id,       // Which queue to dequeue from

    // ── Queue Status (to Scheduler) ───────────────────────────────────
    output wire [`NUM_QUEUES-1:0]           queue_empty,        // Per-queue empty flags
    output wire [`NUM_QUEUES-1:0]           queue_full,         // Per-queue full flags
    output wire [`NUM_QUEUES*8-1:0]         queue_fill_levels   // Packed fill levels (8 bits each)
);

    //------------------------------------------------------------------------
    // Parameters
    //------------------------------------------------------------------------
    localparam DEPTH      = `QUEUE_DEPTH;                        // Entries per queue
    localparam ADDR_BITS  = $clog2(DEPTH);                       // Address bits per queue
    localparam TOTAL_DEPTH = `NUM_QUEUES * DEPTH;                // Total entries
    localparam TOTAL_ADDR  = $clog2(TOTAL_DEPTH);                // Total address bits

    // Width of each stored entry: TDATA + TKEEP + TUSER + TLAST
    localparam ENTRY_WIDTH = `AXIS_DATA_WIDTH + `AXIS_KEEP_WIDTH + `AXIS_USER_WIDTH + 1;

    //------------------------------------------------------------------------
    // Storage Array
    //------------------------------------------------------------------------
    // LEARNING NOTE: This is a large register array. In a real FPGA, the
    // synthesis tool would infer Block RAM if the depth is large enough
    // (typically >= 16 entries). For simulation, registers are fine.

    reg [ENTRY_WIDTH-1:0] mem [0:TOTAL_DEPTH-1];

    //------------------------------------------------------------------------
    // Per-Queue Pointers and Counters
    //------------------------------------------------------------------------
    reg [ADDR_BITS:0] head [`NUM_QUEUES-1:0];  // Read pointer  (extra MSB for wrap)
    reg [ADDR_BITS:0] tail [`NUM_QUEUES-1:0];  // Write pointer (extra MSB for wrap)

    //------------------------------------------------------------------------
    // Per-Queue Status Generation
    //------------------------------------------------------------------------
    genvar g;
    generate
        for (g = 0; g < `NUM_QUEUES; g = g + 1) begin : gen_status
            wire [ADDR_BITS:0] fill = tail[g] - head[g];

            assign queue_empty[g] = (head[g] == tail[g]);
            assign queue_full[g]  = (head[g][ADDR_BITS] != tail[g][ADDR_BITS]) &&
                                    (head[g][ADDR_BITS-1:0] == tail[g][ADDR_BITS-1:0]);
            assign queue_fill_levels[g*8 +: 8] = fill[7:0];
        end
    endgenerate

    //------------------------------------------------------------------------
    // Enqueue Logic
    //------------------------------------------------------------------------
    // Extract the Slice ID from TUSER to determine the target queue
    wire [`TUSER_SLICE_ID_WIDTH-1:0] enq_queue_id =
        s_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO];

    // Limit queue ID to valid range
    wire [`QUEUE_ID_WIDTH-1:0] enq_qid = enq_queue_id[`QUEUE_ID_WIDTH-1:0];

    // Can enqueue if the target queue is not full
    wire enq_target_full = queue_full[enq_qid];
    assign s_axis_tready = !enq_target_full;

    wire enq_handshake = s_axis_tvalid && s_axis_tready;

    // Calculate the memory address for enqueue
    wire [TOTAL_ADDR-1:0] enq_addr = (enq_qid * DEPTH) + tail[enq_qid][ADDR_BITS-1:0];

    integer m;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (m = 0; m < `NUM_QUEUES; m = m + 1) begin
                tail[m] <= {(ADDR_BITS+1){1'b0}};
            end
        end else if (enq_handshake) begin
            // Store the packet beat
            mem[enq_addr] <= {s_axis_tlast, s_axis_tuser, s_axis_tkeep, s_axis_tdata};
            tail[enq_qid] <= tail[enq_qid] + 1'b1;
        end
    end

    //------------------------------------------------------------------------
    // Dequeue Logic
    //------------------------------------------------------------------------
    // The scheduler pulses deq_request with the desired queue ID.
    // We output the head entry on the AXI-Stream master port.

    // Calculate the memory address for dequeue
    wire [TOTAL_ADDR-1:0] deq_addr = (deq_queue_id * DEPTH) + head[deq_queue_id][ADDR_BITS-1:0];

    // Dequeue state machine
    localparam [1:0] DEQ_IDLE    = 2'd0,
                     DEQ_READ    = 2'd1,
                     DEQ_OUTPUT  = 2'd2;

    reg [1:0] deq_state;
    reg [ENTRY_WIDTH-1:0] deq_data;
    reg [`QUEUE_ID_WIDTH-1:0] deq_qid_reg;

    wire deq_output_handshake = m_axis_tvalid && m_axis_tready;

    integer n;
    always @(posedge clk) begin
        if (!rst_n) begin
            deq_state     <= DEQ_IDLE;
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= {`AXIS_DATA_WIDTH{1'b0}};
            m_axis_tkeep  <= {`AXIS_KEEP_WIDTH{1'b0}};
            m_axis_tuser  <= {`AXIS_USER_WIDTH{1'b0}};
            m_axis_tlast  <= 1'b0;
            deq_qid_reg   <= {`QUEUE_ID_WIDTH{1'b0}};
            for (n = 0; n < `NUM_QUEUES; n = n + 1) begin
                head[n] <= {(ADDR_BITS+1){1'b0}};
            end
        end else begin
            case (deq_state)
                DEQ_IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    if (deq_request && !queue_empty[deq_queue_id]) begin
                        // Read from the specified queue
                        deq_data    <= mem[deq_addr];
                        deq_qid_reg <= deq_queue_id;
                        deq_state   <= DEQ_READ;
                    end
                end

                DEQ_READ: begin
                    // Present data on AXI-Stream output
                    m_axis_tdata  <= deq_data[`AXIS_DATA_WIDTH-1:0];
                    m_axis_tkeep  <= deq_data[`AXIS_DATA_WIDTH +: `AXIS_KEEP_WIDTH];
                    m_axis_tuser  <= deq_data[(`AXIS_DATA_WIDTH + `AXIS_KEEP_WIDTH) +: `AXIS_USER_WIDTH];
                    m_axis_tlast  <= deq_data[ENTRY_WIDTH-1];
                    m_axis_tvalid <= 1'b1;
                    deq_state     <= DEQ_OUTPUT;
                end

                DEQ_OUTPUT: begin
                    if (deq_output_handshake) begin
                        // Advance the head pointer
                        head[deq_qid_reg] <= head[deq_qid_reg] + 1'b1;
                        m_axis_tvalid <= 1'b0;

                        // Check if more beats in this packet (TLAST not set)
                        if (!m_axis_tlast) begin
                            // Continue dequeuing from the same queue
                            deq_data  <= mem[(deq_qid_reg * DEPTH) + (head[deq_qid_reg][ADDR_BITS-1:0] + 1'b1)];
                            deq_state <= DEQ_READ;
                        end else begin
                            deq_state <= DEQ_IDLE;
                        end
                    end
                end

                default: deq_state <= DEQ_IDLE;
            endcase
        end
    end

endmodule
