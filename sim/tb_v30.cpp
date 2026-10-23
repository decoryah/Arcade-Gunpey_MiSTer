// The V30 on its own with Gunpey's program: a C++ model of the board's memory, I/O and interrupts (MAME 0.289 gunpey.cpp) around
// rtl/gunpey_v30.sv. Prints the I/O accesses in the format of the MAME trace (W/R <cpu clock> <even address> <data> <mask>), so the two
// can be compared line by line.
//   sim/run_v30.sh <gp_rom1> <gp_rom2> <cpu clocks>
#include "Vgunpey_v30.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

static std::vector<uint8_t> load(const char *p, size_t n)
{
    std::vector<uint8_t> v(n, 0xff);
    FILE *f = fopen(p, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", p); exit(1); }
    if (fread(v.data(), 1, n, f) != n) { fprintf(stderr, "short %s\n", p); exit(1); }
    fclose(f);
    return v;
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    if (argc < 4) { fprintf(stderr, "usage: tb_v30 rom1 rom2 cycles\n"); return 2; }
    std::vector<uint8_t> r1 = load(argv[1], 0x80000), r2 = load(argv[2], 0x80000);
    long long limit = atoll(argv[3]);
    std::vector<uint16_t> rom(0x80000), wram(0x8000, 0);
    for (int i = 0; i < 0x80000; i++) rom[i] = r1[i] | (r2[i] << 8);

    Vgunpey_v30 *m = new Vgunpey_v30;
    uint8_t irq_mask = 0, irq_cause = 0;
    bool irq_line = false;
    uint8_t blit[16] = {0};
    long long blit_end = -1;
    long long cyc = 0;               // CPU clocks (CE pulses)
    const long long FRAME = 233376;  // 442 x 264 dots, two CPU clocks a dot
    auto irq_check = [&](uint8_t t) {
        irq_cause |= t;
        irq_line = (irq_cause & irq_mask) != 0;
    };

    m->reset = 1; m->ready = 1; m->int_vector = 0x80; m->int_req = 0;
    for (int i = 0; i < 40; i++) { m->clk = 0; m->ce = (i & 1); m->eval(); m->clk = 1; m->eval(); }
    m->reset = 0;
    bool io_wr_d = false, io_rd_d = false, ack_d = false;
    long long clk = 0;
    while (cyc < limit) {
        bool ce = (clk & 1);
        // interrupts and the blitter's end, on the CPU clock
        if (ce) {
            cyc++;
            if (cyc % FRAME == 0) irq_check(0x50);
            if (blit_end >= 0 && cyc >= blit_end) { blit_end = -1; irq_check(0x04); }
        }
        m->int_req = irq_line;
        // the read data, from the latched address
        uint32_t a = m->cpu_addr;
        uint16_t din = 0;
        if (m->mem_rd) {
            if (a < 0x10000) din = wram[a >> 1];
            else if (a >= 0x80000) din = rom[a >> 1];       // the region at the same offset: the ROMs' upper halves
            else din = 0;
        } else if (m->io_rd) {
            auto rd8 = [&](uint32_t p) -> uint8_t {
                if (p >= 0x7f40 && p <= 0x7f44) return 0;
                if (p == 0x7f45) return 0xff;
                if (p == 0x7f88) return 0xf0;
                if (p == 0x7fc8) return irq_mask;
                if (p == 0x7fc9) return irq_cause;
                return 0;
            };
            din = rd8(a & 0xffff) | (rd8((a & 0xffff) + 1) << 8);
        }
        m->cpu_din = din;
        m->clk = 0; m->ce = ce; m->eval();
        // writes: memory while the strobe is up (idempotent), I/O once at its rise
        if (m->mem_wr && a < 0x10000) {
            uint16_t &w = wram[a >> 1];
            if (m->cpu_be & 1) w = (w & 0xff00) | (m->cpu_dout & 0x00ff);
            if (m->cpu_be & 2) w = (w & 0x00ff) | (m->cpu_dout & 0xff00);
        }
        if (m->io_wr && !io_wr_d) {
            uint16_t mask = ((m->cpu_be & 2) ? 0xff00 : 0) | ((m->cpu_be & 1) ? 0x00ff : 0);
            printf("W %lld %04x %04x %04x\n", cyc, a & 0xffff, m->cpu_dout & mask, mask);
            for (int b = 0; b < 2; b++) {
                if (!(m->cpu_be & (1 << b))) continue;
                uint32_t p = (a & 0xffff) + b;
                uint8_t d = (m->cpu_dout >> (8 * b)) & 0xff;
                if (p == 0x7fc8) { irq_mask = d; irq_check(0); }
                if (p == 0x7fc9) { irq_cause &= ~d; irq_check(0); }
                if (p >= 0x7fd0 && p <= 0x7fdf) {
                    blit[p - 0x7fd0] = d;
                    if (p == 0x7fd0 && d == 2) blit_end = cyc + (long long)(blit[12] + 1) * 2 * (blit[14] + 1);
                }
            }
        }
        if (m->io_rd && !io_rd_d) {
            uint16_t mask = ((m->cpu_be & 2) ? 0xff00 : 0) | ((m->cpu_be & 1) ? 0x00ff : 0);
            printf("R %lld %04x %04x %04x\n", cyc, a & 0xffff, din & mask, mask);
        }
        static int nshow = 0; static bool mrd_d = false;
        if (getenv("TRACE") && m->mem_rd && !mrd_d && nshow < atoi(getenv("TRACE"))) {
            nshow++;
            printf("M %lld %05x %04x %s\n", cyc, a, din, m->code_fetch ? "code" : "data");
        }
        static long long next_sample = 0;
        if (getenv("SAMPLE") && m->mem_rd && !mrd_d && m->code_fetch && cyc >= next_sample) {
            printf("PC %lld %05x\n", cyc, a);
            next_sample = cyc + atoll(getenv("SAMPLE"));
        }
        mrd_d = m->mem_rd;
        // HOLD_LINE: the acknowledge drops the line
        if (m->int_ack && !ack_d) { irq_line = false; printf("INTA %lld\n", cyc); }
        io_wr_d = m->io_wr; io_rd_d = m->io_rd; ack_d = m->int_ack;
        m->clk = 1; m->eval();
        clk++;
    }
    delete m;
    return 0;
}
