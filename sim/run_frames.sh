#!/bin/sh
# The frame bench: MAME's dumped states (tools/lua/dump_state.lua) through the video chip, each picture compared with MAME's snapshot.
#   sim/run_frames.sh <state dir> [frames...]     (all the dir's states when no frames are given; FLIPX=1 / FLIPY=1: flipped, compared
#                                                  with MAME's snapshot mirrored)
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
DIR="$1"; shift
OBJ=${OBJ:-obj_frame}
if [ ! -x $OBJ/Vtb_frame_top ] || [ -n "$REBUILD" ]; then
verilator --cc --exe --build --no-timing -j ${JOBS:-16} -O3 -CFLAGS "-O2" -LDFLAGS "-lpng" -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME \
    -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-LATCH \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-PROCASSINIT -Wno-BLKSEQ -I../rtl --top-module tb_frame_top -Mdir $OBJ \
    ../rtl/gunpey_sdram.sv ../rtl/gunpey_video.sv sdram_model.sv tb_frame_top.sv tb_frame.cpp > $OBJ.log 2>&1 || { grep -i -B2 -A4 "error" $OBJ.log | head -40; exit 1; }
fi
if [ $# -eq 0 ]; then set -- $(ls "$DIR" | sed -n 's/^state_\([0-9]*\)\.bin$/\1/p' | sort -n); fi
./$OBJ/Vtb_frame_top "$DIR" "$@"
