//============================================================================
// Module: RSS Steer Engine (rss_steer.v)
//============================================================================
// Uses a 128-entry Redirection Table (RETA) to override the Slice ID
// assigned by the Flow Classifier, load-balancing traffic across queues.
// Bypasses URLLC (Queue 0) traffic to guarantee strict priority latency.
//============================================================================

`timescale 1ns / 1ps
`include "smartnic_pkg.vh"

module rss_steer (
    input  wire                             clk,
    input  wire                             rst_n,

    // ── AXI-Stream Slave (from RSS Hash) ─────────────────────────
    input  wire [`AXIS_DATA_WIDTH-1:0]      s_axis_tdata,
    input  wire [`AXIS_KEEP_WIDTH-1:0]      s_axis_tkeep,
    input  wire [`AXIS_USER_WIDTH-1:0]      s_axis_tuser,
    input  wire                             s_axis_tvalid,
    output wire                             s_axis_tready,
    input  wire                             s_axis_tlast,

    // ── AXI-Stream Master (to Queue Manager) ──────────────────────────
    output reg  [`AXIS_DATA_WIDTH-1:0]      m_axis_tdata,
    output reg  [`AXIS_KEEP_WIDTH-1:0]      m_axis_tkeep,
    output reg  [`AXIS_USER_WIDTH-1:0]      m_axis_tuser,
    output reg                              m_axis_tvalid,
    input  wire                             m_axis_tready,
    output reg                              m_axis_tlast,

    // ── RETA Configuration Port (from AXI-Lite) ───────────────────────
    input  wire                             cfg_reta_wr_en,
    input  wire [6:0]                       cfg_reta_idx,
    input  wire [`TUSER_SLICE_ID_WIDTH-1:0] cfg_reta_val
);

    //------------------------------------------------------------------------
    // Redirection Table (RETA) Memory (128 entries)
    //------------------------------------------------------------------------
    reg [`TUSER_SLICE_ID_WIDTH-1:0] reta_mem [127:0];

    // Configuration Write Port
    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            // Default initialization: distribute among Queues 1, 2, 3
            // (Queue 0 is reserved for URLLC)
            for (k = 0; k < 128; k = k + 1) begin
                reta_mem[k] <= (k % 3) + 1;
            end
        end else if (cfg_reta_wr_en) begin
            reta_mem[cfg_reta_idx] <= cfg_reta_val;
        end
    end

    //------------------------------------------------------------------------
    // Fast-Path RETA Lookup
    //------------------------------------------------------------------------
    wire [6:0] hash_idx = s_axis_tuser[`TUSER_RSS_HASH_LO + 6 : `TUSER_RSS_HASH_LO];
    wire       is_eligible = s_axis_tuser[`TUSER_RSS_ELIGIBLE_BIT];
    
    // We do an asynchronous read. Since it's only 128x4 bits, this infers LUTRAM
    // which supports asynchronous reads without penalty at 250MHz.
    wire [`TUSER_SLICE_ID_WIDTH-1:0] lookup_val = reta_mem[hash_idx];

    //------------------------------------------------------------------------
    // Packet Tracking
    //------------------------------------------------------------------------
    reg                              in_packet;
    reg [`TUSER_SLICE_ID_WIDTH-1:0]  current_slice_id;

    wire input_handshake  = s_axis_tvalid && s_axis_tready;
    wire output_handshake = m_axis_tvalid && m_axis_tready;

    assign s_axis_tready = m_axis_tready || !m_axis_tvalid;

    always @(posedge clk) begin
        if (!rst_n) begin
            m_axis_tvalid   <= 1'b0;
            m_axis_tdata    <= {`AXIS_DATA_WIDTH{1'b0}};
            m_axis_tkeep    <= {`AXIS_KEEP_WIDTH{1'b0}};
            m_axis_tuser    <= {`AXIS_USER_WIDTH{1'b0}};
            m_axis_tlast    <= 1'b0;
            in_packet       <= 1'b0;
            current_slice_id <= `DEFAULT_SLICE_ID;
        end else begin
            if (output_handshake) begin
                m_axis_tvalid <= 1'b0;
            end

            if (input_handshake) begin
                m_axis_tdata  <= s_axis_tdata;
                m_axis_tkeep  <= s_axis_tkeep;
                m_axis_tlast  <= s_axis_tlast;
                m_axis_tvalid <= 1'b1;

                if (!in_packet) begin
                    // First beat of packet
                    m_axis_tuser <= s_axis_tuser;
                    
                    if (is_eligible) begin
                        // Override Slice ID with RETA lookup
                        m_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO] <= lookup_val;
                        current_slice_id <= lookup_val;
                    end else begin
                        // Pass through the original Slice ID (e.g. Queue 0)
                        current_slice_id <= s_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO];
                    end

                    if (!s_axis_tlast) begin
                        in_packet <= 1'b1;
                    end
                end else begin
                    // Subsequent beats — maintain the steered Slice ID
                    m_axis_tuser <= s_axis_tuser;
                    m_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO] <= current_slice_id;

                    if (s_axis_tlast) begin
                        in_packet <= 1'b0;
                    end
                end
            end
        end
    end

endmodule
