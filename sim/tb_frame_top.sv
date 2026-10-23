// The frame bench's top: rtl/gunpey_video.sv with the work RAM (a block RAM the C++ driver loads), the SDRAM controller (the video's
// read client) and the SDRAM model (the video RAM, loaded by the driver).
`default_nettype none
module tb_frame_top (
    input  logic        clk,
    input  logic        reset,
    input  logic [15:0] vreg_addr,
    input  logic [15:0] vram_bank,
    input  logic  [7:0] vctrl,
    input  logic        pal_we,
    input  logic [15:0] pal_addr,
    input  logic [15:0] pal_data,
    input  logic        wr_we,              // the driver's work RAM writes
    input  logic [14:0] wr_addr,
    input  logic [15:0] wr_data,
    output logic        ready,
    output logic        vbl,
    output logic        freeze,
    output logic        ce_pix,
    output logic        hblank,
    output logic        vblank,
    output logic  [7:0] r,
    output logic  [7:0] g,
    output logic  [7:0] b,
    output logic [15:0] overruns,
    output logic  [9:0] sprites,
    output logic [12:0] line_clks
);
    wire [12:0] A; wire [1:0] BA; wire [15:0] DQ; wire DQML, DQMH, nCS, nRAS, nCAS, nWE, CKE;
    logic        c_req [1], c_ack [1], c_valid [1], c_we [1], c_wpull [1];
    logic [23:0] c_addr [1];
    logic  [4:0] c_len [1];
    logic [15:0] c_wdata [1];
    logic [15:0] rdata;
    assign c_we[0] = 1'b0; assign c_wdata[0] = '0;

    gunpey_sdram #(.P_SHORT_INIT(1'b1), .NC(1)) u_sdram (
        .clk(clk), .rst_n(!reset), .o_ready(ready), .i_rd_late(1'b0),
        .i_dl_wr(1'b0), .i_dl_addr('0), .i_dl_data('0), .o_dl_busy(), .o_dl_idle(),
        .c_req(c_req), .c_addr(c_addr), .c_len(c_len), .c_we(c_we), .c_wdata(c_wdata),
        .c_ack(c_ack), .c_valid(c_valid), .c_wpull(c_wpull), .o_rdata(rdata),
        .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_DQ(DQ), .SDRAM_DQML(DQML), .SDRAM_DQMH(DQMH),
        .SDRAM_nCS(nCS), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nWE(nWE), .SDRAM_CKE(CKE)
    );
    sdram_model u_model (.clk(clk), .A(A), .BA(BA), .DQ(DQ), .DQML(DQML), .DQMH(DQMH), .nCS(nCS), .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .CKE(CKE));

    logic [15:0] wram [32768];
    logic [14:0] v_wa;
    logic [15:0] v_wq;
    always_ff @(posedge clk) begin
        if (wr_we) wram[wr_addr] <= wr_data;
        v_wq <= wram[v_wa];
    end

    gunpey_video u_video (
        .clk(clk), .reset(reset || !ready),
        .vreg_addr(vreg_addr), .vram_bank(vram_bank), .vctrl(vctrl), .wram_addr(v_wa), .wram_q(v_wq), .freeze(freeze), .vbl(vbl),
        .pal_we(pal_we), .pal_addr(pal_addr), .pal_data(pal_data),
        .m_req(c_req[0]), .m_addr(c_addr[0]), .m_len(c_len[0]), .m_ack(c_ack[0]), .m_valid(c_valid[0]), .m_data(rdata),
        .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .vblank_next(), .hs(), .vs(), .r(r), .g(g), .b(b),
        .dbg_overruns(overruns), .dbg_sprites(sprites), .dbg_line_clks(line_clks), .dbg_frame()
    );
endmodule
`default_nettype wire
