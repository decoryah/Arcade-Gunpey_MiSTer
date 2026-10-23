-- Gunpey: write the video chip's state with MAME's own snapshot of the same frame (the frame bench, sim/run_frames.sh), and a log of
-- every blitter start (the blitter bench, tools/gunpey_ref).
--   DUMPFRAMES=<f,f,...>  frames to capture;  DUMPDIR=<dir>  output (state_<f>.bin, snap_<f>.png, blits.log)
--   SCHED=play            scripted inputs, the same as the system bench's (sim/tb_gunpey.cpp sched()): a coin at frame 600, start at
--                         700, then a fixed pseudo-random pattern of the joystick and button 1 (attract mode only without it)
--   LAST=<f>              stop at frame f (default: the last dump frame)
-- At frame_done MAME has just drawn the frame (screen_update at the start of vblank, line 240) and the CPU has not run since, so the
-- memories read now are the ones the frame was drawn from.
-- state_<f>.bin, little-endian: u16 vram_bank, u16 vreg_addr, u8 irq_mask, u8 irq_cause, 10 bytes zero (16-byte header), the work RAM
-- (0x00000-0x0ffff, 64 KB), the video RAM (MAME's m_vram, 4 MB: byte (x, y) at x + 2048 * y)
-- blits.log: one line per blitter start: frame, the time in CPU clocks (14.3106 MHz), the 16 register bytes (hex)
local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local prg  = cpu.spaces["program"]
local iosp = cpu.spaces["io"]
local scr  = mach.screens[":screen"]
local root = mach.devices[":"]
local function item(name) for n, i in pairs(root.items) do if n == name then return emu.item(i) end end end
local I_vb, I_vr, I_vram = item("0/m_vram_bank"), item("0/m_vreg_addr"), item("0/m_vram")
local I_mask, I_cause = item("0/m_irq_mask"), item("0/m_irq_cause")

local FR, LAST = {}, 0
for n in string.gmatch(os.getenv("DUMPFRAMES") or "", "%d+") do FR[tonumber(n)] = true; if tonumber(n) > LAST then LAST = tonumber(n) end end
if os.getenv("LAST") then LAST = tonumber(os.getenv("LAST")) end
local DIR = os.getenv("DUMPDIR") or "."
local SCHED = os.getenv("SCHED")
if SCHED == "" then SCHED = nil end

-- the blitter log (the tap is a global: a local one is collected and silently removed)
local blog = assert(_G.io.open(DIR .. "/blits.log", "w"))
BREGS = {}
for i = 0, 15 do BREGS[i] = 0 end
BLIT_TAP = iosp:install_write_tap(0x7fd0, 0x7fdf, "blitlog", function(off, data, mask)
  for b = 0, 1 do
    if ((mask >> (8 * b)) & 0xff) ~= 0 then
      local o = (off & 0xe) + b
      local v = (data >> (8 * b)) & 0xff
      BREGS[o] = v
      if o == 0 and v == 2 then
        local t = {}
        for i = 0, 15 do t[#t + 1] = string.format("%02x", BREGS[i]) end
        blog:write(string.format("%d %d %s\n", scr:frame_number(), math.floor(mach.time:as_double() * 14310600 + 0.5), table.concat(t, " ")))
      end
    end
  end
end)

-- the input schedule (the same function as tb_gunpey.cpp's sched)
local function field(port, name) for n, f in pairs(mach.ioport.ports[port].fields) do if n == name then return f end end end
local F = {
  ["Coin 1"] = field(":SYSTEM", "Coin 1"), ["1 Player Start"] = field(":SYSTEM", "1 Player Start"),
  ["P1 Up"] = field(":P1", "P1 Up"), ["P1 Down"] = field(":P1", "P1 Down"), ["P1 Left"] = field(":P1", "P1 Left"),
  ["P1 Right"] = field(":P1", "P1 Right"), ["P1 Button 1"] = field(":P1", "P1 Button 1"),
}
local function hash(f, k) local x = (f * 2654435761 + k * 40503) & 0xffffffff; x = x ~ (x >> 13); x = (x * 1274126177) & 0xffffffff; return x ~ (x >> 16) end
local function sched(f)
  local p = {}
  p["Coin 1"] = (f >= 600 and f < 606)
  p["1 Player Start"] = (f >= 700 and f < 706)
  if SCHED == "play" and f >= 800 and (f % 8) < 4 then
    local names = {"P1 Up", "P1 Down", "P1 Left", "P1 Right", "P1 Button 1"}
    for k, n in ipairs(names) do p[n] = (hash(f // 8, k) % 4) == 0 end
  end
  return p
end

local function le16(v) return string.char(v & 0xff, (v >> 8) & 0xff) end
local function dump(f)
  local fh = assert(_G.io.open(string.format("%s/state_%d.bin", DIR, f), "wb"))
  fh:write(le16(I_vb:read(0)), le16(I_vr:read(0)), string.char(I_mask:read(0), I_cause:read(0)), string.rep("\0", 10))
  local t = {}
  for a = 0, 0xfffe, 2 do t[#t + 1] = le16(prg:read_u16(a)) end
  fh:write(table.concat(t))
  for o = 0, 0x3fffff, 0x10000 do fh:write(I_vram:read_block(o, 0x10000)) end
  fh:close()
  scr:snapshot(string.format("%s/snap_%d.png", DIR, f))
end

emu.register_frame_done(function()
  local f = scr:frame_number()
  local p = sched(f)
  for n, fld in pairs(F) do fld:set_value(p[n] and 1 or 0) end
  if FR[f] then dump(f) end
  if f >= LAST then blog:close(); mach:exit() end
end)
