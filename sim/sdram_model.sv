// Copied from searchsolved/Arcade-HyperDuel_MiSTer sim/tb/sdram_model.sv at 7f154f1 (GPL-3.0-or-later), via the Metro and Rabbit cores
// (decoryah/Arcade-Metro_MiSTer, decoryah/Arcade-Rabbit_MiSTer). Gunpey: +SDRAM=<file> loads the backing store at time 0, and the store is
// public (the benches load and read it from C++).
// Behavioral SDRAM model for Verilator (16 Mword x 16, 4 banks x 8192
// rows x 512 cols = 32 MB, the MiSTer module baseline).
//
// Purpose: prove hyprduel_sdram.sv drives a real part correctly before
// any Quartus build. Models CL2 read latency, BL1, per-bank open rows,
// auto precharge (A10), DQM byte masking, and flags protocol errors
// with $error:
//   - ACT on a bank whose row is already open
//   - READ/WRITE on a bank with no open row, or before tRCD
//   - AUTO REFRESH with any row open
//   - access before the init sequence (PALL + 2x REF + MODE, CL2/BL1)
//
// Backing store is a plain byte array; the TB loads ROM images into it
// hierarchically (u_sdram_model.mem_b). Even byte address = word[15:8]
// (the 68000/build_mainrom.py lane convention used across the project).
//
// Timing alignment (matches hyprduel_sdram P_RET=3): the model samples
// a READ at posedge E1 (command was launched by the controller's
// register at E0), registers an internal fetch at E2, and drives DQ
// during the E2->E3 cycle, i.e. data on the bus two full cycles after
// the command cycle: CAS latency 2.

module sdram_model (
    input  logic        clk,
    input  logic [12:0] A,
    input  logic [1:0]  BA,
    inout  wire  [15:0] DQ,
    input  logic        DQML,
    input  logic        DQMH,
    input  logic        nCS,
    input  logic        nRAS,
    input  logic        nCAS,
    input  logic        nWE,
    input  logic        CKE
);

`ifdef F64
  logic [7:0] mem_b [0:67108863];   // 64 MB (the F64 build: 4 banks x 8192 rows x 1024 cols)
`else
  logic [7:0] mem_b [0:33554431] /* verilator public_flat_rw */;   // 32 MB
`endif

  initial begin
    string f;
    int fd, n;
    if ($value$plusargs("SDRAM=%s", f)) begin
      fd = $fopen(f, "rb");
      if (fd == 0) $fatal(1, "sdram_model: cannot open %s", f);
      n = $fread(mem_b, fd);
      $fclose(fd);
      $display("sdram_model: %0d bytes from %s", n, f);
    end
  end

  // command decode
  wire [3:0] cmd = {nCS, nRAS, nCAS, nWE};
  localparam logic [3:0] CMD_NOP  = 4'b0111;
  localparam logic [3:0] CMD_ACT  = 4'b0011;
  localparam logic [3:0] CMD_READ = 4'b0101;
  localparam logic [3:0] CMD_WRIT = 4'b0100;
  localparam logic [3:0] CMD_PALL = 4'b0010;
  localparam logic [3:0] CMD_REF  = 4'b0001;
  localparam logic [3:0] CMD_MODE = 4'b0000;

  // per-bank state (Verilator zero-initializes; no initial block, it
  // would trip MULTIDRIVEN against the always_ff)
  logic        row_open [4];
  logic [12:0] open_row [4];
  longint      act_time [4];
  longint      now = 0;       // longint: a 32 bit count wrapped after 2^31 clocks = 22.4 s and made every check fail (20261011 sound bench)

  // timing checks beyond the protocol checks above, in clock cycles of the 96 MHz machine clock (10.4 ns): tRCD 2, tRP 2, tRAS 5, tRC 6 (and 7 counted
  // separately: a 70 ns part), tRRD 2, tWR 2, tRFC 7, an average refresh interval of 7.8 us (750 cycles); summary at the end of the run (+SDRCHK prints each one)
  int          chk_print = 0;
  initial void'($value$plusargs("SDRCHK=%d", chk_print));
  bit          act_valid [4];
  longint      pre_ready [4];       // earliest cycle an ACT may go to the bank (after its precharge)
  longint      last_act_any = -1000;
  longint      act_block_until = 0; // after a refresh (tRFC)
  longint      last_ref = 0, max_ref_gap = 0, ref_cnt = 0;
  int          v_rc6 = 0, v_rc7 = 0, v_rrd = 0, v_rp = 0, v_rfc = 0, v_ras = 0, n_act = 0, n_rd = 0;
  function automatic longint imax(input longint a, input longint b); return a > b ? a : b; endfunction
  final $display("SDRCHK summary: ACT %0d READ %0d | violations: tRC6 %0d tRC7 %0d tRRD %0d tRP %0d tRFC %0d tRAS %0d | refreshes %0d, longest gap between two %0d cycles",
                 n_act, n_rd, v_rc6, v_rc7, v_rrd, v_rp, v_rfc, v_ras, ref_cnt, max_ref_gap);

  // the last 10 commands, printed with every violation (+SDRCHK=1)
  longint      hist_t [10];
  logic [3:0]  hist_c [10];
  logic [1:0]  hist_b [10];
  logic [12:0] hist_a [10];
  int          hist_p = 0, dumps = 0;
  task automatic dump_hist(input string why);
    if (dumps < 60) begin
      dumps++;
      $display("SDRCHK ---- %s at t=%0d; last commands (oldest first):", why, now);
      for (int i = 0; i < 10; i++)
        $display("SDRCHK   t=%0d cmd=%b BA=%0d A=%h", hist_t[(hist_p + i) % 10], hist_c[(hist_p + i) % 10], hist_b[(hist_p + i) % 10], hist_a[(hist_p + i) % 10]);
    end
  endtask

  // init tracking
  int  init_refs = 0;
  bit  saw_pall = 0, mode_set = 0;

  // read pipeline (CL2)
  logic        rd_pend = 1'b0;  // stage 1: sampled READ
  logic [24:0] rd_word;
  logic        drv_en = 1'b0;   // stage 2: driving DQ this cycle
  logic [15:0] drv_data;

  assign DQ = drv_en ? drv_data : 16'hzzzz;

  // debug: +SDRTRACE=1 prints every non-NOP command
  int trace = 0;
  initial void'($value$plusargs("SDRTRACE=%d", trace));
  always @(posedge clk)
    if (trace != 0 && CKE && cmd != CMD_NOP && cmd[3] == 1'b0)
      $display("SDR t=%0d cmd=%b A=%h BA=%b", now, cmd, A, BA);

  always_ff @(posedge clk) begin
    logic [24:0] w;
    now <= now + 1;
    if (CKE && cmd != CMD_NOP && cmd[3] == 1'b0) begin
      hist_t[hist_p] <= now; hist_c[hist_p] <= cmd; hist_b[hist_p] <= BA; hist_a[hist_p] <= A;
      hist_p <= (hist_p + 1) % 10;
    end

    // stage 2: drive previously fetched data for exactly one cycle
    drv_en <= rd_pend;
    if (rd_pend)
      drv_data <= {mem_b[{rd_word, 1'b0}], mem_b[{rd_word, 1'b1}]};
    rd_pend <= 1'b0;

    if (CKE) begin
      case (cmd)
        CMD_MODE: begin
          if (A[6:4] != 3'b010)
            $error("sdram_model: mode register CL=%0d, expected CL2", A[6:4]);
          if (A[2:0] != 3'b000)
            $error("sdram_model: mode register BL!=1 (A=%h)", A);
          mode_set <= 1'b1;
        end

        CMD_PALL: begin
          if (A[10]) begin
            for (int b = 0; b < 4; b++) begin
              if (row_open[b] && now - act_time[b] < 5) begin v_ras <= v_ras + 1; if (chk_print != 0) $display("SDRCHK t=%0d PALL violates tRAS on bank %0d", now, b); end
              pre_ready[b] <= imax(now, act_time[b] + 5) + 2;
              row_open[b] <= 1'b0;
            end
            saw_pall <= 1'b1;
          end
        end

        CMD_REF: begin
          for (int b = 0; b < 4; b++)
            if (row_open[b])
              $error("sdram_model: AUTO REFRESH with bank %0d row open", b);
          if (!saw_pall)
            $error("sdram_model: AUTO REFRESH before PRECHARGE ALL");
          init_refs <= init_refs + 1;
          for (int b = 0; b < 4; b++)
            if (now < pre_ready[b]) begin v_rp <= v_rp + 1; if (chk_print != 0) begin $display("SDRCHK t=%0d REF violates tRP on bank %0d", now, b); dump_hist("REF tRP"); end end
          if (ref_cnt != 0 && now - last_ref > max_ref_gap) max_ref_gap <= now - last_ref;
          ref_cnt <= ref_cnt + 1;
          last_ref <= now;
          act_block_until <= now + 7;
        end

        CMD_ACT: begin
          if (row_open[BA])
            $error("sdram_model: ACT on bank %0d with row already open", BA);
          if (init_refs < 2 || !mode_set)
            $error("sdram_model: ACT before init complete (refs=%0d mode=%0d)",
                   init_refs, mode_set);
          n_act <= n_act + 1;
          if (act_valid[BA] && now - act_time[BA] < 6) begin v_rc6 <= v_rc6 + 1; if (chk_print != 0) $display("SDRCHK t=%0d ACT violates tRC(6) on bank %0d (%0d cycles)", now, BA, now - act_time[BA]); end
          if (act_valid[BA] && now - act_time[BA] < 7) v_rc7 <= v_rc7 + 1;
          if (now - last_act_any < 2) begin v_rrd <= v_rrd + 1; if (chk_print != 0) $display("SDRCHK t=%0d ACT violates tRRD (%0d cycles)", now, now - last_act_any); end
          if (now < pre_ready[BA]) begin v_rp <= v_rp + 1; if (chk_print != 0) begin $display("SDRCHK t=%0d ACT violates tRP on bank %0d (%0d cycles early)", now, BA, pre_ready[BA] - now); dump_hist("ACT tRP"); end end
          if (now < act_block_until) begin v_rfc <= v_rfc + 1; if (chk_print != 0) begin $display("SDRCHK t=%0d ACT violates tRFC", now); dump_hist("ACT tRFC"); end end
          last_act_any <= now;
          act_valid[BA] <= 1'b1;
          row_open[BA] <= 1'b1;
          open_row[BA] <= A;
          act_time[BA] <= now;
        end

        CMD_READ: begin
          if (!row_open[BA])
            $error("sdram_model: READ on bank %0d with no open row", BA);
          if (now - act_time[BA] < 2)
            $error("sdram_model: READ violates tRCD on bank %0d", BA);
          rd_pend <= 1'b1;
`ifdef F64
          rd_word <= {BA, open_row[BA], A[9:0]};
`else
          rd_word <= {BA, open_row[BA], A[8:0]};
`endif
          n_rd <= n_rd + 1;
          if (A[10]) begin
            row_open[BA] <= 1'b0;   // auto precharge: it starts after the burst and not before tRAS
            pre_ready[BA] <= imax(now + 1, act_time[BA] + 5) + 2;
          end
        end

        CMD_WRIT: begin
          if (!row_open[BA])
            $error("sdram_model: WRITE on bank %0d with no open row", BA);
          if (now - act_time[BA] < 2)
            $error("sdram_model: WRITE violates tRCD on bank %0d", BA);
`ifdef F64
          w = {BA, open_row[BA], A[9:0]};
`else
          w = {BA, open_row[BA], A[8:0]};
`endif
          if (!DQMH) mem_b[{w, 1'b0}] <= DQ[15:8];  // even byte = high lane
          if (!DQML) mem_b[{w, 1'b1}] <= DQ[7:0];
          if (A[10]) begin
            row_open[BA] <= 1'b0;
            pre_ready[BA] <= imax(now + 1 + 2, act_time[BA] + 5) + 2;     // write recovery (tWR 2) first
          end
        end

        default: ;  // NOP / unencoded
      endcase
    end
  end

endmodule
