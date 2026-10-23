# Vendored modules

Third-party HDL copied into the tree (no submodules, so the build is self-contained and reproducible). Each keeps its own
licence alongside (or, for the V30, its upstream repository's).

| module | upstream | licence |
|---|---|---|
| `rtl/v30/` (the V30) | https://github.com/MiSTer-devel/Arcade-IremM72_MiSTer @ 15c370e6e034a5e8baeea5a6fa651ff95b216c2b, `rtl/v30/`: the ucore V30 (microcode-driven, its tables in `ucrom.hex` / `ucdecode.hex` / `pla3_tables.svh`), copied unchanged except that its bus adapter `v30_bus.sv` is not taken: `rtl/gunpey_v30.sv` is that adapter without the save-state port. It lives in `rtl/v30/` and not here because its ROM loader's default path (`v30u_ucrom.sv`'s HEXDIR) is `rtl/v30/` from the project and `../rtl/v30/` from `sim/` | GPL-2.0-or-later (the M72 core's licence) |
| jt6295 | https://github.com/jotego/jt6295 (Jose Tejada): the 8 files `hdl/jt6295*.v`, copied from the owner's Oh My God! core (decoryah/Arcade-OhMyGod_MiSTer `modules/jt6295`), itself the Metro core's copy, which carries the owner's patches marked in the files (patch 2: a start to a playing voice is dropped; patch 3: BUSY and the status as MAME's) | GPL-3.0 |
| crt-adjust | https://github.com/rmonic79/MiSTer-CRT-Adjust @ c682de9f4acc61d8f4c7779efb48149d3baa3a8e (upstream's `rtl/crt_adjust.sv`; one local fix, below), by rmonic79 (Umberto Parisi) with Andrea Bogazzi (asturur); copied from the owner's Rabbit core | GPL-3.0 or later |

To update one: re-copy from upstream at the new commit and record it here.

Local change to `crt-adjust/crt_adjust.sv` (one line, `hoff_s`): the conditional mixes `$signed(hoffset)` with an unsigned
replication, so by the Verilog rules (and in Verilator) the result is unsigned and a negative H-Position is zero-extended
(-1 becomes 511), which moves the picture window out of the line and blanks the picture. The line sign-extends `hoffset`
explicitly, which is what the module is meant to do and gives the same result in every tool. Nothing else differs from
upstream.

Code taken from the owner's own cores (GPL-3.0-or-later) is noted in each file's header: the SDRAM controller, the program cache,
the fast load and the standby raster (the Rabbit core), the YMZ280B (the Jackie Chan core).
