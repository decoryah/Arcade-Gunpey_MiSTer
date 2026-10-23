// The AG-1 reference: MAME 0.289 gunpey.cpp's blitter_w / decompress_sprite / screen_update / draw_gfx, ported line for line.
#include "ag1.h"
#include <algorithm>
#include <cstring>

namespace ag1 {

// ------------------------------------------------------------------------------------------------ the compressed sprite format
namespace {

struct huff { const char *bits; int func; int arg0_bits; int arg1_val; };
enum { NEW = 0, PREV = 1, COPY = 2, PLUS = 3, MINUS = 4 };

const huff hn[] = {
    { "11",              NEW,   8,  1 }, { "10111",           NEW,   8,  2 }, { "10110011",        NEW,   8,  3 },
    { "1010011000",      NEW,   8,  4 }, { "1010101010000",   NEW,   8,  5 }, { "101010001011110", NEW,   8,  6 },
    { "101010010101110", NEW,   8,  7 }, { "101010010101111", NEW,   8,  8 }, { "101010010101100", NEW,   8,  9 },
    { "10101000101100",  NEW,   8, 10 }, { "101010010101101", NEW,   8, 11 }, { "10101000101101",  NEW,   8, 12 },
    { "0",               PREV,  4,  1 }, { "100",             PREV,  4,  2 }, { "101011",          PREV,  4,  3 },
    { "1010010",         PREV,  4,  4 }, { "101010100",       PREV,  4,  5 }, { "1010100100",      PREV,  4,  6 },
    { "10101010110",     PREV,  4,  7 }, { "10100111000",     PREV,  4,  8 }, { "101010101001",    PREV,  4,  9 },
    { "101001111000",    PREV,  4, 10 }, { "101010010100",    PREV,  4, 11 }, { "1010011001",      PREV,  4, 12 },
    { "101101",          COPY,  0,  2 }, { "10101011",        COPY,  0,  3 }, { "101010011",       COPY,  0,  4 },
    { "101001101",       COPY,  0,  5 }, { "1010011111",      COPY,  0,  6 }, { "1010100011",      COPY,  0,  7 },
    { "10101000100",     COPY,  0,  8 }, { "101010101111",    COPY,  0,  9 }, { "101001110010",    COPY,  0, 10 },
    { "1010011100111",   COPY,  0, 11 }, { "101100101",       COPY,  0, 12 },
    { "1011000",         PLUS,  0,  2 }, { "101010000",       PLUS,  0,  3 }, { "10101001011",     PLUS,  0,  4 },
    { "101010001010",    PLUS,  0,  5 }, { "1010101011101",   PLUS,  0,  6 }, { "1010101011100",   PLUS,  0,  7 },
    { "1010011110010",   PLUS,  0,  8 }, { "10101000101110",  PLUS,  0,  9 }, { "101010001011111", PLUS,  0, 10 },
    { "1010011110011",   PLUS,  0, 11 },
    { "101000",          MINUS, 0,  2 }, { "101100100",       MINUS, 0,  3 }, { "1010011101",      MINUS, 0,  4 },
    { "10101010101",     MINUS, 0,  5 }, { "101001111011",    MINUS, 0,  6 }, { "101001111010",    MINUS, 0,  7 },
    { "1010101010001",   MINUS, 0,  8 }, { "1010011100110",   MINUS, 0,  9 }, { "10101001010101",  MINUS, 0, 10 },
    { "10101001010100",  MINUS, 0, 11 },
    { nullptr,           0,     0,  0 },
};

struct state_s {
    uint8_t *buf;
    const uint8_t *rom;
    uint32_t rom_mask;
    uint8_t bits;
    int num_bits;
    uint8_t colour[16];
    int basex;
    int ix, iy, iw;
    int dx, dy;
    int ow, oh;
    int ox, oy;
    std::vector<uint8_t> written;   // analysis only
    blit_stats *st;

    uint8_t vrom(int x, int y) const { return rom[video_addr(x, y) & rom_mask]; }

    int next_bit() {
        if (num_bits == 0) {
            if (ix >= basex + iw) { ix = basex; iy++; }
            bits = vrom(ix, iy);
            ix++;
            num_bits = 8;
        }
        int res = bits & 1;
        bits >>= 1;
        num_bits--;
        return res;
    }

    void set_o(uint8_t v) {
        uint8_t a = v;
        for (int i = 0; i < 16; i++) {
            uint8_t b = colour[i];
            colour[i] = a;
            a = b;
            if (a == v) break;
        }
        if (ox >= 0 && ox < ow && oy >= 0 && oy < oh) written[oy * ow + ox] = 1;
        buf[video_addr(dx + (ox++), dy + oy)] = v;
    }

    uint8_t get_o(int x, int y) {
        if (st) {
            if (x < 0 || x >= ow || y < 0 || y >= oh) st->reads_outside++;
            else if (!written[y * ow + x]) st->reads_unwritten++;
            else {
                int ss = (ox / 12) * 12;
                if (x < ss - 1 || x > ss + 11) st->reads_far++;
            }
        }
        return buf[video_addr(dx + x, dy + y)];
    }

    // the row before in the strip's direction: below for an odd strip (it runs upwards), above for an even one
    int prev_row() const { return ((ox / 12) & 1) ? oy + 1 : oy - 1; }

    void run(int func, uint8_t v, int n) {
        switch (func) {
        case NEW:   for (int i = 0; i < n; i++) set_o(v); break;
        case PREV:  { uint8_t c = colour[v]; for (int i = 0; i < n; i++) set_o(c); } break;
        case COPY:  for (int i = 0; i < n; i++) set_o(get_o(ox,     prev_row())); break;
        case PLUS:  for (int i = 0; i < n; i++) set_o(get_o(ox + 1, prev_row())); break;
        case MINUS: for (int i = 0; i < n; i++) set_o(get_o(ox - 1, prev_row())); break;
        }
    }

    // next_node: one bit at a time against the table's prefixes (true: no code matches, the sprite is abandoned)
    bool next_node(const huff **res) {
        char b[128];
        memset(b, 0, sizeof(b));
        for (int i = 0; i < (int)sizeof(b) - 1; i++) {
            b[i] = '0' + next_bit();
            for (int j = 0;; j++) {
                if (!hn[j].bits) return true;
                if (strncmp(b, hn[j].bits, i + 1) == 0) {
                    if (!hn[j].bits[i + 1]) { *res = &hn[j]; return false; }
                    break;
                }
            }
        }
        return true;
    }
};

bool decompress_sprite(uint8_t *buf, const uint8_t *rom, uint32_t rom_mask, int ix, int iy, int ow, int oh, int dx, int dy, blit_stats *st)
{
    state_s s;
    s.buf = buf; s.rom = rom; s.rom_mask = rom_mask; s.st = st;
    s.num_bits = 0;
    memset(s.colour, 0, sizeof(s.colour));
    s.basex = ix;
    s.ix = ix;
    s.iy = iy;
    s.iw = s.vrom(s.ix++, s.iy) + 1;
    s.dx = dx; s.dy = dy;
    s.ow = ow; s.oh = oh;
    s.ox = 0; s.oy = 0;
    s.written.assign(size_t(std::max(ow, 1)) * size_t(std::max(oh, 1)), 0);

    s.next_bit(); s.next_bit(); s.next_bit();      // three zero bits

    while (s.ox < s.ow) {
        const huff *n;
        if (s.next_node(&n)) return true;
        uint8_t v = 0;
        for (int i = 0; i < n->arg0_bits; i++) v |= s.next_bit() << i;
        s.run(n->func, v, n->arg1_val);

        bool eol;
        if ((s.ox % 12) == 0) {
            s.ox -= 12;
            if ((s.ox / 12) & 1) s.oy -= 1; else s.oy += 1;
            eol = true;
        } else if (s.ox == s.ow) {
            s.ox -= s.ow % 12;
            if ((s.ox / 12) & 1) s.oy -= 1; else s.oy += 1;
            eol = true;
        } else
            eol = false;

        if (eol && (s.oy == s.oh || s.oy == -1)) {
            s.ox += 12;
            if ((s.ox / 12) & 1) s.oy -= 1; else s.oy += 1;
        }
    }
    return false;
}

} // anonymous namespace

// ------------------------------------------------------------------------------------------------ blitter_w (offset 0, data 2)
uint32_t blit(uint8_t *vram, const uint8_t *rom, uint32_t rom_mask, const uint8_t r[16], blit_stats *st)
{
    int srcx = r[4] | (r[5] << 8);
    int srcy = r[6] | (r[7] << 8);
    int dstx = r[8] | (r[9] << 8);
    int dsty = r[10] | (r[11] << 8);
    int xsize = r[12] + 1;
    int ysize = r[14] + 1;
    int compression = r[1];

    dstx <<= 1;
    xsize <<= 1;

    if (compression) {
        if (compression == 8) {
            if (decompress_sprite(vram, rom, rom_mask, srcx, srcy, xsize, ysize, dstx, dsty, st) && st) st->error = true;
        }
    } else {
        int dstxbase = dstx, dstxcount = 0, dstycount = 0;
        int srcxbase = srcx, srcxcount = 0;
        for (;;) {
            uint8_t d = rom[video_addr(srcx, srcy) & rom_mask];
            srcx++; srcxcount++;
            if (srcxcount == xsize) { srcxcount = 0; srcx = srcxbase; srcy++; }
            vram[video_addr(dstx, dsty)] = d;
            dstx++; dstxcount++;
            if (dstxcount == xsize) {
                dstxcount = 0; dstx = dstxbase; dsty++; dstycount++;
                if (dstycount == ysize) break;
            }
        }
    }
    return uint32_t(xsize) * uint32_t(ysize);
}

// ------------------------------------------------------------------------------------------------ the renderer
namespace {

inline uint16_t blend(uint16_t d, uint16_t s, int level)   // alpha_blend_r16(d, s, level)
{
    return ((((s & 0x001f) * level + (d & 0x001f) * (256 - level)) >> 8)) |
           ((((s & 0x03e0) * level + (d & 0x03e0) * (256 - level)) >> 8) & 0x03e0) |
           ((((s & 0x7c00) * level + (d & 0x7c00) * (256 - level)) >> 8) & 0x7c00);
}

void draw_pixel(uint16_t *bm, int x, int y, uint16_t color_data, int alpha, uint8_t grad)
{
    if (color_data & 0x8000) return;
    if (grad & 0x40) {
        int r = (color_data >> 10) & 31, g = (color_data >> 5) & 31, b = color_data & 31;
        r = std::max(0, r - (grad & 0x1f));
        g = std::max(0, g - (grad & 0x1f));
        b = std::max(0, b - (grad & 0x1f));
        color_data = (color_data & 0x8000) | (r << 10) | (g << 5) | b;
    }
    if (x < 0 || x >= 320 || y < 0 || y >= 240) return;
    uint16_t &p = bm[y * 320 + x];
    if (alpha == 0) p = color_data & 0x7fff;
    else            p = blend(color_data, p, alpha) & 0x7fff;
}

inline uint16_t clut(const uint8_t *vram, int color)
{
    uint32_t o = video_addr((color & 0xff) << 1, color >> 8);
    return vram[o] | (vram[o + 1] << 8);
}

bool draw_gfx(const uint8_t *vram, const uint16_t *w, int count, uint8_t grad, uint16_t *bm)
{
    const int ZOOM_SHIFT = 15;
    auto W = [&](int k) -> uint16_t { return w[(count + k) & 0x7fff]; };
    if (!(W(0) & 1)) {
        int x = (W(3) >> 8) | ((W(4) & 0x03) << 8);
        int y = (W(4) >> 8) | ((W(4) & 0x30) << 4);
        uint32_t zoomheight = W(5) >> 8;
        uint32_t zoomwidth  = W(5) & 0xff;
        int bpp_sel = W(0) & 0x18;
        int color   = W(0) >> 8;
        x -= 0x160;
        y -= 0x188;
        uint32_t sourcewidth  = (W(6) & 0xff) << ZOOM_SHIFT;
        uint32_t sourceheight = (W(7) >> 8) << ZOOM_SHIFT;
        int xsource = ((W(2) & 0x003f) << 5) | ((W(1) & 0xf800) >> 11);
        int ysource = ((W(3) & 0x001f) << 6) | ((W(2) & 0xfc00) >> 10);
        int alpha = (W(1) & 0x1f) << 3;
        uint32_t widthstep = 1 << ZOOM_SHIFT, heightstep = 1 << ZOOM_SHIFT;
        if (zoomwidth)  widthstep  = sourcewidth / zoomwidth;
        if (zoomheight) heightstep = sourceheight / zoomheight;

        if (bpp_sel == 0x00) {
            color <<= 4;
            int ysourceoff = 0;
            for (int yi = 0; yi < (int)zoomheight; yi++) {
                int yi2 = ysourceoff >> ZOOM_SHIFT;
                int xsourceoff = 0;
                for (int xi = 0; xi < (int)zoomwidth; xi++) {
                    int xi2 = xsourceoff >> ZOOM_SHIFT;
                    uint8_t data = vram[video_addr(xsource + (xi2 >> 1), ysource + yi2)];
                    int pix = (data >> ((xi2 & 1) << 2)) & 15;
                    draw_pixel(bm, x + xi, y + yi, clut(vram, color + pix), alpha, grad);
                    xsourceoff += widthstep;
                }
                ysourceoff += heightstep;
            }
        } else if (bpp_sel == 0x10) {
            color <<= 8;
            int ysourceoff = 0;
            for (int yi = 0; yi < (int)zoomheight; yi++) {
                int yi2 = ysourceoff >> ZOOM_SHIFT;
                int xsourceoff = 0;
                for (int xi = 0; xi < (int)zoomwidth; xi++) {
                    int xi2 = xsourceoff >> ZOOM_SHIFT;
                    uint8_t data = vram[video_addr(xsource + xi2, ysource + yi2)];
                    draw_pixel(bm, x + xi, y + yi, clut(vram, color + data), alpha, grad);
                    xsourceoff += widthstep;
                }
                ysourceoff += heightstep;
            }
        }
        // 0x08 (6bpp) and 0x18 (RGB32k): not drawn by MAME
    }
    return W(0) & 0x80;
}

} // anonymous namespace

void render(const uint8_t *vram, const uint16_t *wram, uint16_t vram_bank, uint16_t vreg_addr, uint16_t *out)
{
    std::fill_n(out, 320 * 240, 0);
    uint16_t vb = vram_bank & 0x7fff, vr = vreg_addr & 0x7fff;
    if (!(vreg_addr & 0x8000) || !(vram_bank & 0x8000)) return;

    for (int scene_index = vr / 2; scene_index < (vr + 0x400) / 2; scene_index += 0x10 / 2) {
        auto S = [&](int k) -> uint16_t { return wram[(scene_index + k) & 0x7fff]; };
        // the sums are ints, the halves are kept as u16 (MAME's start_offs / end_offs); an end that wraps below the start draws nothing
        uint16_t start_offs = uint16_t((vb + (S(5) << 8)) / 2);
        uint16_t end_offs   = uint16_t((vb + (S(5) << 8) + 0x1000) / 2);
        bool scene_end_mark = S(0) & 0x80;
        bool scene_enabled  = S(0) & 0x01;
        uint8_t grad        = S(1) & 0xff;
        if (scene_enabled) {
            // (MAME reads past its 32 K-word work RAM for a list starting above 0x7ff8 words; here the index wraps)
            for (int count = start_offs; count < end_offs; count += 0x10 / 2)
                if (draw_gfx(vram, wram, count, grad, out)) break;
        }
        if (scene_end_mark) break;
    }
}

} // namespace ag1
