# The Gunpey board and how the core models it

Gunpey (Bandai / Banpresto, 2000), the arcade version of the WonderSwan puzzle game. PCB VG-10. Everything here is from MAME 0.289's
driver (`src/mame/misc/gunpey.cpp`) and from measurements of MAME running the game (the Lua probes in `tools/lua/`); where the core
departs from MAME it says so.

## The board

| Part | Clock | In the core |
|---|---|---|
| NEC V30 | 57.2424 MHz / 4 = 14.3106 MHz | `rtl/v30/` (the Irem M72 core's microcode V30) behind `rtl/gunpey_v30.sv`, clocked by `rtl/gunpey_main.sv` |
| Axell AG-1 (AX51101): blitter, sprite renderer, double frame buffer | | `rtl/gunpey_blitter.sv`, `rtl/gunpey_video.sv` |
| 2 x T2316162 (4 MB): the AG-1's video RAM | | SDRAM word 0x800000 |
| 2 x 61256 (64 KB): work RAM | | block RAM, two ports |
| Yamaha YMZ280B | 16.9344 MHz | `rtl/gunpey_ymz280b.sv` (the Jackie Chan core's) |
| OKI M6295 | 16.9344 MHz / 8, pin 7 low (a sample every 165 clocks) | jt6295 |

The core runs at 85.8636 MHz (57.2424 MHz * 1.5): the V30 gets a clock enable every 6 clocks on average (never closer than 5:
its longest path is about 46 ns), the dot clock every 12. The sound chips'
clocks come from a different crystal and are fractions of it (the YMZ280B's sample rate 49 / 47702, the OKI's clock 588 / 23851).

## Memory and I/O (MAME's maps)

    00000-0FFFF  work RAM
    80000-FFFFF  ROM: the 1 MB "maincpu" region at the same offsets, so only the upper halves of gp_rom1 (even bytes) and gp_rom2
                 (odd bytes) are visible; the reset vector at FFFF0 jumps to 8000:0000

    7F40-7F44  DSW1, DSW2, P1, P2, SYSTEM (active high; 7F45 reads FF)
    7F48       output: bit 0 the coin counter, bits 6-4 the OKI's ROM bank (eight 256 KB banks)
    7F80/7F81  YMZ280B register select / data       7F88  OKI M6295
    7FC8       interrupt mask    7FC9  interrupt cause (read) / acknowledge (write: the bits written are cleared)
    7FD0-7FDF  the blitter; a 2 written to 7FD0 starts it
    7FEC/7FED  vreg_addr: the scene list's address in the work RAM (bit 15: the display on)
    7FEE/7FEF  vram_bank: the base the scenes' sprite lists are relative to (bit 15: on)

The interrupt is one line with vector 0x80. Causes: 0x50 at the start of line 240 (vblank), 0x04 at the end of a blit. MAME raises the
line whenever a cause is or-ed in or the mask / cause registers are written and cause & mask is not zero, and drops it otherwise or
when the CPU acknowledges (HOLD_LINE). The game only ever reads 7FC9 inside its handler and the OKI's status once a frame; it never
reads the YMZ280B.

## The blitter

Registers (bytes of 7FD0-7FDF): 1 the format (0 raw, 8 compressed), 4/5 source x in bytes, 6/7 source y, 8/9 destination x in
words, 10/11 destination y, 12 width - 1 in words, 14 height - 1. Source and destination are 2048 x 2048 byte images (the graphics
ROM, the video RAM), addressed x + 2048 y with both coordinates wrapping at 2048.

The compressed format (decoded by Morten Shearman Kirkegaard, in MAME since 2018; the 2018 progress report's workaround, the
decompressed sprites dumped from a real board, is gone): the source's first byte is the row width - 1 of the compressed data, which
is read a bit at a time, least significant first, wrapping to the next row at that width. Three zero bits, then codes from a fixed
55-entry prefix code: a run of 1 to 12 bytes of a new colour (8 bits follow), of a colour from a 16-entry move-to-front list (4 bits
follow), or copied from the row before (straight, one to the right, one to the left). The sprite is walked in strips 12 bytes wide,
down the even strips and up the odd ones, so "the row before" is above in an even strip and below in an odd one.

MAME draws the whole blit at once and raises the interrupt xsize * ysize CPU clocks later. The core decodes a code in two clocks and writes
a byte a clock, and raises the interrupt at MAME's time or when it is done if that is later (only narrow raw blits, a word or two a
row, take longer: up to 1.35 times MAME's time).

The game blits all the time: at boot it clears video RAM rows 0-447 with copies of one 32 x 64 block (2065 blits), and every scene
change brings 600-700 blits, a third of them compressed, of up to 254 x 240. The copy codes only ever read the strip's row before and
the last column of the strip before (checked for every compressed sprite of a long play session, `tools/gunpey_ref decstats`), so the
core keeps those two (12 + 256 bytes) instead of reading the video RAM back.

## The display

At the start of vblank MAME draws the frame from the display list: from vreg_addr up to 64 scenes of 8 words (word 0: bit 0 enabled,
bit 7 the last scene; word 1: the darkening, bit 6 on and bits 4-0 the amount subtracted from each colour component; word 5: the
scene's sprite list, at (vram_bank + (word 5 << 8)) / 2 as a word index), each of up to 256 sprites of 8 words:

    word 0  cccc cccc e--b b--d   c palette, e last sprite, b 4 / 6 / 8 bpp / RGB (only 4 and 8 are drawn), d disabled
    word 1  xxxx x--- ---a aaaa   x source x (low bits), a alpha (0 solid)
    word 2  yyyy yy-- --XX XXXX   y source y (low bits), X source x (high bits)
    word 3  nnnn nnnn ---Y YYYY   n screen x (low), Y source y (high)
    word 4  mmmm mmmm --MM --NN   m screen y (low), M screen y (high), N screen x (high)
    word 5  hhhh hhhh wwww wwww   zoomed height, zoomed width
    word 6  ---- ---- oooo oooo   source width
    word 7  pppp pppp ---- ----   source height

The screen position is (x - 0x160, y - 0x188); the zoom steps are (source size << 15) / zoomed size. A pixel's colour is the
little-endian word at video RAM (2 * (index & 0xff), index >> 8) with index = palette * 16 + pixel (4 bpp) or palette * 256 + pixel
(8 bpp), so every palette is in the video RAM's rows 0-255 (the game uses rows 0-132). Bit 15 of a colour is transparency. With
alpha, the result is (dest * alpha * 8 + colour * (256 - alpha * 8)) / 256 a component (MAME's alpha_blend_r16).

The game double-buffers the list: its vblank handler switches vram_bank about 4 lines after the draw (line 244), and it builds the
next list in the other bank. The core copies the list at the start of line 240 (the CPU held meanwhile, so the copy is MAME's instant)
and draws the next frame a line at a time, each line during the one before it. That reads the video RAM during the frame, where MAME
reads it at the start of vblank; over 70000 frames of MAME the game never blitted into what the shown frame reads after the frame's
start (apart from three blits in boot frames 4 and 34, which have nothing on screen). The palettes are read from a block RAM copy of
the video RAM's rows 0-255 that the blitter keeps.

The busiest frames have about 150 sprites and 1540 drawn dots on a line; the core draws a line in at most about 1700 of the 5304
clocks it has.

Real hardware draws into a double-buffered frame buffer in the same video RAM (MAME's TODO); where the frame buffers are and whether
the board shows the game at 30 or 60 frames a second (the 2018 report's open question) are not known. The core shows what MAME
shows: the frame drawn at a vblank, in the next frame.

## The raster

MAME's: 7.1553 MHz dots, 442 dots a line, 264 lines (16.19 kHz, 61.32 Hz), 320 x 240 visible. The PCB's notes give 15.79 kHz and 60 Hz,
which would be about 453 x 263; MAME's numbers are used. MAME starts the machine at line 240 (its first vblank is a frame after
power-on), and so does the core.

## The V30's speed

The core's V30 is cycle-exact to the real chip (the M72 core's ucore, checked against silicon there); MAME's V30 is faster on the
string instructions the game starts with (the boot RAM test: a `rep stosw` takes 4 clocks a word, a `rep cmpsw` 10, where MAME
counts fewer). The core reaches the game's first I/O write at CPU clock 1109343, MAME at 718072, so the core runs about a frame and a
half behind MAME from then on; the I/O accesses are the same, in the same order, until the first interrupt lands at a different
place.
