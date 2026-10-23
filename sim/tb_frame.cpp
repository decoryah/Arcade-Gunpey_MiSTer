// The frame bench (sim/run_frames.sh): for each state_<f>.bin of a directory (tools/lua/dump_state.lua: MAME's work RAM, video RAM and
// registers at the frame's draw), the video chip is reset with that state loaded (the work RAM, the video RAM in the SDRAM model, the
// palette mirror from the video RAM's rows 0-255), its first vblank takes the list, and the frame after it is compared with MAME's
// snapshot of the frame (snap_<f>.png); the picture is written as out_<f>.ppm.
//   Vtb_frame_top <state dir> <frame> [<frame> ...]
// FLIPX=1 / FLIPY=1 in the environment set 7FF0's flip bits (5 / 6) as the game does with the Flip Screen DIP on (MAME has no flip:
// the picture is then compared with MAME's snapshot mirrored the same way).
#include "Vtb_frame_top.h"
#include "Vtb_frame_top___024root.h"
#include "verilated.h"
#include <png.h>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>

static bool load_png(const std::string &path, std::vector<uint32_t> &rgb, int &w, int &h)
{
    FILE *f = fopen(path.c_str(), "rb");
    if (!f) return false;
    png_structp p = png_create_read_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
    png_infop i = png_create_info_struct(p);
    if (setjmp(png_jmpbuf(p))) { fclose(f); return false; }
    png_init_io(p, f);
    png_read_png(p, i, PNG_TRANSFORM_STRIP_16 | PNG_TRANSFORM_PACKING | PNG_TRANSFORM_EXPAND, nullptr);
    w = png_get_image_width(p, i); h = png_get_image_height(p, i);
    int ch = png_get_channels(p, i);
    png_bytepp rows = png_get_rows(p, i);
    rgb.resize(size_t(w) * h);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        png_bytep q = rows[y] + x * ch;
        rgb[y * w + x] = (q[0] << 16) | (q[1] << 8) | q[2];
    }
    png_destroy_read_struct(&p, &i, nullptr);
    fclose(f);
    return true;
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { fprintf(stderr, "usage: Vtb_frame_top <dir> <frame>...\n"); return 2; }
    std::string dir = argv[1];
    int bad = 0;
    const bool fx = getenv("FLIPX") && atoi(getenv("FLIPX")), fy = getenv("FLIPY") && atoi(getenv("FLIPY"));
    Vtb_frame_top *t = new Vtb_frame_top;
    auto &mem = t->rootp->tb_frame_top__DOT__u_model__DOT__mem_b;
    uint64_t cyc = 0;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); cyc++; };

    for (int a = 2; a < argc; a++) {
        std::string fr = argv[a];
        FILE *f = fopen((dir + "/state_" + fr + ".bin").c_str(), "rb");
        if (!f) { fprintf(stderr, "no state %s\n", fr.c_str()); bad++; continue; }
        std::vector<uint8_t> s(16 + 0x10000 + 0x400000);
        if (fread(s.data(), 1, s.size(), f) != s.size()) { fprintf(stderr, "short state %s\n", fr.c_str()); fclose(f); bad++; continue; }
        fclose(f);
        const uint8_t *vram = s.data() + 16 + 0x10000;
        for (uint32_t i = 0; i < 0x400000; i++) mem[0x1000000 + i] = vram[i];

        t->reset = 1; t->pal_we = 0; t->wr_we = 0;
        t->vram_bank = s[0] | (s[1] << 8);
        t->vreg_addr = s[2] | (s[3] << 8);
        t->vctrl = 0x84 | (fx ? 0x20 : 0) | (fy ? 0x40 : 0);
        for (int i = 0; i < 4; i++) tick();
        // the work RAM and the palette mirror, through their write ports while the chip is held
        for (int i = 0; i < 0x8000; i++) {
            t->wr_we = 1; t->wr_addr = i; t->wr_data = s[16 + 2 * i] | (s[17 + 2 * i] << 8);
            tick();
        }
        t->wr_we = 0;
        for (int e = 0; e < 65536; e++) {
            uint32_t o = (e >> 8) * 2048 + (e & 0xff) * 2;
            t->pal_we = 1; t->pal_addr = e; t->pal_data = vram[o] | (vram[o + 1] << 8);
            tick();
        }
        t->pal_we = 0;
        t->reset = 0;
        while (!t->ready) tick();
        // the first vblank takes the list; the picture is the frame after it
        while (!t->vbl) tick();
        tick();
        std::vector<uint32_t> pic(320 * 240, 0);
        int x = 0, y = 0;
        bool in_v = true;
        uint16_t max_ovr = 0;
        // wait for the end of the vertical blank, then take 240 lines of 320 dots
        while (t->vblank || !t->ce_pix) tick();
        while (y < 240) {
            if (t->ce_pix) {
                if (!t->hblank && !t->vblank) {
                    pic[y * 320 + x] = (t->r << 16) | (t->g << 8) | t->b;
                    if (++x == 320) { x = 0; y++; }
                }
            }
            tick();
            if (cyc > 400000000ULL) break;
        }
        (void)in_v; (void)max_ovr;
        FILE *o = fopen((dir + "/out_" + fr + ".ppm").c_str(), "wb");
        fprintf(o, "P6\n320 240\n255\n");
        for (uint32_t v : pic) { fputc(v >> 16, o); fputc((v >> 8) & 255, o); fputc(v & 255, o); }
        fclose(o);
        std::vector<uint32_t> snap; int w, h;
        printf("frame %s: %d sprites, longest line %d clocks, %d overruns: ", fr.c_str(), t->sprites, t->line_clks, t->overruns);
        if (!load_png(dir + "/snap_" + fr + ".png", snap, w, h) || w != 320 || h != 240) { printf("no snapshot\n"); continue; }
        if (fx || fy) {
            std::vector<uint32_t> m(snap.size());
            for (int k = 0; k < 320 * 240; k++) {
                int sx = k % 320, sy = k / 320;
                m[(fy ? 239 - sy : sy) * 320 + (fx ? 319 - sx : sx)] = snap[k];
            }
            snap.swap(m);
        }
        int diff = 0, first = -1;
        for (int k = 0; k < 320 * 240; k++) if (pic[k] != snap[k]) { if (first < 0) first = k; diff++; }
        if (diff) { printf("%d dots differ (first at %d,%d: core %06x mame %06x)\n", diff, first % 320, first / 320, pic[first], snap[first]); bad++; }
        else printf(fx || fy ? "identical to MAME's, mirrored\n" : "identical to MAME\n");
    }
    delete t;
    return bad != 0;
}
