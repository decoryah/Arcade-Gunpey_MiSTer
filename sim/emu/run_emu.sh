#!/bin/sh
# End-to-end bench of the MiSTer top level (Gunpey.sv): hps_io and the PLL stubbed, everything else real (the Rabbit core's bench, after
# the Mystic Warriors core's).
#   sim/emu/run_emu.sh <image.rom> [frames after the load, default 30] [out prefix]
# The image is the MRA's (python3 tools/mra_build.py "mra/Gunpey (Japan).mra" gunpey.zip gunpey.rom). FAST=1 loads through the DDR3 fast
# load path, PRELOAD=1 skips the load; SNAPEVERY=n (default 10); the OSD settings and the scripted coin / start: tb_emu.cpp.
set -e
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
cd "$(dirname "$0")"
IMG=$(realpath "$1"); FR="${2:-30}"; PRE="${3:-emu}"
case "$PRE" in /*) ;; *) PRE="$(pwd)/$PRE" ;; esac
[ -f "$IMG" ] || { echo "usage: $0 <image.rom> [frames] [prefix]" >&2; exit 2; }
S=../../sys
OBJ=${OBJ:-obj_emu}
mkdir -p $OBJ
# The framework's video_mixer.sv declares R_in/G_in/B_in inside an unnamed generate block and uses them outside it; Quartus accepts
# that, Verilator does not: the bench builds a copy with the wires declared at module level (as the Rabbit core's bench does)
python3 - $S/video_mixer.sv $OBJ/video_mixer_sim.sv <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'generate\s+if\(GAMMA && HALF_DEPTH\) begin.*?end else begin(.*?)end\s+endgenerate', s, re.S)
assert m, 'video_mixer.sv: the R_in generate block was not found'
open(sys.argv[2], 'w').write(s[:m.start()] + m.group(1).strip() + chr(10) + s[m.end():])
PY
J=../../modules/jt6295/hdl
V=../../rtl/v30
if [ ! -x $OBJ/Vtb_emu_top ] || [ -n "$REBUILD" ]; then
echo '`define BUILD_DATE "000000"' > $OBJ/build_id.v
verilator --cc --exe --build --no-timing -j ${JOBS:-16} -O2 -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNOPTFLAT -Wno-PINMISSING \
    -Wno-PINCONNECTEMPTY -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-PROCASSWIRE -Wno-PROCASSINIT -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-UNUSEDSIGNAL \
    +1364-2005ext+v -I$OBJ -I. -I../.. -I../../rtl -I$V -I$J ../waivers.vlt --public-flat-rw \
    --top-module tb_emu_top --prefix Vtb_emu_top -Mdir $OBJ \
    ../../Gunpey.sv $V/v30u_ss_pkg.sv $V/v30_core.sv $V/v30u_biu.sv $V/v30u_eu.sv $V/v30u_ucrom.sv \
    ../../rtl/gunpey_v30.sv ../../rtl/gunpey_main.sv ../../rtl/gunpey_cache.sv ../../rtl/gunpey_sdram.sv ../../rtl/gunpey_blitter.sv \
    ../../rtl/gunpey_video.sv ../../rtl/gunpey_ymz280b.sv ../../rtl/gunpey_sound.sv ../../rtl/gunpey_core.sv ../../rtl/gunpey_loader.sv \
    ../../rtl/gunpey_fastload.sv ../../rtl/gunpey_standby.sv \
    $J/jt6295.v $J/jt6295_acc.v $J/jt6295_adpcm.v $J/jt6295_ctrl.v $J/jt6295_rom.v $J/jt6295_serial.v $J/jt6295_sh_rst.v $J/jt6295_timing.v \
    ../../modules/crt-adjust/crt_adjust.sv \
    $S/arcade_video.v $OBJ/video_mixer_sim.sv $S/scandoubler.v $S/scanlines.v $S/gamma_corr.sv $S/hq2x.sv $S/video_freezer.sv $S/video_freak.sv $S/math.sv \
    hps_io_stub.sv pll_stub.sv sync_fix.sv ../sdram_model.sv ../ddr_model.sv tb_emu_top.sv tb_emu.cpp \
    > $OBJ.log 2>&1 || { grep -E "%Error" $OBJ.log | head -30; tail -5 $OBJ.log; exit 1; }
fi
# from sim/: the V30's microcode tables are read from ../rtl/v30/
cd ..
stdbuf -oL ./emu/$OBJ/Vtb_emu_top "$IMG" "$FR" "$PRE"
