//============================================================================
// SmartNIC Top-Level Wrapper
//============================================================================
// Wraps all Tier 1, 2, and 3 modules into a single cohesive IP block.
// Interfaces:
//   - Network RX/TX (to CMAC)
//   - Host RX/TX (to QDMA)
//   - Control Plane (AXI4-Lite)
//============================================================================

`timescale 1ns / 1ps
`include "smartnic_pkg.vh"

module smartnic_top (
    input  wire         clk,
    input  wire         rst_n,

    // ── Control Plane Interface (AXI4-Lite) ───────────────────────────
    input  wire [31:0]  s_axi_awaddr,
    input  wire         s_axi_awvalid,
    output wire         s_axi_awready,
    input  wire [31:0]  s_axi_wdata,
    input  wire [3:0]   s_axi_wstrb,
    input  wire         s_axi_wvalid,
    output wire         s_axi_wready,
    output wire [1:0]   s_axi_bresp,
    output wire         s_axi_bvalid,
    input  wire         s_axi_bready,
    input  wire [31:0]  s_axi_araddr,
    input  wire         s_axi_arvalid,
    output wire         s_axi_arready,
    output wire [31:0]  s_axi_rdata,
    output wire [1:0]   s_axi_rresp,
    output wire         s_axi_rvalid,
    input  wire         s_axi_rready,

    // ── Network Interface (To/From CMAC MAC) ──────────────────────────
    // Network RX
    input  wire [`AXIS_DATA_WIDTH-1:0]  s_axis_net_rx_tdata,
    input  wire [`AXIS_KEEP_WIDTH-1:0]  s_axis_net_rx_tkeep,
    input  wire                         s_axis_net_rx_tvalid,
    input  wire                         s_axis_net_rx_tlast,
    // Network TX
    output wire [`AXIS_DATA_WIDTH-1:0]  m_axis_net_tx_tdata,
    output wire [`AXIS_KEEP_WIDTH-1:0]  m_axis_net_tx_tkeep,
    output wire                         m_axis_net_tx_tvalid,
    input  wire                         m_axis_net_tx_tready,
    output wire                         m_axis_net_tx_tlast,

    // ── Host Interface (To/From QDMA) ─────────────────────────────────
    // Host TX (H2C)
    input  wire [`AXIS_DATA_WIDTH-1:0]  s_axis_qdma_h2c_tdata,
    input  wire [`AXIS_KEEP_WIDTH-1:0]  s_axis_qdma_h2c_tkeep,
    input  wire                         s_axis_qdma_h2c_tvalid,
    output wire                         s_axis_qdma_h2c_tready,
    input  wire                         s_axis_qdma_h2c_tlast,
    input  wire [15:0]                  s_axis_qdma_h2c_tuser_mdata,
    input  wire [10:0]                  s_axis_qdma_h2c_tuser_qid,
    input  wire [2:0]                   s_axis_qdma_h2c_tuser_port_id,
    
    // Host RX (C2H Data)
    output wire [`AXIS_DATA_WIDTH-1:0]  m_axis_qdma_c2h_tdata,
    output wire [`AXIS_KEEP_WIDTH-1:0]  m_axis_qdma_c2h_tkeep,
    output wire                         m_axis_qdma_c2h_tvalid,
    input  wire                         m_axis_qdma_c2h_tready,
    output wire                         m_axis_qdma_c2h_tlast,
    output wire                         m_axis_qdma_c2h_ctrl_marker,
    output wire [2:0]                   m_axis_qdma_c2h_ctrl_port_id,
    output wire                         m_axis_qdma_c2h_ctrl_has_cmpt,

    // Host RX (C2H Completion)
    output wire [255:0]                 m_axis_qdma_cpl_tdata,
    output wire [1:0]                   m_axis_qdma_cpl_size,
    output wire                         m_axis_qdma_cpl_tvalid,
    input  wire                         m_axis_qdma_cpl_tready,
    output wire                         m_axis_qdma_cpl_ctrl_no_wrb_marker,
    output wire [2:0]                   m_axis_qdma_cpl_ctrl_col_idx,
    output wire [2:0]                   m_axis_qdma_cpl_ctrl_err_idx,
    output wire                         m_axis_qdma_cpl_ctrl_marker,
    output wire                         m_axis_qdma_cpl_ctrl_user_trig,
    output wire [2:0]                   m_axis_qdma_cpl_ctrl_port_id,
    output wire [1:0]                   m_axis_qdma_cpl_ctrl_cmpt_type
);

    //========================================================================
    // Internal Wires
    //========================================================================
    // Control Wires
    wire                             fc_cfg_wr_en;
    wire [`RULE_ID_WIDTH-1:0]        fc_cfg_rule_id;
    wire [31:0]                      fc_cfg_dst_ip, fc_cfg_dst_ip_mask;
    wire [15:0]                      fc_cfg_dst_port, fc_cfg_dst_port_mask;
    wire [7:0]                       fc_cfg_protocol, fc_cfg_protocol_mask;
    wire [`TUSER_SLICE_ID_WIDTH-1:0] fc_cfg_slice_id;
    wire                             fc_cfg_rule_enable;

    wire                             sch_cfg_wr_en;
    wire [`QUEUE_ID_WIDTH-1:0]       sch_cfg_queue_id;
    wire [1:0]                       sch_cfg_priority;
    wire                             sch_cfg_queue_enable;
    wire [31:0]                      sch_cfg_tb_rate, sch_cfg_tb_burst;
    wire                             sch_cfg_tb_enable;

    // Datapath Wires
    wire [`AXIS_DATA_WIDTH-1:0] w_p2c_tdata, w_c2q_tdata, w_q2s_tdata, w_s2b_tdata;
    wire [`AXIS_KEEP_WIDTH-1:0] w_p2c_tkeep, w_c2q_tkeep, w_q2s_tkeep, w_s2b_tkeep;
    wire [`AXIS_USER_WIDTH-1:0] w_p2c_tuser, w_c2q_tuser, w_q2s_tuser, w_s2b_tuser;
    wire                        w_p2c_tvalid, w_c2q_tvalid, w_q2s_tvalid, w_s2b_tvalid;
    wire                        w_p2c_tready, w_c2q_tready, w_q2s_tready, w_s2b_tready;
    wire                        w_p2c_tlast, w_c2q_tlast, w_q2s_tlast, w_s2b_tlast;

    wire [`NUM_QUEUES-1:0]      w_queue_empty, w_queue_full;
    wire                        w_deq_request;
    wire [`QUEUE_ID_WIDTH-1:0]  w_deq_queue_id;

    //========================================================================
    // 1. AXI-Lite CSR (Control Plane)
    //========================================================================
    axilite_csr u_csr (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        
        // Output Configs
        .fc_cfg_wr_en(fc_cfg_wr_en), .fc_cfg_rule_id(fc_cfg_rule_id), .fc_cfg_dst_ip(fc_cfg_dst_ip),
        .fc_cfg_dst_ip_mask(fc_cfg_dst_ip_mask), .fc_cfg_dst_port(fc_cfg_dst_port), .fc_cfg_dst_port_mask(fc_cfg_dst_port_mask),
        .fc_cfg_protocol(fc_cfg_protocol), .fc_cfg_protocol_mask(fc_cfg_protocol_mask), .fc_cfg_slice_id(fc_cfg_slice_id), .fc_cfg_rule_enable(fc_cfg_rule_enable),
        
        .sch_cfg_wr_en(sch_cfg_wr_en), .sch_cfg_queue_id(sch_cfg_queue_id), .sch_cfg_priority(sch_cfg_priority), .sch_cfg_queue_enable(sch_cfg_queue_enable),
        .sch_cfg_tb_rate(sch_cfg_tb_rate), .sch_cfg_tb_burst(sch_cfg_tb_burst), .sch_cfg_tb_enable(sch_cfg_tb_enable)
    );

    //========================================================================
    // 2. QDMA H2C Bridge (Host Ingress) -> Currently mapped direct to Parser
    //========================================================================
    wire [`AXIS_DATA_WIDTH-1:0] w_h2c_tdata;
    wire [`AXIS_KEEP_WIDTH-1:0] w_h2c_tkeep;
    wire [`AXIS_USER_WIDTH-1:0] w_h2c_tuser;
    wire                        w_h2c_tvalid, w_h2c_tready, w_h2c_tlast;

    qdma_h2c_bridge u_h2c_bridge (
        .clk(clk), .rst_n(rst_n),
        .s_axis_qdma_h2c_tdata(s_axis_qdma_h2c_tdata), .s_axis_qdma_h2c_tkeep(s_axis_qdma_h2c_tkeep),
        .s_axis_qdma_h2c_tvalid(s_axis_qdma_h2c_tvalid), .s_axis_qdma_h2c_tready(s_axis_qdma_h2c_tready), .s_axis_qdma_h2c_tlast(s_axis_qdma_h2c_tlast),
        .s_axis_qdma_h2c_tuser_mdata(s_axis_qdma_h2c_tuser_mdata), .s_axis_qdma_h2c_tuser_qid(s_axis_qdma_h2c_tuser_qid), .s_axis_qdma_h2c_tuser_port_id(s_axis_qdma_h2c_tuser_port_id),
        .m_axis_tdata(w_h2c_tdata), .m_axis_tkeep(w_h2c_tkeep), .m_axis_tuser(w_h2c_tuser), .m_axis_tvalid(w_h2c_tvalid), .m_axis_tready(w_h2c_tready), .m_axis_tlast(w_h2c_tlast)
    );

    // Note: For MVP, we route Host traffic directly into the parser.
    // Network RX traffic is currently dropped unless multiplexed here.

    //========================================================================
    // 3. Packet Parser
    //========================================================================
    packet_parser u_parser (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(w_h2c_tdata), .s_axis_tkeep(w_h2c_tkeep), .s_axis_tuser(w_h2c_tuser), .s_axis_tvalid(w_h2c_tvalid), .s_axis_tready(w_h2c_tready), .s_axis_tlast(w_h2c_tlast),
        .m_axis_tdata(w_p2c_tdata), .m_axis_tkeep(w_p2c_tkeep), .m_axis_tuser(w_p2c_tuser), .m_axis_tvalid(w_p2c_tvalid), .m_axis_tready(w_p2c_tready), .m_axis_tlast(w_p2c_tlast)
    );

    //========================================================================
    // 4. Flow Classifier
    //========================================================================
    flow_classifier u_classifier (
        .clk(clk), .rst_n(rst_n),
        .cfg_wr_en(fc_cfg_wr_en), .cfg_rule_id(fc_cfg_rule_id), .cfg_dst_ip(fc_cfg_dst_ip), .cfg_dst_ip_mask(fc_cfg_dst_ip_mask),
        .cfg_dst_port(fc_cfg_dst_port), .cfg_dst_port_mask(fc_cfg_dst_port_mask), .cfg_protocol(fc_cfg_protocol), .cfg_protocol_mask(fc_cfg_protocol_mask),
        .cfg_slice_id(fc_cfg_slice_id), .cfg_rule_enable(fc_cfg_rule_enable),
        .s_axis_tdata(w_p2c_tdata), .s_axis_tkeep(w_p2c_tkeep), .s_axis_tuser(w_p2c_tuser), .s_axis_tvalid(w_p2c_tvalid), .s_axis_tready(w_p2c_tready), .s_axis_tlast(w_p2c_tlast),
        .m_axis_tdata(w_c2q_tdata), .m_axis_tkeep(w_c2q_tkeep), .m_axis_tuser(w_c2q_tuser), .m_axis_tvalid(w_c2q_tvalid), .m_axis_tready(w_c2q_tready), .m_axis_tlast(w_c2q_tlast)
    );

    //========================================================================
    // 5. Queue Manager
    //========================================================================
    queue_manager u_queue (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(w_c2q_tdata), .s_axis_tkeep(w_c2q_tkeep), .s_axis_tuser(w_c2q_tuser), .s_axis_tvalid(w_c2q_tvalid), .s_axis_tready(w_c2q_tready), .s_axis_tlast(w_c2q_tlast),
        .m_axis_tdata(w_q2s_tdata), .m_axis_tkeep(w_q2s_tkeep), .m_axis_tuser(w_q2s_tuser), .m_axis_tvalid(w_q2s_tvalid), .m_axis_tready(w_q2s_tready), .m_axis_tlast(w_q2s_tlast),
        .deq_request(w_deq_request), .deq_queue_id(w_deq_queue_id), .queue_empty(w_queue_empty), .queue_full(w_queue_full)
    );

    //========================================================================
    // 6. Priority Scheduler
    //========================================================================
    priority_scheduler u_scheduler (
        .clk(clk), .rst_n(rst_n),
        .cfg_wr_en(sch_cfg_wr_en), .cfg_queue_id(sch_cfg_queue_id), .cfg_priority(sch_cfg_priority), .cfg_queue_enable(sch_cfg_queue_enable),
        .cfg_tb_rate(sch_cfg_tb_rate), .cfg_tb_burst(sch_cfg_tb_burst), .cfg_tb_enable(sch_cfg_tb_enable),
        .queue_empty(w_queue_empty), .queue_full(w_queue_full), .deq_request(w_deq_request), .deq_queue_id(w_deq_queue_id),
        .qm_axis_tdata(w_q2s_tdata), .qm_axis_tkeep(w_q2s_tkeep), .qm_axis_tuser(w_q2s_tuser), .qm_axis_tvalid(w_q2s_tvalid), .qm_axis_tready(w_q2s_tready), .qm_axis_tlast(w_q2s_tlast),
        .m_axis_tdata(w_s2b_tdata), .m_axis_tkeep(w_s2b_tkeep), .m_axis_tuser(w_s2b_tuser), .m_axis_tvalid(w_s2b_tvalid), .m_axis_tready(w_s2b_tready), .m_axis_tlast(w_s2b_tlast)
    );

    //========================================================================
    // 7. QDMA C2H Bridge (Host Egress)
    //========================================================================
    qdma_c2h_bridge u_c2h_bridge (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(w_s2b_tdata), .s_axis_tkeep(w_s2b_tkeep), .s_axis_tuser(w_s2b_tuser), .s_axis_tvalid(w_s2b_tvalid), .s_axis_tready(w_s2b_tready), .s_axis_tlast(w_s2b_tlast),
        
        .m_axis_qdma_c2h_tdata(m_axis_qdma_c2h_tdata), .m_axis_qdma_c2h_tkeep(m_axis_qdma_c2h_tkeep), .m_axis_qdma_c2h_tvalid(m_axis_qdma_c2h_tvalid), .m_axis_qdma_c2h_tready(m_axis_qdma_c2h_tready), .m_axis_qdma_c2h_tlast(m_axis_qdma_c2h_tlast),
        .m_axis_qdma_c2h_ctrl_marker(m_axis_qdma_c2h_ctrl_marker), .m_axis_qdma_c2h_ctrl_port_id(m_axis_qdma_c2h_ctrl_port_id), .m_axis_qdma_c2h_ctrl_has_cmpt(m_axis_qdma_c2h_ctrl_has_cmpt),
        
        .m_axis_qdma_cpl_tdata(m_axis_qdma_cpl_tdata), .m_axis_qdma_cpl_size(m_axis_qdma_cpl_size), .m_axis_qdma_cpl_tvalid(m_axis_qdma_cpl_tvalid), .m_axis_qdma_cpl_tready(m_axis_qdma_cpl_tready),
        .m_axis_qdma_cpl_ctrl_no_wrb_marker(m_axis_qdma_cpl_ctrl_no_wrb_marker), .m_axis_qdma_cpl_ctrl_col_idx(m_axis_qdma_cpl_ctrl_col_idx), .m_axis_qdma_cpl_ctrl_err_idx(m_axis_qdma_cpl_ctrl_err_idx), .m_axis_qdma_cpl_ctrl_marker(m_axis_qdma_cpl_ctrl_marker), .m_axis_qdma_cpl_ctrl_user_trig(m_axis_qdma_cpl_ctrl_user_trig), .m_axis_qdma_cpl_ctrl_port_id(m_axis_qdma_cpl_ctrl_port_id), .m_axis_qdma_cpl_ctrl_cmpt_type(m_axis_qdma_cpl_ctrl_cmpt_type)
    );

endmodule
