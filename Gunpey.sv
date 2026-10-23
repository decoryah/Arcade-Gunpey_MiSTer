//============================================================================
//
//  Gunpey (Bandai / Banpresto, 2000: NEC V30 + Axell AG-1 + YMZ280B + OKI M6295) for MiSTer.
//
//  Written for MiSTer from MAME 0.289's driver (src/mame/misc/gunpey.cpp). The V30 is the Irem M72 core's (MiSTer-devel/
//  Arcade-IremM72_MiSTer rtl/v30), the YMZ280B the owner's Jackie Chan core's, the OKI jt6295 (Jose Tejada); the platform layer (SDRAM
//  protocol, fast load, standby raster, CRT Adjust) follows the owner's Rabbit core (decoryah/Arcade-Rabbit_MiSTer).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 1;       // signed samples
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

wire [127:0] status;
wire   [1:0] buttons;
wire         forced_scandoubler;
wire         direct_video;
wire  [21:0] gamma_bus;

wire  [1:0] ar = status[122:121];

`include "build_id.v"
localparam CONF_STR = {
	"Gunpey;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[34:32],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer,HV-Integer+;",
	"O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1,CRT Adjust;",
	"P1O[35],CRT Adjust,Off,On;",
	"H1P1O[40:36],CRT H-Size,0,+1,+2,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[47:41],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[52:48],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"O[9:8],Volume,Normal,-6 dB,-12 dB,+6 dB;",
	"O[10],Swap stereo,No,Yes;",
	"-;",
	"DIP;",
	"-;",
	"R0,Reset;",
	"J1,Swap,Raise,Start,Coin;",
	"jn,A,B,Start,Select;",
	"V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_sys;           // 85.8636 MHz: the machine (57.2424 MHz * 1.5)
wire clk_sdram;         // the same, shifted: the SDRAM chip's clock pin
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram;

///////////////////////////////////////////////////

wire         ioctl_download;
wire         ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire         dl_busy;

wire  [31:0] joystick_0, joystick_1;
wire  [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),
	.status_menumask({14'd0, ~status[35], direct_video}),
	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.gamma_bus(gamma_bus),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(dl_busy),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

///////////////////////   CONTROLS   ///////////////////////

// the DIP switches: the MRA's <switches>, two bytes (DSW1, DSW2)
reg [7:0] sw[2];
always @(posedge clk_sys) if (ioctl_wr && (ioctl_index[7:0] == 8'd254) && !ioctl_addr[24:1]) sw[ioctl_addr[0]] <= ioctl_dout;

// keyboard: 1 / 2 start, 5 / 6 coin, 9 service, F2 the test switch (MAME's defaults)
reg key_start1, key_start2, key_coin1, key_coin2, key_service, key_test;
always @(posedge clk_sys) begin
	reg old_stb;
	old_stb <= ps2_key[10];
	if (old_stb != ps2_key[10]) begin
		case (ps2_key[8:0])
			9'h016: key_start1  <= ps2_key[9];
			9'h01E: key_start2  <= ps2_key[9];
			9'h02E: key_coin1   <= ps2_key[9];
			9'h036: key_coin2   <= ps2_key[9];
			9'h046: key_service <= ps2_key[9];
			9'h006: key_test    <= ps2_key[9];      // F2
			default: ;
		endcase
	end
end

// joystick bits: 0 right, 1 left, 2 down, 3 up, 4 Swap, 5 Raise, 6 start, 7 coin (the J1 line above)
// MAME's P1 / P2 (active high): bit 0 up, 1 down, 2 left, 3 right, 4-6 buttons 1-3. What the buttons do was measured in MAME 0.289: button 1
// swaps the two panels in the cursor (and confirms in the menus), button 2 raises the field a row; button 3 does nothing in the game
// (only the test mode's I/O check shows it), so the pad has no third button
wire [7:0] p1 = {2'b00, joystick_0[5:4], joystick_0[0], joystick_0[1], joystick_0[2], joystick_0[3]};
wire [7:0] p2 = {2'b00, joystick_1[5:4], joystick_1[0], joystick_1[1], joystick_1[2], joystick_1[3]};
// MAME's SYSTEM: bit 0 service 1, 2 the test switch, 3 / 4 coin 1 / 2, 5 / 6 start 1 / 2
wire [7:0] in_sys = {1'b0, joystick_1[6] | key_start2, joystick_0[6] | key_start1, joystick_1[7] | key_coin2, joystick_0[7] | key_coin1,
                     key_test, 1'b0, key_service};

///////////////////////   MEMORY   ///////////////////////

// the ROM image: MRA index 0
wire        rom_dl = ioctl_download && (ioctl_index[7:0] == 8'd0);

// Fast load (the MRA's address= attribute): Main_MiSTer copies the image into the DDR3 (byte 0x32000000) and ends a download that
// carries only a start address, the image's length; gunpey_fastload reads it back and plays it into the loader. An older Main_MiSTer
// streams the bytes as before (as in the Rabbit and Metro cores).
reg         rom_dl_d;
always @(posedge clk_sys) rom_dl_d <= rom_dl;
wire        dl_start = rom_dl && !rom_dl_d;
wire        dl_done  = !rom_dl && rom_dl_d;
reg         fast_dl = 1'b0;
reg  [26:0] fast_len;
wire        fl_go    = fast_dl && dl_done;
wire        fl_done, fl_busy_unused;
always @(posedge clk_sys) begin
	if (dl_start) begin fast_dl <= (ioctl_addr != 27'd0); fast_len <= ioctl_addr; end
	else if (fl_done || !pll_locked) fast_dl <= 1'b0;
end
wire        fl_wr;
wire [25:0] fl_addr;
wire  [7:0] fl_data;
wire        fl_ddr_rd;
wire [24:0] fl_ddr_addr;
wire  [7:0] fl_ddr_burst;

gunpey_fastload u_fastload
(
	.clk(clk_sys), .rst(~pll_locked), .go(fl_go), .len(fast_len), .busy(fl_busy_unused), .done(fl_done),
	.ddr_rd(fl_ddr_rd), .ddr_addr(fl_ddr_addr), .ddr_burst(fl_ddr_burst), .ddr_busy(DDRAM_BUSY), .ddr_dout(DDRAM_DOUT), .ddr_dready(DDRAM_DOUT_READY),
	.o_wr(fl_wr), .o_addr(fl_addr), .o_data(fl_data), .hold(dl_busy)
);
assign DDRAM_CLK      = clk_sys;
assign DDRAM_ADDR     = {4'd3, fl_ddr_addr};
assign DDRAM_BURSTCNT = fl_ddr_burst;
assign DDRAM_RD       = fl_ddr_rd;
assign DDRAM_WE       = 1'b0;
assign DDRAM_DIN      = 64'd0;
assign DDRAM_BE       = 8'hFF;

wire        ld_wr;
wire [24:0] ld_addr;
wire  [7:0] ld_data;

gunpey_loader u_loader
(
	.clk(clk_sys),
	.dl_wr(fl_wr || (ioctl_wr && rom_dl)), .dl_addr(fl_wr ? fl_addr : ioctl_addr[25:0]), .dl_data(fl_wr ? fl_data : ioctl_dout),
	.o_wr(ld_wr), .o_addr(ld_addr), .o_data(ld_data)
);

// the SDRAM and its six clients (rtl/gunpey_core.sv)
wire        m_req [6], m_ack [6], m_valid [6], m_we [6], m_wpull [6];
wire [23:0] m_addr [6];
wire  [4:0] m_len [6];
wire [15:0] m_wdata [6];
wire [15:0] m_rdata;
wire        mem_ready, dl_idle;

gunpey_sdram #(.NC(6)) u_sdram
(
	.clk(clk_sys), .rst_n(pll_locked), .o_ready(mem_ready), .i_rd_late(1'b0),
	.i_dl_wr(ld_wr), .i_dl_addr(ld_addr), .i_dl_data(ld_data), .o_dl_busy(dl_busy), .o_dl_idle(dl_idle),
	.c_req(m_req), .c_addr(m_addr), .c_len(m_len), .c_we(m_we), .c_wdata(m_wdata),
	.c_ack(m_ack), .c_valid(m_valid), .c_wpull(m_wpull), .o_rdata(m_rdata),
	.SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE)
);

///////////////////////   THE MACHINE   ///////////////////////

wire        reset_sw = RESET | status[0] | buttons[1];
// held while a ROM loads, until its last word is in the SDRAM, and until the memory is up; registered, it fans out to the whole core
reg         mc_rst = 1'b1;
always @(posedge clk_sys) mc_rst <= reset_sw | rom_dl | fast_dl | dl_busy | ~dl_idle | ~mem_ready | ~pll_locked;
reg         c_flush = 1'b1;
always @(posedge clk_sys) c_flush <= rom_dl | fast_dl | ~pll_locked;

wire        ce_pix, hs, vs, hblank, vblank, vblank_next;
wire  [7:0] r, g, b;
wire signed [15:0] snd_l, snd_r;
wire        frame_tick;

gunpey_core u_core
(
	.clk(clk_sys), .reset(mc_rst), .cache_flush(c_flush),
	.m_req(m_req), .m_addr(m_addr), .m_len(m_len), .m_we(m_we), .m_wdata(m_wdata),
	.m_ack(m_ack), .m_valid(m_valid), .m_wpull(m_wpull), .m_rdata(m_rdata),
	.dsw1(sw[0]), .dsw2(sw[1]), .in_p1(p1), .in_p2(p2), .in_sys(in_sys),
	.ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .vblank_next(vblank_next), .hs(hs), .vs(vs), .r(r), .g(g), .b(b),
	.audio_l(snd_l), .audio_r(snd_r),
	.dbg_frame(frame_tick), .dbg_overruns(), .dbg_sprites(), .dbg_line_clks(), .dbg_blt_error(),
	.dbg_addr(), .dbg_fetch(), .dbg_io_wr(), .dbg_io_rd(), .dbg_io_data(), .dbg_io_be(), .dbg_inta(),
	.dbg_blt_start(), .dbg_blt_irq(), .dbg_vbl(), .dbg_cpu_ce()
);

///////////////////////   AUDIO   ///////////////////////

// the OSD's volume steps
function automatic signed [15:0] f_vol(input signed [15:0] v, input [1:0] st);
	reg signed [16:0] gv;
	begin
		gv = (st == 2'd0) ? {v[15], v} : (st == 2'd1) ? {{2{v[15]}}, v[15:1]} : (st == 2'd2) ? {{3{v[15]}}, v[15:2]} : {v, 1'b0};
		f_vol = (gv > 17'sd32767) ? 16'sd32767 : (gv < -17'sd32768) ? -16'sd32768 : gv[15:0];
	end
endfunction
assign AUDIO_L = f_vol(status[10] ? snd_r : snd_l, status[9:8]);
assign AUDIO_R = f_vol(status[10] ? snd_l : snd_r, status[9:8]);

///////////////////////   VIDEO   ///////////////////////

// while the machine is held in reset the core's raster does not run: a blank one of the same timing keeps the OSD's "Loading" pop-up alive
wire        sb_ce, sb_hblank, sb_vblank, sb_vblank_next, sb_hs, sb_vs;
gunpey_standby u_standby (.clk(clk_sys), .o_ce(sb_ce), .o_hblank(sb_hblank), .o_vblank(sb_vblank), .o_vblank_next(sb_vblank_next),
	.o_hs(sb_hs), .o_vs(sb_vs));
reg         sb_on = 1'b1;
always @(posedge clk_sys) sb_on <= mc_rst;

// the picture (or the standby raster), one clock later, before the CRT Adjust select. HBlank is the horizontal blank alone,
// toggling on every line, vertical blank lines included, with the vertical blank on VBlank: the framework's scandoubler
// takes its line timing from the horizontal blank's edges and without them loses the vertical sync
reg  [23:0] vq_rgb;
reg         vq_hb, vq_vb, vq_vbn, vq_hs, vq_vs, vq_ce;
always @(posedge clk_sys) begin
	vq_rgb <= sb_on ? 24'd0 : {r, g, b};
	vq_hb  <= sb_on ? sb_hblank : hblank;
	vq_vb  <= sb_on ? sb_vblank : vblank;
	vq_vbn <= sb_on ? sb_vblank_next : vblank_next;
	vq_hs  <= sb_on ? sb_hs : hs;
	vq_vs  <= sb_on ? sb_vs : vs;
	vq_ce  <= sb_on ? sb_ce : ce_pix;
end

// CRT Adjust: the size, horizontal position and vertical position of the picture on a 15 kHz analog output (rmonic79's
// MiSTer-CRT-Adjust, modules/crt-adjust), as in the Rabbit core. The picture goes through a line buffer and is read out at a different
// pixel rate (H-Size) or a different place in the line (H-Position), and the vertical sync is delayed by whole lines (V-Shift); the
// sync pulses keep their rate, so the monitor stays locked. It does nothing while the scandoubler is in use (31 kHz).
wire crt_sd = (|status[5:3]) | forced_scandoubler;

// the OSD values, as the menu counts them: H-Size 0..+2 then -16..-1, H-Position 0..+16 then -48..-1, V-Shift signed 5-bit.
// The picture is 320 dots in a line of 442; it starts 66 dots after the hsync pulse ends and ends 24 before the next one starts (CRT
// Adjust starts it about 6 dots later), so it cannot grow or move right by more than that (a size step is 1/48 of a dot, 6.7 dots
// wider across the picture: +2 is the most that fits, sim/emu checks it; H-Position +16 fits at H-Size 0).
localparam signed [8:0] CRT_HBIAS = -9'sd1;     // cancels the module's own one-dot delay of the picture
wire        [4:0] crt_hs_i = status[40:36];
wire signed [5:0] crt_hsz = (crt_hs_i <= 5'd2) ? $signed({1'b0, crt_hs_i}) : $signed({1'b0, crt_hs_i}) - 6'sd19;
wire        [6:0] crt_hp = status[47:41];
wire signed [8:0] crt_hpos = (crt_hp <= 7'd16) ? $signed({2'b00, crt_hp}) : $signed({2'b00, crt_hp}) - 9'sd65;
// the picture is read a line after it is written, so the sync is delayed one line to keep its place; a positive V-Shift moves
// the picture down, which is the sync coming earlier
wire signed [6:0] crt_vs_t = 7'sd1 - $signed({status[52], status[52], status[52:48]});
reg               crt_on = 1'b0;
reg signed  [4:0] crt_hsize;
reg signed  [8:0] crt_hoff;
reg signed  [5:0] crt_voff;
always @(posedge clk_sys) if (vq_ce) begin
	crt_on    <= status[35] & ~crt_sd;
	crt_hsize <= crt_hsz[4:0];
	crt_hoff  <= crt_hpos + CRT_HBIAS;
	crt_voff  <= crt_vs_t[5:0];
end

// the pixel read enable: one every (48 + H-Size) quarters of a clock (twelve clocks a dot), counted from the module's own line reference
wire       crt_hs_ref;
reg        crt_hs_ref_d;
wire [7:0] crt_period = 8'd48 + {{3{crt_hsize[4]}}, crt_hsize};
reg  [7:0] crt_acc;
wire       crt_tick = (crt_acc + 8'd4) >= crt_period;
always @(posedge clk_sys) begin
	crt_hs_ref_d <= crt_hs_ref;
	if      (crt_hs_ref & ~crt_hs_ref_d) crt_acc <= 8'd0;
	else if (crt_tick)                   crt_acc <= crt_acc + 8'd4 - crt_period;
	else                                 crt_acc <= crt_acc + 8'd4;
end
wire crt_rd_en = crt_on ? crt_tick : vq_ce;

wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb_unused;
crt_adjust #(.VTOTAL(264), .HTOTAL(442), .HPOS_MODE(1)) u_crt
(
	.clk(clk_sys), .pxl_cen(vq_ce), .pxl2_cen(crt_rd_en), .active(crt_on),
	.hsize(crt_hsize), .hoffset(crt_hoff), .voffset(crt_voff),
	.r_in(vq_rgb[23:16]), .g_in(vq_rgb[15:8]), .b_in(vq_rgb[7:0]),
	.hs_in(vq_hs), .vs_in(vq_vs), .hb_in(vq_hb), .vb_in(vq_vbn),
	.r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb_unused),
	.hs_ref_out(crt_hs_ref)
);

wire        vga_de_i;
arcade_video #(.WIDTH(320), .DW(24)) arcade_video
(
	.*,
	.VGA_DE(vga_de_i),
	.clk_video(clk_sys),
	.ce_pix(crt_on ? crt_rd_en : vq_ce),
	.RGB_in(crt_on ? {crt_r, crt_g, crt_b} : vq_rgb),
	.HBlank(crt_on ? (crt_hb | crt_hs) : vq_hb),   // CRT Adjust: nothing of the picture inside the hsync pulse; off: the horizontal blank alone
	.VBlank(crt_on ? 1'b0 : vq_vb),               // CRT Adjust: the module's blank already includes the vertical one
	.HSync(crt_on ? crt_hs : vq_hs),
	.VSync(crt_on ? crt_vs : vq_vs),
	.fx(status[5:3])
);

// Scale: the framework's video_freak; its SCALE input counts 0 Normal, 1 V-Integer, 2 Narrower HV-Integer, 3 HV-Integer+, 4 HV-Integer
reg   [2:0] scale_sel;
always @* begin
	case (status[34:32])
		3'd1:    scale_sel = 3'd1;
		3'd2:    scale_sel = 3'd4;
		3'd3:    scale_sel = 3'd2;
		3'd4:    scale_sel = 3'd3;
		default: scale_sel = 3'd0;
	endcase
end
wire fs_int = (ar == 2'd1) && (scale_sel != 3'd0) && (HDMI_WIDTH != 12'd0) && (HDMI_HEIGHT != 12'd0);

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(vga_de_i),
	.ARX(fs_int ? HDMI_WIDTH  : (ar == 2'd0) ? 12'd4 : {10'd0, ar - 2'd1}),
	.ARY(fs_int ? HDMI_HEIGHT : (ar == 2'd0) ? 12'd3 : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(scale_sel)
);

///////////////////////   LEDs   ///////////////////////

// user LED: on while a load / reset holds the machine, then a blink every frame
reg led_frame = 1'b0;
always @(posedge clk_sys) if (frame_tick) led_frame <= ~led_frame;
assign LED_USER = mc_rst ? 1'b1 : led_frame;

endmodule
