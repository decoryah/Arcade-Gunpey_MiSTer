//------------------------------------------------------------------------------
// The Gunpey board's CPU side (MAME 0.289 gunpey.cpp mem_map / io_map): the V30 (rtl/gunpey_v30.sv), its clock, its memory and I/O, and
// the interrupt logic.
//
//   memory  00000-0FFFF  work RAM (64 KB; the video chip reads its display list here through the RAM's second port)
//           80000-FFFFF  the program: the 1 MB region at the same offsets (so the ROMs' upper halves), from the SDRAM through the cache
//   I/O     7F40-7F44    DSW1, DSW2, P1, P2, SYSTEM (7F45 reads FF)       7F48     output: bits 6-4 the OKI's ROM bank
//           7F80/7F81    YMZ280B register / data                          7F88     OKI M6295
//           7FC8 / 7FC9  interrupt mask / cause (a write to 7FC9 clears the bits it has set)
//           7FD0-7FDF    the blitter (a 2 written to 7FD0 starts it)      7FEC/7FED vreg_addr, 7FEE/7FEF vram_bank
//
// The interrupt: one line, always vector 0x80. MAME's irq_check: a cause (0x50 at the start of line 240, 0x04 when a blit ends) is or-ed
// in, and the line is raised while cause & mask is not zero, else dropped; the CPU's acknowledge drops it too (HOLD_LINE), until the next
// irq_check (a cause, or a write to the mask or the cause).
//
// The CPU clock: 14.3106 MHz, one clock enable in six system clocks on average. A read waits until its word is there (the work RAM's,
// the I/O's, or the program's from the cache, which may have to fill a line from the SDRAM), and the video chip holds the CPU while it
// copies the display list; the clock enables those waits withhold are made up afterwards, no closer than CE_MIN clocks apart (the
// V30's timing constraint: five, so the CPU catches up at 1.2 times its speed), so the CPU keeps the board's average speed (the Irem
// M72 core's scheme).
//------------------------------------------------------------------------------
`default_nettype none

module gunpey_main #(
    parameter int CE_DIV = 6,                // system clocks a CPU clock
    parameter int CE_MIN = 5                 // the closest two CPU clocks may be (Gunpey.sdc's multicycle for the V30: its longest path is
                                             // about 46 ns, five clocks are 58 ns)
) (
    input  logic         clk,
    input  logic         reset,
    input  logic         rom_ready,          // the program cache is ready (the CPU is held in reset until then)

    // the program through the cache
    output logic         rom_req,
    output logic  [18:0] rom_addr,           // word address in the 1 MB region
    input  logic         rom_ack,
    input  logic  [15:0] rom_q,              // as the SDRAM holds it: {even byte, odd byte}

    // the work RAM's second port
    input  logic  [14:0] v_addr,
    output logic  [15:0] v_q,

    // the video chip
    input  logic         freeze,
    input  logic         vbl,
    output logic  [15:0] vreg_addr,
    output logic  [15:0] vram_bank,

    // the blitter
    output logic         blt_start,
    output logic [127:0] blt_regs,
    input  logic         blt_irq,
    output logic         cpu_ce,

    // the sound chips
    output logic         ymz_wr,
    output logic         ymz_a0,
    output logic   [7:0] ymz_din,
    output logic         oki_wr,
    output logic   [7:0] oki_din,
    input  logic   [7:0] oki_dout,
    output logic   [2:0] oki_bank,

    // the inputs, as MAME's ports (active high)
    input  logic   [7:0] dsw1,
    input  logic   [7:0] dsw2,
    input  logic   [7:0] in_p1,
    input  logic   [7:0] in_p2,
    input  logic   [7:0] in_sys,
    output logic         coin_counter,

    // diagnostics
    output logic  [19:0] dbg_addr,
    output logic         dbg_fetch,          // one clock at each code fetch (dbg_addr its address)
    output logic         dbg_io_wr,          // one clock at each I/O write: dbg_addr, dbg_io_data, dbg_io_be
    output logic         dbg_io_rd,
    output logic  [15:0] dbg_io_data,
    output logic   [1:0] dbg_io_be,
    output logic         dbg_inta
);
    // ================================================================== the CPU clock
    logic  [2:0] ce_div;
    logic [15:0] ref_cnt, cpu_cnt;
    logic  [2:0] since;
    logic        rd_wait;
    wire         behind = (ref_cnt != cpu_cnt);
    always_ff @(posedge clk) begin
        cpu_ce <= 1'b0;
        if (reset) begin
            ce_div <= '0; ref_cnt <= '0; cpu_cnt <= '0; since <= '0;
        end else begin
            ce_div <= (ce_div == 3'(CE_DIV - 1)) ? 3'd0 : ce_div + 3'd1;
            if (ce_div == 3'(CE_DIV - 1)) ref_cnt <= ref_cnt + 16'd1;
            if (since != 3'(CE_MIN - 1)) since <= since + 3'd1;
            if (behind && !freeze && !rd_wait && since == 3'(CE_MIN - 1)) begin
                cpu_ce <= 1'b1; cpu_cnt <= cpu_cnt + 16'd1; since <= '0;
            end
        end
    end

    // ================================================================== the V30
    logic [19:0] a;
    logic  [1:0] be;
    logic [15:0] dout, din;
    logic        mem_rd, io_rd, mem_wr, io_wr, code_fetch, int_ack;
    logic        irq_line;

    // the CPU stays in reset for sixteen of its clocks after the machine's reset and the cache's sweep
    logic [4:0] rst_cnt;
    always_ff @(posedge clk)
        if (reset || !rom_ready) rst_cnt <= 5'd16;
        else if (cpu_ce && rst_cnt != 5'd0) rst_cnt <= rst_cnt - 5'd1;
    wire cpu_reset = reset || !rom_ready || (rst_cnt != 5'd0);

    gunpey_v30 u_cpu (
        .clk(clk), .ce(cpu_ce), .reset(cpu_reset), .ready(1'b1),
        .cpu_addr(a), .cpu_be(be), .cpu_dout(dout), .cpu_din(din),
        .mem_rd(mem_rd), .io_rd(io_rd), .mem_wr(mem_wr), .io_wr(io_wr), .code_fetch(code_fetch), .bus_active(),
        .int_req(irq_line), .int_vector(8'h80), .int_ack(int_ack)
    );

    // ================================================================== the work RAM (true dual port, byte writes)
    logic [1:0][7:0] wram [32768];
    logic            wr_a;
    logic     [15:0] q_a;
    always_ff @(posedge clk) begin
        if (wr_a) begin
            if (be[0]) wram[a[15:1]][0] <= dout[7:0];
            if (be[1]) wram[a[15:1]][1] <= dout[15:8];
        end
        q_a <= wram[a[15:1]];
    end
    always_ff @(posedge clk) v_q <= wram[v_addr];

    // ================================================================== the I/O registers
    logic  [7:0] irq_mask, irq_cause;
    logic  [7:0] blt [16];

    function automatic [7:0] io8(input [15:0] p);
        case (p)
            16'h7f40: io8 = dsw1;
            16'h7f41: io8 = dsw2;
            16'h7f42: io8 = in_p1;
            16'h7f43: io8 = in_p2;
            16'h7f44: io8 = in_sys;
            16'h7f45: io8 = 8'hff;
            16'h7f80: io8 = 8'hff;                     // the YMZ280B's external memory read: not enabled
            16'h7f81: io8 = 8'h00;                     // its status (the game does not read it)
            16'h7f88: io8 = oki_dout;
            16'h7fc8: io8 = irq_mask;
            16'h7fc9: io8 = irq_cause;
            default:  io8 = 8'h00;
        endcase
    endfunction
    wire [15:0] io16 = {io8({a[15:1], 1'b1}), io8({a[15:1], 1'b0})};

    // ================================================================== the bus
    wire        in_rom  = a[19];
    wire        in_wram = (a[19:16] == 4'd0);
    logic       rd_have, rd_go, wr_done, ack_d;
    logic       ymz_hi_pend;
    logic [7:0] ymz_hi_d;
    logic [15:0] rd_data;
    assign rd_wait  = (mem_rd || io_rd) && !rd_have;
    assign rom_addr = a[19:1];
    assign din      = rd_data;

    always_ff @(posedge clk) begin
        rom_req <= 1'b0;
        wr_a <= 1'b0;
        blt_start <= 1'b0;
        ymz_wr <= 1'b0; oki_wr <= 1'b0;
        dbg_fetch <= 1'b0; dbg_io_wr <= 1'b0; dbg_io_rd <= 1'b0; dbg_inta <= 1'b0;
        if (reset) begin
            rd_have <= 1'b0; rd_go <= 1'b0; wr_done <= 1'b0; ymz_hi_pend <= 1'b0; ack_d <= 1'b0;
            irq_mask <= '0; irq_cause <= '0; irq_line <= 1'b0;
            vreg_addr <= '0; vram_bank <= '0; oki_bank <= '0; coin_counter <= 1'b0;
            for (int i = 0; i < 16; i++) blt[i] <= '0;
        end else begin
            // ---------------------------------------------------------- reads
            if (!(mem_rd || io_rd)) begin
                rd_have <= 1'b0; rd_go <= 1'b0;
            end else if (!rd_have) begin
                if (io_rd) begin
                    rd_data <= io16; rd_have <= 1'b1;
                    dbg_io_rd <= 1'b1; dbg_addr <= a; dbg_io_be <= be; dbg_io_data <= io16;
                end else if (in_rom) begin
                    if (!rd_go) begin
                        rom_req <= 1'b1; rd_go <= 1'b1;
                        if (code_fetch) begin dbg_fetch <= 1'b1; dbg_addr <= a; end
                    end else if (rom_ack) begin
                        rd_data <= {rom_q[7:0], rom_q[15:8]}; rd_have <= 1'b1;
                    end
                end else if (in_wram) begin
                    if (!rd_go) rd_go <= 1'b1;
                    else begin rd_data <= q_a; rd_have <= 1'b1; end
                end else begin
                    rd_data <= 16'h0000; rd_have <= 1'b1;   // unmapped
                end
            end

            // ---------------------------------------------------------- writes (once a bus cycle)
            if (!(mem_wr || io_wr)) wr_done <= 1'b0;
            else if (!wr_done) begin
                wr_done <= 1'b1;
                if (mem_wr && in_wram) wr_a <= 1'b1;
                if (io_wr) begin
                    dbg_io_wr <= 1'b1; dbg_addr <= a; dbg_io_be <= be; dbg_io_data <= dout;
                end
            end

            // the YMZ280B's data byte of a word write, one clock after its register byte
            if (ymz_hi_pend) begin ymz_wr <= 1'b1; ymz_a0 <= 1'b1; ymz_din <= ymz_hi_d; ymz_hi_pend <= 1'b0; end

            // ---------------------------------------------------------- I/O writes and the interrupt (MAME's irq_check)
            begin : io
                logic [7:0] m, c, ev, ack, d0, d1;
                logic chk, w;
                m = irq_mask; c = irq_cause; ev = 8'd0; ack = 8'd0; chk = 1'b0;
                w = io_wr && !wr_done;
                d0 = dout[7:0]; d1 = dout[15:8];
                if (w) begin
                    // the low byte first (MAME calls an 8-bit handler's lanes in that order)
                    if (be[0]) case ({a[15:1], 1'b0})
                        16'h7f48: begin oki_bank <= d0[6:4]; coin_counter <= d0[0]; end
                        16'h7f80: begin ymz_wr <= 1'b1; ymz_a0 <= 1'b0; ymz_din <= d0; end
                        16'h7f88: begin oki_wr <= 1'b1; oki_din <= d0; end
                        16'h7fc8: begin m = d0; chk = 1'b1; end
                        16'h7fd0: begin
                            blt[0] <= d0;
                            // the start takes the registers as they are before this write's high byte (MAME: the low byte's handler first)
                            if (d0 == 8'h02) begin
                                blt_start <= 1'b1;
                                for (int i = 1; i < 16; i++) blt_regs[8*i +: 8] <= blt[i];
                                blt_regs[7:0] <= 8'h02;
                            end
                        end
                        16'h7fd2, 16'h7fd4, 16'h7fd6, 16'h7fd8, 16'h7fda, 16'h7fdc, 16'h7fde: blt[a[3:0]] <= d0;
                        16'h7fec: vreg_addr[7:0] <= d0;
                        16'h7fee: vram_bank[7:0] <= d0;
                        default: ;
                    endcase
                    if (be[1]) case ({a[15:1], 1'b1})
                        16'h7f81: begin
                            if (be[0]) begin ymz_hi_pend <= 1'b1; ymz_hi_d <= d1; end
                            else begin ymz_wr <= 1'b1; ymz_a0 <= 1'b1; ymz_din <= d1; end
                        end
                        16'h7fc9: begin ack = d1; chk = 1'b1; end
                        16'h7fd1, 16'h7fd3, 16'h7fd5, 16'h7fd7, 16'h7fd9, 16'h7fdb, 16'h7fdd, 16'h7fdf: blt[{a[3:1], 1'b1}] <= d1;
                        16'h7fed: vreg_addr[15:8] <= d1;
                        16'h7fef: vram_bank[15:8] <= d1;
                        default: ;
                    endcase
                end
                if (vbl)     begin ev = ev | 8'h50; chk = 1'b1; end
                if (blt_irq) begin ev = ev | 8'h04; chk = 1'b1; end
                c = (c & ~ack) | ev;
                irq_mask <= m;
                irq_cause <= c;
                // the acknowledge drops the line (HOLD_LINE); an irq_check sets it from cause & mask
                ack_d <= int_ack;
                if (chk) irq_line <= (c & m) != 8'd0;
                else if (int_ack && !ack_d) irq_line <= 1'b0;
                if (int_ack && !ack_d) dbg_inta <= 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
