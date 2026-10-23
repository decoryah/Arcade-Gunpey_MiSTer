// The blitter bench's top: rtl/gunpey_blitter.sv on the SDRAM controller (its ROM read and video RAM write clients) and the SDRAM model.
// The C++ driver (tb_blit.cpp) loads the model's store, starts the logged blits and compares the video RAM with MAME's.
`default_nettype none
module tb_blit_top (
    input  logic         clk,
    input  logic         reset,
    input  logic         start,
    input  logic [127:0] regs,
    input  logic         cpu_ce,
    output logic         busy,
    output logic         irq,
    output logic         idle,
    output logic         ready,
    output logic         error,
    output logic         pal_we,
    output logic  [15:0] pal_addr,
    output logic  [15:0] pal_data
);
    wire [12:0] A; wire [1:0] BA; wire [15:0] DQ; wire DQML, DQMH, nCS, nRAS, nCAS, nWE, CKE;

    logic        c_req [2], c_ack [2], c_valid [2], c_we [2], c_wpull [2];
    logic [23:0] c_addr [2];
    logic  [4:0] c_len [2];
    logic [15:0] c_wdata [2];
    logic [15:0] rdata;

    gunpey_sdram #(.P_SHORT_INIT(1'b1), .NC(2)) u_sdram (
        .clk(clk), .rst_n(!reset), .o_ready(ready), .i_rd_late(1'b0),
        .i_dl_wr(1'b0), .i_dl_addr('0), .i_dl_data('0), .o_dl_busy(), .o_dl_idle(),
        .c_req(c_req), .c_addr(c_addr), .c_len(c_len), .c_we(c_we), .c_wdata(c_wdata),
        .c_ack(c_ack), .c_valid(c_valid), .c_wpull(c_wpull), .o_rdata(rdata),
        .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_DQ(DQ), .SDRAM_DQML(DQML), .SDRAM_DQMH(DQMH),
        .SDRAM_nCS(nCS), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nWE(nWE), .SDRAM_CKE(CKE)
    );
    sdram_model u_model (.clk(clk), .A(A), .BA(BA), .DQ(DQ), .DQML(DQML), .DQMH(DQMH), .nCS(nCS), .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .CKE(CKE));

    assign c_we[0] = 1'b0; assign c_wdata[0] = '0;
    assign c_we[1] = 1'b1;
    gunpey_blitter u_blit (
        .clk(clk), .reset(reset || !ready), .start(start), .regs(regs), .cpu_ce(cpu_ce), .busy(busy), .irq(irq),
        .rd_req(c_req[0]), .rd_addr(c_addr[0]), .rd_len(c_len[0]), .rd_ack(c_ack[0]), .rd_valid(c_valid[0]), .rd_data(rdata),
        .wr_req(c_req[1]), .wr_addr(c_addr[1]), .wr_len(c_len[1]), .wr_ack(c_ack[1]), .wr_pull(c_wpull[1]), .wr_data(c_wdata[1]),
        .pal_we(pal_we), .pal_addr(pal_addr), .pal_data(pal_data), .dbg_error(error), .dbg_idle(idle)
    );
endmodule
`default_nettype wire
