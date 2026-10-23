#!/bin/sh
# The blitter bench (tb_blit.cpp): MAME's logged blits through rtl/gunpey_blitter.sv, the video RAM compared with MAME's.
#   sim/run_blit.sh <gp_rom3> <stateA.bin> <stateB.bin> <blits.log> <frameA> <frameB>
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
OBJ=${OBJ:-obj_blit}
if [ ! -x $OBJ/Vtb_blit_top ] || [ -n "$REBUILD" ]; then
verilator --cc --exe --build --no-timing -j ${JOBS:-16} -O3 -CFLAGS "-O2" -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
    -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNSIGNED \
    -Wno-CMPCONST -Wno-PROCASSINIT -Wno-BLKSEQ -I../rtl --top-module tb_blit_top -Mdir $OBJ \
    ../rtl/gunpey_sdram.sv ../rtl/gunpey_blitter.sv sdram_model.sv tb_blit_top.sv tb_blit.cpp > $OBJ.log 2>&1 || { grep -i error $OBJ.log | head -30; exit 1; }
fi
./$OBJ/Vtb_blit_top "$@"
