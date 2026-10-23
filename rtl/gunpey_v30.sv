//------------------------------------------------------------------------------
// The NEC V30 and its bus: the Irem M72 core's ucore V30 (rtl/v30, MiSTer-devel/Arcade-IremM72_MiSTer, GPL-2.0-or-later) behind that
// core's bus adapter (its rtl/v30/v30_bus.sv), here without the save-state port. The adapter is the max-mode bus controller: it follows
// the core's T-states from its bus status (BS) and READY, and gives a word-aligned bus with byte enables, read / write strobes for memory
// and I/O, and the interrupt acknowledge with its vector.
//
// The core's own notes on the adapter's timing (kept from v30_bus.sv):
//   * `ADDR_O` is captured at T1 entry, `UBE_N` inside T1: the two do not change owner together.
//   * the read data into the core is NOT registered here: the core captures it at the `ce` that leaves T2, and the board's read path
//     already takes the clocks between the T1 address latch and that `ce` (gunpey_main stalls the clock enable until its word is there).
//   * the two INTA cycles are paired by count, not by adjacency.
// For this board's clock (a CPU clock enable in five or more system clocks) the core's write word is registered here at every clock
// enable (it is meaningful from the write cycle's T1, so the T3 that writes has it), and every register here that follows the core is
// clock-enabled or only read at a clock enable: Gunpey.sdc gives the paths from the core to them the clock enables' spacing.
//------------------------------------------------------------------------------
`default_nettype none

module gunpey_v30 (
    input  wire        clk,
    input  wire        ce,          // a T-state
    input  wire        reset,
    input  wire        ready,       // READY: low at T3 / Tw inserts a Tw

    // the word-aligned bus
    output wire [19:0] cpu_addr,    // bit 0 is 0
    output wire  [1:0] cpu_be,      // [0] the low byte (A0 = 0), [1] the high byte (UBE)
    output wire [15:0] cpu_dout,    // write data (valid during a write cycle)
    input  wire [15:0] cpu_din,     // read data (taken by the core at the end of T2)

    // the access strobes
    output wire        mem_rd,      // level, T2 .. T3 (code or data read)
    output wire        io_rd,       // level, T2 .. T3
    output wire        mem_wr,      // level, held during T3 / Tw
    output wire        io_wr,       // level, held during T3 / Tw
    output wire        code_fetch,  // the cycle is a prefetch
    output wire        bus_active,  // an address is latched (T2 .. T3 / Tw) for a memory or I/O cycle

    // the interrupt
    input  wire        int_req,
    input  wire  [7:0] int_vector,
    output wire        int_ack      // level, T3 of the second INTA cycle
);
    import v30_ss_pkg::*;

    // bus status codes (8086 S2-S0 compatible)
    localparam bit [2:0] BS_INTA = 3'b000;
    localparam bit [2:0] BS_IOR  = 3'b001;
    localparam bit [2:0] BS_IOW  = 3'b010;
    localparam bit [2:0] BS_HALT = 3'b011;
    localparam bit [2:0] BS_CODE = 3'b100;
    localparam bit [2:0] BS_MEMR = 3'b101;
    localparam bit [2:0] BS_MEMW = 3'b110;
    localparam bit [2:0] BS_PASV = 3'b111;

    localparam bit [2:0] ST_TI = 3'd0;
    localparam bit [2:0] ST_T1 = 3'd1;
    localparam bit [2:0] ST_T2 = 3'd2;
    localparam bit [2:0] ST_T3 = 3'd3;
    localparam bit [2:0] ST_TW = 3'd4;
    localparam bit [2:0] ST_T4 = 3'd5;

    wire  [2:0] BS;
    wire        RD_N, UBE_N;
    wire [19:0] ADDR_O;
    wire [15:0] DATA_O;
    wire  [3:0] STATUS_O;
    wire [15:0] core_din;
    wire [15:0] ss_rdata_unused;
    wire        ss_err_unused, ss_quiet_unused;

    v30_core u_core (
        .CLK         (clk),
        .CE          (ce),
        .RESET       (reset),
        .READY       (ready),
        .INT         (int_q),
        .NMI         (1'b0),
        .POLL_N      (1'b1),
        .DATA_I      (core_din),
        .ADDR_O      (ADDR_O),
        .DATA_O      (DATA_O),
        .STATUS_O    (STATUS_O),
        .QS          (),
        .BS          (BS),
        .RD_N        (RD_N),
        .UBE_N       (UBE_N),
        .BUSLOCK_N   (),
        .SS_ADDR     ('0),
        .SS_WDATA    (16'd0),
        .SS_WE       (1'b0),
        .SS_RDATA    (ss_rdata_unused),
        .SS_ERR      (ss_err_unused),
        .SS_BUS_QUIET(ss_quiet_unused)
    );

    // the bus status, one clock old at the tracker's edge (BS changes only on a `ce`)
    reg  [2:0] bs_q;
    always_ff @(posedge clk) bs_q <= BS;

    // the write word, as it is at each clock enable
    reg [15:0] dout_q;
    always_ff @(posedge clk) if (ce) dout_q <= DATA_O;

    // the interrupt line, taken at the clock enables (the core sees it a CPU clock later; its path into the core then has the clock
    // enables' spacing, Gunpey.sdc)
    reg int_q = 1'b0;
    always_ff @(posedge clk) if (ce) int_q <= int_req;

    // ---------------------------------------------------------------- the T-state tracker (advances under ce)
    reg  [2:0] t_state;
    reg  [2:0] lat_type;
    reg        addr_valid;
    reg        inta_prev, inta_second;
    reg [19:0] addr_lat;
    reg [19:0] addr_ann;
    reg  [1:0] be_lat;

    wire bs_active = bs_q != BS_PASV;

    wire [2:0] next_t =
        (t_state == ST_TI) ? (bs_active ? ST_T1 : ST_TI) :
        (t_state == ST_T1) ? ST_T2 :
        (t_state == ST_T2) ? ST_T3 :
        (t_state == ST_T3) ? (ready ? ST_T4 : ST_TW) :
        (t_state == ST_TW) ? (ready ? ST_T4 : ST_TW) :
        /* ST_T4 */          (bs_active ? ST_T1 : ST_TI);

    always_ff @(posedge clk) begin
        if (reset) begin
            t_state     <= ST_TI;
            lat_type    <= BS_PASV;
            addr_valid  <= 1'b0;
            inta_prev   <= 1'b0;
            inta_second <= 1'b0;
        end else if (ce) begin
            t_state <= next_t;
            if (next_t == ST_T1) begin
                lat_type <= bs_q;
                addr_ann <= ADDR_O;
                if (bs_q == BS_INTA) begin
                    inta_second <= inta_prev;
                    inta_prev   <= ~inta_prev;
                end else
                    inta_second <= 1'b0;
            end
            if (t_state == ST_T1) begin
                addr_lat   <= {addr_ann[19:1], 1'b0};
                be_lat     <= {~UBE_N, ~addr_ann[0]};
                addr_valid <= 1'b1;
            end
            if (next_t == ST_T4 || next_t == ST_TI)
                addr_valid <= 1'b0;
        end
    end

    // INTA cycles present the vector number in the low byte
    assign core_din = (lat_type == BS_INTA) ? {8'h00, int_vector} : cpu_din;

    assign cpu_addr   = addr_lat;
    assign cpu_be     = be_lat;
    assign cpu_dout   = dout_q;
    assign code_fetch = (lat_type == BS_CODE);

    assign mem_rd = addr_valid && ((lat_type == BS_CODE) || (lat_type == BS_MEMR));
    assign io_rd  = addr_valid && (lat_type == BS_IOR);
    assign mem_wr = (lat_type == BS_MEMW) && (t_state == ST_T3 || t_state == ST_TW);
    assign io_wr  = (lat_type == BS_IOW)  && (t_state == ST_T3 || t_state == ST_TW);
    assign bus_active = addr_valid && (lat_type != BS_INTA) && (lat_type != BS_HALT) && (lat_type != BS_PASV);

    assign int_ack = (lat_type == BS_INTA) && inta_second && (t_state == ST_T3);
endmodule
`default_nettype wire
