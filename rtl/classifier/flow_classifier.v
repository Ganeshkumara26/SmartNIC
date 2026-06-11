//============================================================================
// Flow Classifier — CAM-style Slice ID Lookup
//============================================================================
// Takes parsed packets (with TUSER metadata from the Packet Parser) and
// assigns a Slice ID based on a configurable rule table. This determines
// which hardware queue the packet will be routed to.
//
// ARCHITECTURE:
// ─────────────────────────────────────────────────────────────────────────
// The classifier maintains a small table of 16 rules, each specifying:
//   - Match criteria: Dst IP, Dst IP Mask, Dst Port, Dst Port Mask, Protocol
//   - Action: Slice ID (4 bits → up to 16 slices)
//   - Enable bit
//
// On each incoming packet, ALL rules are evaluated in parallel (like a
// Content-Addressable Memory / TCAM). The lowest-index matching rule wins
// (priority ordering). If no rule matches, the default Slice ID is used.
//
// Rules are configured via an AXI-Lite write port, which will eventually
// be connected to the RISC-V control core. For testing, the testbench
// writes rules directly.
//
// LEARNING NOTES:
// ─────────────────────────────────────────────────────────────────────────
// TCAM (Ternary CAM) matching: A rule matches when:
//   (packet_field & mask) == (rule_field & mask)
// This allows wildcard matching. Mask = 0xFFFFFFFF means exact match.
// Mask = 0x00000000 means "don't care" (matches everything).
//============================================================================

`include "smartnic_pkg.vh"

module flow_classifier (
    input  wire                             clk,
    input  wire                             rst_n,

    // ── AXI-Stream Slave (from Packet Parser) ─────────────────────────
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

    // ── Rule Configuration Port (simplified AXI-Lite-style) ───────────
    // Write a rule: assert cfg_wr_en for one cycle with the rule data.
    input  wire                             cfg_wr_en,
    input  wire [`RULE_ID_WIDTH-1:0]        cfg_rule_id,    // Which rule slot (0-15)
    input  wire [31:0]                      cfg_dst_ip,     // Rule: destination IP
    input  wire [31:0]                      cfg_dst_ip_mask,// Mask for dst IP
    input  wire [15:0]                      cfg_dst_port,   // Rule: destination port
    input  wire [15:0]                      cfg_dst_port_mask,// Mask for dst port
    input  wire [7:0]                       cfg_protocol,   // Rule: IP protocol
    input  wire [7:0]                       cfg_protocol_mask,// Mask for protocol
    input  wire [`TUSER_SLICE_ID_WIDTH-1:0] cfg_slice_id,   // Action: assigned Slice ID
    input  wire                             cfg_rule_enable // Enable this rule
);

    //------------------------------------------------------------------------
    // Rule Table Storage
    //------------------------------------------------------------------------
    // Each rule is stored in register arrays. 16 rules × (fields + masks).
    // In a real FPGA this would be ~2KB of distributed RAM / flip-flops.

    reg [31:0] rule_dst_ip       [`NUM_RULES-1:0];
    reg [31:0] rule_dst_ip_mask  [`NUM_RULES-1:0];
    reg [15:0] rule_dst_port     [`NUM_RULES-1:0];
    reg [15:0] rule_dst_port_mask[`NUM_RULES-1:0];
    reg [7:0]  rule_protocol     [`NUM_RULES-1:0];
    reg [7:0]  rule_protocol_mask[`NUM_RULES-1:0];
    reg [`TUSER_SLICE_ID_WIDTH-1:0] rule_slice_id [`NUM_RULES-1:0];
    reg        rule_enable       [`NUM_RULES-1:0];

    //------------------------------------------------------------------------
    // Rule Write Logic
    //------------------------------------------------------------------------
    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (k = 0; k < `NUM_RULES; k = k + 1) begin
                rule_enable[k] <= 1'b0;
                rule_dst_ip[k] <= 32'd0;
                rule_dst_ip_mask[k] <= 32'd0;
                rule_dst_port[k] <= 16'd0;
                rule_dst_port_mask[k] <= 16'd0;
                rule_protocol[k] <= 8'd0;
                rule_protocol_mask[k] <= 8'd0;
                rule_slice_id[k] <= {`TUSER_SLICE_ID_WIDTH{1'b0}};
            end
        end else if (cfg_wr_en) begin
            rule_dst_ip[cfg_rule_id]        <= cfg_dst_ip;
            rule_dst_ip_mask[cfg_rule_id]   <= cfg_dst_ip_mask;
            rule_dst_port[cfg_rule_id]      <= cfg_dst_port;
            rule_dst_port_mask[cfg_rule_id] <= cfg_dst_port_mask;
            rule_protocol[cfg_rule_id]      <= cfg_protocol;
            rule_protocol_mask[cfg_rule_id] <= cfg_protocol_mask;
            rule_slice_id[cfg_rule_id]      <= cfg_slice_id;
            rule_enable[cfg_rule_id]        <= cfg_rule_enable;
        end
    end

    //------------------------------------------------------------------------
    // Parallel Rule Matching
    //------------------------------------------------------------------------
    // Extract fields from incoming TUSER metadata (set by packet parser)
    wire [31:0] pkt_dst_ip   = s_axis_tuser[`TUSER_DST_IP_HI:`TUSER_DST_IP_LO];
    wire [15:0] pkt_dst_port = s_axis_tuser[`TUSER_DST_PORT_HI:`TUSER_DST_PORT_LO];
    wire [7:0]  pkt_protocol = s_axis_tuser[`TUSER_IP_PROTO_HI:`TUSER_IP_PROTO_LO];
    wire        pkt_valid    = s_axis_tuser[`TUSER_VALID_BIT];

    // Generate match signals for all 16 rules in parallel
    wire [`NUM_RULES-1:0] rule_match;

    genvar i;
    generate
        for (i = 0; i < `NUM_RULES; i = i + 1) begin : gen_match
            // A rule matches when all masked fields are equal AND rule is enabled
            wire ip_match   = ((pkt_dst_ip   & rule_dst_ip_mask[i])   ==
                               (rule_dst_ip[i] & rule_dst_ip_mask[i]));
            wire port_match = ((pkt_dst_port & rule_dst_port_mask[i]) ==
                               (rule_dst_port[i] & rule_dst_port_mask[i]));
            wire proto_match= ((pkt_protocol & rule_protocol_mask[i]) ==
                               (rule_protocol[i] & rule_protocol_mask[i]));

            assign rule_match[i] = rule_enable[i] && ip_match && port_match && proto_match;
        end
    endgenerate

    //------------------------------------------------------------------------
    // Priority Encoder (First-Match Wins)
    //------------------------------------------------------------------------
    // LEARNING NOTE: A priority encoder finds the lowest-indexed set bit.
    // This implements "first match wins" — Rule 0 has highest priority.

    reg [`TUSER_SLICE_ID_WIDTH-1:0] matched_slice_id;
    reg                              match_found;

    // Using a simple combinational priority scan
    integer j;
    always @(*) begin
        matched_slice_id = `DEFAULT_SLICE_ID;
        match_found = 1'b0;
        for (j = 0; j < `NUM_RULES; j = j + 1) begin
            if (rule_match[j] && !match_found) begin
                matched_slice_id = rule_slice_id[j];
                match_found = 1'b1;
            end
        end
    end

    //------------------------------------------------------------------------
    // Packet Tracking — First Beat vs Subsequent Beats
    //------------------------------------------------------------------------
    // The Slice ID lookup only happens on the first beat of each packet.
    // Subsequent beats reuse the same Slice ID.

    reg                              in_packet;
    reg [`TUSER_SLICE_ID_WIDTH-1:0]  current_slice_id;
    reg                              current_rss_eligible;

    //------------------------------------------------------------------------
    // AXI-Stream Forwarding with Slice ID Insertion
    //------------------------------------------------------------------------
    wire input_handshake  = s_axis_tvalid && s_axis_tready;
    wire output_handshake = m_axis_tvalid && m_axis_tready;

    // Simple cut-through: we forward data with one cycle of latency
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
            current_rss_eligible <= 1'b0;
        end else begin
            // Clear valid when output is consumed
            if (output_handshake) begin
                m_axis_tvalid <= 1'b0;
            end

            if (input_handshake) begin
                m_axis_tdata  <= s_axis_tdata;
                m_axis_tkeep  <= s_axis_tkeep;
                m_axis_tlast  <= s_axis_tlast;
                m_axis_tvalid <= 1'b1;

                if (!in_packet) begin
                    // First beat of packet — do the lookup
                    if (pkt_valid && match_found) begin
                        current_slice_id <= matched_slice_id;
                        current_rss_eligible <= (matched_slice_id != `DEFAULT_SLICE_ID);
                    end else begin
                        current_slice_id <= `DEFAULT_SLICE_ID;
                        current_rss_eligible <= 1'b0;
                    end

                    // Insert the matched Slice ID into TUSER
                    m_axis_tuser <= s_axis_tuser;
                    m_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO] <=
                        (pkt_valid && match_found) ? matched_slice_id : `DEFAULT_SLICE_ID;
                    
                    m_axis_tuser[`TUSER_RSS_ELIGIBLE_BIT] <=
                        (pkt_valid && match_found && (matched_slice_id != `DEFAULT_SLICE_ID)) ? 1'b1 : 1'b0;

                    if (!s_axis_tlast) begin
                        in_packet <= 1'b1;
                    end
                end else begin
                    // Subsequent beats — reuse the stored Slice ID
                    m_axis_tuser <= s_axis_tuser;
                    m_axis_tuser[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO] <= current_slice_id;
                    m_axis_tuser[`TUSER_RSS_ELIGIBLE_BIT] <= current_rss_eligible;

                    if (s_axis_tlast) begin
                        in_packet <= 1'b0;
                    end
                end
            end
        end
    end

endmodule
