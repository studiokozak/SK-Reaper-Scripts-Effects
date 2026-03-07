--[[---------------------------------------------------------------------------
  SK Drums Generator

  Author   : Studio Kozak
  Version  : 1.0.1
  Requires : ReaImGui extension (https://github.com/cfillion/reaimgui)


  ARCHITECTURE
  ------------
  1. DRUM MAP         — Instrument definitions (id, name, MIDI note, color)
  2. MIDI MAPPING     — Dynamic note assignment with persistence
  3. VELOCITY LAYERS  — 6-level dynamics system (0=off … 5=fortissimo)
  4. GRID             — Sequencer state: grid[instrument][step] = layer (0..5)
  5. RANDOMIZER       — Music-aware pattern generator
  6. FACTORY PRESETS  — Hard-coded style patterns (20 styles)
  7. USER PRESETS     — Save / Load / Delete via ExtState + clipboard export
  8. MIDI WRITER      — Converts grid to REAPER MIDI items
  9. UI LOOP          — ReaImGui render loop
-----------------------------------------------------------------------------]]

local reaper = reaper

-- Guard: abort if ReaImGui is not installed
if not reaper.ImGui_CreateContext then
  reaper.MB("ReaImGui is required. Please install it via ReaPack.", "Missing dependency", 0)
  return
end

-------------------------------------------------------------------------------
-- 1. DRUM MAP
-------------------------------------------------------------------------------

local DRUM_MAP = {
  { id = "kick",         name = "KICK",  note = 36, color = 0xFF4444FF },
  { id = "snare",        name = "SNARE", note = 37, color = 0x44FF44FF },
  { id = "hihat_closed", name = "H.HAT", note = 38, color = 0x4444FFFF },
  { id = "hihat_open",   name = "OPEN",  note = 39, color = 0xFFFF44FF },
  { id = "clap",         name = "CLAP",  note = 47, color = 0xFF8844FF },
  { id = "rimshot",      name = "RIM",   note = 51, color = 0x88FF44FF },
  { id = "tom_high",     name = "T.HI",  note = 43, color = 0x44FFFFFF },
  { id = "tom_low",      name = "T.LO",  note = 41, color = 0xAA44FFFF },
}

local DEFAULT_NOTES = { 36, 37, 38, 39, 47, 51, 43, 41 }

-------------------------------------------------------------------------------
-- 2. MIDI MAPPING  —  Persistence via REAPER ExtState
-------------------------------------------------------------------------------

local EXT_SECTION = "Studio Kozak Drums Generator"

local function save_mapping()
  for _, inst in ipairs(DRUM_MAP) do
    reaper.SetExtState(EXT_SECTION, "note_" .. inst.id, tostring(inst.note), true)
  end
end

local function load_mapping()
  for i, inst in ipairs(DRUM_MAP) do
    local raw = reaper.GetExtState(EXT_SECTION, "note_" .. inst.id)
    local n   = tonumber(raw)
    if n and n >= 0 and n <= 127 then DRUM_MAP[i].note = n end
  end
end

local function reset_mapping()
  for i in ipairs(DRUM_MAP) do DRUM_MAP[i].note = DEFAULT_NOTES[i] end
  save_mapping()
end

load_mapping()

-------------------------------------------------------------------------------
-- 3. VELOCITY LAYERS
--
--  Layer  Name       Velocity range   Typical use
--  -----  ---------  ---------------  ---------------------------
--    0    OFF        —                Step is silent
--    1    GHOST      20 – 40          Ghost notes, brush sweeps
--    2    SOFT       50 – 70          Light filler hits
--    3    NORMAL     80 – 100         Standard playing (default)
--    4    ACCENT     105 – 115        Expressive accents
--    5    FORTISSIMO 118 – 127        Downbeats, crash hits
-------------------------------------------------------------------------------

local VEL_LAYERS = {
  [0] = { name = "OFF",   min = 0,   max = 0   },
  [1] = { name = "GHOST", min = 20,  max = 40  },
  [2] = { name = "SOFT",  min = 50,  max = 70  },
  [3] = { name = "NORM",  min = 80,  max = 100 },
  [4] = { name = "ACCT",  min = 105, max = 115 },
  [5] = { name = "FFFF",  min = 118, max = 127 },
}

local VEL_COLORS = {
  [0] = nil,
  [1] = 0x444488FF,
  [2] = 0x4488AAFF,
  [3] = nil,
  [4] = 0xFF8800FF,
  [5] = 0xFF2222FF,
}

local function to_layer(v)
  if v == true  then return 3 end
  if v == false then return 0 end
  if type(v) == "number" then return math.max(0, math.min(5, math.floor(v))) end
  return 0
end

local function vel_from_layer(layer, h_v)
  local L = VEL_LAYERS[layer]
  if not L or L.min == 0 then return 0 end
  return math.max(1, math.min(127,
    math.random(L.min, L.max) + math.random(-h_v, h_v)))
end

-------------------------------------------------------------------------------
-- 4. GRID
-------------------------------------------------------------------------------

local grid = {}

local function init_grid(total_steps, clear_all)
  if clear_all then grid = {} end
  for i = 1, #DRUM_MAP do
    if not grid[i] then grid[i] = {} end
    for s = 1, total_steps do
      if clear_all or grid[i][s] == nil then grid[i][s] = 0 end
    end
  end
end

local function set(inst, step, layer)
  grid[inst][step] = to_layer(layer == nil and true or layer)
end

-------------------------------------------------------------------------------
-- 5. INTELLIGENT RANDOMIZER
-------------------------------------------------------------------------------

local function randomize_intelligent(page_start, page_end)
  math.randomseed(os.time() + reaper.time_precise() * 100000)
  for p = page_start, page_end do
    for s = 1, 16 do
      local step = (p * 16) + s
      for i = 1, #DRUM_MAP do grid[i][step] = 0 end
    end

    -- Kick
    local kick_density   = math.random(2, 5)
    local kick_positions = {}
    if math.random() > 0.1 then table.insert(kick_positions, 1) end
    local possible_kicks = { 3, 5, 7, 9, 10, 11, 13, 14, 15 }
    local iter = 0
    while #kick_positions < kick_density and iter < 100 do
      iter = iter + 1
      local pos    = possible_kicks[math.random(#possible_kicks)]
      local exists = false
      for _, v in ipairs(kick_positions) do if v == pos then exists = true break end end
      if not exists then table.insert(kick_positions, pos) end
    end
    for _, pos in ipairs(kick_positions) do
      grid[1][(p*16)+pos] = (pos == 1) and 5 or (math.random() > 0.4 and 4 or 3)
    end

    -- Snare
    if math.random() > 0.05 then
      grid[2][(p*16)+5]  = 4
      grid[2][(p*16)+13] = 4
    end
    if math.random() > 0.8 then
      local gp = { 3, 7, 11, 15 }
      for _ = 1, math.random(1, 2) do
        grid[2][(p*16) + gp[math.random(#gp)]] = 1
      end
    end

    -- Hi-hat
    local hat_mode = math.random(1, 4)
    if hat_mode == 1 then
      for s = 1, 16, 2 do
        if math.random() > 0.1 then
          grid[3][(p*16)+s] = (s%4==1) and 3 or 2
        end
      end
    elseif hat_mode == 2 then
      for s = 1, 16 do
        if math.random() > 0.2 then
          grid[3][(p*16)+s] = (s%4==1) and 4 or (s%2==0) and 1 or 2
        end
      end
    elseif hat_mode == 3 then
      for s = 1, 16, 4 do grid[3][(p*16)+s] = 3 end
    else
      for s = 1, 16 do
        if s%2==1 or math.random()>0.6 then
          grid[3][(p*16)+s] = math.random()>0.7 and 4 or 2
        end
      end
    end

    -- Open hat
    if math.random() > 0.5 then
      local candidates = { 4, 8, 12, 16 }
      local placed = {}
      for _ = 1, math.random(1, 3) do
        local pos    = candidates[math.random(#candidates)]
        local exists = false
        for _, v in ipairs(placed) do if v == pos then exists = true break end end
        if not exists then
          table.insert(placed, pos)
          grid[4][(p*16)+pos] = 3
          grid[3][(p*16)+pos] = 0
        end
      end
    end

    -- Clap / Rimshot / Toms
    if math.random() > 0.7 then
      grid[5][(p*16)+5]  = 4
      grid[5][(p*16)+13] = 4
    end
    if math.random() > 0.6 then
      for _ = 1, math.random(1, 4) do
        local pos = math.random(1, 16)
        if pos ~= 5 and pos ~= 13 then grid[6][(p*16)+pos] = 2 end
      end
    end
    if math.random() > 0.95 then grid[7][(p*16)+math.random(1,16)] = 4 end
    if math.random() > 0.97 then grid[8][(p*16)+math.random(1,16)] = 4 end
  end
end

-------------------------------------------------------------------------------
-- 6. FACTORY PRESETS
-------------------------------------------------------------------------------

local FACTORY_PRESETS = {
  { name = "--- EMPTY ---",
    func = function(gs) init_grid(gs, true) end },
  { name = "Hip-Hop — Dilla Soul",
    func = function(gs) init_grid(gs,true) for s=1,gs,16 do set(1,s,5) set(1,s+10,4) set(2,s+4,4) set(2,s+12,4) set(3,s,3) set(3,s+2,2) set(3,s+4,3) set(3,s+6,2) set(3,s+9,1) set(3,s+11,2) set(3,s+13,2) set(3,s+15,1) end end },
  { name = "Trap — Dark Drill",
    func = function(gs) init_grid(gs,true) for s=1,gs,16 do set(1,s,5) set(1,s+10,4) set(2,s+8,4) for h=1,16,3 do set(3,s+h-1,2) end set(3,s+11,3) set(3,s+12,2) end end },
  { name = "Rock — Ghost Notes",
    func = function(gs) init_grid(gs,true) for s=1,gs,16 do set(1,s,5) set(1,s+6,4) set(1,s+9,3) set(2,s+4,5) set(2,s+12,5) set(2,s+7,1) set(2,s+10,1) for h=1,16,2 do set(3,s+h-1,3) end end end },
  { name = "Trip-Hop — Bristol Groove",
    func = function(gs) init_grid(gs,true) for s=1,gs,16 do set(1,s,5) set(1,s+2,3) set(1,s+11,4) set(2,s+5,4) set(2,s+13,4) set(4,s+7,3) set(4,s+15,3) end end },
  { name = "Electro — Industrial",
    func = function(gs) init_grid(gs,true) for s=1,gs,4 do set(1,s,5) end for s=1,gs,16 do set(6,s+3,4) set(6,s+7,4) set(6,s+11,4) set(6,s+15,5) set(5,s+4,4) set(5,s+12,4) end end },
  { name = "Afrobeat — Lagos",
    func = function(gs) init_grid(gs,true) for s=1,gs,16 do set(1,s,5) set(1,s+6,4) set(1,s+10,3) set(6,s+2,3) set(6,s+5,2) set(6,s+8,3) set(6,s+13,2) set(3,s,3) set(3,s+4,3) set(3,s+8,3) set(3,s+12,3) end end },
  { name = "Phonk — Drift",
    func = function(gs) init_grid(gs,true) for s=1,gs,16 do set(1,s,5) set(1,s+6,4) set(1,s+8,4) set(1,s+14,3) set(5,s+4,4) set(5,s+12,4) for h=1,16 do set(3,s+h-1,2) end end end },
  { name = "Funk — Linear Break",
    func = function(gs) init_grid(gs,true) for s=1,gs,16 do set(1,s,5) set(2,s+3,2) set(3,s+4,3) set(1,s+6,4) set(2,s+9,1) set(3,s+11,2) set(1,s+12,3) set(2,s+14,4) end end },
  { name = "UK Garage — 2-Step",
    func = function(gs) init_grid(gs,true) for s=1,gs,16 do set(1,s,5) set(1,s+10,4) set(2,s+4,4) set(2,s+12,4) set(4,s+2,3) set(4,s+6,3) set(4,s+11,3) set(4,s+14,3) end end },
  { name = "Drum & Bass — Amen Style",
    func = function(gs) init_grid(gs,true) for s=1,gs,16 do set(1,s,5) set(1,s+10,4) set(2,s+4,5) set(2,s+12,5) set(2,s+15,3) for h=1,16,2 do set(3,s+h-1,3) end set(3,s+10,2) end end },
  { name = "Jazz — Ride Swing",
    func = function(gs) init_grid(gs,true) for s=1,gs,16 do set(3,s,3) set(3,s+2,4) set(3,s+4,3) set(3,s+6,4) set(3,s+8,3) set(3,s+10,4) set(3,s+12,3) set(3,s+14,4) set(2,s+2,1) set(2,s+4,2) set(2,s+6,1) set(2,s+9,1) set(2,s+12,2) set(2,s+14,1) set(1,s,4) set(1,s+6,2) set(1,s+14,2) set(4,s+4,3) set(4,s+12,3) end end },
  { name = "Jazz — Brushes Ballad",
    func = function(gs) init_grid(gs,true) for s=1,gs,16 do for h=1,16 do if h%3~=0 then set(2,s+h-1,1) end end set(2,s,2) set(2,s+4,2) set(2,s+8,2) set(2,s+12,2) set(3,s,3) set(3,s+8,3) set(1,s,3) end end },
  { name = "Jazz — Latin Swing",
    func = function(gs) init_grid(gs,true) for s=1,gs,16 do set(6,s,5) set(6,s+3,4) set(6,s+6,4) set(6,s+8,5) set(6,s+12,4) for h=1,16,2 do set(3,s+h-1,3) end set(3,s+2,4) set(3,s+10,4) set(2,s+5,1) set(2,s+9,2) set(2,s+13,1) set(1,s,5) set(1,s+8,4) end end },
  { name = "Bossa Nova — Classic",
    func = function(gs) init_grid(gs,true) for s=1,gs,16 do set(6,s+1,5) set(6,s+4,5) set(6,s+7,4) set(6,s+9,5) set(6,s+12,4) set(4,s,2) set(4,s+4,2) set(4,s+8,2) set(4,s+12,2) set(2,s+4,2) set(2,s+12,2) set(1,s,3) set(1,s+8,2) end end },
  { name = "Bossa Nova — Batucada",
    func = function(gs) init_grid(gs,true) for s=1,gs,16 do set(6,s,4) set(6,s+3,3) set(6,s+6,4) set(6,s+8,5) set(6,s+11,3) set(6,s+13,4) for h=1,16 do set(3,s+h-1,2) end set(3,s,3) set(3,s+4,3) set(3,s+8,3) set(3,s+12,3) set(7,s+2,3) set(7,s+6,4) set(7,s+10,3) set(7,s+14,4) set(2,s+4,3) set(2,s+9,2) set(2,s+12,3) set(1,s,5) set(1,s+6,3) set(1,s+8,4) end end },
  { name = "Samba — Traditional",
    func = function(gs) init_grid(gs,true) for s=1,gs,16 do set(6,s,4) set(6,s+3,5) set(6,s+6,4) set(6,s+9,5) set(6,s+11,3) set(6,s+14,4) set(1,s,2) set(1,s+8,5) set(4,s,2) set(4,s+4,2) set(4,s+8,2) set(4,s+12,2) set(2,s,3) set(2,s+2,2) set(2,s+4,4) set(2,s+6,2) set(2,s+8,3) set(2,s+10,1) set(2,s+12,4) set(2,s+14,2) set(7,s+1,3) set(7,s+5,2) set(7,s+9,3) set(7,s+13,2) end end },
  { name = "Samba — Pagode Groove",
    func = function(gs) init_grid(gs,true) for s=1,gs,16 do set(1,s,4) set(1,s+3,3) set(1,s+8,5) set(1,s+10,3) set(1,s+13,2) set(2,s+1,1) set(2,s+3,1) set(2,s+4,4) set(2,s+7,1) set(2,s+9,1) set(2,s+11,1) set(2,s+12,4) set(2,s+14,2) for h=1,16,2 do set(3,s+h-1,2) end set(3,s,3) set(3,s+8,3) set(6,s+2,4) set(6,s+6,5) set(6,s+10,4) set(6,s+14,5) set(8,s+4,3) set(8,s+12,3) end end },
  { name = "Afro-Cuban — Son Clave",
    func = function(gs) init_grid(gs,true) for s=1,gs,16 do set(6,s,5) set(6,s+3,5) set(6,s+6,5) set(6,s+8,5) set(6,s+12,5) set(1,s+2,3) set(1,s+7,4) set(1,s+10,3) set(1,s+15,4) set(2,s+4,3) set(2,s+8,2) set(2,s+12,4) for h=1,16,2 do set(3,s+h-1,3) end set(4,s+7,4) set(4,s+15,4) set(5,s+3,3) set(5,s+11,3) end end },
  { name = "Afro-Cuban — Rumba",
    func = function(gs) init_grid(gs,true) for s=1,gs,16 do set(6,s,5) set(6,s+3,5) set(6,s+7,5) set(6,s+8,5) set(6,s+12,5) set(1,s,4) set(1,s+6,3) set(1,s+11,4) set(2,s+2,2) set(2,s+5,3) set(2,s+9,2) set(2,s+13,3) set(7,s+1,3) set(7,s+4,4) set(7,s+8,3) set(7,s+12,4) set(8,s+3,3) set(8,s+7,4) set(8,s+11,3) set(8,s+15,4) set(4,s+4,2) set(4,s+12,2) end end },
}

-------------------------------------------------------------------------------
-- 7. USER PRESET SYSTEM
--
--  Storage layout in ExtState (section = EXT_SECTION):
--    "user_preset_count"        → total number of saved user presets
--    "user_preset_name_N"       → display name of preset N
--    "user_preset_bars_N"       → number of bars
--    "user_preset_data_N"       → grid serialized as a comma-separated string
--                                 format: "layer,layer,layer,..."
--                                 instruments are stored sequentially:
--                                 inst1_step1, inst1_step2 ... inst8_stepN
--
--  The user_presets table (in memory) mirrors ExtState:
--    user_presets[i] = { name = string, bars = number, func = function }
--
--  Clipboard export format:
--    Ready-to-paste Lua code block compatible with the FACTORY_PRESETS table.
--    The user can copy it into the -- ====== USER PRESETS section below.
-------------------------------------------------------------------------------

-- In-memory list of user presets (populated by load_user_presets)
local user_presets = {}

-- Serialize the current grid into a flat comma-separated string.
-- Only serializes steps 1..bars*16 to keep the string compact.
local function serialize_grid(bars)
  local parts = {}
  local total = bars * 16
  for i = 1, #DRUM_MAP do
    for s = 1, total do
      parts[#parts + 1] = tostring(grid[i][s] or 0)
    end
  end
  return table.concat(parts, ",")
end

-- Deserialize a grid string back into the global grid table.
-- bars must match the value stored alongside the data string.
local function deserialize_grid(data, bars)
  local total  = bars * 16
  local values = {}
  for v in data:gmatch("[^,]+") do values[#values + 1] = tonumber(v) or 0 end
  local idx = 1
  for i = 1, #DRUM_MAP do
    grid[i] = {}
    for s = 1, total do
      grid[i][s] = values[idx] or 0
      idx = idx + 1
    end
  end
end

-- Persist all in-memory user presets to ExtState.
local function save_user_presets()
  reaper.SetExtState(EXT_SECTION, "user_preset_count",
    tostring(#user_presets), true)
  for i, p in ipairs(user_presets) do
    reaper.SetExtState(EXT_SECTION, "user_preset_name_" .. i, p.name,  true)
    reaper.SetExtState(EXT_SECTION, "user_preset_bars_" .. i,
      tostring(p.bars), true)
    reaper.SetExtState(EXT_SECTION, "user_preset_data_" .. i, p.data,  true)
  end
  -- Wipe any stale slots beyond the current count
  for i = #user_presets + 1, #user_presets + 10 do
    reaper.DeleteExtState(EXT_SECTION, "user_preset_name_" .. i, true)
    reaper.DeleteExtState(EXT_SECTION, "user_preset_bars_" .. i, true)
    reaper.DeleteExtState(EXT_SECTION, "user_preset_data_" .. i, true)
  end
end

-- Load user presets from ExtState into the in-memory user_presets table.
-- Rebuilds the .func closure from the stored data string.
local function load_user_presets()
  user_presets = {}
  local count = tonumber(
    reaper.GetExtState(EXT_SECTION, "user_preset_count")) or 0
  for i = 1, count do
    local name = reaper.GetExtState(EXT_SECTION, "user_preset_name_" .. i)
    local bars = tonumber(
      reaper.GetExtState(EXT_SECTION, "user_preset_bars_" .. i)) or 1
    local data = reaper.GetExtState(EXT_SECTION, "user_preset_data_" .. i)
    if name ~= "" and data ~= "" then
      -- Capture data and bars in the closure so the func is self-contained
      local captured_data = data
      local captured_bars = bars
      user_presets[#user_presets + 1] = {
        name = name,
        bars = captured_bars,
        data = captured_data,
        func = function(_gs)
          init_grid(captured_bars * 16, true)
          deserialize_grid(captured_data, captured_bars)
        end,
      }
    end
  end
end

-- Save the current grid as a new user preset with the given name.
-- Returns true on success, false if the name is empty or duplicate.
local function save_current_as_user_preset(name, bars)
  name = name:match("^%s*(.-)%s*$")  -- trim whitespace
  if name == "" then return false, "Name cannot be empty." end
  for _, p in ipairs(user_presets) do
    if p.name == name then return false, "A preset named '" .. name .. "' already exists." end
  end
  local data = serialize_grid(bars)
  local captured_data = data
  local captured_bars = bars
  user_presets[#user_presets + 1] = {
    name = name,
    bars = bars,
    data = data,
    func = function(_gs)
      init_grid(captured_bars * 16, true)
      deserialize_grid(captured_data, captured_bars)
    end,
  }
  save_user_presets()
  return true, "Preset '" .. name .. "' saved."
end

-- Delete a user preset by index and persist the updated list.
local function delete_user_preset(idx)
  if idx < 1 or idx > #user_presets then return end
  table.remove(user_presets, idx)
  save_user_presets()
end

-- Export the current grid as a ready-to-paste Lua preset block.
-- The output is written to the system clipboard.
-- Format matches the FACTORY_PRESETS table so it can be pasted verbatim.
local function export_to_clipboard(preset_name, bars)
  preset_name = preset_name:match("^%s*(.-)%s*$")
  if preset_name == "" then preset_name = "My Pattern" end

  -- Build the set() call list for every active step
  local lines = {}
  local total = bars * 16
  for i = 1, #DRUM_MAP do
    for s = 1, total do
      local layer = to_layer(grid[i][s])
      if layer > 0 then
        lines[#lines + 1] = string.format("    set(%d, %d, %d)", i, s, layer)
      end
    end
  end

  -- Wrap in a preset table entry block with header comment
  local block = {}
  block[#block+1] = "  -- ======================================================"
  block[#block+1] = "  -- USER PRESET : " .. preset_name
  block[#block+1] = "  -- Bars   : " .. bars
  block[#block+1] = "  -- Saved  : " .. os.date("%Y-%m-%d %H:%M")
  block[#block+1] = "  -- ======================================================"
  block[#block+1] = "  { name = \"" .. preset_name .. "\","
  block[#block+1] = "    func = function(gs)"
  block[#block+1] = "      init_grid(gs, true)"
  if #lines > 0 then
    for _, l in ipairs(lines) do block[#block+1] = l end
  else
    block[#block+1] = "      -- (empty pattern)"
  end
  block[#block+1] = "    end },"

  local result = table.concat(block, "\n")
  reaper.CF_SetClipboard(result)
  return result
end

-- Load user presets at startup
load_user_presets()

-------------------------------------------------------------------------------
-- 8. MIDI WRITER
-------------------------------------------------------------------------------

local function write_to_reaper(state)
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    reaper.MB("Please select a track first.", "No track selected", 0)
    return
  end
  for i = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
    local item = reaper.GetTrackMediaItem(track, i)
    if reaper.IsMediaItemSelected(item) then
      reaper.DeleteTrackMediaItem(track, item)
    end
  end
  local start_pos = reaper.GetCursorPosition()
  local qn_offset = reaper.TimeMap2_timeToQN(0, start_pos)
  local end_time  = reaper.TimeMap2_QNToTime(0, qn_offset + (state.bars * 4))
  local item      = reaper.CreateNewMIDIItemInProj(track, start_pos, end_time, false)
  reaper.SetMediaItemSelected(item, true)
  local take = reaper.GetActiveTake(item)
  reaper.MIDI_DisableSort(take)

  for i = 1, #DRUM_MAP do
    local inst = DRUM_MAP[i]
    for s = 1, state.bars * 16 do
      local layer = to_layer(grid[i][s])

      -- M4 auto-fill override
      if state.use_fill and state.bars >= 4 and s >= 57 and s <= 64 then
        layer = 0
        if inst.id == "snare"   or inst.id == "tom_high"
        or inst.id == "tom_low" or inst.id == "rimshot" then
          if math.random() > 0.65 then
            layer = math.min(5, 2 + math.floor((s - 56) / 2))
          end
        end
        if s == 64 then
          if     inst.id == "kick"       then layer = 5
          elseif inst.id == "snare"
              or inst.id == "hihat_open" then
            layer = math.random() > 0.5 and 5 or 4
          end
        end
      end

      if layer > 0 then
        local pos_qn = (s - 1) * 0.25
        if s % 2 == 0 then
          pos_qn = pos_qn + ((state.swing / 100) * 0.083)
        end
        local ppq = math.floor(pos_qn * 960) + math.random(-state.h_t, state.h_t)
        local vel = vel_from_layer(layer, state.h_v)
        if inst.id == "hihat_closed" and layer <= 2 then
          vel = math.max(1, vel - 10)
        end
        reaper.MIDI_InsertNote(take, false, false, ppq, ppq + 120, 0,
          inst.note, vel, true)
      end
    end
  end
  reaper.MIDI_Sort(take)
  reaper.UpdateArrange()
end

-------------------------------------------------------------------------------
-- 9. UI LOOP
-------------------------------------------------------------------------------

local NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
local function note_to_name(n)
  if n < 0 or n > 127 then return "?" end
  return NOTE_NAMES[(n % 12) + 1] .. tostring(math.floor(n / 12) - 2)
end

local VEL_LEGEND = "1=GHOST   2=SOFT   3=NORM   4=ACCENT   5=FFFF"

local ctx = reaper.ImGui_CreateContext("Studio Kozak Drums Generator")

local state = {
  bars            = 1,
  h_t             = 8,
  h_v             = 15,
  swing           = 0,
  current_page    = 0,
  use_fill        = false,
  -- Preset selection: positive index = factory, negative = user (-(idx))
  selected_factory = 1,
  selected_user    = 0,   -- 0 = none selected
  vel_edit_mode   = false,
}

-- User preset panel UI state
local ui_save_name     = ""            -- text buffer for the Save Name field
local ui_save_msg      = ""            -- feedback message after save/delete
local ui_save_msg_time = 0             -- reaper.time_precise() timestamp for auto-clear
local ui_clipboard_msg = ""            -- feedback after clipboard export
local ui_clipboard_time = 0
local ui_export_name   = ""            -- name field for clipboard export

local note_inputs = {}
for i, inst in ipairs(DRUM_MAP) do note_inputs[i] = inst.note end

init_grid(16, true)

-- Helper: display a timed feedback message (auto-clears after 3 seconds)
local function feedback(msg, is_clipboard)
  if is_clipboard then
    ui_clipboard_msg  = msg
    ui_clipboard_time = reaper.time_precise()
  else
    ui_save_msg       = msg
    ui_save_msg_time  = reaper.time_precise()
  end
end

-- Flag to sync note_inputs on the very first frame only
local first_frame = true

local function loop()
  -- On the first frame, re-sync note_inputs from DRUM_MAP (which may have been
  -- updated by load_mapping() before note_inputs was initialised). This prevents
  -- ImGui_InputInt from seeing a spurious delta and firing 'changed = true'.
  if first_frame then
    for i, inst in ipairs(DRUM_MAP) do note_inputs[i] = inst.note end
    first_frame = false
  end

  -- Clear timed messages after 3 seconds
  if ui_save_msg ~= "" and reaper.time_precise() - ui_save_msg_time > 3 then
    ui_save_msg = ""
  end
  if ui_clipboard_msg ~= "" and reaper.time_precise() - ui_clipboard_time > 3 then
    ui_clipboard_msg = ""
  end

  reaper.ImGui_SetNextWindowSize(ctx, 680, 900, reaper.ImGui_Cond_FirstUseEver())
  local visible, open = reaper.ImGui_Begin(ctx,
    "STUDIO KOZAK DRUMS GENERATOR",
    true, reaper.ImGui_WindowFlags_AlwaysAutoResize())

  if visible then

    -- -------------------------------------------------------------------------
    -- A. TOP CONTROLS
    -- -------------------------------------------------------------------------
    reaper.ImGui_SetNextItemWidth(ctx, 50)
    local chg, nb = reaper.ImGui_InputInt(ctx, "Bars", state.bars)
    if chg and nb > 0 then
      state.bars = nb
      init_grid(state.bars * 16, false)
    end

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "DUPLICATE") then
      local old  = state.bars
      state.bars = old * 2
      init_grid(state.bars * 16, false)
      for i = 1, #DRUM_MAP do
        for s = 1, old * 16 do
          grid[i][s + (old * 16)] = grid[i][s]
        end
      end
    end

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "RESET") then init_grid(state.bars * 16, true) end

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "RANDOM") then
      randomize_intelligent(state.current_page, state.current_page)
    end

    reaper.ImGui_Separator(ctx)

    -- -------------------------------------------------------------------------
    -- B. PRESET SELECTOR  (factory presets)
    -- -------------------------------------------------------------------------
    reaper.ImGui_Text(ctx, "Factory presets")
    reaper.ImGui_SetNextItemWidth(ctx, 300)
    -- selected_factory may be 0 when a user preset is active; guard against nil
    local factory_label = state.selected_factory > 0
      and FACTORY_PRESETS[state.selected_factory].name
      or  "-- user preset active --"
    if reaper.ImGui_BeginCombo(ctx, "##factory", factory_label) then
      for i, p in ipairs(FACTORY_PRESETS) do
        if reaper.ImGui_Selectable(ctx, p.name, i == state.selected_factory) then
          state.selected_factory = i
          state.selected_user    = 0
          p.func(state.bars * 16)
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end

    reaper.ImGui_Separator(ctx)

    -- -------------------------------------------------------------------------
    -- C. USER PRESET PANEL  (collapsible)
    -- -------------------------------------------------------------------------

    local user_header_label = #user_presets == 0
      and "USER PRESETS  (none saved)"
      or  "USER PRESETS  (" .. #user_presets .. " saved)"

    if reaper.ImGui_CollapsingHeader(ctx, user_header_label) then

      reaper.ImGui_Spacing(ctx)

      -- C1. Load / Delete --
      if #user_presets == 0 then
        reaper.ImGui_TextDisabled(ctx, "  No user presets saved yet.")
      else
        reaper.ImGui_SetNextItemWidth(ctx, 300)
        local user_label = state.selected_user > 0
          and user_presets[state.selected_user].name
          or  "-- select a user preset --"
        if reaper.ImGui_BeginCombo(ctx, "##user", user_label) then
          for i, p in ipairs(user_presets) do
            local is_sel = (i == state.selected_user)
            if reaper.ImGui_Selectable(ctx, p.name, is_sel) then
              state.selected_user    = i
              state.selected_factory = 0
            end
          end
          reaper.ImGui_EndCombo(ctx)
        end

        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "LOAD") then
          if state.selected_user > 0 then
            local p = user_presets[state.selected_user]
            state.bars = p.bars
            init_grid(p.bars * 16, true)
            p.func(p.bars * 16)
            feedback("Loaded: " .. p.name)
          end
        end

        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x882222FF)
        if reaper.ImGui_Button(ctx, "DELETE") then
          if state.selected_user > 0 then
            local name = user_presets[state.selected_user].name
            delete_user_preset(state.selected_user)
            state.selected_user = 0
            feedback("Deleted: " .. name)
          end
        end
        reaper.ImGui_PopStyleColor(ctx)
      end

      if ui_save_msg ~= "" then
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_TextColored(ctx, 0x88FF88FF, ui_save_msg)
      end

      reaper.ImGui_Separator(ctx)

      -- C2. Save current pattern --
      reaper.ImGui_Text(ctx, "Save current pattern as user preset :")
      reaper.ImGui_SetNextItemWidth(ctx, 220)
      _, ui_save_name = reaper.ImGui_InputText(ctx, "##savename", ui_save_name)
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x226622FF)
      if reaper.ImGui_Button(ctx, "SAVE PRESET") then
        local ok, msg = save_current_as_user_preset(ui_save_name, state.bars)
        feedback(msg)
        if ok then ui_save_name = "" end
      end
      reaper.ImGui_PopStyleColor(ctx)

      reaper.ImGui_Separator(ctx)

      -- C3. Export to clipboard --
      reaper.ImGui_Text(ctx, "Export to clipboard (paste into script source) :")
      reaper.ImGui_SetNextItemWidth(ctx, 220)
      _, ui_export_name = reaper.ImGui_InputText(ctx, "##exportname", ui_export_name)
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x225566FF)
      if reaper.ImGui_Button(ctx, "COPY LUA CODE") then
        export_to_clipboard(ui_export_name, state.bars)
        feedback("Lua code copied to clipboard!", true)
      end
      reaper.ImGui_PopStyleColor(ctx)

      if ui_clipboard_msg ~= "" then
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_TextColored(ctx, 0xFFDD44FF, ui_clipboard_msg)
      end

      reaper.ImGui_TextDisabled(ctx,
        "  Paste the copied code inside FACTORY_PRESETS in the script source.")

      reaper.ImGui_Spacing(ctx)

    end  -- end CollapsingHeader USER PRESETS

    reaper.ImGui_Separator(ctx)

    -- -------------------------------------------------------------------------
    -- D. MIDI MAPPING PANEL  (collapsible)
    -- -------------------------------------------------------------------------

    local mapping_summary = ""
    local abbr = { "K", "S", "H", "O", "C", "R", "↑", "↓" }
    for i, inst in ipairs(DRUM_MAP) do
      mapping_summary = mapping_summary .. abbr[i] .. ":" .. note_to_name(inst.note)
      if i < #DRUM_MAP then mapping_summary = mapping_summary .. "  " end
    end

    if reaper.ImGui_CollapsingHeader(ctx,
        "MIDI MAPPING##midi_mapping") then
      -- Display the live note summary on the same line as the header
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_TextDisabled(ctx, " —  " .. mapping_summary)

      reaper.ImGui_Spacing(ctx)

      -- SAVE MAPPING button (green) — persists note assignments to ExtState
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x226622FF)
      if reaper.ImGui_Button(ctx, "SAVE MAPPING") then
        save_mapping()
      end
      reaper.ImGui_PopStyleColor(ctx)
      reaper.ImGui_SameLine(ctx)

      -- RESET MAPPING button (orange) — restores default note assignments
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x884400FF)
      if reaper.ImGui_Button(ctx, "RESET MAPPING") then
        reset_mapping()
        for i, inst in ipairs(DRUM_MAP) do note_inputs[i] = inst.note end
      end
      reaper.ImGui_PopStyleColor(ctx)
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_TextDisabled(ctx, "per-instrument note assignment (0 – 127)")

      reaper.ImGui_Spacing(ctx)

      local cols_per_row = 4
      for i, inst in ipairs(DRUM_MAP) do
        if (i - 1) % cols_per_row ~= 0 then reaper.ImGui_SameLine(ctx) end
        reaper.ImGui_BeginGroup(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        inst.color)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), inst.color)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  inst.color)
        reaper.ImGui_Button(ctx, "##dot" .. i, 10, 10)
        reaper.ImGui_PopStyleColor(ctx, 3)
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_Text(ctx, inst.name)
        reaper.ImGui_SetNextItemWidth(ctx, 65)
        reaper.ImGui_PushID(ctx, 9000 + i)
        local changed, new_val = reaper.ImGui_InputInt(ctx, "##note" .. i, note_inputs[i])
        if changed then
          new_val          = math.max(0, math.min(127, new_val))
          note_inputs[i]   = new_val
          DRUM_MAP[i].note = new_val
          -- Note: save_mapping() is now triggered only via the SAVE MAPPING button
        end
        reaper.ImGui_PopID(ctx)
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_TextDisabled(ctx, note_to_name(note_inputs[i]))
        reaper.ImGui_EndGroup(ctx)
        if (i % cols_per_row ~= 0) and i < #DRUM_MAP then
          reaper.ImGui_SameLine(ctx, 0, 20)
        end
      end

      reaper.ImGui_Spacing(ctx)

    end  -- end CollapsingHeader MIDI MAPPING

    reaper.ImGui_Separator(ctx)

    -- -------------------------------------------------------------------------
    -- E. VELOCITY MODE + AUTO-FILL
    -- -------------------------------------------------------------------------
    local vel_col = state.vel_edit_mode and 0x00FF88FF or 0x555555FF
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), vel_col)
    if reaper.ImGui_Button(ctx,
        state.vel_edit_mode and "VELOCITY MODE  [ON] " or "VELOCITY MODE [OFF]") then
      state.vel_edit_mode = not state.vel_edit_mode
    end
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextDisabled(ctx,
      state.vel_edit_mode
        and VEL_LEGEND
        or "(click = on/off  |  enable to cycle through layers)")

    local can_fill = state.bars >= 4
    if not can_fill then reaper.ImGui_BeginDisabled(ctx) end
    _, state.use_fill = reaper.ImGui_Checkbox(ctx,
      "AUTO-FILL ON BAR 4  (crescendo roll)", state.use_fill)
    if not can_fill then reaper.ImGui_EndDisabled(ctx) end

    reaper.ImGui_Separator(ctx)

    -- -------------------------------------------------------------------------
    -- F. PAGE NAVIGATION
    -- -------------------------------------------------------------------------
    for p = 0, state.bars - 1 do
      if p > 0 and p % 8 ~= 0 then reaper.ImGui_SameLine(ctx) end
      local is_sel = (state.current_page == p)
      if is_sel then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x00FF00FF)
      end
      if reaper.ImGui_Button(ctx, tostring(p + 1), 35, 25) then
        state.current_page = p
      end
      if is_sel then reaper.ImGui_PopStyleColor(ctx) end
    end

    reaper.ImGui_Spacing(ctx)

    -- -------------------------------------------------------------------------
    -- G. STEP SEQUENCER GRID
    -- -------------------------------------------------------------------------
    if reaper.ImGui_BeginTable(ctx, "grid", 17,
        reaper.ImGui_TableFlags_Borders() | reaper.ImGui_TableFlags_RowBg()) then
      reaper.ImGui_TableSetupColumn(ctx, "INST",
        reaper.ImGui_TableColumnFlags_WidthFixed(), 70)
      for s = 1, 16 do
        reaper.ImGui_TableSetupColumn(ctx, "",
          reaper.ImGui_TableColumnFlags_WidthFixed(), 25)
      end

      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableSetColumnIndex(ctx, 0)
      reaper.ImGui_Text(ctx, "BEAT")
      for s = 1, 16 do
        reaper.ImGui_TableSetColumnIndex(ctx, s)
        if s % 4 == 1 then reaper.ImGui_TextColored(ctx, 0x00FF00FF, "|")
        else reaper.ImGui_Text(ctx, ".") end
      end

      for i = 1, #DRUM_MAP do
        reaper.ImGui_TableNextRow(ctx)
        reaper.ImGui_TableSetColumnIndex(ctx, 0)
        reaper.ImGui_Text(ctx, DRUM_MAP[i].name)
        if reaper.ImGui_IsItemHovered(ctx) then
          reaper.ImGui_SetTooltip(ctx,
            "MIDI note : " .. DRUM_MAP[i].note
            .. "  (" .. note_to_name(DRUM_MAP[i].note) .. ")")
        end

        for s = 1, 16 do
          local step  = (state.current_page * 16) + s
          local layer = to_layer(grid[i][step])
          reaper.ImGui_TableSetColumnIndex(ctx, s)
          reaper.ImGui_PushID(ctx, (i * 1000) + step)

          local btn_col
          if layer == 0 then
            btn_col = (s % 4 == 1) and 0x333333FF or 0x222222FF
          elseif layer == 3 then
            btn_col = DRUM_MAP[i].color
          else
            btn_col = VEL_COLORS[layer] or DRUM_MAP[i].color
          end

          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), btn_col)
          local label = (layer > 0) and (tostring(layer) .. "##b") or "##c"
          if reaper.ImGui_Button(ctx, label, 25, 25) then
            if state.vel_edit_mode then
              grid[i][step] = (layer + 1) % 6
            else
              grid[i][step] = (layer == 0) and 3 or 0
            end
          end
          reaper.ImGui_PopStyleColor(ctx)
          reaper.ImGui_PopID(ctx)
        end
      end
      reaper.ImGui_EndTable(ctx)
    end

    -- -------------------------------------------------------------------------
    -- H. VELOCITY LEGEND
    -- -------------------------------------------------------------------------
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_TextDisabled(ctx, "Layers : ")
    reaper.ImGui_SameLine(ctx)
    local legend = {
      { col = 0x4444AAFF, txt = "1-GHOST"  },
      { col = 0x4488AAFF, txt = "2-SOFT"   },
      { col = 0x44FF44FF, txt = "3-NORM"   },
      { col = 0xFF8800FF, txt = "4-ACCENT" },
      { col = 0xFF2222FF, txt = "5-FFFF"   },
    }
    for _, li in ipairs(legend) do
      reaper.ImGui_TextColored(ctx, li.col, li.txt)
      reaper.ImGui_SameLine(ctx)
    end
    reaper.ImGui_NewLine(ctx)

    reaper.ImGui_Separator(ctx)

    -- -------------------------------------------------------------------------
    -- I. GROOVE & HUMANIZATION
    -- -------------------------------------------------------------------------
    reaper.ImGui_Text(ctx, "GROOVE & HUMANIZATION")
    reaper.ImGui_SetNextItemWidth(ctx, 130)
    _, state.swing = reaper.ImGui_SliderInt(ctx, "Swing",   state.swing, 0, 100)
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 130)
    _, state.h_t   = reaper.ImGui_SliderInt(ctx, "Timing",  state.h_t,   0, 100)
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 130)
    _, state.h_v   = reaper.ImGui_SliderInt(ctx, "Var.Vel", state.h_v,   0, 80)

    -- -------------------------------------------------------------------------
    -- J. GENERATE BUTTON
    -- -------------------------------------------------------------------------
    reaper.ImGui_Spacing(ctx)
    if reaper.ImGui_Button(ctx, "  GENERATE & REPLACE  ", -1, 45) then
      write_to_reaper(state)
    end

    reaper.ImGui_End(ctx)
  end

  if open then reaper.defer(loop) end
end

reaper.defer(loop)
