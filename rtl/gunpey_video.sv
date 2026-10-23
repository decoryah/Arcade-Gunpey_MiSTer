//------------------------------------------------------------------------------
// The AG-1's display (MAME 0.289 gunpey.cpp screen_update / draw_gfx): the raster, the vblank interrupt, and the sprites.
//
// The raster is MAME's: a dot every 12 clocks (7.1553 MHz at 85.86 MHz), 442 dots a line, 264 lines, 320 x 240 visible; MAME starts the
// machine at the start of vblank (line 240), and so does this one coming out of reset (the first vblank comes a frame later).
//
// MAME draws a frame at the start of vblank from the display list in the CPU's work RAM: up to 64 scenes of 8 words from vreg_addr,
// each pointing (with vram_bank) to up to 256 sprites of 8 words; a sprite reads 4 or 8 bit pixels from the video RAM, zoomed, through
// a 256 or 16 colour palette that is itself in the video RAM (rows 0-255), with the scene's darkening and the sprite's alpha. Here the
// list is copied at the start of line 240 (the CPU is held meanwhile, so the copy is MAME's instant: the game's vblank handler switches
// vram_bank a few lines later), with each drawable sprite's geometry worked out (the zoom steps by division), and the picture is drawn a
// line at a time during the frame that follows, into a line buffer while the line before is shown: the sprites of each line in the
// list's order, their pixels from the video RAM (an SDRAM row fetch a sprite) and their colours from the palette mirror (block RAM,
// kept by the blitter). The game never writes the video RAM the shown frame reads after the frame's start (checked over 70000 frames
// of MAME), so drawing during the frame gives MAME's picture.
//
// The flip (the AG-1's "built-in flip", which MAME does not have): the game writes 7FF0 every frame, 0x84, or 0xE4 with the Flip Screen
// DIP on, and changes nothing else. Bit 5 here mirrors the picture left to right (the line buffer is shown from its end), bit 6 top to
// bottom (screen line y is drawn from the list's line 239 - y); which bit is which axis is a guess, as the game only ever sets both.
// They are taken at the start of line 240, between the last line shown and the first one drawn of the next frame.
//------------------------------------------------------------------------------
`default_nettype none

module gunpey_video #(
    parameter logic [23:0] VRAM_BASE = 24'h800000,
    parameter int          MAXSPR    = 512
) (
    input  logic        clk,
    input  logic        reset,

    // the registers (as the CPU writes them) and the work RAM's second port (its word comes the clock after the address)
    input  logic [15:0] vreg_addr,
    input  logic [15:0] vram_bank,
    input  logic  [7:0] vctrl,              // 7FF0: bit 5 the horizontal flip, bit 6 the vertical
    output logic [14:0] wram_addr,
    input  logic [15:0] wram_q,
    output logic        freeze,             // hold the CPU (the list copy)
    output logic        vbl,                // one clock at the start of line 240

    // the palette mirror's write port (the blitter)
    input  logic        pal_we,
    input  logic [15:0] pal_addr,
    input  logic [15:0] pal_data,

    // the SDRAM read client (sprite rows)
    output logic        m_req,
    output logic [23:0] m_addr,
    output logic  [4:0] m_len,
    input  logic        m_ack,
    input  logic        m_valid,
    input  logic [15:0] m_data,

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

    output logic [15:0] dbg_overruns,       // lines whose drawing was not done in time
    output logic  [9:0] dbg_sprites,        // the last list's drawable sprites
    output logic [12:0] dbg_line_clks,      // the longest line's drawing time (clocks) since the last vblank
    output logic        dbg_frame           // one clock a frame
);
    // ================================================================== the raster
    localparam int HTOTAL = 442, VTOTAL = 264, HVIS = 320, VVIS = 240;
    localparam int HS_START = 344, HS_END = 376, VS_START = 244, VS_END = 247;

    logic [3:0] div;
    logic [8:0] hc, vc;
    logic       started;                      // the first line (240) after reset has passed: MAME's first vblank is a frame later
    wire        line_start = (div == 4'd0) && (hc == 9'd0);
    always_ff @(posedge clk) begin
        if (reset) begin
            div <= 4'd0; hc <= 9'd0; vc <= 9'd240; started <= 1'b0;
        end else begin
            div <= (div == 4'd11) ? 4'd0 : div + 4'd1;
            if (div == 4'd11) begin
                started <= 1'b1;
                if (hc == 9'(HTOTAL - 1)) begin
                    hc <= 9'd0;
                    vc <= (vc == 9'(VTOTAL - 1)) ? 9'd0 : vc + 9'd1;
                end else hc <= hc + 9'd1;
            end
        end
    end
    assign vbl = !reset && started && line_start && (vc == 9'd240);
    assign dbg_frame = vbl;

    logic [1:0] flip;                         // {vertical, horizontal}, the frame's
    always_ff @(posedge clk) begin
        if (reset) flip <= '0;
        else if (vbl) flip <= vctrl[6:5];
    end

    // ================================================================== the list copy (line 240)
    // Each drawable sprite's entry in the table:
    //   [10:0] x  [21:11] y  [29:22] zoomed width  [37:30] zoomed height  [38] 8 bpp  [46:39] colour  [51:47] alpha
    //   [57:52] {darkening on, amount}  [68:58] source x  [79:69] source y  [102:80] width step  [125:103] height step (1.15)
    typedef enum logic [3:0] { L_IDLE, L_SC0, L_SC1, L_SC2, L_SC3, L_SP, L_SPW, L_DIV0, L_DIV, L_PUT, L_NEXT, L_SCN, L_END } lst_t;
    lst_t        lst;
    logic [15:0] vb_l;
    logic  [5:0] sc_i;                        // scene number
    logic [14:0] sc_base;
    logic [15:0] s0, s1;
    logic [16:0] cnt, cnt_end;                // the sprite list's word index (MAME's int count against its u16 end)
    logic [15:0] w [8];
    logic  [3:0] rk;
    logic  [9:0] n_spr;

    (* ramstyle = "M10K,no_rw_check" *) logic [125:0] tbl [MAXSPR];
    logic         tbl_we;
    logic   [8:0] tbl_wa, tbl_ra;
    logic [125:0] tbl_wd, tbl_q;
    always_ff @(posedge clk) begin
        if (tbl_we) tbl[tbl_wa] <= tbl_wd;
        tbl_q <= tbl[tbl_ra];
    end

    // the two dividers: (source size << 15) / zoomed size, a quotient bit a clock
    logic  [4:0] dv_n;
    logic  [8:0] dv_rw, dv_rh;
    logic [22:0] dv_qw, dv_qh, dv_aw, dv_ah;
    wire   [7:0] e_zw = w[5][7:0], e_zh = w[5][15:8];
    wire   [7:0] e_sw = w[6][7:0], e_sh = w[7][15:8];
    wire  [10:0] e_x  = 11'({w[4][1:0], w[3][15:8]}) - 11'h160;
    wire  [10:0] e_y  = 11'({w[4][5:4], w[4][15:8]}) - 11'h188;
    wire  [10:0] e_xs = {w[2][5:0], w[1][15:11]};
    wire  [10:0] e_ys = {w[3][4:0], w[2][15:10]};
    wire   [1:0] e_bs = w[0][4:3];
    wire         e_draw = !w[0][0] && (e_bs == 2'b00 || e_bs == 2'b10) && (e_zw != 8'd0) && (e_zh != 8'd0);

    // MAME: start_offs = (vram_bank + (s5 << 8)) / 2 and end_offs = (vram_bank + (s5 << 8) + 0x1000) / 2, ints kept as u16
    function automatic [15:0] list_offs(input [14:0] vb, input [15:0] s5, input [12:0] add);
        logic [24:0] sum;
        sum = 25'(vb) + {1'b0, s5, 8'd0} + 25'(add);
        list_offs = sum[16:1];
    endfunction

    always_ff @(posedge clk) begin
        tbl_we <= 1'b0;
        if (reset) begin
            lst <= L_IDLE; freeze <= 1'b0; n_spr <= '0;
        end else begin
            case (lst)
                L_IDLE: if (vbl) begin
                    vb_l <= vram_bank; n_spr <= '0; sc_i <= '0;
                    freeze <= 1'b1;
                    sc_base <= 15'(vreg_addr[14:1]);
                    lst <= (vreg_addr[15] && vram_bank[15]) ? L_SC0 : L_END;
                end
                // a scene: words 0, 1 and 5 (an address's word comes two clocks after the state that sets it)
                L_SC0: begin wram_addr <= sc_base;          lst <= L_SC1; end
                L_SC1: begin wram_addr <= sc_base + 15'd1;  lst <= L_SC2; end
                L_SC2: begin wram_addr <= sc_base + 15'd5;  s0 <= wram_q; lst <= L_SC3; end
                L_SC3: begin s1 <= wram_q; lst <= L_SP; end
                L_SP: begin
                    cnt     <= {1'b0, list_offs(vb_l[14:0], wram_q, 13'd0)};
                    cnt_end <= {1'b0, list_offs(vb_l[14:0], wram_q, 13'h1000)};
                    rk <= '0;
                    lst <= s0[0] ? L_SPW : L_SCN;
                end
                // a sprite's eight words
                L_SPW:
                    if (cnt >= cnt_end) lst <= L_SCN;
                    else begin
                        if (rk < 4'd8) wram_addr <= 15'(cnt) + 15'(rk);
                        if (rk >= 4'd2) w[rk - 4'd2] <= wram_q;
                        rk <= rk + 4'd1;
                        if (rk == 4'd9) lst <= L_DIV0;
                    end
                L_DIV0: begin
                    dv_aw <= {e_sw, 15'd0}; dv_ah <= {e_sh, 15'd0}; dv_rw <= '0; dv_rh <= '0; dv_n <= 5'd22;
                    lst <= e_draw ? L_DIV : L_NEXT;
                end
                L_DIV: begin : divstep
                    logic [8:0] tw, th;
                    tw = {dv_rw[7:0], dv_aw[22]};
                    th = {dv_rh[7:0], dv_ah[22]};
                    dv_aw <= {dv_aw[21:0], 1'b0};
                    dv_ah <= {dv_ah[21:0], 1'b0};
                    if (tw >= {1'b0, e_zw}) begin dv_rw <= tw - {1'b0, e_zw}; dv_qw <= {dv_qw[21:0], 1'b1}; end
                    else begin dv_rw <= tw; dv_qw <= {dv_qw[21:0], 1'b0}; end
                    if (th >= {1'b0, e_zh}) begin dv_rh <= th - {1'b0, e_zh}; dv_qh <= {dv_qh[21:0], 1'b1}; end
                    else begin dv_rh <= th; dv_qh <= {dv_qh[21:0], 1'b0}; end
                    if (dv_n == 5'd0) lst <= L_PUT;
                    else dv_n <= dv_n - 5'd1;
                end
                L_PUT: begin
                    if (n_spr != 10'(MAXSPR)) begin
                        tbl_we <= 1'b1; tbl_wa <= n_spr[8:0];
                        tbl_wd <= {dv_qh, dv_qw, e_ys, e_xs, s1[6], s1[4:0], w[1][4:0], w[0][15:8], e_bs[1], e_zh, e_zw, e_y, e_x};
                        n_spr <= n_spr + 10'd1;
                    end
                    lst <= L_NEXT;
                end
                L_NEXT: begin
                    // the end mark (bit 7) ends the scene after its sprite, drawn or not
                    cnt <= cnt + 17'd8; rk <= '0;
                    lst <= w[0][7] ? L_SCN : L_SPW;
                end
                L_SCN:
                    if (s0[7] || sc_i == 6'd63) lst <= L_END;
                    else begin sc_i <= sc_i + 6'd1; sc_base <= sc_base + 15'd8; lst <= L_SC0; end
                L_END: begin freeze <= 1'b0; lst <= L_IDLE; end
                default: lst <= L_IDLE;
            endcase
        end
    end
    assign dbg_sprites = n_spr;

    // ================================================================== the palette mirror and the row buffer
    // MAME's video RAM starts as 0xFF bytes: every colour transparent until the game writes it (Quartus: a memory initialisation file,
    // its 65536-pass initial loop takes it forever)
`ifdef SYNTHESIS
    (* ramstyle = "M10K,no_rw_check", ram_init_file = "rtl/gunpey_pal_init.mif" *) logic [15:0] pal [65536];
`else
    logic [15:0] pal [65536];
    initial for (int i = 0; i < 65536; i++) pal[i] = 16'hffff;
`endif
    logic [15:0] pal_ra, pal_q;
    always_ff @(posedge clk) begin
        if (pal_we) pal[pal_addr] <= pal_data;
        pal_q <= pal[pal_ra];
    end

    // four slots of 256 words: a sprite's source row
    logic [15:0] rbuf [1024];
    logic  [9:0] rb_wa, rb_ra;
    logic [15:0] rb_q;
    always_ff @(posedge clk) begin
        if (m_valid) rbuf[rb_wa] <= m_data;
        rb_q <= rbuf[rb_ra];
    end

    // ================================================================== the fetcher
    // walks the table for the line being drawn; a sprite on it gets its source row's words into a slot, then a job for the drawer
    typedef enum logic [3:0] { F_IDLE, F_RD, F_WAIT, F_CHK, F_CLIP, F_MUL, F_SLOT, F_REQ, F_ACK, F_RECV, F_JOB } fst_t;
    fst_t         fst;
    logic   [8:0] rl;                         // the line being drawn
    logic         rl_pend;                    // a line waits to be drawn
    logic   [8:0] rl_next;
    logic         ovr;                        // the line was not done in time: stop looking for sprites
    logic   [9:0] fi;
    logic [125:0] e;
    logic signed [11:0] yi;
    logic   [8:0] xi0, xi1;
    logic  [31:0] m_y, m_x0, m_x1;
    logic  [10:0] srow;
    logic  [11:0] fw1, fwc;
    logic   [7:0] fn_recv, fn_want, fwp;
    logic   [1:0] fslot;
    logic   [3:0] slot_busy;
    logic   [4:0] blen;
    logic  [12:0] line_clks;

    wire signed [10:0] t_x = e[10:0];
    wire signed [10:0] t_y = e[21:11];
    wire   [7:0] t_zw = e[29:22], t_zh = e[37:30];
    wire         t_b8 = e[38];
    wire  [10:0] t_xs = e[68:58], t_ys = e[79:69];
    wire  [22:0] t_ws = e[102:80], t_hs = e[125:103];

    // the jobs: {slot, first dot, dots, accumulator, step, source x, 8 bpp, colour, alpha, darkening}
    localparam int JW = 2 + 9 + 9 + 32 + 23 + 11 + 1 + 8 + 5 + 6;
    logic [JW-1:0] jq [4];
    logic   [1:0] jq_wp, jq_rp;
    logic   [2:0] jq_cnt;
    logic         jq_push, jq_pop;
    logic [JW-1:0] jq_in;
    logic         d_busy, d_free;
    logic   [1:0] d_free_slot;

    assign rb_wa = {fslot, fwp};

    // a line is drawn during the line before it (line 0 during line 263)
    wire        draw_next = line_start && ((vc == 9'(VTOTAL - 1)) || (vc < 9'(VVIS - 1)));
    wire  [8:0] draw_line = (vc == 9'(VTOTAL - 1)) ? 9'd0 : vc + 9'd1;
    wire        r_idle    = (fst == F_IDLE) && (jq_cnt == 3'd0) && !d_busy;

    always_ff @(posedge clk) begin
        jq_push <= 1'b0;
        if (m_ack) m_req <= 1'b0;
        if (reset) begin
            fst <= F_IDLE; rl_pend <= 1'b0; ovr <= 1'b0; slot_busy <= '0; m_req <= 1'b0; fslot <= '0;
            dbg_overruns <= '0; dbg_line_clks <= '0; line_clks <= '0;
        end else begin
            if (vbl) dbg_line_clks <= '0;
            if (!r_idle) line_clks <= line_clks + 13'd1;
            if (d_free) slot_busy[d_free_slot] <= 1'b0;
            if (draw_next) begin
                rl_pend <= 1'b1; rl_next <= flip[1] ? 9'(VVIS - 1) - draw_line : draw_line;
                if (!r_idle) begin ovr <= 1'b1; dbg_overruns <= dbg_overruns + 16'd1; end
            end

            case (fst)
                F_IDLE: if (rl_pend && r_idle && lst == L_IDLE && !draw_next) begin
                    rl <= rl_next; rl_pend <= 1'b0; ovr <= 1'b0; fi <= '0; line_clks <= '0;
                    if (line_clks > dbg_line_clks) dbg_line_clks <= line_clks;
                    fst <= F_RD;
                end
                F_RD:   if (fi == n_spr || ovr) fst <= F_IDLE; else begin tbl_ra <= fi[8:0]; fst <= F_WAIT; end
                F_WAIT: fst <= F_CHK;
                F_CHK:  begin e <= tbl_q; fst <= F_CLIP; end
                F_CLIP: begin : clip
                    // on the line?  its dots on the screen: xi0 = max(0, -x), xi1 = min(zw, 320 - x)
                    logic signed [11:0] a0, a1;
                    yi <= $signed({3'd0, rl}) - 12'(t_y);
                    a0 = (t_x < 0) ? 12'sd0 - 12'(t_x) : 12'sd0;
                    a1 = 12'sd320 - 12'(t_x);
                    if (a1 > $signed({4'd0, t_zw})) a1 = $signed({4'd0, t_zw});
                    xi0 <= (a0 > 12'sd256) ? 9'd256 : 9'(a0);
                    xi1 <= (a1 < 12'sd0) ? 9'd0 : 9'(a1);
                    fst <= F_MUL;
                end
                F_MUL:
                    if (yi < 0 || yi >= $signed({4'd0, t_zh}) || xi0 >= xi1) begin fi <= fi + 10'd1; fst <= F_RD; end
                    else begin
                        m_y  <= 32'(yi[7:0]) * 32'(t_hs);
                        m_x0 <= 32'(xi0) * 32'(t_ws);
                        m_x1 <= 32'(xi1 - 9'd1) * 32'(t_ws);
                        fst <= F_SLOT;
                    end
                F_SLOT:
                    if (ovr) fst <= F_IDLE;
                    else if (!slot_busy[fslot]) begin : rowwords
                        logic [16:0] s0x, s1x;
                        logic [11:0] b0, b1;
                        s0x = 17'(m_x0 >> 15); s1x = 17'(m_x1 >> 15);
                        b0 = 12'(t_xs) + (t_b8 ? 12'(s0x) : 12'(s0x >> 1));
                        b1 = 12'(t_xs) + (t_b8 ? 12'(s1x) : 12'(s1x >> 1));
                        srow <= 11'(t_ys + 11'(m_y >> 15));
                        fw1 <= {1'b0, b1[11:1]}; fwc <= {1'b0, b0[11:1]};
                        fn_want <= 8'(b1[11:1] - b0[11:1] + 11'd1);
                        fn_recv <= '0; fwp <= b0[8:1];
                        fst <= F_REQ;
                    end
                // the bursts: each to its 16-word block's end or the row's last word; the words land meanwhile
                F_REQ: begin : burst
                    logic [11:0] be, last;
                    be = fwc | 12'h00f;
                    last = (fw1 < be) ? fw1 : be;
                    blen   <= 5'(last - fwc + 12'd1);
                    m_req  <= 1'b1;
                    m_addr <= VRAM_BASE + {3'd0, srow, fwc[9:0]};
                    m_len  <= 5'(last - fwc + 12'd1);
                    fst <= F_ACK;
                end
                F_ACK: if (m_ack) begin
                    fwc <= fwc + 12'(blen);
                    fst <= (fwc + 12'(blen) > fw1) ? F_RECV : F_REQ;
                end
                F_RECV: if (fn_recv == fn_want) fst <= F_JOB;
                F_JOB: begin
                    jq_push <= 1'b1;
                    jq_in <= {fslot, 9'(10'(t_x) + 10'(xi0)), 9'(xi1 - xi0), m_x0, t_ws, t_xs, t_b8, e[46:39], e[51:47], e[57:52]};
                    slot_busy[fslot] <= 1'b1;
                    fslot <= fslot + 2'd1;
                    fi <= fi + 10'd1;
                    fst <= F_RD;
                end
                default: fst <= F_IDLE;
            endcase
            if (m_valid) begin fwp <= fwp + 8'd1; fn_recv <= fn_recv + 8'd1; end
        end
    end

    // ------------------------------------------------------------------ the job queue
    always_ff @(posedge clk) begin
        if (reset) begin
            jq_wp <= '0; jq_rp <= '0; jq_cnt <= '0;
        end else begin
            if (jq_push) begin jq[jq_wp] <= jq_in; jq_wp <= jq_wp + 2'd1; end
            if (jq_pop) jq_rp <= jq_rp + 2'd1;
            jq_cnt <= jq_cnt + 3'(jq_push) - 3'(jq_pop);
        end
    end

    // ================================================================== the drawer: a dot a clock
    // stage 0: the dot's source byte is addressed in the row buffer;  1: its word -> the pixel -> the palette and the line buffer are
    // addressed;  2: the colour darkened;  3: blended;  4: written. A job starts five clocks after the one before ended (a dot of the
    // new one may be one the old one is still writing).
    logic        d_on;
    logic  [1:0] d_slot;
    logic  [8:0] d_x, d_n;
    logic [31:0] d_acc;
    logic [22:0] d_ws;
    logic [10:0] d_xs;
    logic        d_b8;
    logic  [7:0] d_col;
    logic  [4:0] d_al;
    logic  [5:0] d_gr;
    logic  [2:0] d_drain;
    logic        p1_v, p2_v, p3_v, p4_v;
    logic  [8:0] p1_x, p2_x, p3_x, p4_x;
    logic        p1_bs, p1_ns, p1_b8;
    logic  [7:0] p1_col;
    logic  [4:0] p1_al, p2_al;
    logic  [5:0] p1_gr, p2_gr;
    logic [14:0] p3_col, p3_dst, p4_c;
    logic  [8:0] p3_lvl;
    logic        p3_w, p4_w;
    logic [14:0] lb_draw_q;

    assign jq_pop = !d_on && (jq_cnt != 3'd0) && (d_drain == 3'd0);
    assign d_busy = d_on || p1_v || p2_v || p3_v || p4_v || (d_drain != 3'd0);

    // stage 0's row buffer address and stage 1's palette address go straight to their RAMs
    wire [16:0] st0_s  = d_acc[31:15];
    wire [11:0] st0_bx = 12'(d_xs) + (d_b8 ? 12'(st0_s) : 12'(st0_s >> 1));
    assign rb_ra = {d_slot, st0_bx[8:1]};
    wire  [7:0] st1_by = p1_bs ? rb_q[7:0] : rb_q[15:8];
    wire  [7:0] st1_px = p1_b8 ? st1_by : {4'd0, (p1_ns ? st1_by[7:4] : st1_by[3:0])};
    assign pal_ra = p1_b8 ? {p1_col, st1_px} : {4'd0, p1_col, st1_px[3:0]};

    always_ff @(posedge clk) begin
        d_free <= 1'b0;
        if (reset) begin
            d_on <= 1'b0; p1_v <= 1'b0; p2_v <= 1'b0; p3_v <= 1'b0; p4_v <= 1'b0; d_drain <= '0;
        end else begin
            if (d_drain != 3'd0) d_drain <= d_drain - 3'd1;
            // stage 0
            p1_v <= d_on;
            p1_x <= d_x; p1_bs <= st0_bx[0]; p1_ns <= st0_s[0]; p1_b8 <= d_b8; p1_col <= d_col; p1_al <= d_al; p1_gr <= d_gr;
            if (jq_pop) begin
                {d_slot, d_x, d_n, d_acc, d_ws, d_xs, d_b8, d_col, d_al, d_gr} <= jq[jq_rp];
                d_on <= 1'b1;
            end else if (d_on) begin
                d_acc <= d_acc + 32'(d_ws);
                d_x <= d_x + 9'd1;
                d_n <= d_n - 9'd1;
                if (d_n == 9'd1) begin d_on <= 1'b0; d_free <= 1'b1; d_free_slot <= d_slot; d_drain <= 3'd5; end
            end
            // stage 1 -> 2
            p2_v <= p1_v; p2_x <= p1_x; p2_al <= p1_al; p2_gr <= p1_gr;
            // stage 2 -> 3: the darkening (MAME's draw_pixel), the line buffer's dot and the alpha level kept
            p3_v <= p2_v; p3_x <= p2_x;
            begin : darken
                logic [4:0] cr, cg, cb, am;
                cr = pal_q[14:10]; cg = pal_q[9:5]; cb = pal_q[4:0];
                am = p2_gr[4:0];
                if (p2_gr[5]) begin
                    cr = (cr > am) ? cr - am : 5'd0;
                    cg = (cg > am) ? cg - am : 5'd0;
                    cb = (cb > am) ? cb - am : 5'd0;
                end
                p3_col <= {cr, cg, cb};
                p3_dst <= lb_draw_q;
                p3_lvl <= {1'b0, p2_al, 3'd0};
                p3_w   <= !pal_q[15];
            end
            // stage 3 -> 4: the alpha (alpha_blend_r16(colour, dest, level); level 0 is solid)
            p4_v <= p3_v; p4_x <= p3_x; p4_w <= p3_w;
            if (p3_lvl == 9'd0) p4_c <= p3_col;
            else p4_c <= {5'((13'(p3_dst[14:10]) * 13'(p3_lvl) + 13'(p3_col[14:10]) * 13'(9'd256 - p3_lvl)) >> 8),
                          5'((13'(p3_dst[9:5])   * 13'(p3_lvl) + 13'(p3_col[9:5])   * 13'(9'd256 - p3_lvl)) >> 8),
                          5'((13'(p3_dst[4:0])   * 13'(p3_lvl) + 13'(p3_col[4:0])   * 13'(9'd256 - p3_lvl)) >> 8)};
        end
    end

    // ================================================================== the line buffers
    // two 512 x 15 RAMs: line L is drawn into buffer L & 1 while line L - 1 is shown from the other, which is cleared as it is shown
    logic [14:0] lb0 [512], lb1 [512];
    logic  [8:0] show_x;
    logic        show_clr;
    logic  [8:0] ra0, ra1, wa0, wa1;
    logic        we0, we1;
    logic [14:0] wd0, wd1, q0, q1;
    always_ff @(posedge clk) begin
        if (we0) lb0[wa0] <= wd0;
        q0 <= lb0[ra0];
        if (we1) lb1[wa1] <= wd1;
        q1 <= lb1[ra1];
    end
    wire sbuf = vc[0];                        // shown: line vc's
    wire dbuf = ~sbuf;                        // drawn: line vc + 1's (line 0's during line 263)
    always_comb begin
        ra0 = show_x; wa0 = show_x; we0 = show_clr && !sbuf; wd0 = '0;
        ra1 = show_x; wa1 = show_x; we1 = show_clr &&  sbuf; wd1 = '0;
        if (!dbuf) begin ra0 = p1_x; wa0 = p4_x; we0 = p4_v && p4_w; wd0 = p4_c; end
        else       begin ra1 = p1_x; wa1 = p4_x; we1 = p4_v && p4_w; wd1 = p4_c; end
    end
    assign lb_draw_q = dbuf ? q1 : q0;
    wire [14:0] lb_show_q = sbuf ? q1 : q0;

    // ================================================================== the picture out
    // dot hc is read at div 1 (its address set at div 0), taken at div 2 and cleared then, and shown with the next ce_pix; flipped, the
    // buffer is read (and cleared) from dot 319 down
    logic [14:0] rgb_n;
    always_ff @(posedge clk) begin
        show_clr <= 1'b0;
        if (div == 4'd0) show_x <= flip[0] ? 9'(HVIS - 1) - hc : hc;
        if (div == 4'd1) show_clr <= (hc < 9'(HVIS));
        if (div == 4'd2) rgb_n <= (hc < 9'(HVIS) && vc < 9'(VVIS)) ? lb_show_q : 15'd0;
        ce_pix <= (div == 4'd11);
        if (div == 4'd11) begin
            r <= {rgb_n[14:10], rgb_n[14:12]};
            g <= {rgb_n[9:5], rgb_n[9:7]};
            b <= {rgb_n[4:0], rgb_n[4:2]};
            hblank <= (hc >= 9'(HVIS));
            vblank <= (vc >= 9'(VVIS));
            vblank_next <= (vc >= 9'(VVIS - 1)) && (vc != 9'(VTOTAL - 1));
            hs <= (hc >= 9'(HS_START)) && (hc < 9'(HS_END));
            vs <= (vc >= 9'(VS_START)) && (vc < 9'(VS_END));
        end
    end
endmodule
`default_nettype wire
