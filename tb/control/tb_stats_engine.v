//============================================================================
// Testbench: Statistics Engine & AXI-Lite Read Path
//============================================================================

`timescale 1ns / 1ps

module tb_stats_engine;

    //------------------------------------------------------------------------
    // Clock and Reset
    //------------------------------------------------------------------------
    reg clk;
    reg rst_n;
    initial clk = 0;
    always #5 clk = ~clk;

    //------------------------------------------------------------------------
    // Wires and Regs
    //------------------------------------------------------------------------
    // Datapath Events
    reg         event_rx_pkt;
    reg [15:0]  event_rx_bytes;
    reg         event_tx_pkt;
    reg [3:0]   event_enq_pkt;
    reg [3:0]   event_drop_pkt;
    reg [3:0]   event_deq_pkt;

    // AXI-Lite Interface
    reg  [31:0] s_axi_araddr;
    reg         s_axi_arvalid;
    wire        s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready;

    // CSR to Stats Engine Interface
    wire        stat_rd_en;
    wire [7:0]  stat_rd_addr;
    wire [31:0] stat_rd_data;

    //------------------------------------------------------------------------
    // DUT: Statistics Engine
    //------------------------------------------------------------------------
    stats_engine dut_stats (
        .clk             (clk),
        .rst_n           (rst_n),
        .event_rx_pkt    (event_rx_pkt),
        .event_rx_bytes  (event_rx_bytes),
        .event_tx_pkt    (event_tx_pkt),
        .event_enq_pkt   (event_enq_pkt),
        .event_drop_pkt  (event_drop_pkt),
        .event_deq_pkt   (event_deq_pkt),
        .stat_rd_en      (stat_rd_en),
        .stat_rd_addr    (stat_rd_addr),
        .stat_rd_data    (stat_rd_data)
    );

    //------------------------------------------------------------------------
    // DUT: AXI-Lite CSR (Read Path Only for this test)
    //------------------------------------------------------------------------
    axilite_csr dut_csr (
        .clk             (clk),
        .rst_n           (rst_n),
        
        // Write channels tied off
        .s_axi_awaddr    (32'd0),
        .s_axi_awvalid   (1'b0),
        .s_axi_wdata     (32'd0),
        .s_axi_wstrb     (4'd0),
        .s_axi_wvalid    (1'b0),
        .s_axi_bready    (1'b1),

        // Read channels
        .s_axi_araddr    (s_axi_araddr),
        .s_axi_arvalid   (s_axi_arvalid),
        .s_axi_arready   (s_axi_arready),
        .s_axi_rdata     (s_axi_rdata),
        .s_axi_rresp     (s_axi_rresp),
        .s_axi_rvalid    (s_axi_rvalid),
        .s_axi_rready    (s_axi_rready),

        // To Stats Engine
        .stat_rd_en      (stat_rd_en),
        .stat_rd_addr    (stat_rd_addr),
        .stat_rd_data    (stat_rd_data)
    );

    //------------------------------------------------------------------------
    // Test Procedure
    //------------------------------------------------------------------------
    
    // Helper task to read an AXI-Lite register
    task read_csr;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(negedge clk);
            s_axi_araddr = addr;
            s_axi_arvalid = 1;
            s_axi_rready = 1;

            @(posedge clk);
            while (!s_axi_arready) @(posedge clk);
            #1 s_axi_arvalid = 0;

            while (!s_axi_rvalid) @(posedge clk);
            data = s_axi_rdata;
            #1 s_axi_rready = 0;
        end
    endtask

    reg [31:0] read_val;

    initial begin
        // Initialize
        rst_n = 0;
        event_rx_pkt = 0;
        event_rx_bytes = 0;
        event_tx_pkt = 0;
        event_enq_pkt = 0;
        event_drop_pkt = 0;
        event_deq_pkt = 0;

        s_axi_araddr = 0;
        s_axi_arvalid = 0;
        s_axi_rready = 0;

        #20;
        rst_n = 1;
        #20;

        //--------------------------------------------------------------------
        // Step 1: Simulate Traffic Events
        //--------------------------------------------------------------------
        $display("Simulating datapath events...");
        
        // Fire 5 Rx Packets of 100 bytes each
        repeat (5) begin
            @(negedge clk);
            event_rx_pkt = 1;
            event_rx_bytes = 100;
            // Also say they were enqueued into Queue 2 (eMBB)
            event_enq_pkt = 4'b0100;
            @(negedge clk);
            event_rx_pkt = 0;
            event_rx_bytes = 0;
            event_enq_pkt = 0;
            #10;
        end

        // Drop 2 packets in Queue 0 (URLLC overflow)
        repeat (2) begin
            @(negedge clk);
            event_drop_pkt = 4'b0001;
            @(negedge clk);
            event_drop_pkt = 0;
            #10;
        end

        // Dequeue 3 packets from Queue 2
        repeat (3) begin
            @(negedge clk);
            event_deq_pkt = 4'b0100;
            event_tx_pkt  = 1;
            @(negedge clk);
            event_deq_pkt = 0;
            event_tx_pkt  = 0;
            #10;
        end

        //--------------------------------------------------------------------
        // Step 2: Read Counters via AXI-Lite
        //--------------------------------------------------------------------
        $display("Reading Counters over AXI-Lite...");
        
        // 1. Read Rx Total Packets (Offset 0x300 for Low Word)
        read_csr(32'h4000_0300, read_val);
        $display("Rx Packets: %0d", read_val);
        if (read_val !== 5) $display("ERROR!");

        // 2. Read Rx Total Bytes (Offset 0x308 for Low Word)
        read_csr(32'h4000_0308, read_val);
        $display("Rx Bytes: %0d", read_val);
        if (read_val !== 500) $display("ERROR!");

        // 3. Read Queue 2 Enqueued Packets (Offset 0x314: Base 0x310 + 4 for Queue 1? Wait!)
        // Let's check axilite_csr / stats_engine mapping:
        // 0x10 is Q0_Low, 0x12 is Q1_Low, 0x14 is Q2_Low.
        // Wait: 8'h10 = 16. In axilite_csr, stat_rd_addr is addr[9:2].
        // 0x300 -> 0xC0.
        // 0x310 is 0x310 >> 2 = 0xC4. 0xC4 - 0xC0 = 4. 
        // Wait! In stats_engine, I mapped Tx Pkts to 4. 
        // Let's manually trigger reads to exactly the addresses.
        // Q2 Enq Low is 0x14 relative. So 0xC0 + 0x14 = 0xD4. 0xD4 << 2 = 0x350.
        read_csr(32'h4000_0350, read_val);
        $display("Queue 2 Enqueued: %0d", read_val);
        if (read_val !== 5) $display("ERROR!");

        // 4. Read Queue 0 Dropped Packets
        // Q0 Drop Low is 0x18 relative. 0xC0 + 0x18 = 0xD8. 0xD8 << 2 = 0x360.
        read_csr(32'h4000_0360, read_val);
        $display("Queue 0 Dropped: %0d", read_val);
        if (read_val !== 2) $display("ERROR!");

        // 5. Read Queue 2 Dequeued Packets
        // Q2 Deq Low is 0x24 relative. 0xC0 + 0x24 = 0xE4. 0xE4 << 2 = 0x390.
        read_csr(32'h4000_0390, read_val);
        $display("Queue 2 Dequeued: %0d", read_val);
        if (read_val !== 3) $display("ERROR!");

        $display("ALL TESTS PASSED.");
        $finish;
    end

endmodule
