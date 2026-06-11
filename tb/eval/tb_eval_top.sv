//============================================================================
// Performance Evaluation Framework: Traffic Generator
//============================================================================
// Top-level SystemVerilog testbench. 
// Instantiates the full SmartNIC datapath and injects statistically modeled
// 5G traffic profiles (URLLC, eMBB, IoT).
// Dumps 64-bit hardware counters to a CSV file for Python visualization.
//============================================================================

`timescale 1ns / 1ps
`include "smartnic_pkg.vh"

module tb_eval_top;

    //------------------------------------------------------------------------
    // Clock and Reset
    //------------------------------------------------------------------------
    reg clk;
    reg rst_n;
    initial clk = 0;
    always #2 clk = ~clk; // 250MHz (4ns period)

    //------------------------------------------------------------------------
    // Interfaces to SmartNIC
    //------------------------------------------------------------------------
    // AXI-Lite
    reg  [31:0] s_axi_awaddr;
    reg         s_axi_awvalid;
    wire        s_axi_awready;
    reg  [31:0] s_axi_wdata;
    reg  [3:0]  s_axi_wstrb;
    reg         s_axi_wvalid;
    wire        s_axi_wready;
    wire [1:0]  s_axi_bresp;
    wire        s_axi_bvalid;
    reg         s_axi_bready;
    
    reg  [31:0] s_axi_araddr;
    reg         s_axi_arvalid;
    wire        s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready;

    // H2C (Host to Card) AXI-Stream - Used for injection
    reg  [`AXIS_DATA_WIDTH-1:0] s_axis_qdma_h2c_tdata;
    reg  [`AXIS_KEEP_WIDTH-1:0] s_axis_qdma_h2c_tkeep;
    reg                         s_axis_qdma_h2c_tvalid;
    wire                        s_axis_qdma_h2c_tready;
    reg                         s_axis_qdma_h2c_tlast;
    reg  [15:0]                 s_axis_qdma_h2c_tuser_mdata;
    reg  [10:0]                 s_axis_qdma_h2c_tuser_qid;
    reg  [2:0]                  s_axis_qdma_h2c_tuser_port_id;

    // C2H (Card to Host) AXI-Stream - Used for extraction/sink
    wire [`AXIS_DATA_WIDTH-1:0] m_axis_qdma_c2h_tdata;
    wire [`AXIS_KEEP_WIDTH-1:0] m_axis_qdma_c2h_tkeep;
    wire                        m_axis_qdma_c2h_tvalid;
    reg                         m_axis_qdma_c2h_tready;
    wire                        m_axis_qdma_c2h_tlast;

    // Network Interfaces (Tied off for this evaluation)
    reg  [`AXIS_DATA_WIDTH-1:0] s_axis_net_rx_tdata = 0;
    reg  [`AXIS_KEEP_WIDTH-1:0] s_axis_net_rx_tkeep = 0;
    reg                         s_axis_net_rx_tvalid = 0;
    reg                         s_axis_net_rx_tlast = 0;
    wire [`AXIS_DATA_WIDTH-1:0] m_axis_net_tx_tdata;
    wire [`AXIS_KEEP_WIDTH-1:0] m_axis_net_tx_tkeep;
    wire                        m_axis_net_tx_tvalid;
    reg                         m_axis_net_tx_tready = 1;
    wire                        m_axis_net_tx_tlast;

    //------------------------------------------------------------------------
    // DUT: SmartNIC Top
    //------------------------------------------------------------------------
    smartnic_top dut (
        .clk(clk),
        .rst_n(rst_n),
        
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        
        .s_axis_net_rx_tdata(s_axis_net_rx_tdata), .s_axis_net_rx_tkeep(s_axis_net_rx_tkeep), .s_axis_net_rx_tvalid(s_axis_net_rx_tvalid), .s_axis_net_rx_tlast(s_axis_net_rx_tlast),
        .m_axis_net_tx_tdata(m_axis_net_tx_tdata), .m_axis_net_tx_tkeep(m_axis_net_tx_tkeep), .m_axis_net_tx_tvalid(m_axis_net_tx_tvalid), .m_axis_net_tx_tready(m_axis_net_tx_tready), .m_axis_net_tx_tlast(m_axis_net_tx_tlast),
        
        .s_axis_qdma_h2c_tdata(s_axis_qdma_h2c_tdata), .s_axis_qdma_h2c_tkeep(s_axis_qdma_h2c_tkeep), .s_axis_qdma_h2c_tvalid(s_axis_qdma_h2c_tvalid), .s_axis_qdma_h2c_tready(s_axis_qdma_h2c_tready), .s_axis_qdma_h2c_tlast(s_axis_qdma_h2c_tlast),
        .s_axis_qdma_h2c_tuser_mdata(s_axis_qdma_h2c_tuser_mdata), .s_axis_qdma_h2c_tuser_qid(s_axis_qdma_h2c_tuser_qid), .s_axis_qdma_h2c_tuser_port_id(s_axis_qdma_h2c_tuser_port_id),
        
        .m_axis_qdma_c2h_tdata(m_axis_qdma_c2h_tdata), .m_axis_qdma_c2h_tkeep(m_axis_qdma_c2h_tkeep), .m_axis_qdma_c2h_tvalid(m_axis_qdma_c2h_tvalid), .m_axis_qdma_c2h_tready(m_axis_qdma_c2h_tready), .m_axis_qdma_c2h_tlast(m_axis_qdma_c2h_tlast)
    );

    // Sink Egress Traffic
    initial m_axis_qdma_c2h_tready = 1;

    //------------------------------------------------------------------------
    // Latency Extraction Monitor
    //------------------------------------------------------------------------
    integer lat_fd;
    reg is_first_c2h_beat;
    
    initial begin
        lat_fd = $fopen("latency_log.csv", "w");
        $fwrite(lat_fd, "slice_id,latency_ns\n");
        is_first_c2h_beat = 1;
    end

    always @(posedge clk) begin
        if (rst_n && m_axis_qdma_c2h_tvalid && m_axis_qdma_c2h_tready) begin
            if (is_first_c2h_beat) begin
                longint inj_time;
                longint lat;
                integer slice_id;
                reg [15:0] egress_port;
                
                inj_time = m_axis_qdma_c2h_tdata[511:448];
                lat = $time - inj_time;
                
                // Read dst_port from bytes 36-37 (same layout as injection)
                egress_port = {m_axis_qdma_c2h_tdata[295:288], m_axis_qdma_c2h_tdata[303:296]};
                
                if (egress_port == 16'd8000) slice_id = 0; // URLLC
                else if (egress_port == 16'd8001) slice_id = 1; // eMBB
                else slice_id = 3; // IoT

                $fwrite(lat_fd, "%0d,%0d\n", slice_id, lat);
                $fflush(lat_fd);
            end
            
            if (m_axis_qdma_c2h_tlast)
                is_first_c2h_beat <= 1;
            else
                is_first_c2h_beat <= 0;
        end
    end

    //------------------------------------------------------------------------
    // Time-Series Logger (Throughput / Policing)
    //------------------------------------------------------------------------
    integer ts_fd;
    initial begin
        ts_fd = $fopen("timeseries_log.csv", "w");
        $fwrite(ts_fd, "time_ns,q0_deq,q1_deq,q2_deq,q3_deq\n");
        
        // Wait for reset and configuration to complete
        #200000;
        
        while (1) begin
            #10000; // Sample every 10us
            $fwrite(ts_fd, "%0d,%0d,%0d,%0d,%0d\n", 
                    $time, 
                    dut.u_stats.cnt_deq_pkts[0],
                    dut.u_stats.cnt_deq_pkts[1],
                    dut.u_stats.cnt_deq_pkts[2],
                    dut.u_stats.cnt_deq_pkts[3]);
            $fflush(ts_fd);
        end
    end

    //------------------------------------------------------------------------
    // AXI-Lite Driver Tasks
    //------------------------------------------------------------------------
    task axi_write(input [31:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            #1; // Output delay
            s_axi_awaddr  = addr;
            s_axi_awvalid = 1;
            s_axi_wdata   = data;
            s_axi_wstrb   = 4'hF;
            s_axi_wvalid  = 1;
            s_axi_bready  = 1;
            
            // Wait for address and data to be accepted
            do begin
                @(posedge clk);
            end while (!(s_axi_awready && s_axi_wready && s_axi_awvalid && s_axi_wvalid));
            
            #1;
            s_axi_awvalid = 0;
            s_axi_wvalid  = 0;
            
            // Wait for response
            do begin
                @(posedge clk);
            end while (!s_axi_bvalid);
            
            #1;
            s_axi_bready = 0;
        end
    endtask

    task axi_read(input [31:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            #1;
            s_axi_araddr  = addr;
            s_axi_arvalid = 1;
            s_axi_rready  = 1;
            
            do begin
                @(posedge clk);
            end while (!(s_axi_arready && s_axi_arvalid));
            
            #1;
            s_axi_arvalid = 0;
            
            do begin
                @(posedge clk);
            end while (!s_axi_rvalid);
            data = s_axi_rdata;
            
            #1;
            s_axi_rready = 0;
        end
    endtask

    //------------------------------------------------------------------------
    // Traffic Generation Tasks
    //------------------------------------------------------------------------
    task inject_packet(input [15:0] dst_port, input [31:0] src_ip, input integer size_bytes);
        reg [511:0] packet;
        integer bytes_remaining;
        integer is_first_beat;
        begin
            bytes_remaining = size_bytes;
            is_first_beat = 1;
            while (bytes_remaining > 0) begin
                packet = 512'd0;
                
                if (is_first_beat) begin
                    // Build a proper Ethernet / IPv4 / UDP header
                    // that the packet_parser can decode.
                    //
                    // Byte layout (AXI-Stream: byte 0 = TDATA[7:0]):
                    //   [0:5]   Dst MAC          = 00:00:00:00:00:01
                    //   [6:11]  Src MAC          = 00:00:00:00:00:02
                    //   [12:13] EtherType        = 0x0800 (IPv4)
                    //   [14]    Ver+IHL          = 0x45
                    //   [23]    Protocol         = 17 (UDP)
                    //   [26:29] Src IP
                    //   [30:33] Dst IP           = 10.0.0.1
                    //   [34:35] UDP Src Port     = 0x1234
                    //   [36:37] UDP Dst Port
                    //   [56:63] Timestamp (for latency tracking)
                    
                    // Ethernet header
                    packet[47:0]    = 48'h010000000000;       // Dst MAC
                    packet[95:48]   = 48'h020000000000;       // Src MAC
                    // EtherType 0x0800: byte 12 = 0x08, byte 13 = 0x00
                    packet[103:96]  = 8'h08;                  // Byte 12 (MSB of EtherType)
                    packet[111:104] = 8'h00;                  // Byte 13 (LSB of EtherType)
                    
                    // IPv4 header
                    packet[119:112] = 8'h45;                  // Byte 14: Version=4, IHL=5
                    // Byte 23: Protocol = UDP (17)
                    packet[191:184] = 8'd17;                  // Byte 23: IP Protocol = UDP
                    
                    // Source IP (bytes 26-29, big-endian byte order)
                    packet[215:208] = src_ip[31:24];          // Byte 26
                    packet[223:216] = src_ip[23:16];          // Byte 27
                    packet[231:224] = src_ip[15:8];           // Byte 28
                    packet[239:232] = src_ip[7:0];            // Byte 29
                    
                    // Dest IP = 10.0.0.1 (bytes 30-33)
                    packet[247:240] = 8'd10;                  // Byte 30
                    packet[255:248] = 8'd0;                   // Byte 31
                    packet[263:256] = 8'd0;                   // Byte 32
                    packet[271:264] = 8'd1;                   // Byte 33
                    
                    // UDP Src Port = 0x1234 (bytes 34-35)
                    packet[279:272] = 8'h12;                  // Byte 34 (MSB)
                    packet[287:280] = 8'h34;                  // Byte 35 (LSB)
                    
                    // UDP Dst Port (bytes 36-37)
                    packet[295:288] = dst_port[15:8];         // Byte 36 (MSB)
                    packet[303:296] = dst_port[7:0];          // Byte 37 (LSB)
                    
                    // Embed timestamp in payload area (bytes 56-63) for latency tracking
                    packet[511:448] = $time;
                    
                    is_first_beat = 0;
                end
                
                @(posedge clk);
                #1;
                s_axis_qdma_h2c_tdata  = packet;
                
                if (bytes_remaining <= 64) begin
                    s_axis_qdma_h2c_tkeep  = {64{1'b1}} >> (64 - bytes_remaining);
                    s_axis_qdma_h2c_tlast  = 1;
                    bytes_remaining = 0;
                end else begin
                    s_axis_qdma_h2c_tkeep  = {64{1'b1}};
                    s_axis_qdma_h2c_tlast  = 0;
                    bytes_remaining = bytes_remaining - 64;
                end
                
                s_axis_qdma_h2c_tvalid = 1;
                
                // Wait for the clock edge where handshake occurs
                do begin
                    @(posedge clk);
                end while (!(s_axis_qdma_h2c_tready && s_axis_qdma_h2c_tvalid));
                
                #1;
                s_axis_qdma_h2c_tvalid = 0;
                s_axis_qdma_h2c_tlast  = 0;
            end
        end
    endtask

    //------------------------------------------------------------------------
    // Main Evaluation Sequence
    //------------------------------------------------------------------------
    integer i, j;
    reg [31:0] r_data_lo, r_data_hi;
    reg [63:0] cnt_rx_pkts;
    reg [63:0] cnt_enq[3:0];
    reg [63:0] cnt_drop[3:0];
    reg [63:0] cnt_deq[3:0];
    
    // Test parameters (passed via plusargs from Python)
    integer PARAM_NUM_PKTS = 1000;
    integer PARAM_SCH_MODE = 0;     // 0=SP, 1=WRR
    integer PARAM_TB_ENABLE = 0;    // 0=Off, 1=On
    integer PARAM_RSS_ENABLE = 1;   // 0=Off, 1=On

    integer fd;

    initial begin
        $display("Simulation started"); $fflush();
        $value$plusargs("pkts=%d", PARAM_NUM_PKTS);
        $value$plusargs("mode=%d", PARAM_SCH_MODE);
        $value$plusargs("tb=%d", PARAM_TB_ENABLE);
        $value$plusargs("rss=%d", PARAM_RSS_ENABLE);
        
        // Init AXI
        s_axi_awaddr = 0; s_axi_awvalid = 0; s_axi_wdata = 0; s_axi_wstrb = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        s_axi_araddr = 0; s_axi_arvalid = 0; s_axi_rready = 0;
        s_axis_qdma_h2c_tdata = 0; s_axis_qdma_h2c_tkeep = 0; s_axis_qdma_h2c_tvalid = 0; s_axis_qdma_h2c_tlast = 0;
        rst_n = 0;
        
        #40; rst_n = 1; #40;

        // 1. Configure the SmartNIC Control Plane
        
        // Rule 0: URLLC Traffic (Dst Port 8000 -> Slice ID 0)
        axi_write(32'h4000_0010, {4'd0, 12'd0, 16'd8000}); // Dst Port 8000, Slice 0
        axi_write(32'h4000_0014, {8'd0, 8'd0, 16'hFFFF});  // Port Mask = exact match
        axi_write(32'h4000_0004, {1'b1, 15'd0, 16'd0});    // Enable, Rule 0
        axi_write(32'h4000_0000, 32'h1);                   // Commit

        // Rule 1: eMBB Traffic (Dst Port 8001 -> Slice ID 1)
        axi_write(32'h4000_0010, {4'd1, 12'd0, 16'd8001}); // Dst Port 8001, Slice 1
        axi_write(32'h4000_0014, {8'd0, 8'd0, 16'hFFFF});  // Port Mask = exact match
        axi_write(32'h4000_0004, {1'b1, 15'd0, 16'd1});    // Enable, Rule 1
        axi_write(32'h4000_0000, 32'h1);                   // Commit

        // Rule 2: IoT Traffic (Dst Port 8002 -> Slice ID 3)
        axi_write(32'h4000_0010, {4'd3, 12'd0, 16'd8002}); // Dst Port 8002, Slice 3
        axi_write(32'h4000_0014, {8'd0, 8'd0, 16'hFFFF});  // Port Mask = exact match
        axi_write(32'h4000_0004, {1'b1, 15'd0, 16'd2});    // Enable, Rule 2
        axi_write(32'h4000_0000, 32'h1);                   // Commit

        // Configure QoS Scheduler (SP or WRR)
        axi_write(32'h4000_0400, PARAM_SCH_MODE);
        // WRR Weights: Q0=50, Q1=30, Q2=20, Q3=10
        axi_write(32'h4000_0404, {16'd50, 14'd0, 2'd0});
        axi_write(32'h4000_0404, {16'd30, 14'd0, 2'd1});
        axi_write(32'h4000_0404, {16'd20, 14'd0, 2'd2});
        axi_write(32'h4000_0404, {16'd10, 14'd0, 2'd3});

        if (PARAM_TB_ENABLE == 1) begin
            // Enforce CIR limit on IoT Queue (Queue 3)
            // Clock = 250MHz. Rate of 1 = 250 MBytes/s = 2 Gbps.
            // Let's set rate to 2 = 4 Gbps.
            $display("Enabling Token Bucket on Queue 3"); $fflush();
            axi_write(32'h4000_0104, {1'b1, 27'd0, 4'd3}); // Enable=1, Priority=0, QueueID=3
            axi_write(32'h4000_0108, 32'd2);    // TB Rate
            axi_write(32'h4000_010C, 32'd2000); // TB Burst
            axi_write(32'h4000_0110, 32'd1);    // TB Enable
            axi_write(32'h4000_0100, 32'd1);    // Commit
        end

        // 2. Traffic Generation Loop
        // 2. Traffic Generation Loop
        // All packets are 64 bytes (1 AXI beat) for simulation speed.
        // Traffic type is differentiated by destination port only.
        for (i = 0; i < PARAM_NUM_PKTS; i = i + 1) begin
            // 40% URLLC (Port 8000), 40% eMBB (Port 8001), 20% IoT (Port 8002)
            integer rand_val = $urandom_range(0, 99);
            
            if (rand_val < 40) begin
                // URLLC - High priority, low latency
                inject_packet(16'd8000, 32'hC0A80100 + i, 64);
            end else if (rand_val < 80) begin
                // eMBB - High bandwidth
                if (PARAM_RSS_ENABLE == 1)
                    inject_packet(16'd8001, 32'hC0A80100 + i, 64);
                else
                    inject_packet(16'd8001, 32'hC0A80101, 64);
            end else begin
                // IoT/mMTC
                inject_packet(16'd8002, 32'hC0A80100 + i, 64);
            end
        end

        // Let pipeline drain — scheduler needs time to dequeue all packets
        #500000;

        // 3. Extract Statistics
        fd = $fopen("results.csv", "w");
        $fwrite(fd, "queue,enqueued,dropped,dequeued\n");

        // Read total Rx Packets
        axi_read(32'h4000_0300, r_data_lo);
        axi_read(32'h4000_0304, r_data_hi);
        cnt_rx_pkts = {r_data_hi, r_data_lo};
        $display("Total Rx Packets: %0d", cnt_rx_pkts);

        for (j = 0; j < 4; j = j + 1) begin
            // Enqueued (0x310 + j*8)
            axi_read(32'h4000_0300 + 16 + j*8, r_data_lo);
            axi_read(32'h4000_0300 + 20 + j*8, r_data_hi);
            cnt_enq[j] = {r_data_hi, r_data_lo};
            
            // Dropped (0x318 + j*8 -> wait, 0x18 * 4 = 0x60 -> 0x360)
            // Let's use exact offsets from axilite_csr
            // Enqueued: Q0=0x340, Q1=0x348, Q2=0x350, Q3=0x358 (Wait, 0x10 * 4 = 0x40 -> 0x340)
            // Dropped: Q0=0x360, Q1=0x368, Q2=0x370, Q3=0x378
            // Dequeued: Q0=0x380, Q1=0x388, Q2=0x390, Q3=0x398
            axi_read(32'h4000_0340 + j*8, r_data_lo);
            axi_read(32'h4000_0344 + j*8, r_data_hi);
            cnt_enq[j] = {r_data_hi, r_data_lo};

            axi_read(32'h4000_0360 + j*8, r_data_lo);
            axi_read(32'h4000_0364 + j*8, r_data_hi);
            cnt_drop[j] = {r_data_hi, r_data_lo};

            axi_read(32'h4000_0380 + j*8, r_data_lo);
            axi_read(32'h4000_0384 + j*8, r_data_hi);
            cnt_deq[j] = {r_data_hi, r_data_lo};

            $fwrite(fd, "%0d,%0d,%0d,%0d\n", j, cnt_enq[j], cnt_drop[j], cnt_deq[j]);
            $display("Q%0d | Enq: %0d | Drop: %0d | Deq: %0d", j, cnt_enq[j], cnt_drop[j], cnt_deq[j]);
        end

        $fclose(fd);
        $finish;
    end

endmodule
