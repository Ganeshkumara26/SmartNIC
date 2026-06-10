//============================================================================
// Priority Scheduler — Strict Priority Queue Drain
//============================================================================
// Implements a Strict Priority scheduler that always services the highest-
// priority non-empty queue first. This is the final stage of the SmartNIC
// datapath before packets exit toward the CMAC (network) or QDMA (host).
//
// ARCHITECTURE:
// ─────────────────────────────────────────────────────────────────────────
// Priority mapping (configurable via AXI-Lite, defaults to queue order):
//   Queue 0 → Priority 0 (HIGHEST — e.g., URLLC / ultra-low-latency)
//   Queue 1 → Priority 1 (HIGH    — e.g., real-time voice)
//   Queue 2 → Priority 2 (MEDIUM  — e.g., eMBB video streaming)
//   Queue 3 → Priority 3 (LOWEST  — e.g., best-effort / IoT)
//
// Scheduling Algorithm:
//   1. Check all queue empty flags (from Queue Manager)
//   2. Select the non-empty queue with the lowest priority number
//   3. Issue a dequeue request to the Queue Manager
//   4. Forward the dequeued packet to the output AXI-Stream
//   5. Repeat
//
// CAUTION: Strict Priority can cause starvation of lower-priority queues
// if higher-priority queues always have data. This is intentional for
// URLLC — but Tier 2 adds Token Bucket rate limiting to prevent abuse.
//
// AXI-Lite Configuration Port (for future RISC-V control):
//   - Per-queue priority assignment registers
//   - Per-queue enable/disable
//   - Token Bucket parameters (Tier 2): rate, burst_size
//
// LEARNING NOTES:
// ─────────────────────────────────────────────────────────────────────────
// In real networking, "Strict Priority" is the simplest QoS scheduler.
// More advanced designs use Weighted Fair Queuing (WFQ) or Deficit Round
// Robin (DRR) to prevent starvation while still providing differentiated
// service. We start with SP because it clearly demonstrates the QoS
// concept and directly proves the HP-gets-lower-latency thesis.
//============================================================================

`include "smartnic_pkg.vh"

module priority_scheduler (
    input  wire                             clk,
    input  wire                             rst_n,

    // ── Queue Status (from Queue Manager) ─────────────────────────────
    input  wire [`NUM_QUEUES-1:0]           queue_empty,
    input  wire [`NUM_QUEUES-1:0]           queue_full,

    // ── Dequeue Control (to Queue Manager) ────────────────────────────
    output reg                              deq_request,
    output reg  [`QUEUE_ID_WIDTH-1:0]       deq_queue_id,

    // ── AXI-Stream from Queue Manager (dequeued packets) ──────────────
    input  wire [`AXIS_DATA_WIDTH-1:0]      qm_axis_tdata,
    input  wire [`AXIS_KEEP_WIDTH-1:0]      qm_axis_tkeep,
    input  wire [`AXIS_USER_WIDTH-1:0]      qm_axis_tuser,
    input  wire                             qm_axis_tvalid,
    output wire                             qm_axis_tready,
    input  wire                             qm_axis_tlast,

    // ── AXI-Stream Master (scheduled output) ──────────────────────────
    output reg  [`AXIS_DATA_WIDTH-1:0]      m_axis_tdata,
    output reg  [`AXIS_KEEP_WIDTH-1:0]      m_axis_tkeep,
    output reg  [`AXIS_USER_WIDTH-1:0]      m_axis_tuser,
    output reg                              m_axis_tvalid,
    input  wire                             m_axis_tready,
    output reg                              m_axis_tlast,

    // ── Configuration Port ────────────────────────────────────────────
    input  wire                             cfg_wr_en,
    input  wire [`QUEUE_ID_WIDTH-1:0]       cfg_queue_id,
    input  wire [1:0]                       cfg_priority,    // 0=highest, 3=lowest
    input  wire                             cfg_queue_enable,
    
    // Token Bucket Configuration
    input  wire [31:0]                      cfg_tb_rate,
    input  wire [31:0]                      cfg_tb_burst,
    input  wire                             cfg_tb_enable,

    // ── Statistics Output (for testbench analysis) ────────────────────
    output reg  [31:0]                      stat_total_packets,
    output wire [(`NUM_QUEUES*32)-1:0]      stat_queue_packets
);

    reg [31:0] internal_stat_queue_packets [0:`NUM_QUEUES-1];
    
    genvar g_stat;
    generate
        for (g_stat = 0; g_stat < `NUM_QUEUES; g_stat = g_stat + 1) begin : gen_stat_assign
            assign stat_queue_packets[(g_stat*32)+31 : g_stat*32] = internal_stat_queue_packets[g_stat];
        end
    endgenerate

    //------------------------------------------------------------------------
    // Priority Configuration Registers
    //------------------------------------------------------------------------
    reg [1:0] queue_priority [`NUM_QUEUES-1:0];  // Priority per queue
    reg       queue_enable   [`NUM_QUEUES-1:0];  // Enable per queue
    
    // Token Bucket Configuration Registers
    reg [31:0] queue_tb_rate   [`NUM_QUEUES-1:0];
    reg [31:0] queue_tb_burst  [`NUM_QUEUES-1:0];
    reg        queue_tb_enable [`NUM_QUEUES-1:0];

    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            stat_total_packets <= 32'd0;
            for (k = 0; k < `NUM_QUEUES; k = k + 1) begin
                queue_priority[k] <= k[1:0]; 
                queue_enable[k]   <= 1'b1; 
                queue_tb_rate[k]  <= 32'd0;
                queue_tb_burst[k] <= 32'd0;
                queue_tb_enable[k]<= 1'b0;
                internal_stat_queue_packets[k] <= 32'd0;
            end
        end else if (cfg_wr_en) begin
            queue_priority[cfg_queue_id]  <= cfg_priority;
            queue_enable[cfg_queue_id]    <= cfg_queue_enable;
            queue_tb_rate[cfg_queue_id]   <= cfg_tb_rate;
            queue_tb_burst[cfg_queue_id]  <= cfg_tb_burst;
            queue_tb_enable[cfg_queue_id] <= cfg_tb_enable;
        end
    end

    //------------------------------------------------------------------------
    // Token Bucket Instantiations
    //------------------------------------------------------------------------
    wire [`NUM_QUEUES-1:0] tb_has_tokens;
    wire [`NUM_QUEUES-1:0] tb_consume;
    
    genvar g;
    generate
        for (g = 0; g < `NUM_QUEUES; g = g + 1) begin : gen_tb
            token_bucket #(
                .REFRESH_PERIOD (100)
            ) u_tb (
                .clk         (clk),
                .rst_n       (rst_n),
                .cfg_rate    (queue_tb_rate[g]),
                .cfg_burst   (queue_tb_burst[g]),
                .cfg_enable  (queue_tb_enable[g]),
                .has_tokens  (tb_has_tokens[g]),
                .consume     (tb_consume[g])
            );
        end
    endgenerate

    //------------------------------------------------------------------------
    // Priority Selection Logic
    //------------------------------------------------------------------------
    reg [`QUEUE_ID_WIDTH-1:0]   selected_queue;
    reg                         any_queue_ready;

    integer p, q;
    always @(*) begin
        selected_queue = {`QUEUE_ID_WIDTH{1'b0}};
        any_queue_ready = 1'b0;

        for (p = 0; p < 4; p = p + 1) begin
            if (!any_queue_ready) begin
                for (q = 0; q < `NUM_QUEUES; q = q + 1) begin
                    if (!any_queue_ready &&
                        queue_enable[q] &&
                        (queue_priority[q] == p[1:0]) &&
                        !queue_empty[q] &&
                        tb_has_tokens[q]) begin
                        selected_queue = q[`QUEUE_ID_WIDTH-1:0];
                        any_queue_ready = 1'b1;
                    end
                end
            end
        end
    end

    //------------------------------------------------------------------------
    // Scheduler State Machine
    //------------------------------------------------------------------------
    localparam [2:0] SCH_IDLE     = 3'd0,
                     SCH_REQUEST  = 3'd1,
                     SCH_WAIT     = 3'd2,
                     SCH_FORWARD  = 3'd3,
                     SCH_NEXT     = 3'd4;

    reg [2:0] sch_state;
    reg [`QUEUE_ID_WIDTH-1:0] active_queue;

    wire output_handshake = m_axis_tvalid && m_axis_tready;

    assign qm_axis_tready = (sch_state == SCH_FORWARD) && (m_axis_tready || !m_axis_tvalid);
    assign tb_consume = (sch_state == SCH_FORWARD && qm_axis_tvalid && qm_axis_tready) ? 
                        (1 << active_queue) : {`NUM_QUEUES{1'b0}};

    always @(posedge clk) begin
        if (!rst_n) begin
            sch_state       <= SCH_IDLE;
            deq_request     <= 1'b0;
            deq_queue_id    <= {`QUEUE_ID_WIDTH{1'b0}};
            active_queue    <= {`QUEUE_ID_WIDTH{1'b0}};
            m_axis_tvalid   <= 1'b0;
            m_axis_tdata    <= {`AXIS_DATA_WIDTH{1'b0}};
            m_axis_tkeep    <= {`AXIS_KEEP_WIDTH{1'b0}};
            m_axis_tuser    <= {`AXIS_USER_WIDTH{1'b0}};
            m_axis_tlast    <= 1'b0;
        end else begin
            deq_request <= 1'b0;

            case (sch_state)
                SCH_IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    if (any_queue_ready) begin
                        active_queue <= selected_queue;
                        sch_state    <= SCH_REQUEST;
                    end
                end

                SCH_REQUEST: begin
                    deq_request  <= 1'b1;
                    deq_queue_id <= active_queue;
                    sch_state    <= SCH_WAIT;
                end

                SCH_WAIT: begin
                    if (qm_axis_tvalid) begin
                        sch_state <= SCH_FORWARD;
                    end
                end

                SCH_FORWARD: begin
                    if (qm_axis_tvalid && qm_axis_tready) begin
                        m_axis_tdata  <= qm_axis_tdata;
                        m_axis_tkeep  <= qm_axis_tkeep;
                        m_axis_tuser  <= qm_axis_tuser;
                        m_axis_tlast  <= qm_axis_tlast;
                        m_axis_tvalid <= 1'b1;

                        if (qm_axis_tlast) begin
                            stat_total_packets <= stat_total_packets + 1;
                            internal_stat_queue_packets[active_queue] <= internal_stat_queue_packets[active_queue] + 1;
                            sch_state <= SCH_NEXT;
                        end
                    end
                end

                SCH_NEXT: begin
                    if (output_handshake || !m_axis_tvalid) begin
                        m_axis_tvalid <= 1'b0;
                        sch_state     <= SCH_IDLE;
                    end
                end

                default: sch_state <= SCH_IDLE;
            endcase
        end
    end

endmodule
