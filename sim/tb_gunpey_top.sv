// The system bench's top: rtl/gunpey_core.sv on the SDRAM controller and the SDRAM model (loaded by the C++ driver, tb_gunpey.cpp).
`default_nettype none
module tb_gunpey_top (
    input  logic        clk,
    input  logic        reset,
    input  logic  [7:0] dsw1,
    input  logic  [7:0] dsw2,
    input  logic  [7:0] in_p1,
    input  logic  [7:0] in_p2,
    input  logic  [7:0] in_sys,
    output logic        ready,
    output logic        ce_pix,
    output logic        hblank,
    output logic        vblank,
    output logic  [7:0] r,
    output logic  [7:0] g,
    output logic  [7:0] b,
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic        frame,
    output logic [15:0] overruns,
    output logic  [9:0] sprites,
    output logic [12:0] line_clks,
    output logic        blt_error,
    output logic [19:0] dbg_addr,
    output logic        dbg_fetch,
    output logic        dbg_io_wr,
    output logic        dbg_io_rd,
    output logic [15:0] dbg_io_data,
    output logic  [1:0] dbg_io_be,
    output logic        dbg_inta,
    output logic        dbg_blt_start,
    output logic        dbg_blt_irq,
    output logic        cpu_ce
);
    wire [12:0] A; wire [1:0] BA; wire [15:0] DQ; wire DQML, DQMH, nCS, nRAS, nCAS, nWE, CKE;
    logic        c_req [6], c_ack [6], c_valid [6], c_we [6], c_wpull [6];
    logic [23:0] c_addr [6];
    logic  [4:0] c_len [6];
    logic [15:0] c_wdata [6];
    logic [15:0] rdata;

    gunpey_sdram #(.P_SHORT_INIT(1'b1), .NC(6)) u_sdram (
        .clk(clk), .rst_n(!reset), .o_ready(ready), .i_rd_late(1'b0),
        .i_dl_wr(1'b0), .i_dl_addr('0), .i_dl_data('0), .o_dl_busy(), .o_dl_idle(),
        .c_req(c_req), .c_addr(c_addr), .c_len(c_len), .c_we(c_we), .c_wdata(c_wdata),
        .c_ack(c_ack), .c_valid(c_valid), .c_wpull(c_wpull), .o_rdata(rdata),
        .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_DQ(DQ), .SDRAM_DQML(DQML), .SDRAM_DQMH(DQMH),
        .SDRAM_nCS(nCS), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nWE(nWE), .SDRAM_CKE(CKE)
    );
    sdram_model u_model (.clk(clk), .A(A), .BA(BA), .DQ(DQ), .DQML(DQML), .DQMH(DQMH), .nCS(nCS), .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .CKE(CKE));

    logic mreset;
    always_ff @(posedge clk) mreset <= reset || !ready;

    gunpey_core u_core (
        .clk(clk), .reset(mreset), .cache_flush(reset),
        .m_req(c_req), .m_addr(c_addr), .m_len(c_len), .m_we(c_we), .m_wdata(c_wdata),
        .m_ack(c_ack), .m_valid(c_valid), .m_wpull(c_wpull), .m_rdata(rdata),
        .dsw1(dsw1), .dsw2(dsw2), .in_p1(in_p1), .in_p2(in_p2), .in_sys(in_sys),
        .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .vblank_next(), .hs(), .vs(), .r(r), .g(g), .b(b),
        .audio_l(audio_l), .audio_r(audio_r),
        .dbg_frame(frame), .dbg_overruns(overruns), .dbg_sprites(sprites), .dbg_line_clks(line_clks), .dbg_blt_error(blt_error),
        .dbg_addr(dbg_addr), .dbg_fetch(dbg_fetch), .dbg_io_wr(dbg_io_wr), .dbg_io_rd(dbg_io_rd), .dbg_io_data(dbg_io_data),
        .dbg_io_be(dbg_io_be), .dbg_inta(dbg_inta), .dbg_blt_start(dbg_blt_start), .dbg_blt_irq(dbg_blt_irq), .dbg_vbl(), .dbg_cpu_ce(cpu_ce)
    );
endmodule
`default_nettype wire
