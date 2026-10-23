# Gunpey for MiSTer

A MiSTer FPGA core for **Gunpey** (Bandai / Banpresto, 2000), the arcade version of Gunpei Yokoi's WonderSwan puzzle game, on the
VG-10 board: an NEC V30, the Axell AG-1 sprite chip with its 4 MB video RAM, a YMZ280B and an OKI M6295. Written from MAME 0.289's
driver (`src/mame/misc/gunpey.cpp`), with MAME as the reference for everything; the platform layer follows the owner's Rabbit core
([decoryah/Arcade-Rabbit_MiSTer](https://github.com/decoryah/Arcade-Rabbit_MiSTer)).

No ROMs or other copyrighted data are in this repository; you supply your own MAME `gunpey.zip`.

**Status.** New core: built, simulated with the real game, **not yet tested on a MiSTer**. See "What is verified" for exactly
what has been checked and how, and "Known differences / open points" for what has not.

## Install

1. Unzip `dist/Gunpey_MiSTer_<date>.zip` (`python3 tools/package.py` writes it) over the root of the SD card (`/media/fat/`): the
   core goes to `_Arcade/cores/`, `Gunpey (Japan).mra` to `_Arcade/`. (By hand: `releases/gunpey_<date>.rbf` to `_Arcade/cores/`,
   `mra/Gunpey (Japan).mra` to `_Arcade/`. Keep the RBF's `gunpey_` name: MiSTer finds the core by the MRA's `<rbf>`.)
2. Put your MAME 0.289 `gunpey.zip` in `/media/fat/games/mame/`.
3. Start `Gunpey (Japan)` from the Arcade menu. The image is 15 MB (the ROMs and 4 MB of 0xFF for the video RAM's first contents);
   a recent Main_MiSTer copies it to the DDR3 in one go (the MRA's `address=`) and the core loads it from there in about a second,
   an older one streams it through the HPS port.

## Controls and OSD

A 4-way joystick and two buttons per player, Start and Coin. The buttons are named for what they do, measured in MAME: **Swap**
(button 1: swaps the two panels in the cursor; it also confirms in the menus) and **Raise** (button 2: pushes the field up a row).
The board has a third button input, but the game does nothing with it (only the test mode's I/O check shows it), so the pad has no
third button. Keyboard: 1 / 2 start, 5 / 6 coin, 9 service, F2 the test switch (the test mode: I/O, monitor and sound tests).

| Option | Values |
|---|---|
| Aspect ratio | Original (4:3), Full Screen, [ARC1], [ARC2] |
| Scale | Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+ (the framework's integer scaling for HDMI) |
| Scandoubler Fx | None, HQ2x, CRT 25 / 50 / 75 % |
| CRT Adjust (page) | Off, On; H-Size 0 to +2 and -16 to -1, H-Position -48 to +16, V-Shift -16 to +15. rmonic79's CRT Adjust (`modules/crt-adjust`) for a 15 kHz analog output: the picture's size and place on the tube are changed through a line buffer while the sync pulses keep their timing, so the monitor stays locked. A size step is 1/48 of a dot (6.7 dots across the picture); +2 is the most that fits before the next hsync pulse, and H-Position +16 fits at H-Size 0 (larger settings together cut the picture's right edge at the hsync pulse). It does nothing while the scandoubler is on (31 kHz) |
| Volume | Normal (twice MAME's level), -6 dB, -12 dB, +6 dB |
| Swap stereo | No, Yes |
| DIP switches | MAME's: difficulty (single and vs. mode), matches in vs. mode, demo sounds, flip screen, coin A / B, free play, continue |

## What is verified

* **The blitter**, against MAME's video RAM: MAME's dumps (`tools/lua/dump_state.lua`: the work RAM, the video RAM and the
  registers at a frame, and every blit the game starts) replayed through `rtl/gunpey_blitter.sv` on the SDRAM controller and model
  (`sim/run_blit.sh`): 5789 blits of the boot, the attract mode and a play session, 1590 of them compressed, leave the video RAM
  byte-identical to MAME's. The palette mirror's 99584 writes match the video RAM they copy.
* **The display**, against MAME's snapshots: 23 dumped frames (attract mode, menus, play) drawn by `rtl/gunpey_video.sv` from MAME's
  state (`sim/run_frames.sh`) are pixel-identical to MAME's pictures. The longest line takes 1687 of the 5304 clocks a line has.
* **The C++ reference** (`tools/gunpey_ref`, MAME's code ported line for line): the same frames and blits, identical to MAME; it also
  checked that every compressed sprite's copy codes read only what the core keeps (the strip's row before and the last column of
  the strip before).
* **The V30**, against MAME's I/O trace: with the board's memory and I/O modelled around it (`sim/run_v30.sh`), its first 627 I/O
  accesses are MAME's, value for value, in the same order; they part where the first interrupt arrives, because the two CPUs differ
  in speed (below).
* **The whole board** (`sim/run_sys.sh`): from reset with the ROM set, the game boots, runs its attract mode, takes a coin and starts
  a game (1500 frames; 1100 with the released logic); at frame 1000, with MAME's scripted inputs, its picture is MAME's frame 1000
  but for a moving banner a few dots further on. No line ever ran out of time (the longest took 1063 of its 5304 clocks).
* **The sound**, against MAME's `-wavwrite` recording of the same scripted session: the system bench's 48 kHz capture starts where
  MAME's does, at twice MAME's level as designed, and its waveform matches MAME's: the normalised cross-correlation of half-second
  windows is 0.86 to 0.997 (at offsets of 0 and 65 ms: the core's slower V30 moves some sound events by a few frames).
* **The MRA**: `tools/mra_build.py` assembles exactly the image the benches load, and checks the MRA's md5 the way MiSTer computes
  it (over the files as read, before the interleave). MiSTer's own assembly code (`rom_data()` from Main_MiSTer's
  `mra_loader.cpp`, run on a PC) builds the same image and the same md5.
* **The MiSTer top level** (`sim/emu/run_emu.sh`: `Gunpey.sv` with the framework's video path, hps_io and the PLL stubbed, the SDRAM
  and DDR3 modelled): the MRA's image loads through the HPS port and through the DDR3 fast load (0.83 s of machine time) into the
  SDRAM byte for byte; the raster is 442 x 264 dots of 12 clocks (61.32 Hz) with 240 rows of 320 dots, scandoubled 480 rows; every
  Scale setting asks the HDMI scaler for the size the framework's rule gives; CRT Adjust's extremes (H-Size +2 and -16, H-Position +16
  and -48, V-Shift -16 and +15) keep every row whole.
* **The build** (Quartus 17.0.2, `releases/gunpey_20261023.rbf`): every clock meets timing, the machine's 85.86 MHz with 1.26 ns to
  spare; 48 % of the logic, 54 % of the block RAM, 46 % of the DSP blocks. The fitter and timing summaries are next to the RBF.

## Where the core is not MAME

* **The CPU's speed.** The core's V30 is the Irem M72 core's, which runs every instruction in the real chip's clocks; MAME's V30 is
  faster on some, notably the string instructions of the boot RAM test (a `rep cmpsw` word is 10 clocks on the chip). The core reaches
  the game's first I/O write at CPU clock 1109343, MAME at 718072, and runs about a frame and a half behind MAME from there.
* **The blitter's interrupt** comes at MAME's time (width x height CPU clocks after the start) or when the blit is done, if that is
  later; narrow raw blits (a word or two a row) take up to 1.35 times MAME's time in the simulation.
* **Drawing during the frame.** MAME draws a frame at once at the start of vblank; the core copies the display list then (the CPU held
  meanwhile, so the list is MAME's) but reads the sprites' pixels from the video RAM while it draws the next frame a line at a time.
  The game never blits into what the shown frame reads after its start (checked over 70000 frames of MAME), apart from three blits in
  boot frames with nothing on the screen.

## Known differences / open points

* Not yet run on a MiSTer: the SDRAM at 85.86 MHz (the Rabbit core's controller and timing, proven at 96 MHz), the fractional PLL, the
  V30 at 14.3 MHz (the M72 core runs it at 8 MHz), the video and audio output.
* MAME's own open points stay open: where the board's two frame buffers are in the video RAM, and whether the board shows the game at
  60 or 30 frames a second (the 2018 progress report's question); the core shows what MAME shows. MAME's raster (442 x 264 dots,
  61.32 Hz) is used; the PCB's notes give 60 Hz / 15.79 kHz.
* The flip screen DIP switch is passed to the game as in MAME, which does not flip the picture either.
* The sound is MAME's chips (the YMZ280B from MAME's code, the OKI by jt6295) at twice MAME's mix level; compared with MAME's
  recording by correlation, not sample by sample.

## Repository layout

| Path | |
|---|---|
| `Gunpey.sv`, `Gunpey.q*`, `Gunpey.sdc`, `files.qip` | the MiSTer top level (`emu`), Quartus project, timing constraints |
| `rtl/` | the machine: `gunpey_core` (the board), `gunpey_main` (the V30's clock, memory, I/O and interrupts), `gunpey_v30` (the V30's bus), `gunpey_blitter` and `gunpey_video` (the AG-1), `gunpey_sound` with `gunpey_ymz280b`, `gunpey_cache` (program cache); the platform: `gunpey_sdram`, `gunpey_loader`, `gunpey_fastload`, `gunpey_standby`; `v30/` the vendored V30 |
| `modules/` | vendored: jt6295, rmonic79's CRT Adjust (`modules/VENDOR.md`, which also covers `rtl/v30`) |
| `sys/` | the MiSTer framework |
| `mra/` | the MRA |
| `sim/` | Verilator benches: the whole board (`run_sys.sh`), the frame bench (`run_frames.sh`), the blitter bench (`run_blit.sh`), the V30 alone (`run_v30.sh`), the MiSTer top level with the framework's video path (`emu/run_emu.sh`: the streamed and the fast load, the raster, Scale, the scandoubler, CRT Adjust) |
| `tools/` | the AG-1 reference in C++ (`gunpey_ref/`), the MAME Lua probe (`lua/dump_state.lua`) and its runner (`mame_dump.sh`), the decoder table's generator (`gen_huff.py`), MRA image builder (`mra_build.py`), picture tools (`ppm2png.py`, `montage.py`, `cmp_frame.py`, `pngio.py`) |
| `docs/` | `hardware.md`: the board as MAME describes it, what the game does with it, and the core's design |
| `releases/` | the RBF of each release with its fitter and timing summaries |

## Building

Quartus Prime Lite 17.0.2:

    quartus_sh --flow compile Gunpey

The benches need Verilator 5 (in WSL), g++ with libpng, Python 3 and your romset (unzipped in `work/roms/gunpey/`):

    tools/mame_dump.sh ../work/dump "1000,2000" play                 # MAME's states, snapshots and blit log (Git Bash)
    sim/run_frames.sh ../work/dump                                    # draw them, compare with MAME
    sim/run_blit.sh ../work/roms/gunpey/gp_rom3.025 ../work/dump/state_1000.bin ../work/dump/state_2000.bin ../work/dump/blits.log 1000 2000
    SCHED=play sim/run_sys.sh ../work/roms/gunpey ../work/sys 1500 500 1000   # the whole board, pictures of frames 500 and 1000
    make -C tools/gunpey_ref && tools/gunpey_ref/gunpey_ref render ../work/dump/state_1000.bin out.ppm ../work/dump/snap_1000.png

MAME's captures, the images and the benches' pictures go to a scratch folder `work/` next to the repository (never committed).

## Credits

* **MAME**: the gunpey driver (Angelo Salese, Tomasz Slanina, David Haywood, Luca Elia, Morten Shearman Kirkegaard, who decoded the
  sprite compression), the YMZ280B and OKI devices; the hardware knowledge and the reference for every comparison.
* **The Irem M72 core** (MiSTer-devel/Arcade-IremM72_MiSTer): the V30 and its bus adapter (GPL-2.0-or-later).
* **Jose Tejada (jotego)**: jt6295 (GPL-3.0).
* **rmonic79 (Umberto Parisi)**, with Andrea Bogazzi (asturur): CRT Adjust (GPL-3.0-or-later).
* The owner's cores: Rabbit (the SDRAM controller and its model, the fast load, the program cache, the standby raster, the CRT Adjust
  glue, the bench conventions), Jackie Chan (the YMZ280B), Oh My God! (the jt6295 copy and its wiring), Metro and Mystic Warriors
  before them.
* The MiSTer framework (Sorgelig and contributors).

## Licence

GPL-3.0-or-later (`LICENSE`); vendored modules keep their own licences.
