//============================================================================
// Dual-Mode QoS Scheduler (qos_scheduler.v)
//============================================================================
// Replaces the basic priority_scheduler.v.
// Features two selectable scheduling engines:
//   - Mode 0: Strict Priority (Original behavior)
//   - Mode 1: Weighted Round Robin (WRR) for fairness
//
// Selectable dynamically via AXI-Lite.
//============================================================================

`timescale 1ns / 1ps
`include "smartnic_pkg.vh"

module qos_scheduler (
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

    // ── SP Configuration Port ─────────────────────────────────────────
    input  wire                             cfg_wr_en,
    input  wire [`QUEUE_ID_WIDTH-1:0]       cfg_queue_id,
    input  wire [1:0]                       cfg_priority,    // 0=highest, 3=lowest
    input  wire                             cfg_queue_enable,
    
    // Token Bucket Configuration
    input  wire [31:0]                      cfg_tb_rate,
    input  wire [31:0]                      cfg_tb_burst,
    input  wire                             cfg_tb_enable,

    // ── WRR Configuration Port ────────────────────────────────────────
    input  wire                             qos_cfg_wr_en,
    input  wire                             qos_cfg_mode,
    input  wire [`QUEUE_ID_WIDTH-1:0]       qos_cfg_weight_id,
    input  wire [15:0]                      qos_cfg_weight_val
);

    //------------------------------------------------------------------------
    // Configuration Registers
    //------------------------------------------------------------------------
    reg [1:0]  queue_priority [`NUM_QUEUES-1:0];
    reg        queue_enable   [`NUM_QUEUES-1:0];
    reg [31:0] queue_tb_rate  [`NUM_QUEUES-1:0];
    reg [31:0] queue_tb_burst [`NUM_QUEUES-1:0];
    reg        queue_tb_enable[`NUM_QUEUES-1:0];
    
    reg [15:0] queue_weight   [`NUM_QUEUES-1:0]; // Packets per cycle in WRR

    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (k = 0; k < `NUM_QUEUES; k = k + 1) begin
                queue_priority[k] <= k[1:0]; 
                queue_enable[k]   <= 1'b1; 
                queue_tb_rate[k]  <= 32'd0;
                queue_tb_burst[k] <= 32'd0;
                queue_tb_enable[k]<= 1'b0;
                queue_weight[k]   <= 16'd10; // Default weight
            end
        end else begin
            if (cfg_wr_en) begin
                queue_priority[cfg_queue_id]  <= cfg_priority;
                queue_enable[cfg_queue_id]    <= cfg_queue_enable;
                queue_tb_rate[cfg_queue_id]   <= cfg_tb_rate;
                queue_tb_burst[cfg_queue_id]  <= cfg_tb_burst;
                queue_tb_enable[cfg_queue_id] <= cfg_tb_enable;
            end
            if (qos_cfg_wr_en) begin
                queue_weight[qos_cfg_weight_id] <= qos_cfg_weight_val;
            end
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
    // Mode 0: Strict Priority Logic
    //------------------------------------------------------------------------
    reg [`QUEUE_ID_WIDTH-1:0]   sp_selected_queue;
    reg                         sp_any_queue_ready;

    integer p, q;
    always @(*) begin
        sp_selected_queue = {`QUEUE_ID_WIDTH{1'b0}};
        sp_any_queue_ready = 1'b0;

        for (p = 0; p < 4; p = p + 1) begin
            if (!sp_any_queue_ready) begin
                for (q = 0; q < `NUM_QUEUES; q = q + 1) begin
                    if (!sp_any_queue_ready && queue_enable[q] && (queue_priority[q] == p[1:0]) && !queue_empty[q] && tb_has_tokens[q]) begin
                        sp_selected_queue = q[`QUEUE_ID_WIDTH-1:0];
                        sp_any_queue_ready = 1'b1;
                    end
                end
            end
        end
    end

    //------------------------------------------------------------------------
    // Mode 1: WRR Logic
    //------------------------------------------------------------------------
    reg [`QUEUE_ID_WIDTH-1:0] wrr_current_queue;
    reg [15:0]                wrr_packets_served;
    
    reg [`QUEUE_ID_WIDTH-1:0] wrr_selected_queue;
    reg                       wrr_any_queue_ready;
    reg                       wrr_need_to_switch;

    integer i, check_q;
    always @(*) begin
        wrr_selected_queue = wrr_current_queue;
        wrr_any_queue_ready = 1'b0;
        wrr_need_to_switch = 1'b0;

        // Try the current queue first
        if (queue_enable[wrr_current_queue] && !queue_empty[wrr_current_queue] && tb_has_tokens[wrr_current_queue] && (wrr_packets_served < queue_weight[wrr_current_queue]) && (queue_weight[wrr_current_queue] > 0)) begin
            wrr_selected_queue = wrr_current_queue;
            wrr_any_queue_ready = 1'b1;
        end else begin
            // Need to switch. Scan the queues in round-robin order.
            wrr_need_to_switch = 1'b1;
            for (i = 1; i <= `NUM_QUEUES; i = i + 1) begin
                if (!wrr_any_queue_ready) begin
                    // (wrr_current_queue + i) % NUM_QUEUES
                    check_q = (wrr_current_queue + i);
                    if (check_q >= `NUM_QUEUES) check_q = check_q - `NUM_QUEUES;
                    
                    if (queue_enable[check_q] && !queue_empty[check_q] && tb_has_tokens[check_q] && (queue_weight[check_q] > 0)) begin
                        wrr_selected_queue = check_q[`QUEUE_ID_WIDTH-1:0];
                        wrr_any_queue_ready = 1'b1;
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
            sch_state          <= SCH_IDLE;
            deq_request        <= 1'b0;
            deq_queue_id       <= {`QUEUE_ID_WIDTH{1'b0}};
            active_queue       <= {`QUEUE_ID_WIDTH{1'b0}};
            m_axis_tvalid      <= 1'b0;
            m_axis_tdata       <= {`AXIS_DATA_WIDTH{1'b0}};
            m_axis_tkeep       <= {`AXIS_KEEP_WIDTH{1'b0}};
            m_axis_tuser       <= {`AXIS_USER_WIDTH{1'b0}};
            m_axis_tlast       <= 1'b0;
            wrr_current_queue  <= {`QUEUE_ID_WIDTH{1'b0}};
            wrr_packets_served <= 16'd0;
        end else begin
            deq_request <= 1'b0;

            case (sch_state)
                SCH_IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    if (qos_cfg_mode == 1'b0) begin
                        // Strict Priority Mode
                        if (sp_any_queue_ready) begin
                            active_queue <= sp_selected_queue;
                            sch_state    <= SCH_REQUEST;
                        end
                    end else begin
                        // WRR Mode
                        if (wrr_any_queue_ready) begin
                            active_queue <= wrr_selected_queue;
                            if (wrr_need_to_switch) begin
                                wrr_current_queue <= wrr_selected_queue;
                                wrr_packets_served <= 16'd0;
                            end
                            sch_state    <= SCH_REQUEST;
                        end
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
                            if (qos_cfg_mode == 1'b1) begin
                                wrr_packets_served <= wrr_packets_served + 1'b1;
                            end
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
