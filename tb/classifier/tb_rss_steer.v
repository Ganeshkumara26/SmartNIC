//============================================================================
// Testbench: RSS Steer Engine
//============================================================================

`timescale 1ns / 1ps
`include "smartnic_pkg.vh"

module tb_rss_steer;

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

    reg                             cfg_reta_wr_en;
    reg [6:0]                       cfg_reta_idx;
    reg [`TUSER_SLICE_ID_WIDTH-1:0] cfg_reta_val;

    //------------------------------------------------------------------------
    // Instantiate DUT
    //------------------------------------------------------------------------
    rss_steer dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .s_axis_tdata    (s_axis_tdata),
        .s_axis_tkeep    (s_axis_tkeep),
        .s_axis_tuser    (s_axis_tuser),
        .s_axis_tvalid   (s_axis_tvalid),
        .s_axis_tready   (s_axis_tready),
        .s_axis_tlast    (s_axis_tlast),
        .m_axis_tdata    (m_axis_tdata),
        .m_axis_tkeep    (m_axis_tkeep),
        .m_axis_tuser    (m_axis_tuser),
        .m_axis_tvalid   (m_axis_tvalid),
        .m_axis_tready   (m_axis_tready),
        .m_axis_tlast    (m_axis_tlast),
        .cfg_reta_wr_en  (cfg_reta_wr_en),
        .cfg_reta_idx    (cfg_reta_idx),
        .cfg_reta_val    (cfg_reta_val)
    );

    //------------------------------------------------------------------------
    // Test Procedure
    //------------------------------------------------------------------------
    initial begin
        // Initialize
        rst_n = 0;
        s_axis_tdata = 0;
        s_axis_tkeep = 0;
        s_axis_tuser = 0;
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
        m_axis_tready = 1;
        cfg_reta_wr_en = 0;
        cfg_reta_idx = 0;
        cfg_reta_val = 0;

        #20;
        rst_n = 1;
        #20;

        //--------------------------------------------------------------------
        // Step 1: Program RETA via AXI-Lite simulation
        //--------------------------------------------------------------------
        $display("Programming RETA Table...");
        @(negedge clk);
        cfg_reta_wr_en = 1;
        cfg_reta_idx = 7'd42;
        cfg_reta_val = 4'd3; // We expect hash ending in 42 to go to Queue 3
        @(negedge clk);
        cfg_reta_wr_en = 0;
        #20;

        //--------------------------------------------------------------------
        // Test 1: RSS-Eligible Packet (eMBB)
        //--------------------------------------------------------------------
        $display("Sending RSS-Eligible Packet (Hash=42)...");
        @(negedge clk);
        s_axis_tvalid = 1;
        s_axis_tlast = 1;
        s_axis_tuser[`TUSER_RSS_ELIGIBLE_BIT] = 1'b1;
        s_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO] = 4'd1; // Original from classifier
        s_axis_tuser[`TUSER_RSS_HASH_HI:`TUSER_RSS_HASH_LO] = 32'd42; // LSBs = 42
        
        @(posedge clk);
        while (!s_axis_tready) @(posedge clk);
        #1 s_axis_tvalid = 0;

        while (!m_axis_tvalid) @(posedge clk);
        
        $display("Expected Slice ID: 3, Got: %0d", m_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO]);
        if (m_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO] !== 4'd3) begin
            $display("ERROR: RSS Steer failed!");
            $finish;
        end

        //--------------------------------------------------------------------
        // Test 2: Non-RSS-Eligible Packet (URLLC)
        //--------------------------------------------------------------------
        #20;
        $display("Sending Non-Eligible Packet (URLLC, Queue 0)...");
        @(negedge clk);
        s_axis_tvalid = 1;
        s_axis_tlast = 1;
        s_axis_tuser[`TUSER_RSS_ELIGIBLE_BIT] = 1'b0; // NOT eligible
        s_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO] = 4'd0; // URLLC
        s_axis_tuser[`TUSER_RSS_HASH_HI:`TUSER_RSS_HASH_LO] = 32'd42; // Should be ignored
        
        @(posedge clk);
        while (!s_axis_tready) @(posedge clk);
        #1 s_axis_tvalid = 0;

        while (!m_axis_tvalid) @(posedge clk);
        
        $display("Expected Slice ID: 0, Got: %0d", m_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO]);
        if (m_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO] !== 4'd0) begin
            $display("ERROR: URLLC packet was incorrectly steered!");
            $finish;
        end

        //--------------------------------------------------------------------
        // Test 3: Multi-beat Packet Test
        //--------------------------------------------------------------------
        #20;
        $display("Sending Multi-beat RSS-Eligible Packet...");
        @(negedge clk);
        // Beat 1
        s_axis_tvalid = 1;
        s_axis_tlast = 0;
        s_axis_tuser[`TUSER_RSS_ELIGIBLE_BIT] = 1'b1;
        s_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO] = 4'd1;
        s_axis_tuser[`TUSER_RSS_HASH_HI:`TUSER_RSS_HASH_LO] = 32'd42;
        
        @(posedge clk);
        while (!s_axis_tready) @(posedge clk);
        
        // Beat 2
        #1;
        s_axis_tuser = 0; // TUSER drops, but steer engine should remember Slice ID 3
        s_axis_tlast = 1;
        
        @(posedge clk);
        while (!s_axis_tready) @(posedge clk);
        #1 s_axis_tvalid = 0;

        // Check outputs
        while (!m_axis_tvalid) @(posedge clk);
        if (m_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO] !== 4'd3) begin
            $display("ERROR: Beat 1 failed!");
            $finish;
        end
        @(posedge clk); // Move to Beat 2
        if (m_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO] !== 4'd3) begin
            $display("ERROR: Beat 2 failed! Did not remember steered Slice ID.");
            $finish;
        end

        #50;
        $display("ALL TESTS PASSED.");
        $finish;
    end

endmodule
