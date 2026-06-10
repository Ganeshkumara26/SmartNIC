//============================================================================
// QDMA Card-to-Host (C2H) Bridge
//============================================================================
// Interfaces the SmartNIC egress pipeline directly to the Xilinx QDMA 
// Subsystem for transmission over the PCIe bus to the Host PC's RAM.
//
// QDMA REQUIREMENTS:
// ─────────────────────────────────────────────────────────────────────────
// The OpenNIC driver expects every C2H data packet to be accompanied by a 
// C2H Completion (CMPT) packet. The completion packet informs the Linux 
// Kernel exactly how many bytes were transferred, allowing the host to 
// process the ring buffer without polling payload data.
//
// This module bridges the standard AXI-Stream output of our Priority 
// Scheduler into the specialized QDMA Data and CMPT channels.
//============================================================================

`timescale 1ns / 1ps
`include "smartnic_pkg.vh"

module qdma_c2h_bridge (
    input  wire         clk,
    input  wire         rst_n,

    // ── Input: From Priority Scheduler (Egress Datapath) ──────────────
    input  wire [`AXIS_DATA_WIDTH-1:0]  s_axis_tdata,
    input  wire [`AXIS_KEEP_WIDTH-1:0]  s_axis_tkeep,
    input  wire [`AXIS_USER_WIDTH-1:0]  s_axis_tuser,
    input  wire                         s_axis_tvalid,
    output wire                         s_axis_tready,
    input  wire                         s_axis_tlast,

    // ── Output: To QDMA C2H Data Channel ──────────────────────────────
    output wire [`AXIS_DATA_WIDTH-1:0]  m_axis_qdma_c2h_tdata,
    output wire [`AXIS_KEEP_WIDTH-1:0]  m_axis_qdma_c2h_tkeep,
    output wire                         m_axis_qdma_c2h_tvalid,
    input  wire                         m_axis_qdma_c2h_tready,
    output wire                         m_axis_qdma_c2h_tlast,
    
    // QDMA Specific Control Signals
    output wire                         m_axis_qdma_c2h_ctrl_marker,
    output wire [2:0]                   m_axis_qdma_c2h_ctrl_port_id,
    output wire                         m_axis_qdma_c2h_ctrl_has_cmpt,

    // ── Output: To QDMA C2H Completion Channel ────────────────────────
    output reg  [255:0]                 m_axis_qdma_cpl_tdata,
    output reg  [1:0]                   m_axis_qdma_cpl_size,
    output reg                          m_axis_qdma_cpl_tvalid,
    input  wire                         m_axis_qdma_cpl_tready,
    
    // CMPT Specific Control Signals
    output wire                         m_axis_qdma_cpl_ctrl_no_wrb_marker,
    output wire [2:0]                   m_axis_qdma_cpl_ctrl_col_idx,
    output wire [2:0]                   m_axis_qdma_cpl_ctrl_err_idx,
    output wire                         m_axis_qdma_cpl_ctrl_marker,
    output wire                         m_axis_qdma_cpl_ctrl_user_trig,
    output wire [2:0]                   m_axis_qdma_cpl_ctrl_port_id,
    output wire [1:0]                   m_axis_qdma_cpl_ctrl_cmpt_type
);

    //------------------------------------------------------------------------
    // QDMA Constant Tie-Offs (As per OpenNIC Specification)
    //------------------------------------------------------------------------
    assign m_axis_qdma_c2h_ctrl_marker    = 1'b0;
    assign m_axis_qdma_c2h_ctrl_port_id   = 3'd0;
    assign m_axis_qdma_c2h_ctrl_has_cmpt  = 1'b1; // We always send completions!

    assign m_axis_qdma_cpl_ctrl_no_wrb_marker = 1'b0;
    assign m_axis_qdma_cpl_ctrl_col_idx       = 3'd0;
    assign m_axis_qdma_cpl_ctrl_err_idx       = 3'd0;
    assign m_axis_qdma_cpl_ctrl_marker        = 1'b0;
    assign m_axis_qdma_cpl_ctrl_user_trig     = 1'b0;
    assign m_axis_qdma_cpl_ctrl_port_id       = 3'd0;
    assign m_axis_qdma_cpl_ctrl_cmpt_type     = 2'b11; // Regular mode

    //------------------------------------------------------------------------
    // Datapath Passthrough
    //------------------------------------------------------------------------
    // The Data channel is a direct pass-through to the QDMA block.
    // However, we can only assert TREADY if BOTH the QDMA Data channel and 
    // the QDMA Completion channel are ready to accept data (preventing deadlocks).
    
    wire data_transfer    = s_axis_tvalid && m_axis_qdma_c2h_tready;
    wire end_of_packet    = data_transfer && s_axis_tlast;
    
    // We only accept data from the scheduler if the QDMA Data channel is ready
    // AND we aren't currently blocked waiting to send a completion packet.
    assign s_axis_tready = m_axis_qdma_c2h_tready && (!m_axis_qdma_cpl_tvalid || m_axis_qdma_cpl_tready);

    assign m_axis_qdma_c2h_tdata  = s_axis_tdata;
    assign m_axis_qdma_c2h_tkeep  = s_axis_tkeep;
    assign m_axis_qdma_c2h_tlast  = s_axis_tlast;
    assign m_axis_qdma_c2h_tvalid = s_axis_tvalid && (!m_axis_qdma_cpl_tvalid || m_axis_qdma_cpl_tready);

    //------------------------------------------------------------------------
    // Packet Byte Counter
    //------------------------------------------------------------------------
    // The completion packet requires the exact byte length of the packet.
    // We calculate this dynamically by counting the active TKEEP bits.
    
    reg [15:0] packet_byte_count;
    
    function [6:0] count_ones;
        input [63:0] keep_mask;
        integer i;
        begin
            count_ones = 0;
            for (i = 0; i < 64; i = i + 1) begin
                if (keep_mask[i]) count_ones = count_ones + 1;
            end
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            packet_byte_count <= 16'd0;
        end else if (data_transfer) begin
            if (s_axis_tlast) begin
                packet_byte_count <= 16'd0; // Reset for next packet
            end else begin
                packet_byte_count <= packet_byte_count + count_ones(s_axis_tkeep);
            end
        end
    end

    //------------------------------------------------------------------------
    // Completion Generator
    //------------------------------------------------------------------------
    reg [15:0] packet_id_counter;

    always @(posedge clk) begin
        if (!rst_n) begin
            m_axis_qdma_cpl_tvalid <= 1'b0;
            m_axis_qdma_cpl_tdata  <= 256'd0;
            m_axis_qdma_cpl_size   <= 2'b00; // 8 bytes of completion data
            packet_id_counter      <= 16'd0;
        end else begin
            // If the completion channel accepted our previous packet, clear the valid bit
            if (m_axis_qdma_cpl_tvalid && m_axis_qdma_cpl_tready) begin
                m_axis_qdma_cpl_tvalid <= 1'b0;
            end
            
            // When a packet finishes transferring on the Data channel, generate a Completion
            if (end_of_packet) begin
                m_axis_qdma_cpl_tvalid <= 1'b1;
                m_axis_qdma_cpl_size   <= 2'b00; 
                
                // OpenNIC Format: [15:0] Packet ID, [31:16] Byte Length, [47:32] Queue ID
                m_axis_qdma_cpl_tdata[15:0]  <= packet_id_counter;
                m_axis_qdma_cpl_tdata[31:16] <= packet_byte_count + count_ones(s_axis_tkeep);
                
                // Extract the physical queue ID from the sideband metadata
                m_axis_qdma_cpl_tdata[47:32] <= {12'd0, s_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO]};
                
                // Upper bytes are tied to 0 for the 8-byte completion mode
                m_axis_qdma_cpl_tdata[255:48] <= 208'd0;
                
                packet_id_counter <= packet_id_counter + 1'b1;
            end
        end
    end

endmodule
