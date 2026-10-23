// The system bench (sim/run_sys.sh): the whole board (rtl/gunpey_core.sv) from reset with MAME's ROM set, the inputs scripted as
// tools/lua/dump_state.lua scripts MAME's (SCHED=play: a coin at frame 600, start at 700, then the same pseudo-random joystick and
// button 1), frame k counted at the k-th vblank as MAME counts its frame_done. The picture shown after vblank k (MAME's snap_k) is
// written as out_<k>.ppm for the frames asked for; a line a frame (or every 50) reports the video chip's load.
//   Vtb_gunpey_top <rom dir> <out dir> <last frame> [<frame> ...]       (IOLOG=<file>: the CPU's I/O accesses, MAME's iotrace format;
//                                                                         WAV=<file>: the sound, 48 kHz stereo;
//                                                                         DSW1=<n> / DSW2=<n>: the DIP switches, MAME's ports)
#include "Vtb_gunpey_top.h"
#include "Vtb_gunpey_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <set>
#include <string>
#include <vector>

static std::vector<uint8_t> load(const std::string &p, size_t n)
{
    std::vector<uint8_t> v(n);
    FILE *f = fopen(p.c_str(), "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(1); }
    if (fread(v.data(), 1, n, f) != n) { fprintf(stderr, "short %s\n", p.c_str()); exit(1); }
    fclose(f);
    return v;
}

// the input schedule: tools/lua/dump_state.lua's sched()
static uint32_t hash32(uint64_t f, uint64_t k)
{
    uint64_t x = (f * 2654435761ULL + k * 40503ULL) & 0xffffffffULL;
    x = x ^ (x >> 13);
    x = (x * 1274126177ULL) & 0xffffffffULL;
    return uint32_t(x ^ (x >> 16));
}
static bool play = false;
static void sched(long f, uint8_t &p1, uint8_t &sys)
{
    p1 = 0; sys = 0;
    if (f >= 600 && f < 606) sys |= 0x08;          // coin 1
    if (f >= 700 && f < 706) sys |= 0x20;          // 1 player start
    if (play && f >= 800 && (f % 8) < 4) {
        static const uint8_t bit[5] = {0x01, 0x02, 0x04, 0x08, 0x10};   // up, down, left, right, button 1
        for (int k = 1; k <= 5; k++) if (hash32(f / 8, k) % 4 == 0) p1 |= bit[k - 1];
    }
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    if (argc < 4) { fprintf(stderr, "usage: Vtb_gunpey_top <rom dir> <out dir> <last frame> [frames...]\n"); return 2; }
    std::string rd = argv[1], od = argv[2];
    long last = atol(argv[3]);
    std::set<long> dumps;
    for (int i = 4; i < argc; i++) dumps.insert(atol(argv[i]));
    play = getenv("SCHED") && !strcmp(getenv("SCHED"), "play");
    int every = getenv("EVERY") ? atoi(getenv("EVERY")) : 50;
    FILE *iolog = getenv("IOLOG") ? fopen(getenv("IOLOG"), "w") : nullptr;
    FILE *wav = getenv("WAV") ? fopen(getenv("WAV"), "wb") : nullptr;
    std::vector<int16_t> snd;
    double snd_next = 0, snd_step = 85863600.0 / 48000.0;
    int16_t peak = 0;

    Vtb_gunpey_top *t = new Vtb_gunpey_top;
    auto &mem = t->rootp->tb_gunpey_top__DOT__u_model__DOT__mem_b;
    {
        std::vector<uint8_t> r1 = load(rd + "/gp_rom1.021", 0x80000), r2 = load(rd + "/gp_rom2.022", 0x80000);
        for (int i = 0; i < 0x80000; i++) { mem[2 * i] = r1[i]; mem[2 * i + 1] = r2[i]; }
        std::vector<uint8_t> r3 = load(rd + "/gp_rom3.025", 0x400000);
        for (int i = 0; i < 0x400000; i++) mem[0x100000 + i] = r3[i];
        std::vector<uint8_t> r4 = load(rd + "/gp_rom4.525", 0x400000);
        for (int i = 0; i < 0x400000; i++) mem[0x500000 + i] = r4[i];
        std::vector<uint8_t> r5 = load(rd + "/gp_rom5.622", 0x400000);
        for (int i = 0; i < 0x200000; i++) mem[0x900000 + i] = r5[i];
        for (int i = 0; i < 0x400000; i++) mem[0x1000000 + i] = 0xff;
    }

    uint64_t cyc = 0, cpu_clk = 0;
    t->dsw1 = getenv("DSW1") ? strtol(getenv("DSW1"), nullptr, 0) : 0;
    t->dsw2 = getenv("DSW2") ? strtol(getenv("DSW2"), nullptr, 0) : 0;
    t->in_p1 = 0; t->in_p2 = 0; t->in_sys = 0;
    t->reset = 1;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); cyc++; };
    for (int i = 0; i < 20; i++) tick();
    t->reset = 0;

    long frame = -1;
    long cap = -1; int cx = 0, cy = 0; bool capturing = false;
    std::vector<uint8_t> pic(320 * 240 * 3);
    long fetches = 0, iow = 0, blits = 0, inta = 0;
    uint16_t ovr_prev = 0;
    while (frame < last) {
        tick();
        if (t->cpu_ce) cpu_clk++;
        if (t->dbg_fetch) fetches++;
        if (wav && (double)cyc >= snd_next) {
            snd_next += snd_step;
            snd.push_back(t->audio_l); snd.push_back(t->audio_r);
            int16_t a = t->audio_l < 0 ? -t->audio_l : t->audio_l;
            if (a > peak) peak = a;
        }
        if (t->dbg_inta) inta++;
        if (t->dbg_blt_start) blits++;
        if (iolog && (t->dbg_io_wr || t->dbg_io_rd)) {
            uint16_t mask = ((t->dbg_io_be & 2) ? 0xff00 : 0) | ((t->dbg_io_be & 1) ? 0x00ff : 0);
            fprintf(iolog, "%c %llu %04x %04x %04x\n", t->dbg_io_wr ? 'W' : 'R', (unsigned long long)cpu_clk, t->dbg_addr & 0xffff,
                    t->dbg_io_data & mask, mask);
        }
        if (t->dbg_io_wr) iow++;
        if (t->frame) {
            frame++;
            uint8_t p1, sys;
            sched(frame, p1, sys);
            t->in_p1 = p1; t->in_sys = sys;
            if (frame % every == 0 || t->overruns != ovr_prev || t->blt_error)
                printf("frame %ld: cpu %llu clk, %d sprites, longest line %d clocks, overruns %d, fetches %ld, io writes %ld, blits %ld, "
                       "interrupts %ld%s\n", frame, (unsigned long long)cpu_clk, t->sprites, t->line_clks, t->overruns, fetches, iow, blits,
                       inta, t->blt_error ? ", BLIT DECODE ERROR" : "");
            fflush(stdout);
            ovr_prev = t->overruns;
            if (iolog) fprintf(iolog, "FRAME %ld %llu\n", frame, (unsigned long long)cpu_clk);
            if (dumps.count(frame)) { cap = frame; capturing = false; cx = cy = 0; }
        }
        // the picture after vblank `cap`: the next 240 visible lines
        if (cap >= 0 && t->ce_pix) {
            if (!capturing && !t->vblank) capturing = true;
            if (capturing && !t->hblank && !t->vblank) {
                uint8_t *p = &pic[(cy * 320 + cx) * 3];
                p[0] = t->r; p[1] = t->g; p[2] = t->b;
                if (++cx == 320) {
                    cx = 0;
                    if (++cy == 240) {
                        FILE *o = fopen((od + "/out_" + std::to_string(cap) + ".ppm").c_str(), "wb");
                        fprintf(o, "P6\n320 240\n255\n");
                        fwrite(pic.data(), 1, pic.size(), o);
                        fclose(o);
                        cap = -1; capturing = false;
                    }
                }
            }
        }
    }
    if (iolog) fclose(iolog);
    if (wav) {
        auto w32 = [&](uint32_t v) { fwrite(&v, 4, 1, wav); };
        auto w16 = [&](uint16_t v) { fwrite(&v, 2, 1, wav); };
        uint32_t bytes = uint32_t(snd.size() * 2);
        fwrite("RIFF", 1, 4, wav); w32(36 + bytes); fwrite("WAVEfmt ", 1, 8, wav); w32(16); w16(1); w16(2); w32(48000); w32(48000 * 4);
        w16(4); w16(16); fwrite("data", 1, 4, wav); w32(bytes);
        fwrite(snd.data(), 2, snd.size(), wav);
        fclose(wav);
        printf("sound: %zu samples, peak %d\n", snd.size() / 2, peak);
    }
    delete t;
    return 0;
}
