// gunpey_ref: the AG-1 reference model against MAME's dumps (tools/lua/dump_state.lua).
//   gunpey_ref render <state.bin> <out.ppm> [snap.png]           draw a dumped frame; with MAME's snapshot, compare
//   gunpey_ref blits <gp_rom3> <stateA.bin> <stateB.bin> <blits.log> <frameA> <frameB>
//                                                                replay the blits logged after frame A on A's video RAM, compare with B's
//   gunpey_ref decstats <gp_rom3> <blits.log>                    the compressed blits' reads outside the RTL's row buffers
#include "ag1.h"
#include <png.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static std::vector<uint8_t> load(const char *path, size_t want = 0)
{
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    std::vector<uint8_t> v;
    uint8_t buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) v.insert(v.end(), buf, buf + n);
    fclose(f);
    if (want && v.size() != want) { fprintf(stderr, "%s: %zu bytes, expected %zu\n", path, v.size(), want); exit(1); }
    return v;
}

struct state {
    uint16_t vram_bank, vreg_addr;
    std::vector<uint16_t> wram;
    std::vector<uint8_t> vram;
};

static state load_state(const char *path)
{
    std::vector<uint8_t> b = load(path, 16 + 0x10000 + 0x400000);
    state s;
    s.vram_bank = b[0] | (b[1] << 8);
    s.vreg_addr = b[2] | (b[3] << 8);
    s.wram.resize(0x8000);
    for (int i = 0; i < 0x8000; i++) s.wram[i] = b[16 + 2 * i] | (b[17 + 2 * i] << 8);
    s.vram.assign(b.begin() + 16 + 0x10000, b.end());
    return s;
}

static bool load_png(const char *path, std::vector<uint32_t> &rgb, int &w, int &h)
{
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    png_structp p = png_create_read_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
    png_infop i = png_create_info_struct(p);
    if (setjmp(png_jmpbuf(p))) { fclose(f); return false; }
    png_init_io(p, f);
    png_read_png(p, i, PNG_TRANSFORM_STRIP_16 | PNG_TRANSFORM_PACKING | PNG_TRANSFORM_EXPAND, nullptr);
    w = png_get_image_width(p, i);
    h = png_get_image_height(p, i);
    int ch = png_get_channels(p, i);
    png_bytepp rows = png_get_rows(p, i);
    rgb.resize(size_t(w) * h);
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            png_bytep q = rows[y] + x * ch;
            rgb[y * w + x] = (q[0] << 16) | (q[1] << 8) | q[2];
        }
    png_destroy_read_struct(&p, &i, nullptr);
    fclose(f);
    return true;
}

static uint32_t rgb555_to_888(uint16_t c)
{
    auto e = [](int v) { return (v << 3) | (v >> 2); };    // pal5bit
    return (e((c >> 10) & 31) << 16) | (e((c >> 5) & 31) << 8) | e(c & 31);
}

static int cmd_render(int argc, char **argv)
{
    if (argc < 4) return 2;
    state s = load_state(argv[2]);
    std::vector<uint16_t> pic(320 * 240);
    ag1::render(s.vram.data(), s.wram.data(), s.vram_bank, s.vreg_addr, pic.data());
    FILE *f = fopen(argv[3], "wb");
    fprintf(f, "P6\n320 240\n255\n");
    for (uint16_t c : pic) { uint32_t v = rgb555_to_888(c); fputc(v >> 16, f); fputc((v >> 8) & 255, f); fputc(v & 255, f); }
    fclose(f);
    if (argc >= 5) {
        std::vector<uint32_t> snap;
        int w, h;
        if (!load_png(argv[4], snap, w, h)) { fprintf(stderr, "cannot read %s\n", argv[4]); return 1; }
        if (w != 320 || h != 240) { printf("snapshot is %dx%d\n", w, h); return 1; }
        int diff = 0, first = -1;
        for (int k = 0; k < 320 * 240; k++)
            if (rgb555_to_888(pic[k]) != snap[k]) { if (first < 0) first = k; diff++; }
        if (diff) printf("%d pixels differ (first at %d,%d: ref %06x mame %06x)\n", diff, first % 320, first / 320,
                         rgb555_to_888(pic[first]), snap[first]);
        else printf("identical\n");
        return diff != 0;
    }
    return 0;
}

struct logged_blit { long frame; long long t; uint8_t r[16]; };

static std::vector<logged_blit> load_blits(const char *path)
{
    std::vector<logged_blit> v;
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    char line[512];
    while (fgets(line, sizeof(line), f)) {
        logged_blit b;
        char *p = line;
        b.frame = strtol(p, &p, 10);
        b.t = strtoll(p, &p, 10);
        for (int i = 0; i < 16; i++) b.r[i] = uint8_t(strtol(p, &p, 16));
        v.push_back(b);
    }
    fclose(f);
    return v;
}

static int cmd_blits(int argc, char **argv)
{
    if (argc < 8) return 2;
    std::vector<uint8_t> rom = load(argv[2], 0x400000);
    state a = load_state(argv[3]), b = load_state(argv[4]);
    std::vector<logged_blit> bl = load_blits(argv[5]);
    long fa = atol(argv[6]), fb = atol(argv[7]);
    // blits logged with frame number f ran after frame_done(f - 1) and before frame_done(f)
    int n = 0;
    for (auto &x : bl)
        if (x.frame > fa && x.frame <= fb) { ag1::blit(a.vram.data(), rom.data(), 0x3fffff, x.r); n++; }
    long diff = 0, first = -1;
    for (size_t k = 0; k < a.vram.size(); k++) if (a.vram[k] != b.vram[k]) { if (first < 0) first = long(k); diff++; }
    printf("%d blits: ", n);
    if (diff) printf("%ld bytes differ (first at x %ld y %ld: ref %02x mame %02x)\n", diff, first & 0x7ff, first >> 11, a.vram[first], b.vram[first]);
    else printf("video RAM identical\n");
    return diff != 0;
}

static int cmd_decstats(int argc, char **argv)
{
    if (argc < 4) return 2;
    std::vector<uint8_t> rom = load(argv[2], 0x400000);
    std::vector<logged_blit> bl = load_blits(argv[3]);
    std::vector<uint8_t> vram(0x400000, 0xff);
    long nc = 0, errs = 0, maxw = 0, maxh = 0;
    ag1::blit_stats tot;
    for (auto &x : bl) {
        if (x.r[1] == 0) continue;
        ag1::blit_stats st;
        ag1::blit(vram.data(), rom.data(), 0x3fffff, x.r, &st);
        nc++;
        if (st.error) errs++;
        if (st.reads_unwritten || st.reads_outside || st.reads_far)
            printf("frame %ld src %d,%d size %dx%d: unwritten %ld outside %ld far %ld\n", x.frame, x.r[4] | (x.r[5] << 8),
                   x.r[6] | (x.r[7] << 8), (x.r[12] + 1) * 2, x.r[14] + 1, st.reads_unwritten, st.reads_outside, st.reads_far);
        tot.reads_unwritten += st.reads_unwritten; tot.reads_outside += st.reads_outside; tot.reads_far += st.reads_far;
        maxw = std::max<long>(maxw, (x.r[12] + 1) * 2); maxh = std::max<long>(maxh, x.r[14] + 1);
        if (x.r[1] != 8) printf("frame %ld: compression mode %02x\n", x.frame, x.r[1]);
    }
    printf("%ld compressed blits (%ld failed), largest %ld x %ld; reads: unwritten %ld outside %ld far %ld\n", nc, errs, maxw, maxh,
           tot.reads_unwritten, tot.reads_outside, tot.reads_far);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc >= 2 && !strcmp(argv[1], "render"))   return cmd_render(argc, argv);
    if (argc >= 2 && !strcmp(argv[1], "blits"))    return cmd_blits(argc, argv);
    if (argc >= 2 && !strcmp(argv[1], "decstats")) return cmd_decstats(argc, argv);
    fprintf(stderr, "usage: see the head of ref_main.cpp\n");
    return 2;
}
