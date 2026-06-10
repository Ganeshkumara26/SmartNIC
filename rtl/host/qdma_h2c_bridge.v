//============================================================================
// QDMA Host-to-Card (H2C) Bridge
//============================================================================
// Interfaces the Xilinx QDMA Subsystem to the SmartNIC ingress pipeline.
// Receives data from the Host PC (Linux Driver) over PCIe and translates
// it into standard AXI-Stream for the Packet Parser.
//
// QDMA REQUIREMENTS:
// ─────────────────────────────────────────────────────────────────────────
// The OpenNIC driver supplies the total packet length in the lower 16 bits
// of the `tuser_mdata` bus. The core SmartNIC datapath does not natively 
// require this upfront length, but this module bridges the interface cleanly
// and initializes the `TUSER` valid bit.
//============================================================================

`timescale 1ns / 1ps
`include "smartnic_pkg.vh"

module qdma_h2c_bridge (
    input  wire         clk,
    input  wire         rst_n,

    // ── Input: From QDMA H2C Data Channel ──────────────────────────────
    input  wire [`AXIS_DATA_WIDTH-1:0]  s_axis_qdma_h2c_tdata,
    input  wire [`AXIS_KEEP_WIDTH-1:0]  s_axis_qdma_h2c_tkeep,
    input  wire                         s_axis_qdma_h2c_tvalid,
    output wire                         s_axis_qdma_h2c_tready,
    input  wire                         s_axis_qdma_h2c_tlast,
    
    // QDMA Specific Sideband
    input  wire [15:0]                  s_axis_qdma_h2c_tuser_mdata, // Driver fills packet length here
    input  wire [10:0]                  s_axis_qdma_h2c_tuser_qid,   // Which host queue sent this
    input  wire [2:0]                   s_axis_qdma_h2c_tuser_port_id,
    
    // ── Output: To Packet Parser (Ingress Datapath) ───────────────────
    output wire [`AXIS_DATA_WIDTH-1:0]  m_axis_tdata,
    output wire [`AXIS_KEEP_WIDTH-1:0]  m_axis_tkeep,
    output wire [`AXIS_USER_WIDTH-1:0]  m_axis_tuser,
    output wire                         m_axis_tvalid,
    input  wire                         m_axis_tready,
    output wire                         m_axis_tlast
);

    //------------------------------------------------------------------------
    // Datapath Passthrough
    //------------------------------------------------------------------------
    // The main data path is a direct combinatorial passthrough to ensure 
    // zero latency penalty. Backpressure is natively propagated.
    
    assign s_axis_qdma_h2c_tready = m_axis_tready;
    
    assign m_axis_tdata  = s_axis_qdma_h2c_tdata;
    assign m_axis_tkeep  = s_axis_qdma_h2c_tkeep;
    assign m_axis_tvalid = s_axis_qdma_h2c_tvalid;
    assign m_axis_tlast  = s_axis_qdma_h2c_tlast;

    //------------------------------------------------------------------------
    // Metadata Translation
    //------------------------------------------------------------------------
    // The Packet Parser expects TUSER[0] to be initially zeroed (it will set 
    // it to 1 if it successfully validates the IPv4 headers). We initialize 
    // the entire 128-bit TUSER bus to 0 here to maintain a clean slate.
    //
    // Note: The OpenNIC driver supplies the packet size in `tuser_mdata`. 
    // We could pass this down into the SmartNIC sideband if desired, but 
    // for standard routing, it is ignored by the fast path.
    
    assign m_axis_tuser = {`AXIS_USER_WIDTH{1'b0}};

endmodule
