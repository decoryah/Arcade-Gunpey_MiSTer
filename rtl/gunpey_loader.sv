//------------------------------------------------------------------------------
// The ROM image's way in: the HPS download (or the fast load's replay of it) arrives a byte at a time at its image offset; this module
// routes each byte to its place in the SDRAM.
//
// The image (mra/*.mra):
//   0x000000  maincpu  1 MB   the V30's region as MAME loads it (gp_rom1 the even bytes, gp_rom2 the odd ones)
//   0x100000  blit_rom 4 MB   gp_rom3, the blitter's source
//   0x500000  ymz      4 MB   gp_rom4
//   0x900000  oki      2 MB   gp_rom5's first half (the chip's eight 256 KB banks; the second half is 0xFF)
//   0xB00000  4 MB of 0xFF    the video RAM's first contents (MAME fills it with 0xFF)
// The SDRAM holds the image at byte address = image offset, except the video RAM's fill, which goes to byte 0x1000000.
//------------------------------------------------------------------------------
`default_nettype none
module gunpey_loader (
    input  logic        clk,
    input  logic        dl_wr,                 // one clock per byte
    input  logic [25:0] dl_addr,               // image offset
    input  logic  [7:0] dl_data,
    output logic        o_wr,                  // to the SDRAM's download port
    output logic [24:0] o_addr,
    output logic  [7:0] o_data
);
    localparam logic [25:0] VFILL = 26'h0B00000, VEND = 26'h0F00000;
    always_ff @(posedge clk) begin
        o_wr <= 1'b0;
        if (dl_wr && dl_addr < VEND) begin
            o_wr   <= 1'b1;
            o_data <= dl_data;
            o_addr <= (dl_addr >= VFILL) ? 25'(dl_addr - VFILL) + 25'h1000000 : dl_addr[24:0];
        end
    end
endmodule
`default_nettype wire
