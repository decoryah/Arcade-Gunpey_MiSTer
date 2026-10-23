//------------------------------------------------------------------------------
// The Gunpey board (MAME 0.289 gunpey.cpp, Banpresto 2000): the V30 and its work RAM, the Axell AG-1 (the blitter and the display), the
// YMZ280B and the OKI M6295. Everything in ROM, and the AG-1's 4 MB video RAM, is in the SDRAM, served to six clients in priority order:
//   0 the display's sprite rows   1 the program cache   2 the YMZ280B   3 the OKI   4 the blitter's ROM reads   5 its video RAM writes
// SDRAM word addresses (gunpey_loader.sv): program 0x000000 (the 1 MB region), graphics 0x080000 (gp_rom3), YMZ280B 0x280000 (gp_rom4),
// OKI 0x480000 (gp_rom5's first 2 MB), video RAM 0x800000 (4 MB).
//------------------------------------------------------------------------------
`default_nettype none

module gunpey_core (
    input  logic        clk,                // 85.8636 MHz
    input  logic        reset,
    input  logic        cache_flush,        // a new image is loading

    // the SDRAM's clients
    output logic        m_req   [6],
    output logic [23:0] m_addr  [6],
    output logic  [4:0] m_len   [6],
    output logic        m_we    [6],
    output logic [15:0] m_wdata [6],
    input  logic        m_ack   [6],
    input  logic        m_valid [6],
    input  logic        m_wpull [6],
    input  logic [15:0] m_rdata,

    // the inputs, as MAME's ports (active high)
    input  logic  [7:0] dsw1,
    input  logic  [7:0] dsw2,
    input  logic  [7:0] in_p1,
    input  logic  [7:0] in_p2,
    input  logic  [7:0] in_sys,

    // the picture
    output logic        ce_pix,
    output logic        hblank,
    output logic        vblank,
    output logic        vblank_next,
    output logic        hs,
    output logic        vs,
    output logic  [7:0] r,
    output logic  [7:0] g,
    output logic  [7:0] b,

    // the sound
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,

    // diagnostics
    output logic        dbg_frame,
    output logic [15:0] dbg_overruns,
    output logic  [9:0] dbg_sprites,
    output logic [12:0] dbg_line_clks,
    output logic        dbg_blt_error,
    output logic [19:0] dbg_addr,
    output logic        dbg_fetch,
    output logic        dbg_io_wr,
    output logic        dbg_io_rd,
    output logic [15:0] dbg_io_data,
    output logic  [1:0] dbg_io_be,
    output logic        dbg_inta,
    output logic        dbg_blt_start,
    output logic        dbg_blt_irq,
    output logic        dbg_vbl,
    output logic        dbg_cpu_ce
);
    localparam logic [23:0] PROG_BASE = 24'h000000, GFX_BASE = 24'h080000, YMZ_BASE = 24'h280000, OKI_BASE = 24'h480000,
                            VRAM_BASE = 24'h800000;

    // ------------------------------------------------------------------ the program cache
    logic        cache_ready, rom_req, rom_ack;
    logic [18:0] rom_addr;
    logic [15:0] rom_q;
    gunpey_cache #(.AW(19), .IDX(11), .BASE(PROG_BASE)) u_cache (
        .clk(clk), .reset(cache_flush), .ready(cache_ready),
        .req(rom_req), .addr(rom_addr), .ack(rom_ack), .q(rom_q),
        .m_req(m_req[1]), .m_addr(m_addr[1]), .m_len(m_len[1]), .m_ack(m_ack[1]), .m_valid(m_valid[1]), .m_data(m_rdata)
    );

    // ------------------------------------------------------------------ the CPU side
    logic [14:0]  v_wa;
    logic [15:0]  v_wq, vreg_addr, vram_bank;
    logic         freeze, vbl, blt_start, blt_irq, cpu_ce;
    logic [127:0] blt_regs;
    logic         ymz_wr, ymz_a0, oki_wr;
    logic  [7:0]  ymz_din, oki_din, oki_dout;
    logic  [2:0]  oki_bank;

    gunpey_main u_main (
        .clk(clk), .reset(reset), .rom_ready(cache_ready),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_q(rom_q),
        .v_addr(v_wa), .v_q(v_wq),
        .freeze(freeze), .vbl(vbl), .vreg_addr(vreg_addr), .vram_bank(vram_bank),
        .blt_start(blt_start), .blt_regs(blt_regs), .blt_irq(blt_irq), .cpu_ce(cpu_ce),
        .ymz_wr(ymz_wr), .ymz_a0(ymz_a0), .ymz_din(ymz_din),
        .oki_wr(oki_wr), .oki_din(oki_din), .oki_dout(oki_dout), .oki_bank(oki_bank),
        .dsw1(dsw1), .dsw2(dsw2), .in_p1(in_p1), .in_p2(in_p2), .in_sys(in_sys), .coin_counter(),
        .dbg_addr(dbg_addr), .dbg_fetch(dbg_fetch), .dbg_io_wr(dbg_io_wr), .dbg_io_rd(dbg_io_rd), .dbg_io_data(dbg_io_data),
        .dbg_io_be(dbg_io_be), .dbg_inta(dbg_inta)
    );
    assign dbg_blt_start = blt_start;
    assign dbg_blt_irq   = blt_irq;
    assign dbg_vbl       = vbl;
    assign dbg_cpu_ce    = cpu_ce;

    // ------------------------------------------------------------------ the AG-1
    logic        pal_we;
    logic [15:0] pal_addr, pal_data;

    gunpey_blitter #(.GFX_BASE(GFX_BASE), .VRAM_BASE(VRAM_BASE)) u_blit (
        .clk(clk), .reset(reset), .start(blt_start), .regs(blt_regs), .cpu_ce(cpu_ce), .busy(), .irq(blt_irq),
        .rd_req(m_req[4]), .rd_addr(m_addr[4]), .rd_len(m_len[4]), .rd_ack(m_ack[4]), .rd_valid(m_valid[4]), .rd_data(m_rdata),
        .wr_req(m_req[5]), .wr_addr(m_addr[5]), .wr_len(m_len[5]), .wr_ack(m_ack[5]), .wr_pull(m_wpull[5]), .wr_data(m_wdata[5]),
        .pal_we(pal_we), .pal_addr(pal_addr), .pal_data(pal_data), .dbg_error(dbg_blt_error), .dbg_idle()
    );

    gunpey_video #(.VRAM_BASE(VRAM_BASE)) u_video (
        .clk(clk), .reset(reset),
        .vreg_addr(vreg_addr), .vram_bank(vram_bank), .wram_addr(v_wa), .wram_q(v_wq), .freeze(freeze), .vbl(vbl),
        .pal_we(pal_we), .pal_addr(pal_addr), .pal_data(pal_data),
        .m_req(m_req[0]), .m_addr(m_addr[0]), .m_len(m_len[0]), .m_ack(m_ack[0]), .m_valid(m_valid[0]), .m_data(m_rdata),
        .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .vblank_next(vblank_next), .hs(hs), .vs(vs), .r(r), .g(g), .b(b),
        .dbg_overruns(dbg_overruns), .dbg_sprites(dbg_sprites), .dbg_line_clks(dbg_line_clks), .dbg_frame(dbg_frame)
    );

    // ------------------------------------------------------------------ the sound
    gunpey_sound #(.YMZ_BASE(YMZ_BASE), .OKI_BASE(OKI_BASE)) u_sound (
        .clk(clk), .reset(reset),
        .ymz_wr(ymz_wr), .ymz_a0(ymz_a0), .ymz_din(ymz_din),
        .oki_wr(oki_wr), .oki_din(oki_din), .oki_dout(oki_dout), .oki_bank(oki_bank),
        .y_req(m_req[2]), .y_addr(m_addr[2]), .y_ack(m_ack[2]), .y_valid(m_valid[2]),
        .o_req(m_req[3]), .o_addr(m_addr[3]), .o_ack(m_ack[3]), .o_valid(m_valid[3]), .sd_data(m_rdata),
        .out_l(audio_l), .out_r(audio_r)
    );

    // the clients' fixed fields
    assign m_len[2] = 5'd1;
    assign m_len[3] = 5'd1;
    always_comb begin
        for (int i = 0; i < 6; i++) begin m_we[i] = (i == 5); end
        for (int i = 0; i < 5; i++) m_wdata[i] = 16'h0000;
    end
endmodule
`default_nettype wire
