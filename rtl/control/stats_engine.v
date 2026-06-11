//============================================================================
// Module: Statistics Engine (stats_engine.v)
//============================================================================
// Centralized, passive observer module that counts critical datapath events.
// Maintains 64-bit counters to prevent rapid overflow at 100 Gbps.
// Connects to axilite_csr.v for host-CPU monitoring.
//============================================================================

`timescale 1ns / 1ps

module stats_engine (
    input  wire         clk,
    input  wire         rst_n,

    // ── Datapath Event Snooping ───────────────────────────────────────────
    input  wire         event_rx_pkt,       // Pulse from Parser
    input  wire [15:0]  event_rx_bytes,     // From Parser (valid with event_rx_pkt)
    input  wire         event_tx_pkt,       // Pulse from Egress Scheduler
    
    input  wire [3:0]   event_enq_pkt,      // Pulse bitmask from Queue Manager
    input  wire [3:0]   event_drop_pkt,     // Pulse bitmask from Queue Manager
    input  wire [3:0]   event_deq_pkt,      // Pulse bitmask from QoS Scheduler

    // ── CSR Read Interface ────────────────────────────────────────────────
    input  wire         stat_rd_en,
    input  wire [7:0]   stat_rd_addr,       // Word index (addr[9:2])
    output reg  [31:0]  stat_rd_data
);

    //------------------------------------------------------------------------
    // 64-bit Counter Storage
    //------------------------------------------------------------------------
    reg [63:0] cnt_rx_pkts;
    reg [63:0] cnt_rx_bytes;
    reg [63:0] cnt_tx_pkts;
    
    reg [63:0] cnt_enq_pkts [3:0];
    reg [63:0] cnt_drop_pkts [3:0];
    reg [63:0] cnt_deq_pkts [3:0];

    //------------------------------------------------------------------------
    // Counter Accumulation
    //------------------------------------------------------------------------
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            cnt_rx_pkts  <= 64'd0;
            cnt_rx_bytes <= 64'd0;
            cnt_tx_pkts  <= 64'd0;
            for (i = 0; i < 4; i = i + 1) begin
                cnt_enq_pkts[i]  <= 64'd0;
                cnt_drop_pkts[i] <= 64'd0;
                cnt_deq_pkts[i]  <= 64'd0;
            end
        end else begin
            // Global Rx/Tx
            if (event_rx_pkt) begin
                cnt_rx_pkts  <= cnt_rx_pkts + 1'b1;
                cnt_rx_bytes <= cnt_rx_bytes + event_rx_bytes;
            end
            if (event_tx_pkt) begin
                cnt_tx_pkts <= cnt_tx_pkts + 1'b1;
            end
            
            // Per-Queue Events
            for (i = 0; i < 4; i = i + 1) begin
                if (event_enq_pkt[i])  cnt_enq_pkts[i]  <= cnt_enq_pkts[i] + 1'b1;
                if (event_drop_pkt[i]) cnt_drop_pkts[i] <= cnt_drop_pkts[i] + 1'b1;
                if (event_deq_pkt[i])  cnt_deq_pkts[i]  <= cnt_deq_pkts[i] + 1'b1;
            end
        end
    end

    //------------------------------------------------------------------------
    // AXI-Lite Read Multiplexer
    //------------------------------------------------------------------------
    // Mapped to CSR Offset 0x300 - 0x3FF
    // Because addresses are byte-aligned, and counters are 64-bit (8 bytes),
    // each counter takes 2 words (Low Word, High Word).
    // stat_rd_addr is addr[9:2].
    // Base 0x300 -> stat_rd_addr = 0xC0 (192)
    
    // Address Map (Word Indices relative to base 0xC0):
    // 0x00: Rx Pkts Low
    // 0x01: Rx Pkts High
    // 0x02: Rx Bytes Low
    // 0x03: Rx Bytes High
    // 0x04: Tx Pkts Low
    // 0x05: Tx Pkts High
    
    // 0x10 - 0x17: Enqueued Pkts [0-3] (Low/High interleaved)
    // 0x18 - 0x1F: Dropped Pkts [0-3]
    // Pure combinational address decode — no enable gating.
    // The CSR module latches stat_rd_data on the cycle AFTER it sets
    // stat_rd_addr, so the mux must hold valid data whenever the
    // address lines are stable, regardless of stat_rd_en.
    always @(*) begin
        case (stat_rd_addr - 8'hC0)
            8'h00: stat_rd_data = cnt_rx_pkts[31:0];
            8'h01: stat_rd_data = cnt_rx_pkts[63:32];
            8'h02: stat_rd_data = cnt_rx_bytes[31:0];
            8'h03: stat_rd_data = cnt_rx_bytes[63:32];
            8'h04: stat_rd_data = cnt_tx_pkts[31:0];
            8'h05: stat_rd_data = cnt_tx_pkts[63:32];
            
            8'h10: stat_rd_data = cnt_enq_pkts[0][31:0];
            8'h11: stat_rd_data = cnt_enq_pkts[0][63:32];
            8'h12: stat_rd_data = cnt_enq_pkts[1][31:0];
            8'h13: stat_rd_data = cnt_enq_pkts[1][63:32];
            8'h14: stat_rd_data = cnt_enq_pkts[2][31:0];
            8'h15: stat_rd_data = cnt_enq_pkts[2][63:32];
            8'h16: stat_rd_data = cnt_enq_pkts[3][31:0];
            8'h17: stat_rd_data = cnt_enq_pkts[3][63:32];

            8'h18: stat_rd_data = cnt_drop_pkts[0][31:0];
            8'h19: stat_rd_data = cnt_drop_pkts[0][63:32];
            8'h1A: stat_rd_data = cnt_drop_pkts[1][31:0];
            8'h1B: stat_rd_data = cnt_drop_pkts[1][63:32];
            8'h1C: stat_rd_data = cnt_drop_pkts[2][31:0];
            8'h1D: stat_rd_data = cnt_drop_pkts[2][63:32];
            8'h1E: stat_rd_data = cnt_drop_pkts[3][31:0];
            8'h1F: stat_rd_data = cnt_drop_pkts[3][63:32];

            8'h20: stat_rd_data = cnt_deq_pkts[0][31:0];
            8'h21: stat_rd_data = cnt_deq_pkts[0][63:32];
            8'h22: stat_rd_data = cnt_deq_pkts[1][31:0];
            8'h23: stat_rd_data = cnt_deq_pkts[1][63:32];
            8'h24: stat_rd_data = cnt_deq_pkts[2][31:0];
            8'h25: stat_rd_data = cnt_deq_pkts[2][63:32];
            8'h26: stat_rd_data = cnt_deq_pkts[3][31:0];
            8'h27: stat_rd_data = cnt_deq_pkts[3][63:32];
            
            default: stat_rd_data = 32'hDEADBEEF;
        endcase
    end

endmodule
