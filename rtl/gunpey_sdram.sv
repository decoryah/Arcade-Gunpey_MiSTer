//------------------------------------------------------------------------------
// SDRAM controller of the Gunpey core: one 16-bit SDR SDRAM (the MiSTer 32 MB module: 4 banks x 8192 rows x 512 columns) shared by the
// ROM image's download and the machine's clients, which read and (the blitter, into the video RAM) write.
//
// The Rabbit core's rabbit_sdram.sv (the Metro core's pin protocol and timing, proven on the owner's MiSTer at 96 MHz; here it runs at
// 85.86 MHz): close-page, burst length 1, CAS latency 2, every access ACT, tRCD, a run of READ or WRITE commands one a clock in the open
// row (auto precharge on the last), the read data captured P_RET clocks after its READ (one more with i_rd_late), a refresh every 670
// clocks (7.8 us), full-word writes only (the MiSTer SDRAM boards tie DQML / DQMH low). What is new is the client write: a client that
// asks with c_we gives its words on c_wdata, one a clock, and is told with c_wpull that the word it shows was taken.
//
//   client protocol: c_req[i] high with c_addr[i] / c_len[i] / c_we[i] stable; the controller answers c_ack[i] (one clock) when it takes
//   the request (the ACT is issued then), and the client drops c_req[i] in the next clock (or keeps it up for a new request with new
//   fields). A read's c_len words then arrive on o_rdata, one c_valid[i] each; a write's words are taken from c_wdata[i], one c_wpull[i]
//   each (the client shows the next word in the clock after a pull). A burst is 1 .. 16 words inside one aligned 16-word block.
//
// Priority: refresh when overdue, the download (the machine is in reset meanwhile), then client 0 first.
//------------------------------------------------------------------------------
`default_nettype none

module gunpey_sdram #(
    parameter bit P_SHORT_INIT = 1'b0,  // simulation: skip the 100 us power-up wait
    parameter int P_RET = 3,            // READ command -> captured data, clocks
    parameter int NC = 6,               // clients
    parameter int REFRESH_PERIOD = 670, // 7.8 us at 85.86 MHz
    parameter int INIT_WAIT_CLKS = 8600 // 100 us at 85.86 MHz
) (
    input  logic        clk,
    input  logic        rst_n,
    output logic        o_ready,
    input  logic        i_rd_late,      // capture the read data one clock later

    // the ROM image, a byte at a time in address order (even byte then odd byte of every word)
    input  logic        i_dl_wr,
    input  logic [24:0] i_dl_addr,      // byte address in the SDRAM
    input  logic  [7:0] i_dl_data,
    output logic        o_dl_busy,
    output logic        o_dl_idle,      // every downloaded word is written (the machine may start)

    // clients
    input  logic        c_req  [NC],
    input  logic [23:0] c_addr [NC],    // word address
    input  logic  [4:0] c_len  [NC],    // 1 .. 16 words, within one aligned 16-word block
    input  logic        c_we   [NC],
    input  logic [15:0] c_wdata[NC],
    output logic        c_ack  [NC],
    output logic        c_valid[NC],
    output logic        c_wpull[NC],
    output logic [15:0] o_rdata,

    // SDRAM pins
    output logic [12:0] SDRAM_A,
    output logic  [1:0] SDRAM_BA,
    inout  wire  [15:0] SDRAM_DQ,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH,
    output logic        SDRAM_nCS,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_nWE,
    output logic        SDRAM_CKE
);
    // command encoding {nCS, nRAS, nCAS, nWE}
    localparam logic [3:0] CMD_NOP  = 4'b0111;
    localparam logic [3:0] CMD_ACT  = 4'b0011;
    localparam logic [3:0] CMD_READ = 4'b0101;
    localparam logic [3:0] CMD_WRIT = 4'b0100;
    localparam logic [3:0] CMD_PALL = 4'b0010;
    localparam logic [3:0] CMD_REF  = 4'b0001;
    localparam logic [3:0] CMD_MODE = 4'b0000;

    localparam logic [12:0] MODE_REG = 13'h020;           // burst length 1, sequential, CAS latency 2
    localparam int INIT_WAIT = P_SHORT_INIT ? 32 : INIT_WAIT_CLKS;

    /* verilator lint_off PROCASSINIT */
    logic [3:0] cmd = CMD_NOP;
    /* verilator lint_on PROCASSINIT */
    assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
    assign SDRAM_CKE = 1'b1;

    logic [15:0] dq_out;
    logic        dq_oe;
    assign SDRAM_DQ = dq_oe ? dq_out : 16'hzzzz;

    logic [15:0] dq_in0, dq_in1;
    always_ff @(posedge clk) begin dq_in0 <= SDRAM_DQ; dq_in1 <= dq_in0; end
    wire  [15:0] dq_in = i_rd_late ? dq_in1 : dq_in0;

    // ------------------------------------------------------------------ the read-return tags
    // written at each READ command: {valid, client}; the tag reaching stage P_RET (P_RET + 1 late) lands with its word
    localparam int CW = (NC > 1) ? $clog2(NC) : 1;
    logic [CW:0] ret_tag [P_RET+2];
    always_ff @(posedge clk)
        for (int i = P_RET + 1; i > 0; i--) ret_tag[i] <= ret_tag[i-1];
    wire  [CW:0] land = i_rd_late ? ret_tag[P_RET+1] : ret_tag[P_RET];

    always_ff @(posedge clk) begin
        o_rdata <= dq_in;
        for (int i = 0; i < NC; i++) c_valid[i] <= land[CW] && (land[CW-1:0] == CW'(i));
    end

    // ------------------------------------------------------------------ the download FIFO
    // 16 words: the byte stream is paired into words (the even byte waits for its odd partner) before it is queued
    logic [39:0] dlf [16];           // {word address [23:0], data}
    logic  [3:0] dlf_wp, dlf_rp;
    logic  [4:0] dlf_cnt;
    logic  [7:0] dl_even;
    logic        dlf_pop;
    wire         dlf_empty = (dlf_cnt == 5'd0);
    wire         dlf_push  = i_dl_wr && i_dl_addr[0] && (dlf_cnt != 5'd16);
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dlf_wp <= '0; dlf_rp <= '0; dlf_cnt <= '0;
        end else begin
            if (i_dl_wr && !i_dl_addr[0]) dl_even <= i_dl_data;
            if (dlf_push) begin dlf[dlf_wp] <= {i_dl_addr[24:1], dl_even, i_dl_data}; dlf_wp <= dlf_wp + 4'd1; end
            if (dlf_pop) dlf_rp <= dlf_rp + 4'd1;
            case ({dlf_push, dlf_pop})
                2'b10:   dlf_cnt <= dlf_cnt + 5'd1;
                2'b01:   dlf_cnt <= dlf_cnt - 5'd1;
                default: ;
            endcase
        end
    end
    assign o_dl_busy = !o_ready || (dlf_cnt >= 5'd12);

    // ------------------------------------------------------------------ the state machine
    typedef enum logic [3:0] {
        ST_INIT_WAIT, ST_INIT_PALL, ST_INIT_REF1, ST_INIT_REF2, ST_INIT_MODE,
        ST_IDLE, ST_ACT, ST_RCD, ST_CAS, ST_WCAS, ST_WWAIT, ST_RFC
    } st_e;
    st_e st;

    logic          own_dl;           // the access is the download's write
    wire           own_dl_busy = own_dl && (st != ST_IDLE);
    assign o_dl_idle = o_ready && dlf_empty && !own_dl_busy;
    logic          own_we;           // the access is a client's write
    logic [CW-1:0] owner;
    logic [23:0]   cur_word;
    logic  [4:0]   cas_left;
    logic          req_short;
    logic [15:0]   dl_data_q;
    logic  [3:0]   wait_cnt;
    logic [13:0]   init_cnt;
    logic  [9:0]   ref_cnt;
    logic          ref_due, ref_urgent, idle_d;
    logic          any_req_q;        // a client asked a clock ago (the refresh's yield; registered for the clock's sake)

    // the highest-priority client asking
    logic          any_req;
    logic [CW-1:0] pick;
    always_comb begin
        any_req = 1'b0; pick = '0;
        for (int i = NC - 1; i >= 0; i--) if (c_req[i] && !c_ack[i]) begin any_req = 1'b1; pick = CW'(i); end
    end

    wire [8:0]  col9  = cur_word[8:0];
    wire [12:0] row13 = cur_word[21:9];
    wire [1:0]  bank2 = cur_word[23:22];

    always_comb for (int i = 0; i < NC; i++) c_wpull[i] = (st == ST_WCAS) && (owner == CW'(i));

    always_ff @(posedge clk) begin
        idle_d     <= (st == ST_IDLE) && (wait_cnt == 4'd0);
        any_req_q  <= any_req;
        cmd        <= CMD_NOP;
        SDRAM_A    <= '0;
        SDRAM_BA   <= bank2;
        dq_oe      <= 1'b0;
        ret_tag[0] <= '0;
        dlf_pop    <= 1'b0;
        for (int i = 0; i < NC; i++) c_ack[i] <= 1'b0;

        if (!rst_n) begin
            st <= ST_INIT_WAIT; o_ready <= 1'b0;
            init_cnt <= '0; wait_cnt <= '0; cas_left <= '0;
            ref_cnt <= '0; ref_due <= 1'b0; ref_urgent <= 1'b0;
            SDRAM_DQML <= 1'b1; SDRAM_DQMH <= 1'b1;
            own_dl <= 1'b0; own_we <= 1'b0; owner <= '0;
        end else begin
            if (32'(ref_cnt) == REFRESH_PERIOD - 1) begin
                ref_cnt <= '0; ref_urgent <= ref_due; ref_due <= 1'b1;
            end else ref_cnt <= ref_cnt + 10'd1;

            case (st)
                ST_INIT_WAIT: begin
                    SDRAM_DQML <= 1'b1; SDRAM_DQMH <= 1'b1;
                    init_cnt <= init_cnt + 14'd1;
                    if (32'(init_cnt) == INIT_WAIT) st <= ST_INIT_PALL;
                end
                ST_INIT_PALL: begin
                    cmd <= CMD_PALL; SDRAM_A <= 13'h400;
                    wait_cnt <= 4'd2; st <= ST_INIT_REF1;
                end
                ST_INIT_REF1:
                    if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
                    else begin cmd <= CMD_REF; wait_cnt <= 4'd8; st <= ST_INIT_REF2; end
                ST_INIT_REF2:
                    if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
                    else begin cmd <= CMD_REF; wait_cnt <= 4'd8; st <= ST_INIT_MODE; end
                ST_INIT_MODE:
                    if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
                    else begin
                        cmd <= CMD_MODE; SDRAM_A <= MODE_REG; SDRAM_BA <= 2'b00;
                        wait_cnt <= 4'd2; st <= ST_IDLE; o_ready <= 1'b1;
                    end

                ST_IDLE: begin
                    SDRAM_DQML <= 1'b0; SDRAM_DQMH <= 1'b0;
                    if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
                    else if (ref_urgent && !idle_d) begin
                        // one more clock for the precharge of the access before
                    end else if (idle_d && (ref_urgent || (ref_due && !any_req_q && dlf_empty))) begin
                        cmd <= CMD_REF; ref_due <= 1'b0; ref_urgent <= 1'b0;
                        wait_cnt <= 4'd8; st <= ST_RFC;
                    end else if (!dlf_empty) begin
                        own_dl <= 1'b1; own_we <= 1'b0; req_short <= 1'b1;
                        dl_data_q <= dlf[dlf_rp][15:0];
                        cur_word  <= dlf[dlf_rp][39:16];
                        dlf_pop   <= 1'b1;
                        st <= ST_ACT;
                    end else if (any_req) begin
                        own_dl <= 1'b0; own_we <= c_we[pick]; owner <= pick;
                        cur_word <= c_addr[pick];
                        cas_left <= (c_len[pick] == 5'd0) ? 5'd1 : c_len[pick];
                        req_short <= (c_len[pick] < 5'd4);
                        c_ack[pick] <= 1'b1;
                        st <= ST_ACT;
                    end
                end

                ST_ACT: begin
                    cmd <= CMD_ACT; SDRAM_A <= row13;
                    st <= ST_RCD;
                end
                ST_RCD: st <= own_we ? ST_WCAS : ST_CAS;          // tRCD: ACT, this clock, then the column command

                ST_CAS: begin
                    if (own_dl) begin
                        cmd <= CMD_WRIT; dq_oe <= 1'b1; dq_out <= dl_data_q;
                        SDRAM_A <= {2'b00, 1'b1, 1'b0, col9};       // A10: auto precharge
                        wait_cnt <= 4'd4;                            // tWR + tRP (+1 for tRC)
                        st <= ST_WWAIT;
                    end else begin
                        cmd <= CMD_READ;
                        SDRAM_A <= {2'b00, (cas_left == 5'd1), 1'b0, col9};
                        ret_tag[0] <= {1'b1, owner};
                        cur_word <= cur_word + 24'd1;
                        cas_left <= cas_left - 5'd1;
                        if (cas_left == 5'd1) begin
                            // ACT, tRCD, the READs, two waits and the grant: under tRC for the next ACT to the bank (a 1 .. 3 word access one more)
                            wait_cnt <= req_short ? 4'd3 : 4'd2;
                            st <= ST_IDLE;
                        end
                    end
                end
                // a client's write burst: one WRITE a clock with the word the client shows (c_wpull tells it the word was taken)
                ST_WCAS: begin
                    cmd <= CMD_WRIT; dq_oe <= 1'b1; dq_out <= c_wdata[owner];
                    SDRAM_A <= {2'b00, (cas_left == 5'd1), 1'b0, col9};
                    cur_word <= cur_word + 24'd1;
                    cas_left <= cas_left - 5'd1;
                    if (cas_left == 5'd1) begin
                        wait_cnt <= 4'd4;                            // tWR + tRP (+1 for tRC)
                        st <= ST_WWAIT;
                    end
                end
                ST_WWAIT: begin
                    SDRAM_DQML <= 1'b0; SDRAM_DQMH <= 1'b0;
                    if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
                    else st <= ST_IDLE;
                end
                ST_RFC:
                    if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
                    else st <= ST_IDLE;
                default: st <= ST_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
