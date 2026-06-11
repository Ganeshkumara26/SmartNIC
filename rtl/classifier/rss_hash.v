//============================================================================
// Module: RSS Toeplitz Hashing Engine (rss_hash.v)
//============================================================================
// Computes a 32-bit Toeplitz Hash over the 96-bit IPv4 4-tuple 
// (Src IP, Dst IP, Src Port, Dst Port) for Receive-Side Scaling (RSS).
// The hash is appended to the TUSER sideband so DPDK can distribute
// traffic across multiple CPU cores without software locking.
//============================================================================

`timescale 1ns / 1ps
`include "smartnic_pkg.vh"

module rss_hash (
    input  wire                          clk,
    input  wire                          rst_n,

    // Ingress AXI-Stream (From Packet Parser)
    input  wire [`AXIS_DATA_WIDTH-1:0]   s_axis_tdata,
    input  wire [`AXIS_KEEP_WIDTH-1:0]   s_axis_tkeep,
    input  wire [`AXIS_USER_WIDTH-1:0]   s_axis_tuser,
    input  wire                          s_axis_tvalid,
    output wire                          s_axis_tready,
    input  wire                          s_axis_tlast,

    // Egress AXI-Stream (To Flow Classifier / Queue Manager)
    output wire [`AXIS_DATA_WIDTH-1:0]   m_axis_tdata,
    output wire [`AXIS_KEEP_WIDTH-1:0]   m_axis_tkeep,
    output reg  [`AXIS_USER_WIDTH-1:0]   m_axis_tuser,
    output wire                          m_axis_tvalid,
    input  wire                          m_axis_tready,
    output wire                          m_axis_tlast
);

    // Standard Microsoft RSS 40-byte Symmetric Key
    localparam [319:0] RSS_KEY = 320'h6d5a56da255b0ec24167253d43a38fb0d0ca2bcbae7b30b477cb2da38030f20c6a42b73bbeac01fa;

    //------------------------------------------------------------------------
    // Pipeline Register (1-cycle delay to absorb XOR tree latency)
    //------------------------------------------------------------------------
    reg [`AXIS_DATA_WIDTH-1:0]  int_tdata;
    reg [`AXIS_KEEP_WIDTH-1:0]  int_tkeep;
    reg [`AXIS_USER_WIDTH-1:0]  int_tuser;
    reg                         int_tvalid;
    reg                         int_tlast;
    wire                        int_tready;

    // Simple pass-through assignments for backpressure
    assign s_axis_tready = int_tready;
    assign m_axis_tdata  = int_tdata;
    assign m_axis_tkeep  = int_tkeep;
    assign m_axis_tvalid = int_tvalid;
    assign m_axis_tlast  = int_tlast;

    assign int_tready = m_axis_tready || !int_tvalid;

    //------------------------------------------------------------------------
    // Tuple Extraction
    //------------------------------------------------------------------------
    wire        is_ipv4  = s_axis_tuser[`TUSER_IS_IPV4_BIT];
    wire        is_udp   = s_axis_tuser[`TUSER_IS_UDP_BIT];
    wire        is_tcp   = s_axis_tuser[`TUSER_IS_TCP_BIT];
    wire [31:0] src_ip   = s_axis_tuser[`TUSER_SRC_IP_HI:`TUSER_SRC_IP_LO];
    wire [31:0] dst_ip   = s_axis_tuser[`TUSER_DST_IP_HI:`TUSER_DST_IP_LO];
    wire [15:0] src_port = s_axis_tuser[`TUSER_SRC_PORT_HI:`TUSER_SRC_PORT_LO];
    wire [15:0] dst_port = s_axis_tuser[`TUSER_DST_PORT_HI:`TUSER_DST_PORT_LO];

    wire [95:0] tuple = {src_ip, dst_ip, src_port, dst_port};

    //------------------------------------------------------------------------
    // Toeplitz Hash Combinatorial Logic
    //------------------------------------------------------------------------
    reg [31:0] hash_result;
    integer i;

    always @(*) begin
        hash_result = 32'd0;
        // If it's a valid IPv4 UDP/TCP packet, calculate the hash
        if (s_axis_tuser[`TUSER_VALID_BIT] && is_ipv4 && (is_udp || is_tcp)) begin
            for (i = 0; i < 96; i = i + 1) begin
                if (tuple[95 - i]) begin
                    hash_result = hash_result ^ RSS_KEY[319 - i -: 32];
                end
            end
        end else if (s_axis_tuser[`TUSER_VALID_BIT] && is_ipv4) begin
            // If it's just IPv4 (e.g. ICMP), only hash the IPs (64 bits)
            for (i = 0; i < 64; i = i + 1) begin
                if (tuple[95 - i]) begin
                    hash_result = hash_result ^ RSS_KEY[319 - i -: 32];
                end
            end
        end
    end

    //------------------------------------------------------------------------
    // Synchronous Pipeline Stage
    //------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            int_tvalid <= 1'b0;
            int_tdata  <= 0;
            int_tkeep  <= 0;
            int_tuser  <= 0;
            int_tlast  <= 0;
            m_axis_tuser <= 0;
        end else if (int_tready) begin
            int_tvalid <= s_axis_tvalid;
            
            if (s_axis_tvalid) begin
                int_tdata <= s_axis_tdata;
                int_tkeep <= s_axis_tkeep;
                int_tlast <= s_axis_tlast;
                
                // Inject the computed hash into the TUSER bus
                m_axis_tuser <= s_axis_tuser;
                m_axis_tuser[`TUSER_RSS_HASH_HI:`TUSER_RSS_HASH_LO] <= hash_result;
            end
        end
    end

endmodule
