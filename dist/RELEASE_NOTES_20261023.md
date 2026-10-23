## Gunpey for MiSTer - 20261023

Bandai / Banpresto's **Gunpey** (2000), the arcade version of Gunpei Yokoi's WonderSwan puzzle game, on the VG-10 board (an NEC
V30, the Axell AG-1 sprite chip with its 4 MB video RAM, a YMZ280B and an OKI M6295), with one MRA: Gunpey (Japan).

**First release. Tested on a real MiSTer by the repository owner: it works.** It was also checked in simulation against MAME
0.289 (below).

### Install

1. Unzip `Gunpey_MiSTer_20261023.zip` over the root of the SD card. It adds `Gunpey (Japan).mra` to `_Arcade/` and
   `_Arcade/cores/gunpey_20261023.rbf`.
2. Put your own MAME 0.289 romset `gunpey.zip` in `games/mame/`. No ROMs are included. The MRA checks the romset's md5 the way
   MiSTer computes it: another dump of the set gives "md5 mismatch for rom 0", and MiSTer then does not load it.
3. Start the game from the Arcade menu. The ROM image is 15 MB (the ROMs and 4 MB of 0xFF, the video RAM's first contents):
   with a recent Main_MiSTer it is copied to the DDR3 in one go and loads in about a second (the MRA's `address=` attribute),
   with an older one it is streamed, with the same RBF and MRA. The game's power-on RAM test then runs, as on the board.

The OSD's version line reads `v261023`. The game's settings are its DIP switches (the OSD's DIP page); it has no NVRAM. The game
reads the switches when it starts, so reset it after changing one (Flip Screen too).

### Checked

- **On a real MiSTer:** this RBF with this MRA was tested by the repository owner, and it works.
- **ROM path:** `tools/mra_build.py` builds the MRA's image by the MiSTer MRA rules and checks its md5 as MiSTer computes it
  (over the files as read, before the interleave); MiSTer's own assembly code (`rom_data()` from Main_MiSTer's
  `mra_loader.cpp`, compiled on a PC) builds the same image and the same md5.
- **The blitter against MAME's video RAM** (`sim/run_blit.sh`, every blit MAME's game started, replayed through the core's
  blitter, SDRAM controller and SDRAM model): 5,789 blits of the boot, the attract mode and a play session, 1,590 of them in the
  compressed sprite format, leave the 4 MB video RAM byte-identical to MAME's.
- **The display against MAME's snapshots** (`sim/run_frames.sh`, MAME's state at a frame drawn by the core's video chip): every
  dumped frame of the attract mode, the menus and play is pixel-identical to MAME's picture; the busiest line is drawn in a third
  of the time a line has. With the flip bits set the frames are MAME's turned 180 degrees, dot for dot.
- **The V30 against MAME's I/O trace** (`sim/run_v30.sh`): its first 627 I/O accesses are MAME's, value for value, in the same
  order; they part where the first interrupt arrives (the CPUs' speeds differ, below).
- **The whole machine** (`sim/run_sys.sh`: the V30 running the game from reset, the blitter, the display and the sound behind the
  SDRAM controller and model): the game boots, runs its attract mode, takes a coin and starts a game with MAME's scripted inputs,
  and its frame 1,000 is MAME's frame 1,000 but for a moving banner a few dots further on; no line is ever drawn late. With the
  Flip Screen DIP on, the game turns the picture 180 degrees (frame 300 is the unflipped run's, turned, dot for dot).
- **The sound against MAME's recording** (`-wavwrite`) of the same scripted session: it starts where MAME's does, at twice MAME's
  level as designed, and the normalised cross-correlation of half-second windows is 0.86 to 0.997.
- **The MiSTer top level** (`sim/emu/run_emu.sh`, the framework's own video path): the image loads through the DDR3 fast load (in
  0.83 s) and through the HPS port into the SDRAM byte for byte; the raster is 442 x 264 dots (61.32 Hz) with 240 rows of 320
  dots; every Scale setting asks the HDMI scaler for the size the framework's rule gives; CRT Adjust's extremes keep every row
  whole.
- **Quartus 17.0.2:** 48 % of the ALMs (20,313), 392 of 553 M10K, 51 DSPs; every clock's slack positive (the 85.86 MHz machine
  clock +1.091 ns setup, +0.244 ns hold; the tightest, +0.202 ns hold, is the framework's HDMI clock; fitter seed 8).
  `releases/gunpey_20261023.fit.summary` / `.sta.summary`.

### Controls

A 4-way joystick and two buttons, **Swap** and **Raise** (A and B on a gamepad by default), Start and Coin, for two players. Swap
swaps the two panels in the cursor (and confirms in the menus), Raise pushes the field up a row: measured in MAME, pressing each
button alone. The board's third button input does nothing in the game (only the test mode's I/O check shows it), so the core and
the MRA do not offer it. Keyboard: 1 / 2 start, 5 / 6 coin, 9 service, F2 the test switch (the I/O, monitor and sound tests).

### OSD

Aspect ratio, Scale (Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+), Scandoubler Fx (None, HQ2x, CRT 25 / 50 /
75 %), CRT Adjust (rmonic79's module: H-Size, H-Position, V-Shift for a 15 kHz analog output), Volume (Normal is twice MAME's
level; -6 dB, -12 dB, +6 dB), Swap stereo (the game pans some of its sounds), the DIP switches (MAME's: difficulty, the vs. mode's
difficulty and matches, demo sounds, flip screen, coin A / B, free play, continue), Reset. See the README.

### Where the core is not MAME

- **Flip Screen turns the picture.** With the DIP on, the game writes 0xE4 instead of 0x84 to the AG-1's register 7FF0 every frame
  and changes nothing else; the chip turns the picture itself. MAME has no 7FF0 and shows the game unflipped; the core turns it
  180 degrees.
- **The V30's speed.** The core's V30 (the Irem M72 core's) runs every instruction in the real chip's clocks; MAME's V30 is faster
  on some, notably the string instructions of the boot RAM test, so the core runs about a frame and a half behind MAME after boot.
- **The blitter's interrupt** comes at MAME's time (width x height CPU clocks after the start) or when the blit is done, if that
  is later: narrow raw blits (a word or two a row) take up to 1.35 times MAME's time.
- **Drawing during the frame.** MAME draws a frame at once at the start of vblank; the core copies the display list then (the CPU
  held meanwhile, so the list is MAME's) and draws the frame a line at a time while the line before is shown. The game never blits
  into what the shown frame reads after its start (checked over 70,000 frames of MAME).

### Known differences / open points

- MAME's own open points stay open: where the board's two frame buffers are in the video RAM, and whether the board shows the game
  at 60 or 30 frames a second (MAME's 2018 progress report's question); the core shows what MAME shows. MAME's raster (442 x 264
  dots, 61.32 Hz) is used; the PCB's notes give 60 Hz and 15.79 kHz.
- Which of 7FF0's two flip bits turns which axis is a guess: the game only ever sets both.
- The sound is MAME's chips (the YMZ280B from MAME's code, the OKI by jt6295), compared with MAME's recording by correlation,
  not sample by sample.
- The comparisons with MAME cover the attract mode, the menus and scripted one-player play; two-player and vs. mode play were
  not compared.

### Credits

MAME (the gunpey driver by Angelo Salese, Tomasz Slanina, David Haywood, Luca Elia and Morten Shearman Kirkegaard, who decoded the
sprite compression; the YMZ280B and OKI devices), the Irem M72 core's V30 (MiSTer-devel/Arcade-IremM72_MiSTer), Jose Tejada's
jt6295, rmonic79's CRT Adjust (with Andrea Bogazzi), decoryah/Arcade-Rabbit_MiSTer (the SDRAM controller and model, the fast load,
the program cache, the standby raster) and the repository owner's Jackie Chan core (the YMZ280B), plasticbugs' `mra_build.py`, and
the MiSTer framework.
