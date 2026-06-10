//============================================================================
// AXI-Stream Synchronous FIFO
//============================================================================
// A parameterized synchronous FIFO with full AXI4-Stream handshaking.
// This is the fundamental building block for buffering between pipeline
// stages in the SmartNIC datapath.
//
// LEARNING NOTES:
// ─────────────────────────────────────────────────────────────────────────
// AXI-Stream Handshaking Rules:
//   1. TVALID is asserted by the source when data is available
//   2. TREADY is asserted by the sink when it can accept data
//   3. A transfer occurs ONLY when BOTH TVALID && TREADY are high
//   4. TVALID must NOT depend on TREADY (no combinational loops!)
//   5. TLAST marks the final beat of a packet
//   6. TKEEP indicates which bytes of TDATA are valid (bit-per-byte)
//
// FIFO Architecture:
//   - Uses a simple dual-pointer circular buffer in register array
//   - Write pointer (wr_ptr) advances on successful enqueue
//   - Read pointer (rd_ptr) advances on successful dequeue
//   - Full when wr_ptr + 1 == rd_ptr
//   - Empty when wr_ptr == rd_ptr
//============================================================================

`include "smartnic_pkg.vh"

module axi_stream_fifo #(
    parameter DATA_WIDTH = `AXIS_DATA_WIDTH,   // Width of TDATA (default 512)
    parameter KEEP_WIDTH = DATA_WIDTH / 8,     // Width of TKEEP
    parameter USER_WIDTH = `AXIS_USER_WIDTH,   // Width of TUSER (default 128)
    parameter FIFO_DEPTH = 16,                 // Number of entries (must be power of 2)
    parameter ADDR_WIDTH = $clog2(FIFO_DEPTH)  // Pointer width (auto-calculated)
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // ── AXI-Stream Slave (Input) ──────────────────────────────────────
    input  wire [DATA_WIDTH-1:0]    s_axis_tdata,
    input  wire [KEEP_WIDTH-1:0]    s_axis_tkeep,
    input  wire [USER_WIDTH-1:0]    s_axis_tuser,
    input  wire                     s_axis_tvalid,
    output wire                     s_axis_tready,
    input  wire                     s_axis_tlast,

    // ── AXI-Stream Master (Output) ────────────────────────────────────
    output wire [DATA_WIDTH-1:0]    m_axis_tdata,
    output wire [KEEP_WIDTH-1:0]    m_axis_tkeep,
    output wire [USER_WIDTH-1:0]    m_axis_tuser,
    output wire                     m_axis_tvalid,
    input  wire                     m_axis_tready,
    output wire                     m_axis_tlast,

    // ── Status Outputs ────────────────────────────────────────────────
    output wire [ADDR_WIDTH:0]      fill_level,  // Current number of entries
    output wire                     full,
    output wire                     empty
);

    //------------------------------------------------------------------------
    // Internal Storage
    //------------------------------------------------------------------------
    // LEARNING NOTE: In a real FPGA, these would map to Block RAM (BRAM)
    // or distributed RAM depending on depth and synthesis tool decisions.
    // For simulation, register arrays work perfectly.

    // Total width of one FIFO entry: TDATA + TKEEP + TUSER + TLAST
    localparam ENTRY_WIDTH = DATA_WIDTH + KEEP_WIDTH + USER_WIDTH + 1;

    reg [ENTRY_WIDTH-1:0] mem [0:FIFO_DEPTH-1];

    //------------------------------------------------------------------------
    // Pointers & Counter
    //------------------------------------------------------------------------
    // Using an extra bit for full/empty detection:
    //   - If wr_ptr[ADDR_WIDTH-1:0] == rd_ptr[ADDR_WIDTH-1:0] but MSBs differ → FULL
    //   - If wr_ptr == rd_ptr exactly → EMPTY

    reg [ADDR_WIDTH:0] wr_ptr;  // Write pointer (one extra bit)
    reg [ADDR_WIDTH:0] rd_ptr;  // Read pointer (one extra bit)

    wire [ADDR_WIDTH-1:0] wr_addr = wr_ptr[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] rd_addr = rd_ptr[ADDR_WIDTH-1:0];

    //------------------------------------------------------------------------
    // Status Signals
    //------------------------------------------------------------------------
    assign full  = (wr_ptr[ADDR_WIDTH] != rd_ptr[ADDR_WIDTH]) &&
                   (wr_addr == rd_addr);
    assign empty = (wr_ptr == rd_ptr);
    assign fill_level = wr_ptr - rd_ptr;

    //------------------------------------------------------------------------
    // AXI-Stream Handshaking
    //------------------------------------------------------------------------
    // We can accept data when not full
    assign s_axis_tready = ~full;

    // We have valid data when not empty
    assign m_axis_tvalid = ~empty;

    //------------------------------------------------------------------------
    // Write Logic (Enqueue)
    //------------------------------------------------------------------------
    wire write_en = s_axis_tvalid && s_axis_tready;

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= {(ADDR_WIDTH+1){1'b0}};
        end else if (write_en) begin
            // Pack all signals into one wide entry
            mem[wr_addr] <= {s_axis_tlast, s_axis_tuser, s_axis_tkeep, s_axis_tdata};
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    //------------------------------------------------------------------------
    // Read Logic (Dequeue)
    //------------------------------------------------------------------------
    wire read_en = m_axis_tvalid && m_axis_tready;

    // Unpack the stored entry into output signals
    // LEARNING NOTE: We read combinationally from the memory (like a
    // distributed RAM read). The data appears at the output the same
    // cycle it becomes available. This is a "first-word-fall-through"
    // (FWFT) FIFO style, which is ideal for AXI-Stream.
    wire [ENTRY_WIDTH-1:0] rd_data = mem[rd_addr];

    assign m_axis_tdata = rd_data[DATA_WIDTH-1:0];
    assign m_axis_tkeep = rd_data[DATA_WIDTH +: KEEP_WIDTH];
    assign m_axis_tuser = rd_data[(DATA_WIDTH + KEEP_WIDTH) +: USER_WIDTH];
    assign m_axis_tlast = rd_data[ENTRY_WIDTH-1];

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_ptr <= {(ADDR_WIDTH+1){1'b0}};
        end else if (read_en) begin
            rd_ptr <= rd_ptr + 1'b1;
        end
    end

endmodule
