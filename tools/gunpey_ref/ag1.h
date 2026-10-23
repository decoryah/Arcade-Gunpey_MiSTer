// The Axell AG-1 of the Gunpey board as MAME 0.289 emulates it (src/mame/misc/gunpey.cpp): the blitter (a raw copy or the compressed
// sprite format, from the graphics ROM into the 4 MB video RAM) and the sprite renderer (the display list in the CPU's work RAM, drawn
// into a 320 x 240 RGB555 picture). A straight port, the reference the core's RTL is checked against.
#pragma once
#include <cstdint>
#include <vector>

namespace ag1 {

constexpr uint32_t video_addr(uint32_t x, uint32_t y) { return (x & 0x7ff) | ((y & 0x7ff) << 11); }

struct blit_stats {
    // the compressed format's reads outside what this sprite has written so far (the RTL keeps only the previous row of a strip and the
    // last column of the strip before; a read anywhere else would need the video RAM's old contents)
    long reads_unwritten = 0;   // inside the sprite, not yet written by this decompression
    long reads_outside   = 0;   // outside the sprite's rectangle
    long reads_far       = 0;   // inside and written, but not in the previous row of this strip / the last column of the strip before
    bool error           = false;
};

// regs: the 16 blitter register bytes as the CPU left them (0x7fd0-0x7fdf). Returns MAME's busy time in CPU clocks (xsize * ysize).
uint32_t blit(uint8_t *vram, const uint8_t *rom, uint32_t rom_mask, const uint8_t regs[16], blit_stats *st = nullptr);

// Draws the frame MAME draws at the start of vblank. wram: the 64 KB work RAM as 32768 little-endian words.
void render(const uint8_t *vram, const uint16_t *wram, uint16_t vram_bank, uint16_t vreg_addr, uint16_t *out /* 320 x 240 RGB555 */);

}
