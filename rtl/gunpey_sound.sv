//------------------------------------------------------------------------------
// The board's sound (MAME 0.289 gunpey.cpp): a YMZ280B (16.9344 MHz; rtl/gunpey_ymz280b.sv) and an OKI M6295 (16.9344 MHz / 8, pin 7 low:
// a sample every 165 of its clocks; jt6295, Jose Tejada, as the owner's other cores have it), whose 256 KB address space is one of eight
// banks of its ROM (the CPU's output port, bits 6-4). Both read their ROMs a byte at a time from the SDRAM.
//
// MAME's mix: the YMZ280B at 0.25 into each side, the OKI (mono) at 0.125 into both. In 16-bit units (a full-scale sample 32768) that is
// ymz / 4 + oki * 2 (jt6295's 14-bit sum is MAME's level * 2048); the output here is twice that, saturated.
//------------------------------------------------------------------------------
`default_nettype none

module gunpey_sound #(
    parameter logic [23:0] YMZ_BASE = 24'h280000,    // the YMZ280B's ROM (4 MB), word address
    parameter logic [23:0] OKI_BASE = 24'h480000     // the OKI's ROM (2 MB used), word address
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        ymz_wr,
    input  logic        ymz_a0,
    input  logic  [7:0] ymz_din,
    input  logic        oki_wr,
    input  logic  [7:0] oki_din,
    output logic  [7:0] oki_dout,
    input  logic  [2:0] oki_bank,

    // the two SDRAM read clients (one word each)
    output logic        y_req,
    output logic [23:0] y_addr,
    input  logic        y_ack,
    input  logic        y_valid,
    output logic        o_req,
    output logic [23:0] o_addr,
    input  logic        o_ack,
    input  logic        o_valid,
    input  logic [15:0] sd_data,

    output logic signed [15:0] out_l,
    output logic signed [15:0] out_r
);
    // ================================================================== the YMZ280B
    logic        yr_req, yr_ack;
    logic [23:0] yr_addr;
    logic  [7:0] yr_data;
    logic signed [15:0] ymz_l, ymz_r;
    logic        ymz_v;

    gunpey_ymz280b u_ymz (
        .clk(clk), .rst(reset),
        .wr(ymz_wr), .a0(ymz_a0), .din(ymz_din),
        .rom_req(yr_req), .rom_addr(yr_addr), .rom_ack(yr_ack), .rom_data(yr_data),
        .out_valid(ymz_v), .out_l(ymz_l), .out_r(ymz_r), .dbg_l(), .dbg_r(), .overrun(), .dbg_tick()
    );

    // its byte reads: the word, then the byte (the even byte is the word's high half); the 4 MB repeat in its 16 MB space
    typedef enum logic [1:0] { Y_IDLE, Y_REQ, Y_WAIT } yst_t;
    yst_t yst;
    logic ybyte;
    always_ff @(posedge clk) begin
        yr_ack <= 1'b0;
        if (y_ack) y_req <= 1'b0;
        if (reset) begin
            yst <= Y_IDLE; y_req <= 1'b0;
        end else case (yst)
            Y_IDLE: if (yr_req && !yr_ack) begin
                y_req <= 1'b1; y_addr <= YMZ_BASE + {3'd0, yr_addr[21:1]}; ybyte <= yr_addr[0];
                yst <= Y_REQ;
            end
            Y_REQ:  if (y_ack) yst <= Y_WAIT;
            Y_WAIT: if (y_valid) begin
                yr_data <= ybyte ? sd_data[7:0] : sd_data[15:8];
                yr_ack <= 1'b1;
                yst <= Y_IDLE;
            end
            default: yst <= Y_IDLE;
        endcase
    end

    // ================================================================== the OKI M6295
    // its clock: 2.1168 MHz, 588 / 23851 of 85.8636 MHz
    logic [14:0] ocen_acc;
    logic        ocen;
    always_ff @(posedge clk) begin
        ocen <= 1'b0;
        if (reset) ocen_acc <= '0;
        else if (ocen_acc + 15'd588 >= 15'd23851) begin ocen_acc <= ocen_acc + 15'd588 - 15'd23851; ocen <= 1'b1; end
        else ocen_acc <= ocen_acc + 15'd588;
    end

    logic        owrn;
    logic  [7:0] odin_r;
    logic [17:0] orom_a;
    logic  [7:0] orom_d;
    logic        orom_ok;
    logic signed [13:0] oki_snd;

    // a CPU write: the write strobe low for a clock (jt6295 takes its falling edge on the system clock, as the Oh My God! core drives it)
    always_ff @(posedge clk) begin
        owrn <= 1'b1;
        if (oki_wr) begin owrn <= 1'b0; odin_r <= oki_din; end
    end

    jt6295 #(.INTERPOL(0)) u_oki (
        .rst(reset), .clk(clk), .cen(ocen), .ss(1'b0),
        .wrn(owrn), .din(odin_r), .dout(oki_dout),
        .rom_addr(orom_a), .rom_data(orom_d), .rom_ok(orom_ok),
        .sound(oki_snd), .sample()
    );

    // its ROM byte: read whenever the address (or the bank) changes, held in a register
    wire  [20:0] o_want = {oki_bank, orom_a};
    logic [20:0] o_have_a;
    logic        o_have, o_busy, obyte;
    assign orom_ok = o_have && (o_have_a == o_want);
    always_ff @(posedge clk) begin
        if (o_ack) o_req <= 1'b0;
        if (reset) begin
            o_have <= 1'b0; o_busy <= 1'b0; o_req <= 1'b0;
        end else if (o_busy) begin
            if (o_valid) begin orom_d <= obyte ? sd_data[7:0] : sd_data[15:8]; o_have <= 1'b1; o_busy <= 1'b0; end
        end else if (!(o_have && o_have_a == o_want)) begin
            o_req <= 1'b1; o_addr <= OKI_BASE + {4'd0, o_want[20:1]}; obyte <= o_want[0];
            o_have_a <= o_want; o_have <= 1'b0; o_busy <= 1'b1;
        end
    end

    // ================================================================== the mix (MAME's, twice)
    logic signed [15:0] yl, yr;
    always_ff @(posedge clk) if (ymz_v) begin yl <= ymz_l; yr <= ymz_r; end
    function automatic signed [15:0] sat(input signed [19:0] v);
        sat = (v > 20'sd32767) ? 16'sh7fff : (v < -20'sd32768) ? 16'sh8000 : v[15:0];
    endfunction
    always_ff @(posedge clk) begin
        out_l <= sat(20'(yl >>> 1) + 20'(oki_snd) * 20'sd4);
        out_r <= sat(20'(yr >>> 1) + 20'(oki_snd) * 20'sd4);
    end
endmodule
`default_nettype wire
