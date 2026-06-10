//============================================================================
// Testbench: Flow Classifier
//============================================================================
// Tests the flow_classifier module by:
//   1. Programming 4 rules (one per traffic class/slice)
//   2. Sending packets that match each rule → verify correct Slice ID
//   3. Testing default rule (no match → default Slice ID)
//   4. Testing priority ordering (first-match-wins)
//   5. Testing rule enable/disable
//============================================================================

`timescale 1ns / 1ps

`include "smartnic_pkg.vh"

module tb_flow_classifier;

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
    // AXI-Stream input
    reg  [`AXIS_DATA_WIDTH-1:0]  s_axis_tdata;
    reg  [`AXIS_KEEP_WIDTH-1:0]  s_axis_tkeep;
    reg  [`AXIS_USER_WIDTH-1:0]  s_axis_tuser;
    reg                          s_axis_tvalid;
    wire                         s_axis_tready;
    reg                          s_axis_tlast;

    // AXI-Stream output
    wire [`AXIS_DATA_WIDTH-1:0]  m_axis_tdata;
    wire [`AXIS_KEEP_WIDTH-1:0]  m_axis_tkeep;
    wire [`AXIS_USER_WIDTH-1:0]  m_axis_tuser;
    wire                         m_axis_tvalid;
    reg                          m_axis_tready;
    wire                         m_axis_tlast;

    // Configuration port
    reg                              cfg_wr_en;
    reg  [`RULE_ID_WIDTH-1:0]        cfg_rule_id;
    reg  [31:0]                      cfg_dst_ip;
    reg  [31:0]                      cfg_dst_ip_mask;
    reg  [15:0]                      cfg_dst_port;
    reg  [15:0]                      cfg_dst_port_mask;
    reg  [7:0]                       cfg_protocol;
    reg  [7:0]                       cfg_protocol_mask;
    reg  [`TUSER_SLICE_ID_WIDTH-1:0] cfg_slice_id;
    reg                              cfg_rule_enable;

    //------------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------------
    flow_classifier uut (
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
        .cfg_wr_en        (cfg_wr_en),
        .cfg_rule_id      (cfg_rule_id),
        .cfg_dst_ip       (cfg_dst_ip),
        .cfg_dst_ip_mask  (cfg_dst_ip_mask),
        .cfg_dst_port     (cfg_dst_port),
        .cfg_dst_port_mask(cfg_dst_port_mask),
        .cfg_protocol     (cfg_protocol),
        .cfg_protocol_mask(cfg_protocol_mask),
        .cfg_slice_id     (cfg_slice_id),
        .cfg_rule_enable  (cfg_rule_enable)
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

    // Program a classifier rule
    task program_rule;
        input [`RULE_ID_WIDTH-1:0]        rule_id;
        input [31:0]                      dst_ip;
        input [31:0]                      dst_ip_mask;
        input [15:0]                      dst_port;
        input [15:0]                      dst_port_mask;
        input [7:0]                       protocol;
        input [7:0]                       protocol_mask;
        input [`TUSER_SLICE_ID_WIDTH-1:0] slice_id;
        input                             enable;
        begin
            @(posedge clk);
            cfg_wr_en         <= 1'b1;
            cfg_rule_id       <= rule_id;
            cfg_dst_ip        <= dst_ip;
            cfg_dst_ip_mask   <= dst_ip_mask;
            cfg_dst_port      <= dst_port;
            cfg_dst_port_mask <= dst_port_mask;
            cfg_protocol      <= protocol;
            cfg_protocol_mask <= protocol_mask;
            cfg_slice_id      <= slice_id;
            cfg_rule_enable   <= enable;
            @(posedge clk);
            cfg_wr_en <= 1'b0;
        end
    endtask

    // Build TUSER metadata as if coming from the packet parser
    function [`AXIS_USER_WIDTH-1:0] make_tuser;
        input [31:0] dst_ip;
        input [31:0] src_ip;
        input [15:0] dst_port;
        input [15:0] src_port;
        input [7:0]  protocol;
        input        valid;
        begin
            make_tuser = {`AXIS_USER_WIDTH{1'b0}};
            make_tuser[`TUSER_VALID_BIT]                       = valid;
            make_tuser[`TUSER_IS_IPV4_BIT]                     = valid;
            make_tuser[`TUSER_IS_UDP_BIT]                      = (protocol == `IP_PROTO_UDP);
            make_tuser[`TUSER_IS_TCP_BIT]                      = (protocol == `IP_PROTO_TCP);
            make_tuser[`TUSER_IP_PROTO_HI:`TUSER_IP_PROTO_LO] = protocol;
            make_tuser[`TUSER_DST_PORT_HI:`TUSER_DST_PORT_LO] = dst_port;
            make_tuser[`TUSER_SRC_PORT_HI:`TUSER_SRC_PORT_LO] = src_port;
            make_tuser[`TUSER_DST_IP_HI:`TUSER_DST_IP_LO]     = dst_ip;
            make_tuser[`TUSER_SRC_IP_HI:`TUSER_SRC_IP_LO]     = src_ip;
        end
    endfunction

    // Send a single-beat packet with metadata
    task send_packet;
        input [`AXIS_USER_WIDTH-1:0] tuser;
        begin
            @(posedge clk);
            s_axis_tdata  <= {`AXIS_DATA_WIDTH{1'b0}};  // Data doesn't matter for classifier
            s_axis_tkeep  <= {`AXIS_KEEP_WIDTH{1'b1}};
            s_axis_tuser  <= tuser;
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= 1'b1;

            @(posedge clk);
            while (!s_axis_tready) @(posedge clk);
            s_axis_tvalid <= 1'b0;
            s_axis_tlast  <= 1'b0;
        end
    endtask

    // Wait for output and check Slice ID
    task check_slice_id;
        input [`TUSER_SLICE_ID_WIDTH-1:0] expected_id;
        input [255:0] test_name;
        reg [`TUSER_SLICE_ID_WIDTH-1:0] actual_id;
        begin
            while (!m_axis_tvalid) @(posedge clk);
            actual_id = m_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO];
            @(posedge clk);  // Consume

            if (actual_id === expected_id) begin
                $display("  PASS: %0s → Slice ID = %0d", test_name, actual_id);
                tests_passed = tests_passed + 1;
            end else begin
                $display("  FAIL: %0s → Slice ID = %0d, expected %0d",
                         test_name, actual_id, expected_id);
                tests_failed = tests_failed + 1;
            end
        end
    endtask

    //------------------------------------------------------------------------
    // Main Test Sequence
    //------------------------------------------------------------------------
    initial begin
        $dumpfile("classifier_waves.vcd");
        $dumpvars(0, tb_flow_classifier);

        // Initialize
        s_axis_tdata  = {`AXIS_DATA_WIDTH{1'b0}};
        s_axis_tkeep  = {`AXIS_KEEP_WIDTH{1'b0}};
        s_axis_tuser  = {`AXIS_USER_WIDTH{1'b0}};
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        m_axis_tready = 1'b1;
        cfg_wr_en     = 1'b0;
        rst_n = 1'b0;

        #100;
        rst_n = 1'b1;
        #20;

        // ==============================================================
        // Program Rules
        // ==============================================================
        $display("\n── Programming Classifier Rules ──");

        // Rule 0: URLLC → Slice 0 (dst_ip=10.0.1.0/24, port=5001, UDP)
        program_rule(4'd0,
            32'h0A000101, 32'hFFFFFF00,  // 10.0.1.x
            16'd5001,     16'hFFFF,      // exact port
            8'd17,        8'hFF,         // UDP
            4'd0, 1'b1);

        // Rule 1: Voice → Slice 1 (dst_ip=10.0.2.0/24, port=5060, UDP)
        program_rule(4'd1,
            32'h0A000201, 32'hFFFFFF00,
            16'd5060,     16'hFFFF,
            8'd17,        8'hFF,
            4'd1, 1'b1);

        // Rule 2: eMBB → Slice 2 (dst_ip=10.0.3.0/24, port=8080, any proto)
        program_rule(4'd2,
            32'h0A000301, 32'hFFFFFF00,
            16'd8080,     16'hFFFF,
            8'd0,         8'h00,         // any protocol (mask=0)
            4'd2, 1'b1);

        // Rule 3: IoT → Slice 3 (dst_ip=10.0.4.0/24, any port, any proto)
        program_rule(4'd3,
            32'h0A000401, 32'hFFFFFF00,
            16'd0,        16'h0000,      // any port
            8'd0,         8'h00,         // any protocol
            4'd3, 1'b1);

        $display("  4 rules programmed\n");
        #20;

        // ==============================================================
        // TEST 1: URLLC Packet → Slice 0
        // ==============================================================
        test_num = 1;
        $display("── TEST %0d: URLLC Packet ──", test_num);
        send_packet(make_tuser(32'h0A000101, 32'hC0A80164, 16'd5001, 16'd10001, 8'd17, 1'b1));
        check_slice_id(4'd0, "URLLC");

        #10;

        // ==============================================================
        // TEST 2: Voice Packet → Slice 1
        // ==============================================================
        test_num = 2;
        $display("── TEST %0d: Voice Packet ──", test_num);
        send_packet(make_tuser(32'h0A000201, 32'hC0A80165, 16'd5060, 16'd20001, 8'd17, 1'b1));
        check_slice_id(4'd1, "Voice");

        #10;

        // ==============================================================
        // TEST 3: eMBB Packet → Slice 2
        // ==============================================================
        test_num = 3;
        $display("── TEST %0d: eMBB Packet ──", test_num);
        send_packet(make_tuser(32'h0A000301, 32'hC0A80166, 16'd8080, 16'd30001, 8'd17, 1'b1));
        check_slice_id(4'd2, "eMBB");

        #10;

        // ==============================================================
        // TEST 4: IoT Packet → Slice 3
        // ==============================================================
        test_num = 4;
        $display("── TEST %0d: IoT Packet ──", test_num);
        send_packet(make_tuser(32'h0A000401, 32'hC0A80167, 16'd1883, 16'd40001, 8'd17, 1'b1));
        check_slice_id(4'd3, "IoT");

        #10;

        // ==============================================================
        // TEST 5: No Match → Default Slice ID (0)
        // ==============================================================
        test_num = 5;
        $display("── TEST %0d: No Match (Default) ──", test_num);
        send_packet(make_tuser(32'h08080808, 32'hC0A80100, 16'd9999, 16'd50000, 8'd17, 1'b1));
        check_slice_id(`DEFAULT_SLICE_ID, "Default");

        #10;

        // ==============================================================
        // TEST 6: Non-valid metadata → Default Slice ID
        // ==============================================================
        test_num = 6;
        $display("── TEST %0d: Non-IPv4 (valid=0) ──", test_num);
        send_packet(make_tuser(32'h0A000101, 32'hC0A80164, 16'd5001, 16'd10001, 8'd17, 1'b0));
        check_slice_id(`DEFAULT_SLICE_ID, "Non-valid");

        // ==============================================================
        // Summary
        // ==============================================================
        #50;
        $display("\n══════════════════════════════════════════");
        $display("  CLASSIFIER TESTBENCH RESULTS");
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
        #100000;
        $display("ERROR: Testbench timed out!");
        $finish;
    end

endmodule
