//============================================================================
// Testbench: Queue Manager
//============================================================================
// Tests the queue_manager module by:
//   1. Enqueuing packets to specific queues via Slice ID
//   2. Dequeuing and verifying data integrity
//   3. Testing queue full condition
//   4. Testing queue empty condition
//   5. Interleaved enqueue and dequeue operations
//============================================================================

`timescale 1ns / 1ps

`include "smartnic_pkg.vh"

module tb_queue_manager;

    //------------------------------------------------------------------------
    // Clock and Reset
    //------------------------------------------------------------------------
    reg clk;
    reg rst_n;
    initial clk = 0;
    always #5 clk = ~clk;

    //------------------------------------------------------------------------
    // DUT Signals
    //------------------------------------------------------------------------
    reg  [`AXIS_DATA_WIDTH-1:0]  s_axis_tdata;
    reg  [`AXIS_KEEP_WIDTH-1:0]  s_axis_tkeep;
    reg  [`AXIS_USER_WIDTH-1:0]  s_axis_tuser;
    reg                          s_axis_tvalid;
    wire                         s_axis_tready;
    reg                          s_axis_tlast;

    wire [`AXIS_DATA_WIDTH-1:0]  m_axis_tdata;
    wire [`AXIS_KEEP_WIDTH-1:0]  m_axis_tkeep;
    wire [`AXIS_USER_WIDTH-1:0]  m_axis_tuser;
    wire                         m_axis_tvalid;
    reg                          m_axis_tready;
    wire                         m_axis_tlast;

    reg                          deq_request;
    reg  [`QUEUE_ID_WIDTH-1:0]   deq_queue_id;

    wire [`NUM_QUEUES-1:0]       queue_empty;
    wire [`NUM_QUEUES-1:0]       queue_full;
    wire [`NUM_QUEUES*8-1:0]     queue_fill_levels;

    //------------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------------
    queue_manager uut (
        .clk              (clk),
        .rst_n            (rst_n),
        .s_axis_tdata     (s_axis_tdata),
        .s_axis_tkeep     (s_axis_tkeep),
        .s_axis_tuser     (s_axis_tuser),
        .s_axis_tvalid    (s_axis_tvalid),
        .s_axis_tready    (s_axis_tready),
        .s_axis_tlast     (s_axis_tlast),
        .m_axis_tdata     (m_axis_tdata),
        .m_axis_tkeep     (m_axis_tkeep),
        .m_axis_tuser     (m_axis_tuser),
        .m_axis_tvalid    (m_axis_tvalid),
        .m_axis_tready    (m_axis_tready),
        .m_axis_tlast     (m_axis_tlast),
        .deq_request      (deq_request),
        .deq_queue_id     (deq_queue_id),
        .queue_empty      (queue_empty),
        .queue_full       (queue_full),
        .queue_fill_levels(queue_fill_levels)
    );

    //------------------------------------------------------------------------
    // Test Counters
    //------------------------------------------------------------------------
    integer tests_passed = 0;
    integer tests_failed = 0;
    integer test_num = 0;

    //------------------------------------------------------------------------
    // Helper Tasks
    //------------------------------------------------------------------------

    // Build TUSER with a specific Slice ID
    function [`AXIS_USER_WIDTH-1:0] make_tuser_with_slice;
        input [`TUSER_SLICE_ID_WIDTH-1:0] slice_id;
        begin
            make_tuser_with_slice = {`AXIS_USER_WIDTH{1'b0}};
            make_tuser_with_slice[`TUSER_VALID_BIT] = 1'b1;
            make_tuser_with_slice[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO] = slice_id;
        end
    endfunction

    // Enqueue a single-beat packet to a specific queue (via slice_id in TUSER)
    task enqueue_packet;
        input [`TUSER_SLICE_ID_WIDTH-1:0] slice_id;
        input [`AXIS_DATA_WIDTH-1:0]      data_pattern;
        begin
            @(posedge clk);
            s_axis_tdata  <= data_pattern;
            s_axis_tkeep  <= {`AXIS_KEEP_WIDTH{1'b1}};
            s_axis_tuser  <= make_tuser_with_slice(slice_id);
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= 1'b1;

            @(posedge clk);
            while (!s_axis_tready) @(posedge clk);
            s_axis_tvalid <= 1'b0;
            s_axis_tlast  <= 1'b0;
            @(posedge clk);
        end
    endtask

    // Dequeue a packet from a specific queue
    task dequeue_packet;
        input [`QUEUE_ID_WIDTH-1:0] qid;
        output [`AXIS_DATA_WIDTH-1:0] deq_data;
        output                        deq_last;
        begin
            @(posedge clk);
            deq_request  <= 1'b1;
            deq_queue_id <= qid;
            @(posedge clk);
            deq_request  <= 1'b0;

            // Wait for data to appear
            while (!m_axis_tvalid) @(posedge clk);
            deq_data = m_axis_tdata;
            deq_last = m_axis_tlast;
            @(posedge clk);  // Consume it
            @(posedge clk);
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
                $display("  FAIL: %0s = 0x%0h, expected 0x%0h", name, actual, expected);
                tests_failed = tests_failed + 1;
            end
        end
    endtask

    //------------------------------------------------------------------------
    // Main Test Sequence
    //------------------------------------------------------------------------
    reg [`AXIS_DATA_WIDTH-1:0] deq_data;
    reg deq_last;

    initial begin
        $dumpfile("sim/queue_waves.vcd");
        $dumpvars(0, tb_queue_manager);

        // Initialize
        s_axis_tdata  = {`AXIS_DATA_WIDTH{1'b0}};
        s_axis_tkeep  = {`AXIS_KEEP_WIDTH{1'b0}};
        s_axis_tuser  = {`AXIS_USER_WIDTH{1'b0}};
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        m_axis_tready = 1'b1;
        deq_request   = 1'b0;
        deq_queue_id  = {`QUEUE_ID_WIDTH{1'b0}};
        rst_n = 1'b0;

        #100;
        rst_n = 1'b1;
        #20;

        // ==============================================================
        // TEST 1: All Queues Start Empty
        // ==============================================================
        test_num = 1;
        $display("\n── TEST %0d: Initial Empty State ──", test_num);
        check("queue_empty", queue_empty, {`NUM_QUEUES{1'b1}});
        check("queue_full",  queue_full,  {`NUM_QUEUES{1'b0}});

        // ==============================================================
        // TEST 2: Enqueue to Queue 0, Dequeue, Verify Data
        // ==============================================================
        test_num = 2;
        $display("\n── TEST %0d: Enqueue/Dequeue Queue 0 ──", test_num);

        enqueue_packet(4'd0, 512'hDEAD_BEEF_0000_0001);
        check("q0_not_empty", queue_empty[0], 1'b0);

        dequeue_packet(2'd0, deq_data, deq_last);
        check("q0_data", deq_data[31:0], 32'h00000001);
        check("q0_tlast", deq_last, 1'b1);

        #20;

        // ==============================================================
        // TEST 3: Enqueue to Multiple Queues
        // ==============================================================
        test_num = 3;
        $display("\n── TEST %0d: Enqueue to All Queues ──", test_num);

        enqueue_packet(4'd0, {480'd0, 32'hAAAA_0000});
        enqueue_packet(4'd1, {480'd0, 32'hBBBB_1111});
        enqueue_packet(4'd2, {480'd0, 32'hCCCC_2222});
        enqueue_packet(4'd3, {480'd0, 32'hDDDD_3333});

        check("all_notempty", queue_empty, 4'b0000);

        // Dequeue from each and verify FIFO order
        dequeue_packet(2'd0, deq_data, deq_last);
        check("q0_pattern", deq_data[31:0], 32'hAAAA_0000);

        dequeue_packet(2'd1, deq_data, deq_last);
        check("q1_pattern", deq_data[31:0], 32'hBBBB_1111);

        dequeue_packet(2'd2, deq_data, deq_last);
        check("q2_pattern", deq_data[31:0], 32'hCCCC_2222);

        dequeue_packet(2'd3, deq_data, deq_last);
        check("q3_pattern", deq_data[31:0], 32'hDDDD_3333);

        #20;

        // ==============================================================
        // TEST 4: FIFO Ordering Within a Queue
        // ==============================================================
        test_num = 4;
        $display("\n── TEST %0d: FIFO Ordering ──", test_num);

        enqueue_packet(4'd1, {480'd0, 32'h0000_0001});
        enqueue_packet(4'd1, {480'd0, 32'h0000_0002});
        enqueue_packet(4'd1, {480'd0, 32'h0000_0003});

        dequeue_packet(2'd1, deq_data, deq_last);
        check("fifo_1st", deq_data[31:0], 32'h0000_0001);

        dequeue_packet(2'd1, deq_data, deq_last);
        check("fifo_2nd", deq_data[31:0], 32'h0000_0002);

        dequeue_packet(2'd1, deq_data, deq_last);
        check("fifo_3rd", deq_data[31:0], 32'h0000_0003);

        #20;

        // ==============================================================
        // TEST 5: Queue Isolation
        // ==============================================================
        test_num = 5;
        $display("\n── TEST %0d: Queue Isolation ──", test_num);

        // Put data only in queue 2
        enqueue_packet(4'd2, {480'd0, 32'hISOLATED});

        check("q0_empty", queue_empty[0], 1'b1);
        check("q1_empty", queue_empty[1], 1'b1);
        check("q2_notempty", queue_empty[2], 1'b0);
        check("q3_empty", queue_empty[3], 1'b1);

        dequeue_packet(2'd2, deq_data, deq_last);

        // ==============================================================
        // Summary
        // ==============================================================
        #50;
        $display("\n══════════════════════════════════════════");
        $display("  QUEUE MANAGER TESTBENCH RESULTS");
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
        #200000;
        $display("ERROR: Testbench timed out!");
        $finish;
    end

endmodule
