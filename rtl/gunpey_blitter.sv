//------------------------------------------------------------------------------
// The AG-1's blitter (MAME 0.289 gunpey.cpp blitter_w / decompress_sprite): a rectangle of the graphics ROM (gp_rom3, 2048 bytes a row)
// into the 4 MB video RAM (2048 x 2048 bytes), either as it is (register 1 = 0) or from the compressed sprite format (register 1 = 8).
// The CPU starts it by writing 2 to register 0; MAME raises the blitter interrupt xsize * ysize CPU clocks later (the copy itself is
// instantaneous there), and so does this one, or when it is done if that is later.
//
//   registers  1 the format, 4/5 source x (bytes), 6/7 source y, 8/9 destination x (words), 10/11 destination y,
//              12 width - 1 (words), 14 height - 1
//
// The ROM is read through a byte streamer: bursts of a row segment into a byte FIFO, wrapping to the next row at the segment's end as
// MAME does (the raw copy: the rectangle's width; the compressed format: the width in its first byte). The raw copy pairs the bytes
// into words; the decompressor reads bits from them, least significant first, one code in two clocks (rtl/gunpey_huff.svh, generated from
// MAME's table), and writes one pixel a clock. The format walks the sprite in 12 pixel wide strips, down the even ones and up the odd
// ones, and its copy codes read the row before in the strip (or the last column of the strip before, for the pixel left of the strip):
// those two are kept here (a 12-byte row, a 256-byte column), where MAME reads them back from the video RAM. Every compressed sprite of
// the game reads nothing else (tools/gunpey_ref decstats). Every write is a whole word: the destination's x and the width are in words,
// and the format writes a strip row's bytes in pairs.
//
// Words go to the SDRAM through a writer that joins consecutive addresses into bursts (up to 16 words in an aligned block), and to the
// palette mirror (the video RAM's rows 0-255, bytes 0-511: every colour the sprites can use) as they are made.
//
// SDRAM words hold the even byte in [15:8] (the loader's convention); a palette entry is the little-endian pair, so it is swapped.
//------------------------------------------------------------------------------
`default_nettype none

module gunpey_blitter #(
    parameter logic [23:0] GFX_BASE  = 24'h080000,   // the graphics ROM, word address
    parameter logic [23:0] VRAM_BASE = 24'h800000    // the video RAM, word address
) (
    input  logic         clk,
    input  logic         reset,
    input  logic         start,          // the CPU wrote 2 to register 0
    input  logic [127:0] regs,           // the 16 register bytes, register i in [8i +: 8], as they are at the start
    input  logic         cpu_ce,         // a CPU clock: MAME's busy time counts them
    output logic         busy,
    output logic         irq,            // one clock: MAME's blitter_end

    // the ROM's read client
    output logic         rd_req,
    output logic  [23:0] rd_addr,
    output logic   [4:0] rd_len,
    input  logic         rd_ack,
    input  logic         rd_valid,
    input  logic  [15:0] rd_data,

    // the video RAM's write client
    output logic         wr_req,
    output logic  [23:0] wr_addr,
    output logic   [4:0] wr_len,
    input  logic         wr_ack,
    input  logic         wr_pull,
    output logic  [15:0] wr_data,

    // the palette mirror's write port: entry {row, word}, the colour (little-endian)
    output logic         pal_we,
    output logic  [15:0] pal_addr,
    output logic  [15:0] pal_data,

    output logic         dbg_error,      // sticky: a compressed sprite had a bit string no code matches (MAME logs and abandons it)
    output logic         dbg_idle        // the engine and the writer are done (the bench measures the time against MAME's)
);
    function automatic [7:0] R(input [127:0] v, input int i); R = v[8*i +: 8]; endfunction

    // ================================================================== the byte streamer
    // st_go starts it (only while it is idle) at byte s_sx of row s_sy, the segment [base, base + width); st_one stops it after its first
    // burst; st_stop empties the FIFO and lets a burst in flight run out unheard.
    logic        st_go, st_one, st_stop;
    logic [16:0] st_go_base, st_go_sx;
    logic  [9:0] st_go_width;
    logic [10:0] st_go_sy;

    logic [16:0] s_base, s_sx, s_end;            // the segment's first byte, the next byte to fetch, the segment's end (bytes, unwrapped)
    logic [10:0] s_sy;
    logic [15:0] s_wcur, s_wlast;                // the burst's words (unwrapped)
    logic [16:0] s_lo;                           // the burst's first wanted byte
    logic  [4:0] s_left;
    logic        s_once, s_deaf;
    typedef enum logic [1:0] { S_IDLE, S_PLAN, S_REQ, S_DATA } sst_t;
    sst_t sst;
    wire         s_idle = (sst == S_IDLE);

    // the FIFO: 64 bytes, up to two in and two out a clock
    logic  [7:0] fifo [64];
    logic  [5:0] f_wp, f_rp;
    logic  [6:0] f_cnt;
    logic  [1:0] push_n, pop_n;
    logic  [7:0] push_b0, push_b1;
    wire   [7:0] f_out0 = fifo[f_rp];
    wire   [7:0] f_out1 = fifo[f_rp + 6'd1];

    // the burst's words: their two bytes, wanted or not
    wire  [16:0] wb_even = {s_wcur, 1'b0};
    wire  [16:0] wb_odd  = {s_wcur, 1'b1};
    wire         want_e  = (wb_even >= s_lo) && (wb_even < s_end);
    wire         want_o  = (wb_odd  >= s_lo) && (wb_odd  < s_end);

    // the plan of the next burst: from the next byte's word to the segment's last word or the 16-word block's end
    wire  [15:0] p_wf   = s_sx[16:1];
    wire  [15:0] p_wl   = 16'((s_end - 17'd1) >> 1);
    wire  [15:0] p_be   = p_wf | 16'h000f;
    wire  [15:0] p_we   = (p_wl < p_be) ? p_wl : p_be;
    wire   [4:0] p_len  = 5'(p_we - p_wf + 16'd1);

    always_ff @(posedge clk) begin
        if (rd_ack) rd_req <= 1'b0;
        if (reset) begin
            sst <= S_IDLE; rd_req <= 1'b0; s_deaf <= 1'b0;
        end else begin
            if (st_stop) s_deaf <= 1'b1;
            case (sst)
                S_IDLE: if (st_go) begin
                    s_base <= st_go_base; s_sx <= st_go_sx; s_sy <= st_go_sy; s_end <= st_go_base + 17'(st_go_width);
                    s_once <= st_one; s_deaf <= 1'b0;
                    sst <= S_PLAN;
                end
                S_PLAN:
                    if (st_stop || s_deaf) sst <= S_IDLE;
                    else if (s_sx >= s_end) begin s_sx <= s_base; s_sy <= s_sy + 11'd1; end
                    else if (f_cnt <= 7'd32) begin
                        rd_req  <= 1'b1;
                        rd_addr <= GFX_BASE + {3'd0, s_sy, p_wf[9:0]};
                        rd_len  <= p_len;
                        s_wcur  <= p_wf; s_wlast <= p_we; s_lo <= s_sx; s_left <= p_len;
                        sst <= S_REQ;
                    end
                S_REQ:  if (rd_ack) sst <= S_DATA;
                S_DATA: if (rd_valid) begin
                    s_wcur <= s_wcur + 16'd1;
                    s_left <= s_left - 5'd1;
                    if (s_left == 5'd1) begin
                        s_sx <= {s_wlast + 16'd1, 1'b0};
                        sst  <= (s_once || s_deaf || st_stop) ? S_IDLE : S_PLAN;
                    end
                end
            endcase
        end
    end

    always_comb begin
        push_n = 2'd0; push_b0 = rd_data[15:8]; push_b1 = rd_data[7:0];
        if (sst == S_DATA && rd_valid && !s_deaf && !st_stop) begin
            case ({want_e, want_o})
                2'b11:   begin push_n = 2'd2; push_b0 = rd_data[15:8]; push_b1 = rd_data[7:0]; end
                2'b10:   begin push_n = 2'd1; push_b0 = rd_data[15:8]; end
                2'b01:   begin push_n = 2'd1; push_b0 = rd_data[7:0]; end
                default: push_n = 2'd0;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (reset || st_stop) begin
            f_wp <= '0; f_rp <= '0; f_cnt <= '0;
        end else begin
            if (push_n != 2'd0) fifo[f_wp] <= push_b0;
            if (push_n == 2'd2) fifo[f_wp + 6'd1] <= push_b1;
            f_wp  <= f_wp + 6'(push_n);
            f_rp  <= f_rp + 6'(pop_n);
            f_cnt <= f_cnt + 7'(push_n) - 7'(pop_n);
        end
    end

    // ================================================================== the video RAM writer
    // w_push: a word for w_addr; w_flush: the open run is complete. They are registered first (p_*: the run logic starts at registers).
    // A run grows while the addresses are consecutive, up to 16 words or its block's end; a complete run is queued as {address, length}
    // and written as one burst.
    logic        w_push, w_flush, w_ready, w_idle;
    logic [23:0] w_addr;
    logic [15:0] w_data;
    logic        p_push, p_flush;
    logic [23:0] p_addr;
    logic [15:0] p_data;
    always_ff @(posedge clk) begin
        p_push <= !reset && w_push; p_flush <= !reset && w_flush;
        p_addr <= w_addr; p_data <= w_data;
    end

    logic [15:0] wd [32];
    logic  [4:0] wd_wp, wd_rp;
    logic  [5:0] wd_cnt;
    logic [28:0] rq [8];
    logic  [2:0] rq_wp, rq_rp;
    logic  [3:0] rq_cnt;
    logic        run_open;
    logic [23:0] run_addr, run_next;
    logic  [4:0] run_len;
    typedef enum logic [1:0] { W_IDLE, W_REQ, W_DATA } wst_t;
    wst_t        wst;
    logic  [4:0] w_left;

    // room for this word and the one in p_* (two descriptors each at most)
    assign w_ready = (wd_cnt < 6'd29) && (rq_cnt < 4'd5);
    assign w_idle  = (wd_cnt == 6'd0) && (rq_cnt == 4'd0) && !run_open && (wst == W_IDLE) && !p_push && !p_flush;
    assign wr_data = wd[wd_rp];

    // this clock's run: closed runs go to the queue (at most two: the one a jump ends, and a new one complete at once)
    logic        q0_v, q1_v, n_open;
    logic [28:0] q0_d, q1_d;
    logic [23:0] n_addr, n_next;
    logic  [4:0] n_len;
    always_comb begin
        q0_v = 1'b0; q1_v = 1'b0; q0_d = {run_addr, run_len}; q1_d = '0;
        n_open = run_open; n_addr = run_addr; n_next = run_next; n_len = run_len;
        if (p_push) begin
            if (run_open && p_addr == run_next) begin
                n_len = run_len + 5'd1; n_next = run_next + 24'd1;
            end else begin
                if (run_open) begin q0_v = 1'b1; q0_d = {run_addr, run_len}; end
                n_open = 1'b1; n_addr = p_addr; n_len = 5'd1; n_next = p_addr + 24'd1;
            end
        end
        // complete: 16 words, the block's end, or the producer says so
        if (n_open && (n_len == 5'd16 || n_next[3:0] == 4'd0 || p_flush)) begin
            if (q0_v) begin q1_v = 1'b1; q1_d = {n_addr, n_len}; end
            else      begin q0_v = 1'b1; q0_d = {n_addr, n_len}; end
            n_open = 1'b0;
        end
    end
    wire wd_pop = (wst == W_DATA) && wr_pull;
    wire rq_pop = wd_pop && (w_left == 5'd1);

    always_ff @(posedge clk) begin
        if (wr_ack) wr_req <= 1'b0;
        if (reset) begin
            wd_wp <= '0; wd_rp <= '0; wd_cnt <= '0; rq_wp <= '0; rq_rp <= '0; rq_cnt <= '0;
            run_open <= 1'b0; wst <= W_IDLE; wr_req <= 1'b0;
        end else begin
            if (p_push) wd[wd_wp] <= p_data;
            wd_wp  <= wd_wp + 5'(p_push);
            wd_rp  <= wd_rp + 5'(wd_pop);
            wd_cnt <= wd_cnt + 6'(p_push) - 6'(wd_pop);
            run_open <= n_open; run_addr <= n_addr; run_next <= n_next; run_len <= n_len;
            if (q0_v) rq[rq_wp] <= q0_d;
            if (q1_v) rq[rq_wp + 3'd1] <= q1_d;
            rq_wp  <= rq_wp + 3'(q0_v) + 3'(q1_v);
            rq_rp  <= rq_rp + 3'(rq_pop);
            rq_cnt <= rq_cnt + 4'(q0_v) + 4'(q1_v) - 4'(rq_pop);
            case (wst)
                W_IDLE: if (rq_cnt != 4'd0) begin
                    wr_req <= 1'b1; wr_addr <= rq[rq_rp][28:5]; wr_len <= rq[rq_rp][4:0]; w_left <= rq[rq_rp][4:0];
                    wst <= W_REQ;
                end
                W_REQ:  if (wr_ack) wst <= W_DATA;
                W_DATA: if (wr_pull) begin
                    w_left <= w_left - 5'd1;
                    if (w_left == 5'd1) wst <= W_IDLE;
                end
                default: wst <= W_IDLE;
            endcase
        end
    end

    // the palette mirror: the words of video RAM rows 0-255, bytes 0-511
    wire [20:0] w_off = 21'(p_addr - VRAM_BASE);
    always_ff @(posedge clk) begin
        pal_we   <= p_push && (w_off[20:18] == 3'd0) && (w_off[9:8] == 2'd0);
        pal_addr <= {w_off[17:10], w_off[7:0]};
        pal_data <= {p_data[7:0], p_data[15:8]};
    end

    // ================================================================== the command
    logic         act;                           // a blit is running (its engine, its writes, or MAME's time)
    logic         go;                            // a blit waits for the engine
    logic [127:0] nxt, cur;                      // the start's registers, the running blit's
    logic  [17:0] tmr;                           // MAME's busy time left, CPU clocks
    logic         eng_take, eng_done;

    wire  [9:0]  xs_s = {1'b0, R(regs, 12), 1'b0} + 10'd2;       // the start's width in bytes, height
    wire  [8:0]  ys_s = {1'b0, R(regs, 14)} + 9'd1;

    always_ff @(posedge clk) begin
        irq <= 1'b0;
        if (reset) begin
            act <= 1'b0; go <= 1'b0; tmr <= '0;
        end else begin
            if (cpu_ce && tmr != 18'd0) tmr <= tmr - 18'd1;
            if (eng_take) go <= 1'b0;
            if (start) begin
                // MAME restarts its timer at every start; a start while the engine runs waits for it
                tmr <= 18'(xs_s * ys_s);
                act <= 1'b1;
                go  <= 1'b1;
                nxt <= regs;
            end else if (act && !go && !eng_busy && w_idle && tmr == 18'd0) begin
                act <= 1'b0; irq <= 1'b1;
            end
        end
    end
    assign busy = act;
    assign dbg_idle = !go && !eng_busy && w_idle;

    // the current blit's parameters
    wire [16:0] c_srcx = {1'b0, R(cur, 5), R(cur, 4)};
    wire [10:0] c_srcy = {cur[8*7 +: 3], R(cur, 6)};
    wire [10:0] c_dstx = {cur[8*9 +: 2], R(cur, 8), 1'b0};      // bytes, & 0x7ff
    wire [10:0] c_dsty = {cur[8*11 +: 3], R(cur, 10)};
    wire  [9:0] c_xs   = {1'b0, R(cur, 12), 1'b0} + 10'd2;
    wire  [8:0] c_ys   = {1'b0, R(cur, 14)} + 9'd1;
    wire  [7:0] c_mode = R(cur, 1);

    // ================================================================== the raw copy and the decompressor
    typedef enum logic [3:0] {
        E_IDLE, E_START, E_RAW, E_W0, E_W1, E_HDR, E_DEC, E_DEC2, E_RUN, E_EOL, E_LC, E_LC2, E_FIN
    } est_t;
    est_t est;
    wire  eng_busy = (est != E_IDLE);
    assign eng_take = (est == E_IDLE) && go && s_idle && !start;

    // the raw copy's destination walk
    logic  [9:0] r_dxw, r_dxw0;                  // destination word in the row (wraps at 1024)
    logic [10:0] r_dy;
    logic  [9:0] r_col;                          // bytes done in the row
    logic  [8:0] r_row;

    // the decompressor
    logic [39:0] bits;
    logic  [5:0] nb;
    logic  [7:0] colour [16];
    logic  [5:0] q, owq;                         // ox / 12
    logic  [3:0] r, owr;                         // ox % 12
    logic  [9:0] ox;                             // ox itself
    logic  [9:0] ow;
    logic signed [9:0] oy;
    logic  [8:0] oh;
    logic [10:0] d_dx, d_dy;
    logic  [2:0] y_func;
    logic  [3:0] y_n;
    logic  [7:0] y_val;                          // the code's byte (NEW) or the remembered colour (PREV)
    logic  [7:0] prow [12], crow [12];           // the strip's row before, the row being written
    logic  [7:0] lc_val;                         // the strip before's last column, at the row before
    logic        colbank;
    logic  [7:0] even_b;                         // the pixel pair's first byte
    logic  [8:0] iw;

    // the strip before's last column / this strip's last column: one 512-byte RAM, the bank bit flips at a new strip
    logic  [7:0] colmem [512];
    logic        cm_we;
    logic  [8:0] cm_wa, cm_ra;
    logic  [7:0] cm_wd, cm_q;
    always_ff @(posedge clk) begin
        if (cm_we) colmem[cm_wa] <= cm_wd;
        cm_q <= colmem[cm_ra];
    end

    // the code at the window: decoded in E_DEC (sym), taken from a register in E_DEC2 (sym_r; the window's low 23 bits do not change
    // between the two: the bit reader only appends above them), which consumes it
    logic [14:0] sym, sym_r;
    always_comb begin
        casez (bits[14:0])
`include "gunpey_huff.svh"
            default: sym = 15'd0;
        endcase
    end
    wire  [3:0] sym_len   = sym_r[14:11];
    wire  [2:0] sym_func  = sym_r[10:8];
    wire  [3:0] sym_abits = sym_r[7:4];
    wire  [3:0] sym_n     = sym_r[3:0];
    wire  [7:0] sym_arg   = 8'(bits >> sym_len) & ((sym_abits == 4'd8) ? 8'hff : 8'h0f);
    wire  [4:0] sym_k     = 5'(sym_len) + 5'(sym_abits);

    // the pixel of the run: a new colour, a remembered one, or the row before (straight, one right, one left). It depends only on the
    // run's code and the strip column, so it is worked out a clock ahead into pix_q (the move-to-front search then starts at a
    // register): the run's first pixel at its code (pix_first), each next one while the run goes on (pix_next)
    localparam [2:0] F_NEW = 3'd0, F_PREV = 3'd1, F_COPY = 3'd2, F_PLUS = 3'd3, F_MINUS = 3'd4;
    logic [7:0] pix_q, pix_first, pix_next, sym_val;
    wire  [7:0] pix = pix_q;
    wire  [3:0] r_next = (r == 4'd11) ? 4'd0 : r + 4'd1;
    always_comb sym_val = (sym_func == F_PREV) ? colour[sym_arg[3:0]] : sym_arg;
    always_comb begin
        logic signed [4:0] idx;
        idx = $signed({1'b0, r}) + ((sym_func == F_PLUS) ? 5'sd1 : (sym_func == F_MINUS) ? -5'sd1 : 5'sd0);
        if (sym_func == F_NEW || sym_func == F_PREV) pix_first = sym_val;
        else if (idx == -5'sd1) pix_first = lc_val;
        else if (idx >= 5'sd0 && idx <= 5'sd11) pix_first = prow[idx[3:0]];
        else pix_first = 8'h00;                  // the strip after's first column: never read by the game's sprites
    end
    always_comb begin
        logic signed [4:0] idx;
        idx = $signed({1'b0, r_next}) + ((y_func == F_PLUS) ? 5'sd1 : (y_func == F_MINUS) ? -5'sd1 : 5'sd0);
        if (y_func == F_NEW || y_func == F_PREV) pix_next = y_val;
        else if (idx == -5'sd1) pix_next = lc_val;
        else if (idx >= 5'sd0 && idx <= 5'sd11) pix_next = prow[idx[3:0]];
        else pix_next = 8'h00;
    end

    // where the pixel is in the move-to-front list (16: not there)
    logic [4:0] mtf_p;
    always_comb begin
        mtf_p = 5'd16;
        for (int i = 15; i >= 0; i--) if (colour[i] == pix) mtf_p = 5'(i);
    end

    // the parity of a strip's index is its direction: odd strips run upwards, their row before is below
    wire signed [9:0] oy_prev = q[0] ? oy + 10'sd1 : oy - 10'sd1;

    // the bit reader takes a byte a clock while there is room
    wire        br_on   = (est == E_HDR || est == E_DEC || est == E_DEC2 || est == E_RUN || est == E_EOL || est == E_LC || est == E_LC2);
    logic [4:0] consume;
    always_comb begin
        consume = 5'd0;
        if (est == E_HDR && nb >= 6'd3) consume = 5'd3;
        else if (est == E_DEC2 && sym_len != 4'd0) consume = sym_k;
    end
    wire        br_fill = br_on && (f_cnt != 7'd0) && ((7'(nb) - 7'(consume)) <= 7'd32);
    wire        raw_pop = (est == E_RAW) && (f_cnt >= 7'd2) && w_ready;
    wire        w0_pop  = (est == E_W0) && (f_cnt != 7'd0);
    assign pop_n = raw_pop ? 2'd2 : (br_fill || w0_pop) ? 2'd1 : 2'd0;

    // a run's pixel waits while the writer is full (only the pair's second byte writes)
    wire        run_go  = (est == E_RUN) && (!ox[0] || w_ready);

    always_comb begin
        st_go = 1'b0; st_one = 1'b0; st_stop = 1'b0;
        st_go_base = c_srcx; st_go_sx = c_srcx; st_go_sy = c_srcy; st_go_width = c_xs;
        w_push = 1'b0; w_flush = 1'b0; w_addr = '0; w_data = '0;
        cm_we = 1'b0; cm_wa = {~colbank, oy[7:0]}; cm_wd = pix; cm_ra = {colbank, oy_prev[7:0]};
        eng_done = 1'b0;
        case (est)
            E_START: if (c_mode == 8'd0 || c_mode == 8'd8) begin
                st_go = 1'b1;
                if (c_mode == 8'd8) begin st_one = 1'b1; st_go_width = 10'd1; end   // the format's first byte alone
            end
            E_RAW: if (raw_pop) begin
                w_push = 1'b1; w_addr = VRAM_BASE + {3'd0, r_dy, r_dxw}; w_data = {f_out0, f_out1};
            end
            E_W1: if (s_idle) begin
                st_go = 1'b1; st_go_base = c_srcx; st_go_sx = c_srcx + 17'd1; st_go_width = {1'b0, iw};
            end
            E_RUN: if (run_go) begin
                if (ox[0]) begin
                    w_push = 1'b1;
                    w_addr = VRAM_BASE + {3'd0, 11'(d_dy + 11'(oy)), 10'((d_dx + 11'(ox)) >> 1)};
                    w_data = {even_b, pix};
                end
                cm_we = (r == 4'd11);
            end
            E_FIN: begin
                w_flush = 1'b1; st_stop = 1'b1; eng_done = 1'b1;
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            est <= E_IDLE; dbg_error <= 1'b0;
        end else begin
            // the bit reader
            if (est == E_W1) begin bits <= '0; nb <= '0; end
            else if (br_on) begin
                logic [39:0] nbits;
                nbits = bits >> consume;
                if (br_fill) nbits = nbits | (40'(f_out0) << (nb - 6'(consume)));
                bits <= nbits;
                nb   <= nb - 6'(consume) + (br_fill ? 6'd8 : 6'd0);
            end

            case (est)
                E_IDLE: if (eng_take) begin cur <= nxt; est <= E_START; end
                E_START: begin
                    r_dxw <= c_dstx[10:1]; r_dxw0 <= c_dstx[10:1]; r_dy <= c_dsty; r_col <= '0; r_row <= '0;
                    if (c_mode == 8'd0) est <= E_RAW;
                    else if (c_mode == 8'd8) est <= E_W0;
                    else est <= E_FIN;               // MAME: "unknown compression mode", nothing drawn
                end

                E_RAW: if (raw_pop) begin
                    r_dxw <= r_dxw + 10'd1;
                    if (r_col + 10'd2 == c_xs) begin
                        r_col <= '0; r_dxw <= r_dxw0; r_dy <= r_dy + 11'd1; r_row <= r_row + 9'd1;
                        if (r_row + 9'd1 == c_ys) est <= E_FIN;
                    end else r_col <= r_col + 10'd2;
                end

                // the compressed format: its first byte is the source's row width - 1
                E_W0: if (w0_pop) begin iw <= {1'b0, f_out0} + 9'd1; est <= E_W1; end
                E_W1: if (s_idle) begin
                    for (int i = 0; i < 16; i++) colour[i] <= 8'd0;
                    q <= '0; r <= '0; ox <= '0; oy <= '0; colbank <= 1'b0;
                    ow <= c_xs; oh <= c_ys; d_dx <= c_dstx; d_dy <= c_dsty;
                    // ow / 12 and ow % 12 (ow <= 512): by the reciprocal, exact over the range
                    owq <= 6'((32'(c_xs) * 32'd5462) >> 16);
                    owr <= 4'(32'(c_xs) - 32'd12 * ((32'(c_xs) * 32'd5462) >> 16));
                    est <= E_HDR;
                end
                E_HDR: if (nb >= 6'd3) est <= E_LC;      // three zero bits

                E_DEC:
                    if (ox >= ow) est <= E_FIN;
                    else if (nb >= 6'd23) begin sym_r <= sym; est <= E_DEC2; end
                E_DEC2:
                    if (sym_len == 4'd0) begin dbg_error <= 1'b1; est <= E_FIN; end
                    else begin
                        y_func <= sym_func; y_n <= sym_n;
                        y_val  <= sym_val;
                        pix_q  <= pix_first;
                        est <= E_RUN;
                    end

                E_RUN: if (run_go) begin
                    // set_o: the move-to-front list, the pixel, the strip's rows and last column
                    colour[0] <= pix;
                    pix_q <= pix_next;
                    for (int i = 1; i < 16; i++) if (5'(i) <= mtf_p) colour[i] <= colour[i-1];
                    if (!ox[0]) even_b <= pix;
                    crow[r] <= pix;
                    ox <= ox + 10'd1;
                    if (r == 4'd11) begin r <= '0; q <= q + 6'd1; end else r <= r + 4'd1;
                    y_n <= y_n - 4'd1;
                    if (y_n == 4'd1) est <= E_EOL;
                end

                E_EOL: begin : eol
                    logic [5:0] nq; logic [3:0] nr; logic [9:0] nox; logic signed [9:0] noy; logic e, nbank;
                    nq = q; nr = r; nox = ox; noy = oy; e = 1'b0; nbank = colbank;
                    if (r == 4'd0) begin
                        nq = q - 6'd1; nox = ox - 10'd12; e = 1'b1;
                        noy = nq[0] ? oy - 10'sd1 : oy + 10'sd1;
                    end else if (ox == ow) begin
                        nr = 4'd0; nox = ox - 10'(owr); e = 1'b1;
                        noy = q[0] ? oy - 10'sd1 : oy + 10'sd1;
                    end
                    if (e && (noy == $signed({1'b0, oh}) || noy == -10'sd1)) begin
                        nq = nq + 6'd1; nox = nox + 10'd12; nbank = ~colbank;
                        noy = nq[0] ? noy - 10'sd1 : noy + 10'sd1;
                    end
                    q <= nq; r <= nr; ox <= nox; oy <= noy; colbank <= nbank;
                    if (e) begin
                        for (int i = 0; i < 12; i++) prow[i] <= crow[i];
                        est <= E_LC;
                    end else est <= E_DEC;
                end
                E_LC:  est <= E_LC2;                 // the column RAM reads the new row's row before
                E_LC2: begin lc_val <= cm_q; est <= E_DEC; end

                E_FIN: est <= E_IDLE;
                default: est <= E_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
