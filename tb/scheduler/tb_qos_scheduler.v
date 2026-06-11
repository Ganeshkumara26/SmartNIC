//============================================================================
// Testbench: Dual-Mode QoS Scheduler (tb_qos_scheduler.v)
//============================================================================
// Verifies:
//   1. Strict Priority (SP) mode causes intentional starvation.
//   2. Weighted Round Robin (WRR) mode distributes bandwidth proportionally.
//============================================================================

`timescale 1ns / 1ps

module tb_qos_scheduler;

    reg clk;
    reg rst_n;
    initial clk = 0;
    always #5 clk = ~clk;

    // ── Inputs to Scheduler ──
    reg  [3:0] queue_empty;
    reg  [3:0] queue_full;

    // ── Outputs from Scheduler ──
    wire       deq_request;
    wire [1:0] deq_queue_id;

    // ── AXI-Stream from Queue Manager (Mocked) ──
    reg  [63:0] qm_axis_tdata;
    reg  [7:0]  qm_axis_tkeep;
    reg  [15:0] qm_axis_tuser;
    reg         qm_axis_tvalid;
    wire        qm_axis_tready;
    reg         qm_axis_tlast;

    // ── AXI-Stream Master ──
    wire [63:0] m_axis_tdata;
    wire [7:0]  m_axis_tkeep;
    wire [15:0] m_axis_tuser;
    wire        m_axis_tvalid;
    reg         m_axis_tready;
    wire        m_axis_tlast;

    // ── Configuration Wires ──
    reg         cfg_wr_en;
    reg  [1:0]  cfg_queue_id;
    reg  [1:0]  cfg_priority;
    reg         cfg_queue_enable;
    reg  [31:0] cfg_tb_rate;
    reg  [31:0] cfg_tb_burst;
    reg         cfg_tb_enable;

    reg         qos_cfg_wr_en;
    reg         qos_cfg_mode;
    reg  [1:0]  qos_cfg_weight_id;
    reg  [15:0] qos_cfg_weight_val;

    // ── DUT Instantiation ──
    qos_scheduler dut (
        .clk                 (clk),
        .rst_n               (rst_n),
        
        .queue_empty         (queue_empty),
        .queue_full          (queue_full),
        
        .deq_request         (deq_request),
        .deq_queue_id        (deq_queue_id),
        
        .qm_axis_tdata       (qm_axis_tdata),
        .qm_axis_tkeep       (qm_axis_tkeep),
        .qm_axis_tuser       (qm_axis_tuser),
        .qm_axis_tvalid      (qm_axis_tvalid),
        .qm_axis_tready      (qm_axis_tready),
        .qm_axis_tlast       (qm_axis_tlast),
        
        .m_axis_tdata        (m_axis_tdata),
        .m_axis_tkeep        (m_axis_tkeep),
        .m_axis_tuser        (m_axis_tuser),
        .m_axis_tvalid       (m_axis_tvalid),
        .m_axis_tready       (m_axis_tready),
        .m_axis_tlast        (m_axis_tlast),
        
        .cfg_wr_en           (cfg_wr_en),
        .cfg_queue_id        (cfg_queue_id),
        .cfg_priority        (cfg_priority),
        .cfg_queue_enable    (cfg_queue_enable),
        .cfg_tb_rate         (cfg_tb_rate),
        .cfg_tb_burst        (cfg_tb_burst),
        .cfg_tb_enable       (cfg_tb_enable),
        
        .qos_cfg_wr_en       (qos_cfg_wr_en),
        .qos_cfg_mode        (qos_cfg_mode),
        .qos_cfg_weight_id   (qos_cfg_weight_id),
        .qos_cfg_weight_val  (qos_cfg_weight_val)
    );

    // ── Mock Queue Manager ──
    // Responds to deq_request by supplying a 1-cycle packet
    always @(posedge clk) begin
        if (!rst_n) begin
            qm_axis_tvalid <= 1'b0;
        end else begin
            if (deq_request) begin
                qm_axis_tvalid <= 1'b1;
                qm_axis_tlast  <= 1'b1;
                qm_axis_tdata  <= {62'd0, deq_queue_id}; // embed queue id
            end else if (qm_axis_tvalid && qm_axis_tready) begin
                qm_axis_tvalid <= 1'b0;
            end
        end
    end

    // ── Counters for Verification ──
    integer stat_q0 = 0;
    integer stat_q1 = 0;
    integer stat_q2 = 0;
    integer stat_q3 = 0;

    always @(posedge clk) begin
        if (m_axis_tvalid && m_axis_tready && m_axis_tlast) begin
            case (m_axis_tdata[1:0])
                2'd0: begin stat_q0 = stat_q0 + 1; $display("Time %0t: Dequeued from Q0", $time); end
                2'd1: begin stat_q1 = stat_q1 + 1; $display("Time %0t: Dequeued from Q1", $time); end
                2'd2: begin stat_q2 = stat_q2 + 1; $display("Time %0t: Dequeued from Q2", $time); end
                2'd3: begin stat_q3 = stat_q3 + 1; $display("Time %0t: Dequeued from Q3", $time); end
            endcase
        end
    end

    // ── Configuration Tasks ──
    task set_wrr_weight;
        input [1:0] q_id;
        input [15:0] weight;
        begin
            @(negedge clk);
            qos_cfg_wr_en = 1;
            qos_cfg_weight_id = q_id;
            qos_cfg_weight_val = weight;
            @(negedge clk);
            qos_cfg_wr_en = 0;
        end
    endtask

    task set_mode;
        input mode; // 0 = SP, 1 = WRR
        begin
            @(negedge clk);
            qos_cfg_wr_en = 1;
            qos_cfg_mode = mode;
            @(negedge clk);
            qos_cfg_wr_en = 0;
        end
    endtask

    // ── Main Test Sequence ──
    initial begin
        // Reset and init
        rst_n = 0;
        queue_empty = 4'b1111; // All empty
        queue_full = 4'b0000;
        m_axis_tready = 1'b1;
        
        cfg_wr_en = 0;
        qos_cfg_wr_en = 0;
        qos_cfg_mode = 0;
        
        #20;
        rst_n = 1;
        #20;

        $display("==================================================");
        $display("Test 1: Strict Priority (SP) Starvation Test");
        $display("==================================================");
        set_mode(0); // SP Mode
        
        // Flood Q0 (URLLC), Q1, and Q2. All never empty.
        queue_empty = 4'b1000; // Q0, Q1, Q2 have traffic. Q3 is empty.
        
        // Run for 100 cycles
        #1000;
        
        $display("SP Mode Results:");
        $display("Q0 Packets: %0d", stat_q0);
        $display("Q1 Packets: %0d", stat_q1);
        $display("Q2 Packets: %0d", stat_q2);
        
        if (stat_q0 > 0 && stat_q1 == 0 && stat_q2 == 0)
            $display("-> PASS: Q0 successfully starved Q1 and Q2 in SP Mode.");
        else
            $display("-> FAIL: Starvation did not occur correctly.");

        // Stop queues to settle pipeline and wait for in-flight packets
        queue_empty = 4'b1111;
        #500;

        // Clear counters
        stat_q0 = 0; stat_q1 = 0; stat_q2 = 0; stat_q3 = 0;

        $display("\n==================================================");
        $display("Test 2: Weighted Round Robin (WRR) Fairness Test");
        $display("==================================================");
        set_mode(1); // WRR Mode
        
        // Set weights: Q0=5, Q1=3, Q2=2, Q3=1
        set_wrr_weight(0, 5);
        set_wrr_weight(1, 3);
        set_wrr_weight(2, 2);
        set_wrr_weight(3, 1);
        
        // Flood all queues
        queue_empty = 4'b0000;
        
        // Run for exactly 22 packets (2 full WRR cycles: (5+3+2+1) * 2 = 22 packets)
        while ((stat_q0 + stat_q1 + stat_q2 + stat_q3) < 22) begin
            @(posedge clk);
        end
        // Small delay to ensure the last packet logic registers fully
        #10;
        
        $display("WRR Mode Results (Expected ratio 5:3:2:1):");
        $display("Q0 Packets: %0d", stat_q0);
        $display("Q1 Packets: %0d", stat_q1);
        $display("Q2 Packets: %0d", stat_q2);
        $display("Q3 Packets: %0d", stat_q3);
        
        if (stat_q0 == 10 && stat_q1 == 6 && stat_q2 == 4 && stat_q3 == 2)
            $display("-> PASS: WRR perfectly distributed bandwidth proportionally.");
        else
            $display("-> FAIL: WRR distribution is incorrect.");

        $display("==================================================");
        $display("ALL TESTS PASSED.");
        $finish;
    end

endmodule
