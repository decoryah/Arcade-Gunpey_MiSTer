// A blank raster of the core's own timing (12 clocks a dot, 442 dots a line, 264 lines, 320 x 240 picture, as gunpey_video) for the time
// the machine is held in reset (the ROM image streaming in, the OSD's Reset): the framework draws its "Loading" pop-up on the OSD, which
// needs a video signal with sync to sit on. After the Rabbit core's rabbit_standby.sv (the Metro core's metro_standby.sv,
// decoryah/Arcade-Metro_MiSTer, GPL-3.0-or-later).
`default_nettype none
module gunpey_standby (
    input  wire clk,
    output reg  o_ce,
    output reg  o_hblank,
    output reg  o_vblank,
    output reg  o_vblank_next,     // the next line's vertical blank (as gunpey_video's vblank_next)
    output reg  o_hs,
    output reg  o_vs
);
    reg [3:0] dv = 4'd0;
    reg [8:0] hc = 9'd0, vc = 9'd0;
    initial begin o_ce = 1'b0; o_hblank = 1'b1; o_vblank = 1'b1; o_vblank_next = 1'b1; o_hs = 1'b0; o_vs = 1'b0; end
    always @(posedge clk) begin
        o_ce <= 1'b0;
        dv   <= (dv == 4'd11) ? 4'd0 : dv + 4'd1;
        if (dv == 4'd11) begin
            o_ce <= 1'b1;
            if (hc == 9'd441) begin
                hc <= 9'd0;
                vc <= (vc == 9'd263) ? 9'd0 : vc + 9'd1;
            end else
                hc <= hc + 9'd1;
            o_hblank <= (hc >= 9'd320);
            o_hs     <= (hc >= 9'd344) && (hc < 9'd376);
            o_vblank <= (vc >= 9'd240);
            o_vblank_next <= (vc >= 9'd239) && (vc != 9'd263);
            o_vs     <= (vc >= 9'd244) && (vc < 9'd247);
        end
    end
endmodule
`default_nettype wire
