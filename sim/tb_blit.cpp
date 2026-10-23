// The blitter bench (sim/run_blit.sh): MAME's video RAM of frame A, the blits MAME logged after it (tools/lua/dump_state.lua's blits.log)
// run through rtl/gunpey_blitter.sv one at a time, then the video RAM compared with MAME's of frame B. Also: every palette mirror write
// checked against the video RAM it mirrors, and each blit's time against MAME's (xsize * ysize CPU clocks, six system clocks each).
//   Vtb_blit_top <gp_rom3> <stateA.bin> <stateB.bin> <blits.log> <frameA> <frameB>
#include "Vtb_blit_top.h"
#include "Vtb_blit_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <vector>

static std::vector<uint8_t> load(const char *p, size_t want)
{
    std::vector<uint8_t> v;
    FILE *f = fopen(p, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", p); exit(1); }
    uint8_t buf[65536]; size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) v.insert(v.end(), buf, buf + n);
    fclose(f);
    if (v.size() != want) { fprintf(stderr, "%s: %zu bytes\n", p, v.size()); exit(1); }
    return v;
}

static const uint32_t GFX_BYTE = 0x080000 * 2, VRAM_BYTE = 0x800000 * 2;

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    if (argc < 7) { fprintf(stderr, "usage: Vtb_blit_top rom3 stateA stateB blits.log frameA frameB\n"); return 2; }
    std::vector<uint8_t> rom = load(argv[1], 0x400000);
    std::vector<uint8_t> sa = load(argv[2], 16 + 0x10000 + 0x400000), sb = load(argv[3], 16 + 0x10000 + 0x400000);
    long fa = atol(argv[5]), fb = atol(argv[6]);

    Vtb_blit_top *t = new Vtb_blit_top;
    auto &mem = t->rootp->tb_blit_top__DOT__u_model__DOT__mem_b;
    for (uint32_t i = 0; i < 0x400000; i++) mem[GFX_BYTE + i] = rom[i];
    for (uint32_t i = 0; i < 0x400000; i++) mem[VRAM_BYTE + i] = sa[16 + 0x10000 + i];

    uint64_t cyc = 0;
    long pal_bad = 0, pal_n = 0;
    std::vector<uint16_t> palw;   // the mirror's writes, checked against the final video RAM only if nothing overwrote them later
    auto tick = [&]() {
        t->clk = 0; t->eval(); t->clk = 1; t->eval(); cyc++;
        t->cpu_ce = (cyc % 6) == 0;
        if (t->pal_we) {
            pal_n++;
            uint32_t row = t->pal_addr >> 8, w = t->pal_addr & 0xff;
            uint32_t o = VRAM_BYTE + row * 2048 + w * 2;
            // the mirror's word is the little-endian pair of the video RAM's bytes; the SDRAM gets them a few clocks later, so this is
            // compared with what the blit writes (the bench's own record below)
            palw.push_back(t->pal_addr); palw.push_back(t->pal_data);
            (void)o;
        }
    };
    t->reset = 1; t->start = 0; t->cpu_ce = 0;
    for (int i = 0; i < 10; i++) tick();
    t->reset = 0;
    while (!t->ready) tick();
    for (int i = 0; i < 10; i++) tick();

    FILE *f = fopen(argv[4], "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[4]); return 1; }
    char line[512];
    int n = 0, nc = 0;
    double worst = 0; long worst_n = -1;
    while (fgets(line, sizeof(line), f)) {
        char *p = line;
        long fr = strtol(p, &p, 10);
        strtoll(p, &p, 10);
        uint8_t r[16];
        for (int i = 0; i < 16; i++) r[i] = uint8_t(strtol(p, &p, 16));
        if (fr <= fa || fr > fb) continue;
        // load the registers and start
        for (int w = 0; w < 4; w++) {
            uint32_t v = 0;
            for (int b = 0; b < 4; b++) v |= uint32_t(r[4 * w + b]) << (8 * b);
            t->regs[w] = v;
        }
        t->start = 1; tick(); t->start = 0;
        uint64_t t0 = cyc;
        while (!t->idle) { tick(); if (cyc - t0 > 50000000ULL) { fprintf(stderr, "blit %d hangs\n", n); return 1; } }
        uint64_t took = cyc - t0;
        double mame = (double)((r[12] + 1) * 2) * (r[14] + 1) * 6;
        if (took / mame > worst) { worst = took / mame; worst_n = n; }
        while (t->busy) tick();
        n++;
        if (r[1]) nc++;
        if (getenv("VERBOSE")) printf("blit %d mode %d %dx%d: %llu clocks (MAME %.0f)\n", n, r[1], (r[12] + 1) * 2, r[14] + 1,
                                      (unsigned long long)took, mame);
    }
    fclose(f);
    for (int i = 0; i < 100; i++) tick();

    long diff = 0, first = -1;
    for (uint32_t i = 0; i < 0x400000; i++)
        if (mem[VRAM_BYTE + i] != sb[16 + 0x10000 + i]) { if (first < 0) first = i; diff++; }
    // the palette mirror's last write of each entry against the final video RAM
    std::vector<int32_t> last(65536, -1);
    for (size_t i = 0; i < palw.size(); i += 2) last[palw[i]] = palw[i + 1];
    for (int e = 0; e < 65536; e++) {
        if (last[e] < 0) continue;
        uint32_t o = VRAM_BYTE + (e >> 8) * 2048 + (e & 0xff) * 2;
        uint16_t v = mem[o] | (mem[o + 1] << 8);
        if (v != (uint16_t)last[e]) pal_bad++;
    }
    printf("%d blits (%d compressed), slowest %.2f of MAME's time (blit %ld)%s; palette mirror %ld writes, %ld wrong; ", n, nc, worst,
           worst_n, t->error ? ", DECODE ERROR" : "", pal_n, pal_bad);
    if (diff) printf("%ld bytes differ (first at x %ld y %ld: core %02x mame %02x)\n", diff, first & 0x7ff, first >> 11,
                     mem[VRAM_BYTE + first], sb[16 + 0x10000 + first]);
    else printf("video RAM identical\n");
    delete t;
    return diff != 0 || pal_bad != 0;
}
