-- Gunpey: what the three buttons do (the names in Gunpey.sv's J1 line and the MRA come from these runs). A coin and 1P start, then:
--   PART=play (default)  button 1 through the menus (mode select, its "normal" choice, the character), and in play the cursor down to
--                        the bottom row and right onto the panels, then button 3 alone, button 1 alone and button 2 alone
--   PART=menu            in the mode select: button 1 (its sub-menu opens), button 3, button 1 again, button 2
-- with snapshots around each press (DIR/b_<frame>.png).
--   mame gunpey -autoboot_script tools/lua/buttons.lua -snapshot_directory DIR ...      (DIR and PART from the environment)
-- MAME 0.289, PART=play: button 3 at 2440 changes nothing; button 1 at 2540 swaps the cursor's two panels (2546-2552: the panel moves
-- between the cells); button 2 at 2620 raises the field a row (2660). PART=menu: button 3 at 1340 neither confirms nor backs out
-- (the sub-menu stays until button 1 at 1380 confirms it).
local mach = manager.machine
local scr = mach.screens[":screen"]
local DIR = os.getenv("DIR") or "."
local PART = os.getenv("PART") or "play"
local function field(port, name) for n, f in pairs(mach.ioport.ports[port].fields) do if n == name then return f end end end
local F = { c = field(":SYSTEM", "Coin 1"), s = field(":SYSTEM", "1 Player Start"),
            b1 = field(":P1", "P1 Button 1"), b2 = field(":P1", "P1 Button 2"), b3 = field(":P1", "P1 Button 3"),
            dn = field(":P1", "P1 Down"), rt = field(":P1", "P1 Right") }
local plan = {}
local function press(f, k, len) for i = f, f + (len or 3) - 1 do plan[i] = plan[i] or {}; plan[i][k] = true end end
press(600, "c", 6); press(700, "s", 6)
local shots, last
if PART == "menu" then
  press(1300, "b1"); press(1340, "b3"); press(1380, "b1"); press(1420, "b2")
  shots, last = {1295, 1320, 1360, 1400, 1440}, 1450
else
  press(1300, "b1"); press(1330, "b1"); press(1450, "b1")
  for i = 0, 7 do press(2300 + i * 8, "dn") end
  for i = 0, 2 do press(2380 + i * 8, "rt") end
  press(2440, "b3"); press(2540, "b1"); press(2620, "b2")
  shots, last = {2430, 2446, 2452, 2460, 2480, 2530, 2546, 2552, 2560, 2580, 2610, 2624, 2660}, 2670
end
local S = {}
for _, f in ipairs(shots) do S[f] = true end
emu.register_frame_done(function()
  local f = scr:frame_number()
  local p = plan[f] or {}
  for k, fld in pairs(F) do fld:set_value(p[k] and 1 or 0) end
  if S[f] then scr:snapshot(string.format("%s/b_%d.png", DIR, f)) end
  if f >= last then mach:exit() end
end)
