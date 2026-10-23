#!/bin/sh
# The system bench (tb_gunpey.cpp): the whole board from reset with MAME's ROMs.
#   sim/run_sys.sh <rom dir> <out dir> <last frame> [frames to write ...]      (SCHED=play, IOLOG=<file>, EVERY=<n>,
#                                                                                    DSW1=<n> / DSW2=<n>)
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
OBJ=${OBJ:-obj_sys}
if [ ! -x $OBJ/Vtb_gunpey_top ] || [ -n "$REBUILD" ]; then
verilator --cc --exe --build --no-timing -j ${JOBS:-16} -O3 -CFLAGS "-O2" -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
    -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNSIGNED \
    -Wno-CMPCONST -Wno-PROCASSINIT -Wno-BLKSEQ -I../rtl -I../rtl/v30 -I../modules/jt6295/hdl --top-module tb_gunpey_top -Mdir $OBJ \
    ../rtl/v30/v30u_ss_pkg.sv ../rtl/v30/v30_core.sv ../rtl/v30/v30u_biu.sv ../rtl/v30/v30u_eu.sv ../rtl/v30/v30u_ucrom.sv \
    ../rtl/gunpey_v30.sv ../rtl/gunpey_main.sv ../rtl/gunpey_cache.sv ../rtl/gunpey_sdram.sv ../rtl/gunpey_blitter.sv ../rtl/gunpey_video.sv \
    ../rtl/gunpey_ymz280b.sv ../rtl/gunpey_sound.sv ../rtl/gunpey_core.sv \
    ../modules/jt6295/hdl/jt6295.v ../modules/jt6295/hdl/jt6295_acc.v ../modules/jt6295/hdl/jt6295_adpcm.v \
    ../modules/jt6295/hdl/jt6295_ctrl.v ../modules/jt6295/hdl/jt6295_rom.v ../modules/jt6295/hdl/jt6295_serial.v \
    ../modules/jt6295/hdl/jt6295_sh_rst.v ../modules/jt6295/hdl/jt6295_timing.v \
    sdram_model.sv tb_gunpey_top.sv tb_gunpey.cpp > $OBJ.log 2>&1 || { grep -i -B2 -A6 "%Error" $OBJ.log | head -60; exit 1; }
fi
./$OBJ/Vtb_gunpey_top "$@"
