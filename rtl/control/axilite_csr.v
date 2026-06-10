//============================================================================
// AXI-Lite Control and Status Register (CSR) Block
//============================================================================
// Acts as the bridge between the RISC-V Control Plane (Slow Path) and the
// high-speed hardware datapath. 
//
// Translates 32-bit Memory-Mapped I/O (MMIO) read/write requests over the 
// AXI4-Lite bus into direct, cycle-accurate wire pulses to configure the
// Flow Classifier and Priority Scheduler.
//
// MEMORY MAP:
// ─────────────────────────────────────────────────────────────────────────
// Base Address: 0x4000_0000 (Defined in SoC)
// 
// Classifier Offsets (0x000 - 0x0FF):
//   0x000: Write Trigger (Write any value to commit rule to table)
//   0x004: Rule ID (0-15) and Enable Bit [31]
//   0x008: Dst IP
//   0x00C: Dst IP Mask
//   0x010: Dst Port [15:0], Protocol [23:16], Slice ID [31:28]
//   0x014: Dst Port Mask [15:0], Protocol Mask [23:16]
//
// Scheduler Offsets (0x100 - 0x1FF):
//   0x100: Write Trigger (Write any value to commit queue config)
//   0x104: Queue ID (0-3) [3:0], Priority [5:4], Enable [31]
//   0x108: Token Bucket Rate (Tokens per tick)
//   0x10C: Token Bucket Burst (Max Tokens)
//   0x110: Token Bucket Enable [0]
//============================================================================

`timescale 1ns / 1ps
`include "smartnic_pkg.vh"

module axilite_csr (
    input  wire         clk,
    input  wire         rst_n,

    // ── AXI4-Lite Slave Interface (From RISC-V) ───────────────────────
    // Write Address Channel
    input  wire [31:0]  s_axi_awaddr,
    input  wire         s_axi_awvalid,
    output reg          s_axi_awready,
    // Write Data Channel
    input  wire [31:0]  s_axi_wdata,
    input  wire [3:0]   s_axi_wstrb,
    input  wire         s_axi_wvalid,
    output reg          s_axi_wready,
    // Write Response Channel
    output reg  [1:0]   s_axi_bresp,
    output reg          s_axi_bvalid,
    input  wire         s_axi_bready,
    // Read Address Channel
    input  wire [31:0]  s_axi_araddr,
    input  wire         s_axi_arvalid,
    output reg          s_axi_arready,
    // Read Data Channel
    output reg  [31:0]  s_axi_rdata,
    output reg  [1:0]   s_axi_rresp,
    output reg          s_axi_rvalid,
    input  wire         s_axi_rready,

    // ── Hardware Configuration Wires (To Datapath) ────────────────────
    
    // To Flow Classifier
    output reg                             fc_cfg_wr_en,
    output reg [`RULE_ID_WIDTH-1:0]        fc_cfg_rule_id,
    output reg [31:0]                      fc_cfg_dst_ip,
    output reg [31:0]                      fc_cfg_dst_ip_mask,
    output reg [15:0]                      fc_cfg_dst_port,
    output reg [15:0]                      fc_cfg_dst_port_mask,
    output reg [7:0]                       fc_cfg_protocol,
    output reg [7:0]                       fc_cfg_protocol_mask,
    output reg [`TUSER_SLICE_ID_WIDTH-1:0] fc_cfg_slice_id,
    output reg                             fc_cfg_rule_enable,

    // To Priority Scheduler
    output reg                             sch_cfg_wr_en,
    output reg [`QUEUE_ID_WIDTH-1:0]       sch_cfg_queue_id,
    output reg [1:0]                       sch_cfg_priority,
    output reg                             sch_cfg_queue_enable,
    output reg [31:0]                      sch_cfg_tb_rate,
    output reg [31:0]                      sch_cfg_tb_burst,
    output reg                             sch_cfg_tb_enable
);

    //------------------------------------------------------------------------
    // AXI-Lite Write FSM
    //------------------------------------------------------------------------
    reg [31:0] waddr_reg;
    reg aw_en; // Handshake synchronization
    
    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00; // OKAY
            aw_en         <= 1'b1;
            waddr_reg     <= 32'd0;
        end else begin
            // 1. Accept Address
            if (~s_axi_awready && s_axi_awvalid && s_axi_wvalid && aw_en) begin
                s_axi_awready <= 1'b1;
                waddr_reg     <= s_axi_awaddr;
                aw_en         <= 1'b0;
            end else if (s_axi_bready && s_axi_bvalid) begin
                aw_en <= 1'b1;
                s_axi_awready <= 1'b0;
            end else begin
                s_axi_awready <= 1'b0;
            end

            // 2. Accept Data
            if (~s_axi_wready && s_axi_wvalid && s_axi_awvalid && aw_en) begin
                s_axi_wready <= 1'b1;
            end else begin
                s_axi_wready <= 1'b0;
            end

            // 3. Issue Response
            if (s_axi_awready && s_axi_awvalid && s_axi_wready && s_axi_wvalid) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00; // OKAY
            end else begin
                if (s_axi_bready && s_axi_bvalid) begin
                    s_axi_bvalid <= 1'b0;
                end
            end
        end
    end

    //------------------------------------------------------------------------
    // Memory-Mapped Address Decoding (MMIO)
    //------------------------------------------------------------------------
    wire slv_reg_wren = s_axi_wready && s_axi_wvalid && s_axi_awready && s_axi_awvalid;
    wire [11:0] write_offset = waddr_reg[11:0]; // Look at lower 12 bits

    always @(posedge clk) begin
        if (!rst_n) begin
            fc_cfg_wr_en <= 1'b0;
            fc_cfg_rule_id <= 0;
            fc_cfg_dst_ip <= 0;
            fc_cfg_dst_ip_mask <= 0;
            fc_cfg_dst_port <= 0;
            fc_cfg_dst_port_mask <= 0;
            fc_cfg_protocol <= 0;
            fc_cfg_protocol_mask <= 0;
            fc_cfg_slice_id <= 0;
            fc_cfg_rule_enable <= 0;

            sch_cfg_wr_en <= 1'b0;
            sch_cfg_queue_id <= 0;
            sch_cfg_priority <= 0;
            sch_cfg_queue_enable <= 0;
            sch_cfg_tb_rate <= 0;
            sch_cfg_tb_burst <= 0;
            sch_cfg_tb_enable <= 0;
        end else begin
            // Default to no write pulse
            fc_cfg_wr_en  <= 1'b0;
            sch_cfg_wr_en <= 1'b0;

            if (slv_reg_wren) begin
                case (write_offset)
                    // ── Classifier Offsets ──
                    12'h000: fc_cfg_wr_en         <= 1'b1; // Trigger Commit!
                    12'h004: begin
                        fc_cfg_rule_id     <= s_axi_wdata[`RULE_ID_WIDTH-1:0];
                        fc_cfg_rule_enable <= s_axi_wdata[31];
                    end
                    12'h008: fc_cfg_dst_ip        <= s_axi_wdata;
                    12'h00C: fc_cfg_dst_ip_mask   <= s_axi_wdata;
                    12'h010: begin
                        fc_cfg_dst_port    <= s_axi_wdata[15:0];
                        fc_cfg_protocol    <= s_axi_wdata[23:16];
                        fc_cfg_slice_id    <= s_axi_wdata[31:28];
                    end
                    12'h014: begin
                        fc_cfg_dst_port_mask <= s_axi_wdata[15:0];
                        fc_cfg_protocol_mask <= s_axi_wdata[23:16];
                    end

                    // ── Scheduler Offsets ──
                    12'h100: sch_cfg_wr_en        <= 1'b1; // Trigger Commit!
                    12'h104: begin
                        sch_cfg_queue_id     <= s_axi_wdata[`QUEUE_ID_WIDTH-1:0];
                        sch_cfg_priority     <= s_axi_wdata[5:4];
                        sch_cfg_queue_enable <= s_axi_wdata[31];
                    end
                    12'h108: sch_cfg_tb_rate      <= s_axi_wdata;
                    12'h10C: sch_cfg_tb_burst     <= s_axi_wdata;
                    12'h110: sch_cfg_tb_enable    <= s_axi_wdata[0];
                    
                    default: ; // Do nothing for invalid addresses
                endcase
            end
        end
    end

    //------------------------------------------------------------------------
    // AXI-Lite Read Logic (Simplified for MVP)
    //------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b00;
            s_axi_rdata   <= 32'd0;
        end else begin
            // Accept address
            if (~s_axi_arready && s_axi_arvalid) begin
                s_axi_arready <= 1'b1;
            end else begin
                s_axi_arready <= 1'b0;
            end

            // Return dummy data (0xCAFEBABE) to prove memory map is alive
            if (s_axi_arready && s_axi_arvalid && ~s_axi_rvalid) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= 2'b00; // OKAY
                s_axi_rdata  <= 32'hCAFEBABE;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule
