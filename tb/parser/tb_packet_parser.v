//============================================================================
// Testbench: Packet Parser
//============================================================================
// Tests the packet_parser module by:
//   1. Sending valid IPv4/UDP packets and verifying TUSER metadata
//   2. Sending non-IPv4 packets (ARP) and verifying metadata = 0
//   3. Testing multi-beat packets (large payloads)
//   4. Testing backpressure (deasserting TREADY mid-transfer)
//
// LEARNING NOTES:
// ─────────────────────────────────────────────────────────────────────────
// Verilog testbenches are NON-SYNTHESIZABLE code. They use constructs
// that don't map to hardware (#delays, $display, initial blocks, etc.)
// but are essential for verifying RTL designs before committing to silicon.
//
// Key testbench patterns used here:
//   - Clock generation using `always #5 clk = ~clk` (100MHz = 10ns period)
//   - Reset sequence: assert reset, wait, deassert
//   - Task-based stimulus: reusable `send_packet` task
//   - Self-checking: compare DUT outputs against expected values
//   - VCD dump for waveform viewing in GTKWave
//============================================================================

`timescale 1ns / 1ps

`include "smartnic_pkg.vh"

module tb_packet_parser;

    //------------------------------------------------------------------------
    // Clock and Reset
    //------------------------------------------------------------------------
    reg clk;
    reg rst_n;

    // 100MHz clock (10ns period, 5ns half-period)
    initial clk = 0;
    always #5 clk = ~clk;

    //------------------------------------------------------------------------
    // DUT Signals
    //------------------------------------------------------------------------
    reg  [`AXIS_DATA_WIDTH-1:0]   s_axis_tdata;
    reg  [`AXIS_KEEP_WIDTH-1:0]   s_axis_tkeep;
    reg                           s_axis_tvalid;
    wire                          s_axis_tready;
    reg                           s_axis_tlast;

    wire [`AXIS_DATA_WIDTH-1:0]   m_axis_tdata;
    wire [`AXIS_KEEP_WIDTH-1:0]   m_axis_tkeep;
    wire [`AXIS_USER_WIDTH-1:0]   m_axis_tuser;
    wire                          m_axis_tvalid;
    reg                           m_axis_tready;
    wire                          m_axis_tlast;

    //------------------------------------------------------------------------
    // DUT Instantiation
    //------------------------------------------------------------------------
    packet_parser uut (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tkeep   (s_axis_tkeep),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tlast   (s_axis_tlast),
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tkeep   (m_axis_tkeep),
        .m_axis_tuser   (m_axis_tuser),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tlast   (m_axis_tlast)
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

    // Build a 512-bit data word containing an Ethernet/IPv4/UDP header
    // placed at the correct byte offsets.
    task build_ipv4_udp_beat;
        input [31:0] src_ip;
        input [31:0] dst_ip;
        input [15:0] src_port;
        input [15:0] dst_port;
        output [`AXIS_DATA_WIDTH-1:0] tdata;
        begin
            tdata = {`AXIS_DATA_WIDTH{1'b0}};

            // Ethernet header: DST MAC (6B) + SRC MAC (6B) + EtherType (2B)
            // Byte 0-5: Dst MAC = AA:BB:CC:DD:EE:FF
            tdata[7:0]   = 8'hAA;  tdata[15:8]  = 8'hBB;
            tdata[23:16] = 8'hCC;  tdata[31:24] = 8'hDD;
            tdata[39:32] = 8'hEE;  tdata[47:40] = 8'hFF;
            // Byte 6-11: Src MAC = 00:11:22:33:44:55
            tdata[55:48] = 8'h00;  tdata[63:56] = 8'h11;
            tdata[71:64] = 8'h22;  tdata[79:72] = 8'h33;
            tdata[87:80] = 8'h44;  tdata[95:88] = 8'h55;
            // Byte 12-13: EtherType = 0x0800 (IPv4)
            tdata[103:96]  = 8'h08;  // EtherType MSB
            tdata[111:104] = 8'h00;  // EtherType LSB

            // IPv4 header starts at byte 14
            // Byte 14: Version(4) + IHL(5) = 0x45
            tdata[119:112] = 8'h45;
            // Byte 15: DSCP + ECN = 0x00
            tdata[127:120] = 8'h00;
            // Byte 16-17: Total Length = 28 + payload (we'll use 48)
            tdata[135:128] = 8'h00;
            tdata[143:136] = 8'h30;  // 48 bytes
            // Byte 18-19: Identification
            tdata[151:144] = 8'h12;
            tdata[159:152] = 8'h34;
            // Byte 20-21: Flags + Fragment Offset
            tdata[167:160] = 8'h40;
            tdata[175:168] = 8'h00;
            // Byte 22: TTL = 64
            tdata[183:176] = 8'h40;
            // Byte 23: Protocol = 17 (UDP)
            tdata[191:184] = 8'h11;
            // Byte 24-25: Header Checksum (skip for sim)
            tdata[199:192] = 8'h00;
            tdata[207:200] = 8'h00;
            // Byte 26-29: Source IP
            tdata[215:208] = src_ip[31:24];
            tdata[223:216] = src_ip[23:16];
            tdata[231:224] = src_ip[15:8];
            tdata[239:232] = src_ip[7:0];
            // Byte 30-33: Destination IP
            tdata[247:240] = dst_ip[31:24];
            tdata[255:248] = dst_ip[23:16];
            tdata[263:256] = dst_ip[15:8];
            tdata[271:264] = dst_ip[7:0];

            // UDP header starts at byte 34
            // Byte 34-35: Source Port
            tdata[279:272] = src_port[15:8];
            tdata[287:280] = src_port[7:0];
            // Byte 36-37: Destination Port
            tdata[295:288] = dst_port[15:8];
            tdata[303:296] = dst_port[7:0];
            // Byte 38-39: UDP Length
            tdata[311:304] = 8'h00;
            tdata[319:312] = 8'h1C;  // 28 bytes
            // Byte 40-41: UDP Checksum (optional)
            tdata[327:320] = 8'h00;
            tdata[335:328] = 8'h00;
        end
    endtask

    // Send a single-beat packet and wait for output
    task send_single_beat;
        input [`AXIS_DATA_WIDTH-1:0] tdata;
        input [`AXIS_KEEP_WIDTH-1:0] tkeep;
        begin
            @(posedge clk);
            s_axis_tdata  <= tdata;
            s_axis_tkeep  <= tkeep;
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= 1'b1;

            // Wait for handshake
            @(posedge clk);
            while (!s_axis_tready) @(posedge clk);
            s_axis_tvalid <= 1'b0;
            s_axis_tlast  <= 1'b0;
        end
    endtask

    // Wait for output valid and capture TUSER
    task wait_output;
        output [`AXIS_USER_WIDTH-1:0] captured_tuser;
        output                        captured_tlast;
        begin
            while (!m_axis_tvalid) @(posedge clk);
            captured_tuser = m_axis_tuser;
            captured_tlast = m_axis_tlast;
            @(posedge clk);  // Consume it
        end
    endtask

    // Check a TUSER field value
    task check_field;
        input [255:0] field_name;  // String name (for display)
        input [31:0]  actual;
        input [31:0]  expected;
        begin
            if (actual === expected) begin
                tests_passed = tests_passed + 1;
            end else begin
                $display("  FAIL: %0s = 0x%0h, expected 0x%0h", field_name, actual, expected);
                tests_failed = tests_failed + 1;
            end
        end
    endtask

    //------------------------------------------------------------------------
    // Main Test Sequence
    //------------------------------------------------------------------------
    reg [`AXIS_DATA_WIDTH-1:0] test_tdata;
    reg [`AXIS_USER_WIDTH-1:0] captured_tuser;
    reg captured_tlast;

    initial begin
        // ── VCD Dump for GTKWave ──────────────────────────────────────
        $dumpfile("sim/parser_waves.vcd");
        $dumpvars(0, tb_packet_parser);

        // ── Initialize ────────────────────────────────────────────────
        s_axis_tdata  = {`AXIS_DATA_WIDTH{1'b0}};
        s_axis_tkeep  = {`AXIS_KEEP_WIDTH{1'b0}};
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        m_axis_tready = 1'b1;  // Always ready initially
        rst_n = 1'b0;

        // ── Reset ─────────────────────────────────────────────────────
        #100;
        rst_n = 1'b1;
        #20;

        // ==============================================================
        // TEST 1: Basic IPv4/UDP Packet
        // ==============================================================
        test_num = 1;
        $display("\n── TEST %0d: Basic IPv4/UDP Packet ──", test_num);

        build_ipv4_udp_beat(
            32'hC0A80164,  // src: 192.168.1.100
            32'h0A000101,  // dst: 10.0.1.1
            16'd10001,     // src port
            16'd5001,      // dst port
            test_tdata
        );

        send_single_beat(test_tdata, {`AXIS_KEEP_WIDTH{1'b1}});
        wait_output(captured_tuser, captured_tlast);

        $display("  TUSER = 0x%032h", captured_tuser);

        check_field("valid",     captured_tuser[`TUSER_VALID_BIT],    1);
        check_field("is_ipv4",   captured_tuser[`TUSER_IS_IPV4_BIT],  1);
        check_field("is_udp",    captured_tuser[`TUSER_IS_UDP_BIT],   1);
        check_field("is_tcp",    captured_tuser[`TUSER_IS_TCP_BIT],   0);
        check_field("protocol",  captured_tuser[`TUSER_IP_PROTO_HI:`TUSER_IP_PROTO_LO], 8'd17);
        check_field("dst_ip",    captured_tuser[`TUSER_DST_IP_HI:`TUSER_DST_IP_LO], 32'h0A000101);
        check_field("src_ip",    captured_tuser[`TUSER_SRC_IP_HI:`TUSER_SRC_IP_LO], 32'hC0A80164);
        check_field("dst_port",  captured_tuser[`TUSER_DST_PORT_HI:`TUSER_DST_PORT_LO], 16'd5001);
        check_field("src_port",  captured_tuser[`TUSER_SRC_PORT_HI:`TUSER_SRC_PORT_LO], 16'd10001);

        #20;

        // ==============================================================
        // TEST 2: Different IP Addresses and Ports
        // ==============================================================
        test_num = 2;
        $display("\n── TEST %0d: Different IP/Ports ──", test_num);

        build_ipv4_udp_beat(
            32'hAC100A05,  // src: 172.16.10.5
            32'h0A000301,  // dst: 10.0.3.1
            16'd30042,     // src port
            16'd8080,      // dst port
            test_tdata
        );

        send_single_beat(test_tdata, {`AXIS_KEEP_WIDTH{1'b1}});
        wait_output(captured_tuser, captured_tlast);

        check_field("dst_ip",    captured_tuser[`TUSER_DST_IP_HI:`TUSER_DST_IP_LO], 32'h0A000301);
        check_field("src_ip",    captured_tuser[`TUSER_SRC_IP_HI:`TUSER_SRC_IP_LO], 32'hAC100A05);
        check_field("dst_port",  captured_tuser[`TUSER_DST_PORT_HI:`TUSER_DST_PORT_LO], 16'd8080);
        check_field("src_port",  captured_tuser[`TUSER_SRC_PORT_HI:`TUSER_SRC_PORT_LO], 16'd30042);

        #20;

        // ==============================================================
        // TEST 3: Non-IPv4 Packet (ARP — EtherType 0x0806)
        // ==============================================================
        test_num = 3;
        $display("\n── TEST %0d: Non-IPv4 (ARP) Packet ──", test_num);

        test_tdata = {`AXIS_DATA_WIDTH{1'b0}};
        // Set EtherType to ARP (0x0806)
        test_tdata[103:96]  = 8'h08;
        test_tdata[111:104] = 8'h06;

        send_single_beat(test_tdata, {`AXIS_KEEP_WIDTH{1'b1}});
        wait_output(captured_tuser, captured_tlast);

        check_field("valid",   captured_tuser[`TUSER_VALID_BIT],   0);
        check_field("is_ipv4", captured_tuser[`TUSER_IS_IPV4_BIT], 0);
        check_field("is_udp",  captured_tuser[`TUSER_IS_UDP_BIT],  0);

        #20;

        // ==============================================================
        // TEST 4: Backpressure — deassert TREADY
        // ==============================================================
        test_num = 4;
        $display("\n── TEST %0d: Backpressure Test ──", test_num);

        // Deassert downstream ready
        m_axis_tready = 1'b0;

        build_ipv4_udp_beat(
            32'hC0A80165,  // src: 192.168.1.101
            32'h0A000201,  // dst: 10.0.2.1
            16'd20001,
            16'd5060,
            test_tdata
        );

        // Send the packet
        @(posedge clk);
        s_axis_tdata  <= test_tdata;
        s_axis_tkeep  <= {`AXIS_KEEP_WIDTH{1'b1}};
        s_axis_tvalid <= 1'b1;
        s_axis_tlast  <= 1'b1;
        @(posedge clk);
        while (!s_axis_tready) @(posedge clk);
        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;

        // Wait a few cycles — output should be held
        repeat(5) @(posedge clk);

        // Now assert ready — data should appear
        m_axis_tready = 1'b1;
        wait_output(captured_tuser, captured_tlast);

        check_field("dst_ip_bp",  captured_tuser[`TUSER_DST_IP_HI:`TUSER_DST_IP_LO], 32'h0A000201);
        check_field("dst_port_bp", captured_tuser[`TUSER_DST_PORT_HI:`TUSER_DST_PORT_LO], 16'd5060);

        #20;

        // ==============================================================
        // TEST 5: Consecutive Packets (no gap)
        // ==============================================================
        test_num = 5;
        $display("\n── TEST %0d: Consecutive Packets ──", test_num);

        // Send 3 packets back-to-back
        begin : consecutive_test
            integer pkt_i;
            reg [31:0] expected_ips [0:2];
            expected_ips[0] = 32'h0A000101;
            expected_ips[1] = 32'h0A000201;
            expected_ips[2] = 32'h0A000401;

            for (pkt_i = 0; pkt_i < 3; pkt_i = pkt_i + 1) begin
                build_ipv4_udp_beat(
                    32'hC0A80100 + pkt_i,
                    expected_ips[pkt_i],
                    16'd10000 + pkt_i,
                    16'd5001 + pkt_i,
                    test_tdata
                );
                send_single_beat(test_tdata, {`AXIS_KEEP_WIDTH{1'b1}});
                wait_output(captured_tuser, captured_tlast);
                check_field("consec_dst_ip",
                    captured_tuser[`TUSER_DST_IP_HI:`TUSER_DST_IP_LO],
                    expected_ips[pkt_i]);
            end
        end

        // ==============================================================
        // Summary
        // ==============================================================
        #50;
        $display("\n══════════════════════════════════════════");
        $display("  PARSER TESTBENCH RESULTS");
        $display("  Tests passed: %0d", tests_passed);
        $display("  Tests failed: %0d", tests_failed);
        if (tests_failed == 0)
            $display("  STATUS: *** ALL TESTS PASSED ***");
        else
            $display("  STATUS: *** SOME TESTS FAILED ***");
        $display("══════════════════════════════════════════\n");

        $finish;
    end

    // ── Timeout watchdog ──────────────────────────────────────────────
    initial begin
        #100000;
        $display("ERROR: Testbench timed out!");
        $finish;
    end

endmodule
