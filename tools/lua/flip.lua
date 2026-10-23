-- Gunpey: what the Flip Screen DIP (DSW1 bit 7) changes. FLIP=1 sets it before the game reads the switches; every I/O write
-- outside the sound chips and the blitter goes to DIR/io_<FLIP>.log ("frame offset data mask"), and DIR/f<FLIP>_<frame>.png
-- are snapshots.
--   mame gunpey -autoboot_script tools/lua/flip.lua -snapshot_directory DIR ...      (DIR and FLIP from the environment)
local mach = manager.machine
local scr = mach.screens[":screen"]
local DIR = os.getenv("DIR") or "."
local FLIP = os.getenv("FLIP") or "0"
local iosp = mach.devices[":maincpu"].spaces["io"]
for n, f in pairs(mach.ioport.ports[":DSW1"].fields) do
  if n == "Flip Screen" then f.user_value = (FLIP == "1") and f.mask or 0 end
end
local log = _G.io.open(string.format("%s/io_%s.log", DIR, FLIP), "w")
-- the taps are globals: a local one is collected and silently removed
FLIP_TAP = iosp:install_write_tap(0x7f00, 0x7fff, "fliplog", function(off, data, mask)
  local a = off & 0x7ffe
  if a == 0x7f80 or a == 0x7f88 or (a >= 0x7fd0 and a <= 0x7fdf) or a == 0x7fc8 then return end
  log:write(string.format("%d %04x %04x %04x\n", scr:frame_number(), off, data, mask))
end)
local SHOTS = { [200] = true, [400] = true, [900] = true }
emu.register_frame_done(function()
  local f = scr:frame_number()
  if SHOTS[f] then scr:snapshot(string.format("%s/f%s_%d.png", DIR, FLIP, f)) end
  if f >= 900 then log:close(); mach:exit() end
end)
