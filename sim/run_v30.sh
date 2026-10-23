#!/bin/sh
# The V30 bench (tb_v30.cpp): the CPU alone with the board's memory and I/O modelled in C++.
#   sim/run_v30.sh <gp_rom1> <gp_rom2> <cpu clocks>
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
OBJ=${OBJ:-obj_v30}
if [ ! -x $OBJ/Vgunpey_v30 ] || [ -n "$REBUILD" ]; then
verilator --cc --exe --build --no-timing -j ${JOBS:-16} -O3 -CFLAGS "-O2" -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT \
    -Wno-PINCONNECTEMPTY -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-PROCASSINIT -Wno-BLKSEQ -I../rtl -I../rtl/v30 --top-module gunpey_v30 -Mdir $OBJ \
    ../rtl/v30/v30u_ss_pkg.sv ../rtl/v30/v30_core.sv ../rtl/v30/v30u_biu.sv ../rtl/v30/v30u_eu.sv ../rtl/v30/v30u_ucrom.sv \
    ../rtl/gunpey_v30.sv tb_v30.cpp > $OBJ.log 2>&1 || { tail -30 $OBJ.log; exit 1; }
fi
./$OBJ/Vgunpey_v30 "$@"
