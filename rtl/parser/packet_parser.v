//============================================================================
// 5G Packet Parser — Ethernet / IPv4 / UDP Header Extraction
//============================================================================
// This module sits at the head of the SmartNIC datapath. It receives raw
// Ethernet frames on a 512-bit AXI-Stream input and extracts key header
// fields, packing them into the TUSER sideband for downstream modules.
//
// ARCHITECTURE:
// ─────────────────────────────────────────────────────────────────────────
// Because the data bus is 512 bits (64 bytes) wide, the ENTIRE Ethernet +
// IPv4 + UDP header fits in the FIRST beat of the packet:
//   - Ethernet header: 14 bytes
//   - IPv4 header:     20 bytes (minimum)
//   - UDP header:       8 bytes
//   - Total:           42 bytes  ← fits in 64 bytes!
//
// This means we can extract all fields combinationally from the first beat
// without needing a multi-cycle state machine. We use a simple 2-stage
// pipeline:
//   Stage 1: Latch the first beat, extract fields, determine protocol
//   Stage 2: Output packet with populated TUSER metadata
//
// For multi-beat packets (payload > 64 bytes), subsequent beats are
// forwarded with the same TUSER metadata.
//
// SUPPORTED PROTOCOLS:
//   - Ethernet II (no VLAN tags in MVP; add 802.1Q later for Tier 2)
//   - IPv4 (basic 20-byte header; no options parsing in MVP)
//   - UDP
//
// FUTURE (Tier 3): Parse GTP-U tunnel headers for 5G slice identification.
//============================================================================

`include "smartnic_pkg.vh"

module packet_parser (
    input  wire                             clk,
    input  wire                             rst_n,

    // ── AXI-Stream Slave (Raw packets from CMAC/upstream) ─────────────
    input  wire [`AXIS_DATA_WIDTH-1:0]      s_axis_tdata,
    input  wire [`AXIS_KEEP_WIDTH-1:0]      s_axis_tkeep,
    input  wire                             s_axis_tvalid,
    output wire                             s_axis_tready,
    input  wire                             s_axis_tlast,

    // ── AXI-Stream Master (Packets with parsed metadata) ──────────────
    output reg  [`AXIS_DATA_WIDTH-1:0]      m_axis_tdata,
    output reg  [`AXIS_KEEP_WIDTH-1:0]      m_axis_tkeep,
    output reg  [`AXIS_USER_WIDTH-1:0]      m_axis_tuser,
    output reg                              m_axis_tvalid,
    input  wire                             m_axis_tready,
    output reg                              m_axis_tlast
);

    //------------------------------------------------------------------------
    // State Machine
    //------------------------------------------------------------------------
    // LEARNING NOTE: A simple FSM controls how we process multi-beat packets.
    //   IDLE:       Waiting for the first beat of a new packet
    //   FIRST_BEAT: We've latched the first beat and are outputting it with
    //               parsed metadata. Transitions to FORWARDING if not TLAST.
    //   FORWARDING: Passing through subsequent beats of a multi-beat packet
    //               with the same TUSER metadata.

    localparam [1:0] ST_IDLE       = 2'd0,
                     ST_FIRST_BEAT = 2'd1,
                     ST_FORWARDING = 2'd2;

    reg [1:0] state, state_next;

    //------------------------------------------------------------------------
    // Registered Pipeline Stage
    //------------------------------------------------------------------------
    // We latch the first beat to extract headers, then output it next cycle.

    reg [`AXIS_DATA_WIDTH-1:0]   first_beat_data;
    reg [`AXIS_KEEP_WIDTH-1:0]   first_beat_keep;
    reg                          first_beat_last;
    reg [`AXIS_USER_WIDTH-1:0]   parsed_metadata;

    //------------------------------------------------------------------------
    // Combinational Header Extraction
    //------------------------------------------------------------------------
    // These wires extract fields from the FIRST beat of the incoming packet.
    // All byte offsets are defined in smartnic_pkg.vh.
    //
    // LEARNING NOTE: We use the Verilog bit-select operator [MSB:LSB] to
    // extract specific bytes from the 512-bit TDATA bus.
    // Byte N starts at bit N*8, so byte 12 is at bits [103:96].

    // Helper function: extract a byte from TDATA given byte offset
    // TDATA byte ordering: byte 0 = TDATA[7:0], byte 1 = TDATA[15:8], etc.

    // ── Ethernet Fields ───────────────────────────────────────────────
    wire [15:0] ethertype = {
        s_axis_tdata[(`ETH_ETHERTYPE_OFFSET * 8) +: 8],       // byte 12 (MSB)
        s_axis_tdata[((`ETH_ETHERTYPE_OFFSET + 1) * 8) +: 8]  // byte 13 (LSB)
    };

    wire is_ipv4 = (ethertype == `ETHERTYPE_IPV4);

    // ── IPv4 Fields (valid only when is_ipv4) ─────────────────────────
    wire [7:0] ip_protocol = s_axis_tdata[((`IPV4_START + `IPV4_PROTOCOL_OFFSET) * 8) +: 8];

    wire [31:0] src_ip = {
        s_axis_tdata[((`IPV4_START + `IPV4_SRC_IP_OFFSET    ) * 8) +: 8],
        s_axis_tdata[((`IPV4_START + `IPV4_SRC_IP_OFFSET + 1) * 8) +: 8],
        s_axis_tdata[((`IPV4_START + `IPV4_SRC_IP_OFFSET + 2) * 8) +: 8],
        s_axis_tdata[((`IPV4_START + `IPV4_SRC_IP_OFFSET + 3) * 8) +: 8]
    };

    wire [31:0] dst_ip = {
        s_axis_tdata[((`IPV4_START + `IPV4_DST_IP_OFFSET    ) * 8) +: 8],
        s_axis_tdata[((`IPV4_START + `IPV4_DST_IP_OFFSET + 1) * 8) +: 8],
        s_axis_tdata[((`IPV4_START + `IPV4_DST_IP_OFFSET + 2) * 8) +: 8],
        s_axis_tdata[((`IPV4_START + `IPV4_DST_IP_OFFSET + 3) * 8) +: 8]
    };

    wire is_udp = is_ipv4 && (ip_protocol == `IP_PROTO_UDP);
    wire is_tcp = is_ipv4 && (ip_protocol == `IP_PROTO_TCP);

    // ── UDP Fields (valid only when is_udp) ───────────────────────────
    wire [15:0] udp_src_port = {
        s_axis_tdata[((`UDP_START + `UDP_SRC_PORT_OFFSET    ) * 8) +: 8],
        s_axis_tdata[((`UDP_START + `UDP_SRC_PORT_OFFSET + 1) * 8) +: 8]
    };

    wire [15:0] udp_dst_port = {
        s_axis_tdata[((`UDP_START + `UDP_DST_PORT_OFFSET    ) * 8) +: 8],
        s_axis_tdata[((`UDP_START + `UDP_DST_PORT_OFFSET + 1) * 8) +: 8]
    };

    //------------------------------------------------------------------------
    // Build TUSER Metadata
    //------------------------------------------------------------------------
    // Pack all extracted fields into the 128-bit TUSER sideband format
    // defined in smartnic_pkg.vh.

    wire [`AXIS_USER_WIDTH-1:0] metadata;

    assign metadata[`TUSER_VALID_BIT]                           = is_ipv4;
    assign metadata[`TUSER_IS_IPV4_BIT]                         = is_ipv4;
    assign metadata[`TUSER_IS_UDP_BIT]                          = is_udp;
    assign metadata[`TUSER_IS_TCP_BIT]                          = is_tcp;
    assign metadata[`TUSER_SLICE_ID_HI:`TUSER_SLICE_ID_LO]     = `DEFAULT_SLICE_ID; // Set by classifier
    assign metadata[`TUSER_IP_PROTO_HI:`TUSER_IP_PROTO_LO]     = is_ipv4 ? ip_protocol : 8'd0;
    assign metadata[`TUSER_DST_PORT_HI:`TUSER_DST_PORT_LO]     = (is_udp || is_tcp) ? udp_dst_port : 16'd0;
    assign metadata[`TUSER_SRC_PORT_HI:`TUSER_SRC_PORT_LO]     = (is_udp || is_tcp) ? udp_src_port : 16'd0;
    assign metadata[`TUSER_DST_IP_HI:`TUSER_DST_IP_LO]         = is_ipv4 ? dst_ip : 32'd0;
    assign metadata[`TUSER_SRC_IP_HI:`TUSER_SRC_IP_LO]         = is_ipv4 ? src_ip : 32'd0;
    assign metadata[`TUSER_RESERVED_HI:`TUSER_RESERVED_LO]     = 16'd0;

    //------------------------------------------------------------------------
    // AXI-Stream Backpressure Handling
    //------------------------------------------------------------------------
    // LEARNING NOTE: Backpressure means the downstream module is not ready.
    // When m_axis_tready is low, we must NOT advance our state or drop data.
    // We accept new input only when we can output.

    wire output_handshake = m_axis_tvalid && m_axis_tready;
    wire input_handshake  = s_axis_tvalid && s_axis_tready;

    // Accept input when idle, or when forwarding and output is consumed
    assign s_axis_tready = (state == ST_IDLE) ||
                           (state == ST_FORWARDING && m_axis_tready);

    //------------------------------------------------------------------------
    // State Machine Logic
    //------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            m_axis_tvalid  <= 1'b0;
            m_axis_tdata   <= {`AXIS_DATA_WIDTH{1'b0}};
            m_axis_tkeep   <= {`AXIS_KEEP_WIDTH{1'b0}};
            m_axis_tuser   <= {`AXIS_USER_WIDTH{1'b0}};
            m_axis_tlast   <= 1'b0;
            first_beat_data <= {`AXIS_DATA_WIDTH{1'b0}};
            first_beat_keep <= {`AXIS_KEEP_WIDTH{1'b0}};
            first_beat_last <= 1'b0;
            parsed_metadata <= {`AXIS_USER_WIDTH{1'b0}};
        end else begin
            case (state)
                // ── IDLE: Wait for start of a new packet ──────────────
                ST_IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    if (s_axis_tvalid) begin
                        // Latch the first beat and parse headers
                        first_beat_data <= s_axis_tdata;
                        first_beat_keep <= s_axis_tkeep;
                        first_beat_last <= s_axis_tlast;
                        parsed_metadata <= metadata;
                        state <= ST_FIRST_BEAT;
                    end
                end

                // ── FIRST_BEAT: Output the first beat with metadata ───
                ST_FIRST_BEAT: begin
                    m_axis_tdata  <= first_beat_data;
                    m_axis_tkeep  <= first_beat_keep;
                    m_axis_tuser  <= parsed_metadata;
                    m_axis_tvalid <= 1'b1;
                    m_axis_tlast  <= first_beat_last;

                    if (output_handshake) begin
                        if (first_beat_last) begin
                            // Single-beat packet — done
                            state <= ST_IDLE;
                            m_axis_tvalid <= 1'b0;
                        end else begin
                            // Multi-beat packet — forward remaining beats
                            state <= ST_FORWARDING;
                        end
                    end
                end

                // ── FORWARDING: Pass through remaining beats ──────────
                ST_FORWARDING: begin
                    if (input_handshake) begin
                        m_axis_tdata  <= s_axis_tdata;
                        m_axis_tkeep  <= s_axis_tkeep;
                        m_axis_tuser  <= parsed_metadata;  // Same metadata for all beats
                        m_axis_tvalid <= 1'b1;
                        m_axis_tlast  <= s_axis_tlast;
                    end

                    if (output_handshake && m_axis_tlast) begin
                        // Last beat consumed — back to idle
                        state <= ST_IDLE;
                        m_axis_tvalid <= 1'b0;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
