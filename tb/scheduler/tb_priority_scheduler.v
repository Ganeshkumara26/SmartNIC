//============================================================================
// Testbench: Priority Scheduler
//============================================================================
// Tests the priority_scheduler + queue_manager together by:
//   1. Filling multiple queues with different priority packets
//   2. Verifying strict priority ordering (HP always drains first)
//   3. Measuring per-queue latency to prove HP gets lower latency
//   4. This is THE key MVP test — proving QoS differentiation!
//============================================================================

`timescale 1ns / 1ps

`include "smartnic_pkg.vh"

module tb_priority_scheduler;

    //------------------------------------------------------------------------
    // Clock and Reset
    //------------------------------------------------------------------------
    reg clk;
    reg rst_n;
    initial clk = 0;
    always #5 clk = ~clk;  // 100MHz

    //------------------------------------------------------------------------
    // Queue Manager Signals
    //------------------------------------------------------------------------
    reg  [`AXIS_DATA_WIDTH-1:0]  qm_s_tdata;
    reg  [`AXIS_KEEP_WIDTH-1:0]  qm_s_tkeep;
    reg  [`AXIS_USER_WIDTH-1:0]  qm_s_tuser;
    reg                          qm_s_tvalid;
    wire                         qm_s_tready;
    reg                          qm_s_tlast;

    wire [`AXIS_DATA_WIDTH-1:0]  qm_m_tdata;
    wire [`AXIS_KEEP_WIDTH-1:0]  qm_m_tkeep;
    wire [`AXIS_USER_WIDTH-1:0]  qm_m_tuser;
    wire                         qm_m_tvalid;
    wire                         qm_m_tready;
    wire                         qm_m_tlast;

    wire                         deq_request;
    wire [`QUEUE_ID_WIDTH-1:0]   deq_queue_id;
    wire [`NUM_QUEUES-1:0]       queue_empty;
    wire [`NUM_QUEUES-1:0]       queue_full;
    wire [`NUM_QUEUES*8-1:0]     queue_fill_levels;

    //------------------------------------------------------------------------
    // Scheduler Output Signals
    //------------------------------------------------------------------------
    wire [`AXIS_DATA_WIDTH-1:0]  sch_m_tdata;
    wire [`AXIS_KEEP_WIDTH-1:0]  sch_m_tkeep;
    wire [`AXIS_USER_WIDTH-1:0]  sch_m_tuser;
    wire                         sch_m_tvalid;
    reg                          sch_m_tready;
    wire                         sch_m_tlast;

    // Scheduler config
    reg                          cfg_wr_en;
    reg  [`QUEUE_ID_WIDTH-1:0]   cfg_queue_id;
    reg  [1:0]                   cfg_priority;
    reg                          cfg_queue_enable;

    // Scheduler stats
    wire [31:0] stat_total_packets;
    wire [31:0] stat_q0_packets, stat_q1_packets, stat_q2_packets, stat_q3_packets;

    //------------------------------------------------------------------------
    // DUT: Queue Manager
    //------------------------------------------------------------------------
    queue_manager u_qm (
        .clk              (clk),
        .rst_n            (rst_n),
        .s_axis_tdata     (qm_s_tdata),
        .s_axis_tkeep     (qm_s_tkeep),
        .s_axis_tuser     (qm_s_tuser),
        .s_axis_tvalid    (qm_s_tvalid),
        .s_axis_tready    (qm_s_tready),
        .s_axis_tlast     (qm_s_tlast),
        .m_axis_tdata     (qm_m_tdata),
        .m_axis_tkeep     (qm_m_tkeep),
        .m_axis_tuser     (qm_m_tuser),
        .m_axis_tvalid    (qm_m_tvalid),
        .m_axis_tready    (qm_m_tready),
        .m_axis_tlast     (qm_m_tlast),
        .deq_request      (deq_request),
        .deq_queue_id     (deq_queue_id),
        .queue_empty      (queue_empty),
        .queue_full       (queue_full),
        .queue_fill_levels(queue_fill_levels)
    );

    //------------------------------------------------------------------------
    // DUT: Priority Scheduler
    //------------------------------------------------------------------------
    priority_scheduler u_sch (
        .clk              (clk),
        .rst_n            (rst_n),
        .queue_empty      (queue_empty),
        .queue_full       (queue_full),
        .deq_request      (deq_request),
        .deq_queue_id     (deq_queue_id),
        .qm_axis_tdata    (qm_m_tdata),
        .qm_axis_tkeep    (qm_m_tkeep),
        .qm_axis_tuser    (qm_m_tuser),
        .qm_axis_tvalid   (qm_m_tvalid),
        .qm_axis_tready   (qm_m_tready),
        .qm_axis_tlast    (qm_m_tlast),
        .m_axis_tdata     (sch_m_tdata),
        .m_axis_tkeep     (sch_m_tkeep),
        .m_axis_tuser     (sch_m_tuser),
        .m_axis_tvalid    (sch_m_tvalid),
        .m_axis_tready    (sch_m_tready),
        .m_axis_tlast     (sch_m_tlast),
        .cfg_wr_en        (cfg_wr_en),
        .cfg_queue_id     (cfg_queue_id),
        .cfg_priority     (cfg_priority),
        .cfg_queue_enable (cfg_queue_enable),
        .stat_total_packets(stat_total_packets)
        // Note: stat_queue_packets is an array - access individually if needed
    );

    //------------------------------------------------------------------------
    // Test Counters & Latency Tracking
    //------------------------------------------------------------------------
    integer tests_passed = 0;
    integer tests_failed = 0;
    integer test_num = 0;

    // Latency tracking: record the cycle each packet was enqueued and dequeued
    integer enqueue_time [0:63];   // Indexed by packet sequence number
    integer dequeue_time [0:63];
    integer pkt_queue    [0:63];   // Which queue each packet was in
    integer enq_count = 0;
    integer deq_count = 0;
    integer current_cycle = 0;

    always @(posedge clk) current_cycle = current_cycle + 1;

    //------------------------------------------------------------------------
    // Helper Tasks
    //------------------------------------------------------------------------

    // Build TUSER with Slice ID and a packet sequence number in the data
    function [`AXIS_USER_WIDTH-1:0] make_tuser;
        input [`TUSER_SLICE_ID_WIDTH-1:0] slice_id;
        begin
            make_tuser = {`AXIS_USER_WIDTH{1'b0}};
            make_tuser[`TUSER_VALID_BIT] = 1'b1;
            make_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO] = slice_id;
        end
    endfunction

    // Enqueue a packet to a specific queue
    task enqueue;
        input [`TUSER_SLICE_ID_WIDTH-1:0] slice_id;
        input [31:0] seq_num;
        begin
            @(posedge clk);
            qm_s_tdata  <= {480'd0, seq_num};
            qm_s_tkeep  <= {`AXIS_KEEP_WIDTH{1'b1}};
            qm_s_tuser  <= make_tuser(slice_id);
            qm_s_tvalid <= 1'b1;
            qm_s_tlast  <= 1'b1;

            @(posedge clk);
            while (!qm_s_tready) @(posedge clk);
            qm_s_tvalid <= 1'b0;
            qm_s_tlast  <= 1'b0;

            enqueue_time[enq_count] = current_cycle;
            pkt_queue[enq_count] = slice_id;
            enq_count = enq_count + 1;
        end
    endtask

    // Check assertion
    task check;
        input [255:0] name;
        input [31:0] actual;
        input [31:0] expected;
        begin
            if (actual === expected) begin
                tests_passed = tests_passed + 1;
            end else begin
                $display("  FAIL: %0s = %0d, expected %0d", name, actual, expected);
                tests_failed = tests_failed + 1;
            end
        end
    endtask

    //------------------------------------------------------------------------
    // Output Monitor — Captures dequeued packets and records latency
    //------------------------------------------------------------------------
    reg [31:0] output_sequence [0:63];
    reg [`TUSER_SLICE_ID_WIDTH-1:0] output_slice [0:63];
    integer output_count = 0;

    always @(posedge clk) begin
        if (sch_m_tvalid && sch_m_tready && sch_m_tlast) begin
            output_sequence[output_count] = sch_m_tdata[31:0];
            output_slice[output_count] = sch_m_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO];
            dequeue_time[output_count] = current_cycle;
            output_count = output_count + 1;
        end
    end

    //------------------------------------------------------------------------
    // Main Test Sequence
    //------------------------------------------------------------------------
    initial begin
        $dumpfile("scheduler_waves.vcd");
        $dumpvars(0, tb_priority_scheduler);

        // Initialize
        qm_s_tdata    = {`AXIS_DATA_WIDTH{1'b0}};
        qm_s_tkeep    = {`AXIS_KEEP_WIDTH{1'b0}};
        qm_s_tuser    = {`AXIS_USER_WIDTH{1'b0}};
        qm_s_tvalid   = 1'b0;
        qm_s_tlast    = 1'b0;
        sch_m_tready  = 1'b1;
        cfg_wr_en     = 1'b0;
        cfg_queue_id  = 2'd0;
        cfg_priority  = 2'd0;
        cfg_queue_enable = 1'b1;
        rst_n = 1'b0;

        #100;
        rst_n = 1'b1;
        #20;

        // ==============================================================
        // TEST 1: Basic Priority Ordering
        // ==============================================================
        test_num = 1;
        $display("\n── TEST %0d: Basic Strict Priority ──", test_num);
        $display("  Enqueuing: 3 LP (Q3), 3 HP (Q0)");
        $display("  Expected output order: All Q0 first, then Q3");

        // Fill LP queue first (Queue 3 — lowest priority)
        enqueue(4'd3, 32'd100);  // LP packet 1
        enqueue(4'd3, 32'd101);  // LP packet 2
        enqueue(4'd3, 32'd102);  // LP packet 3

        // Then fill HP queue (Queue 0 — highest priority)
        enqueue(4'd0, 32'd200);  // HP packet 1
        enqueue(4'd0, 32'd201);  // HP packet 2
        enqueue(4'd0, 32'd202);  // HP packet 3

        // Wait for all packets to be drained
        #2000;

        $display("  Output order:");
        begin : print_output
            integer idx;
            for (idx = 0; idx < output_count; idx = idx + 1) begin
                $display("    [%0d] Queue %0d, SeqNum %0d, Latency %0d cycles",
                    idx, output_slice[idx], output_sequence[idx],
                    dequeue_time[idx] - enqueue_time[idx]);
            end
        end

        // Verify HP packets came out first
        // The first LP packet is already in-flight when HP arrives!
        check("first_out_is_LP_inflight",  output_slice[0], 4'd3);
        check("second_out_is_HP", output_slice[1], 4'd0);
        check("third_out_is_HP",  output_slice[2], 4'd0);
        check("fourth_out_is_HP", output_slice[3], 4'd0);
        check("fifth_out_is_LP",  output_slice[4], 4'd3);
        check("sixth_out_is_LP",  output_slice[5], 4'd3);

        // ==============================================================
        // TEST 2: Mixed Priority with All 4 Queues
        // ==============================================================
        test_num = 2;
        $display("\n── TEST %0d: All 4 Priority Levels ──", test_num);

        // Reset counters
        output_count = 0;
        enq_count = 0;

        // Enqueue in reverse priority order (worst first)
        enqueue(4'd3, 32'd300);  // Lowest priority
        enqueue(4'd2, 32'd301);  // Medium
        enqueue(4'd1, 32'd302);  // High
        enqueue(4'd0, 32'd303);  // Highest priority — should come out first

        #2000;

        $display("  Output order:");
        begin : print_output2
            integer idx;
            for (idx = 0; idx < output_count; idx = idx + 1) begin
                $display("    [%0d] Queue %0d, SeqNum %0d",
                    idx, output_slice[idx], output_sequence[idx]);
            end
        end

        // Q3 was in-flight because it arrived first. Then strict priority takes over!
        check("q3_first_inflight", output_slice[0], 4'd3);
        check("q0_second", output_slice[1], 4'd0);
        check("q1_third",  output_slice[2], 4'd1);
        check("q2_fourth", output_slice[3], 4'd2);

        // ==============================================================
        // TEST 3: Latency Comparison Under Load (THE MVP PROOF)
        // ==============================================================
        test_num = 3;
        $display("\n── TEST %0d: Latency Comparison Under Load ──", test_num);
        $display("  This is the KEY QoS test!");

        output_count = 0;
        enq_count = 0;

        // Simulate a burst: lots of LP traffic, then HP traffic arrives
        $display("  Phase 1: Flooding Queue 3 (Best-Effort) with 8 packets...");
        begin : flood_lp
            integer f;
            for (f = 0; f < 8; f = f + 1) begin
                enqueue(4'd3, 32'd400 + f);
            end
        end

        $display("  Phase 2: HP packet (Queue 0 URLLC) arrives...");
        enqueue(4'd0, 32'd500);  // This HP packet should be serviced BEFORE remaining LP

        $display("  Phase 3: More LP arrives...");
        enqueue(4'd3, 32'd408);
        enqueue(4'd3, 32'd409);

        // Wait for drain
        #5000;

        $display("\n  ┌──────┬────────┬────────┬─────────────┐");
        $display("  │ Slot │ Queue  │ SeqNum │ Latency(cyc)│");
        $display("  ├──────┼────────┼────────┼─────────────┤");
        begin : print_latency
            integer idx;
            integer hp_latency, lp_latency_total, lp_count;
            hp_latency = 0;
            lp_latency_total = 0;
            lp_count = 0;

            for (idx = 0; idx < output_count; idx = idx + 1) begin
                $display("  │ %4d │   Q%0d   │  %4d  │    %4d     │",
                    idx, output_slice[idx], output_sequence[idx],
                    dequeue_time[idx] - enqueue_time[idx]);

                if (output_sequence[idx] == 32'd500) begin
                    hp_latency = dequeue_time[idx] - enqueue_time[idx];
                end else begin
                    lp_latency_total = lp_latency_total + (dequeue_time[idx] - enqueue_time[idx]);
                    lp_count = lp_count + 1;
                end
            end

            $display("  └──────┴────────┴────────┴─────────────┘");
            $display("");
            $display("  ╔═══════════════════════════════════════╗");
            $display("  ║  QoS LATENCY COMPARISON RESULTS      ║");
            $display("  ╠═══════════════════════════════════════╣");
            $display("  ║  HP (URLLC) latency:  %4d cycles     ║", hp_latency);
            if (lp_count > 0)
                $display("  ║  LP (Avg)  latency:  %4d cycles     ║", lp_latency_total / lp_count);
            $display("  ║                                       ║");
            if (hp_latency < (lp_latency_total / lp_count))
                $display("  ║  ✓ HP LATENCY < LP LATENCY  ║");
            else
                $display("  ║  ✗ HP did NOT get lower latency      ║");
            $display("  ╚═══════════════════════════════════════╝");

            // The key assertion: HP latency must be less than average LP latency
            if (hp_latency < (lp_latency_total / lp_count)) begin
                $display("\n  >>> MVP PROOF: High Priority packets achieve LOWER LATENCY <<<");
                tests_passed = tests_passed + 1;
            end else begin
                $display("\n  >>> FAIL: HP latency not lower than LP <<<");
                tests_failed = tests_failed + 1;
            end
        end

        // ==============================================================
        // Summary
        // ==============================================================
        #50;
        $display("\n══════════════════════════════════════════");
        $display("  SCHEDULER TESTBENCH RESULTS");
        $display("  Tests passed: %0d", tests_passed);
        $display("  Tests failed: %0d", tests_failed);
        if (tests_failed == 0)
            $display("  STATUS: *** ALL TESTS PASSED ***");
        else
            $display("  STATUS: *** SOME TESTS FAILED ***");
        $display("══════════════════════════════════════════\n");

        $finish;
    end

    initial begin
        #500000;
        $display("ERROR: Testbench timed out!");
        $finish;
    end

endmodule
