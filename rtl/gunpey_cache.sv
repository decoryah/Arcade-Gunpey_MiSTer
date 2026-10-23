//------------------------------------------------------------------------------
// The V30's program ROM cache: direct mapped, 8-word (16-byte) lines in block RAM, filled from the SDRAM by an 8-word burst
// (gunpey_sdram's client protocol). The Rabbit core's rabbit_cache.sv, after the Mystic Warriors core's rom_cache.sv (the owner's,
// proven on the MiSTer).
//
// The CPU side: `req` is a one-clock pulse with the address; the tag and the word are read in that clock and compared
// in the next, where a hit raises `ack` (combinationally) with the word on `q`. A miss fills the line and answers when it is there.
// `reset` drops every line (a new image is loading); a sweep then clears the tags and `ready` rises when it is done.
//------------------------------------------------------------------------------
`default_nettype none

module gunpey_cache #(
    parameter int AW  = 19,                     // word-address bits of the ROM (1 MB)
    parameter int IDX = 11,                     // lines: 2^IDX (2048 lines = 32 KB)
    parameter logic [23:0] BASE = 24'h000000    // the ROM's first word in the SDRAM
) (
    input  logic          clk,
    input  logic          reset,
    output logic          ready,

    input  logic          req,
    input  logic [AW-1:0] addr,
    output logic          ack,
    output logic   [15:0] q,

    // the SDRAM client
    output logic          m_req,
    output logic   [23:0] m_addr,
    output logic    [4:0] m_len,
    input  logic          m_ack,
    input  logic          m_valid,
    input  logic   [15:0] m_data
);
    localparam int TAGW = AW - 3 - IDX;

    typedef enum logic [2:0] { C_SWEEP, C_IDLE, C_RD, C_CMP, C_FILL } cst_t;
    cst_t st;

    logic [AW-1:0]  addr_l;
    logic [IDX-1:0] sweep_i;
    logic           tw_en;
    logic [TAGW:0]  tw_d;
    logic [IDX-1:0] tw_a;
    logic   [2:0]   fill_i;
    logic           fill_go;                    // the burst was taken, words are coming

    wire [IDX-1:0] r_idx  = (st == C_IDLE) ? addr[IDX+2:3] : addr_l[IDX+2:3];
    wire     [2:0] r_word = (st == C_IDLE) ? addr[2:0]      : addr_l[2:0];

    (* ramstyle = "M10K,no_rw_check" *) logic [15:0]   dmem [1 << (IDX + 3)];
    (* ramstyle = "M10K,no_rw_check" *) logic [TAGW:0] tmem [1 << IDX];
    logic [15:0]   dat_q;
    logic [TAGW:0] tag_q;

    wire fill_wr = (st == C_FILL) && fill_go && m_valid;
    wire fill_done = fill_wr && (fill_i == 3'd7);

    always_ff @(posedge clk) begin
        if (fill_wr) dmem[{addr_l[IDX+2:3], fill_i}] <= m_data;
        dat_q <= dmem[{r_idx, r_word}];
    end
    always_ff @(posedge clk) begin
        if (tw_en) tmem[tw_a] <= tw_d;
        tag_q <= tmem[r_idx];
    end

    always_comb begin
        tw_en = 1'b0; tw_a = sweep_i; tw_d = '0;
        if (!reset && st == C_SWEEP) tw_en = 1'b1;
        else if (!reset && fill_done) begin
            tw_en = 1'b1; tw_a = addr_l[IDX+2:3]; tw_d = {1'b1, addr_l[AW-1:IDX+3]};
        end
    end

    wire hit = tag_q[TAGW] && (tag_q[TAGW-1:0] == addr_l[AW-1:IDX+3]);
    assign ack = (st == C_CMP) && hit;
    assign q   = dat_q;

    always_ff @(posedge clk) begin
        if (m_ack) m_req <= 1'b0;
        if (reset) begin
            st <= C_SWEEP; sweep_i <= '0; ready <= 1'b0; m_req <= 1'b0; fill_go <= 1'b0;
        end else case (st)
            C_SWEEP: begin
                sweep_i <= sweep_i + 1'b1;
                if (sweep_i == {IDX{1'b1}}) begin st <= C_IDLE; ready <= 1'b1; end
            end
            C_IDLE: if (req) begin addr_l <= addr; st <= C_CMP; end
            C_RD:   st <= C_CMP;
            C_CMP: begin
                if (hit) st <= C_IDLE;
                else begin
                    m_req <= 1'b1; m_addr <= BASE + 24'({addr_l[AW-1:3], 3'b000}); m_len <= 5'd8;
                    fill_i <= '0; fill_go <= 1'b0;
                    st <= C_FILL;
                end
            end
            C_FILL: begin
                if (m_ack) fill_go <= 1'b1;
                if (fill_wr) begin
                    fill_i <= fill_i + 3'd1;
                    if (fill_i == 3'd7) begin fill_go <= 1'b0; st <= C_RD; end
                end
            end
            default: st <= C_IDLE;
        endcase
    end
endmodule
`default_nettype wire
