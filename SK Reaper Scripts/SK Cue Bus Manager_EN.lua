-- =============================================================================
--  SK Cue Bus Manager
--  Studio Kozak — https://github.com/StudioKozak
--
--  Integrated headphone monitoring console for REAPER. Creates and manages an
--  independent headphone mix (cue bus) per musician — with per-track volume,
--  pan, mute, stereo VU metering, A/B snapshots and hardware-output assignment —
--  without touching REAPER's native routing.
--
--  Requirement: ReaImGui (install via ReaPack)
-- =============================================================================

if not reaper.ImGui_CreateContext then
  reaper.MB(
    "ReaImGui is not installed.\nPlease install it via ReaPack then restart the script.",
    "SK Cue Bus Manager", 0)
  return
end

-- =============================================================================
--  CONFIGURATION
-- =============================================================================

local CFG = {
  SCRIPT_NAME = "SK Cue Bus Manager",
  VERSION     = "1.5",
  WINDOW_W    = 1100,
  WINDOW_H    = 640,
  SIDEBAR_W   = 200,
  AVAIL_W     = 240,
  STRIP_W     = 80,
  FADER_W     = 46,
  STRIP_PAD   = 4,
  VU_W        = 6,
  VU_GAP      = 2,
  MASTER_H    = 28,
  TOPBAR_H    = 38,

  -- Send mode to cue buses: PRE-FADER / POST-FX
  -- The musician hears the signal after plugins (including VSTi),
  -- but the REAPER console fader does not affect the headphone mix.
  SEND_MODE = 3,

  -- Color palette available for cue buses
  PALETTE = {
    { label="Red",  r=180, g=60,  b=60  },
    { label="Orange", r=190, g=110, b=40  },
    { label="Yellow",  r=170, g=160, b=40  },
    { label="Green",   r=60,  g=160, b=80  },
    { label="Cyan",   r=40,  g=160, b=170 },
    { label="Blue",   r=60,  g=100, b=190 },
    { label="Purple", r=120, g=60,  b=180 },
    { label="Pink",   r=180, g=80,  b=140 },
    { label="Gray",   r=100, g=100, b=110 },
  },

  -- Studio Kozak house style — amber accent · warm dark background · cream text
  COL = {
    BG          = 0x1E2024FF,  -- main window
    SIDEBAR_BG  = 0x191B1FFF,  -- cue column (darker)
    TOPBAR_BG   = 0x181A1EFF,  -- title bar
    PANEL_BG    = 0x212429FF,  -- inner panels
    STRIP_BG    = 0x2A2D33FF,  -- strip / frame background
    STRIP_MUTED = 0x241F1BFF,  -- muted strip (warm-dark)
    FADER_RAIL  = 0x232529FF,  -- fader rail
    FADER_GRAB  = 0xD9A441FF,  -- fader grab (amber)
    FADER_MUTED = 0x6E5A3AFF,  -- muted fader grab (dim amber)
    MUTE_ON     = 0xC0533FFF,  -- mute active (warm red)
    MUTE_OFF    = 0x30343BFF,  -- mute inactive (neutral button)
    ACCENT      = 0xD9A441FF,  -- Studio Kozak amber
    ACCENT_H    = 0xE6B75AFF,  -- amber hover
    ACCENT_A    = 0xB8863BFF,  -- amber active
    ACCENT2     = 0xC79A3EFF,  -- deep gold (ON / secondary states)
    ACCENT2_H   = 0xDDB055FF,  -- deep gold hover
    ACCENT2_A   = 0xA5822FFF,  -- deep gold active
    INK         = 0x181A1FFF,  -- ink (dark text on amber)
    DANGER      = 0xC0533FFF,  -- warm red
    DANGER_H    = 0xD46A4CFF,  -- warm red hover
    TEXT_DIM    = 0x8C8778FF,  -- dimmed text (olive-grey)
    TEXT_BRIGHT = 0xE9E5DAFF,  -- primary text (cream)
    TEXT_LABEL  = 0xC9C3B4FF,  -- labels (soft cream)
    SEP         = 0x3A3E46FF,  -- separators
    CUE_SEL     = 0x40381FFF,  -- selected cue (amber-brown)
    CUE_HOVER   = 0x2A2D33FF,  -- hovered cue
    STRIP_SEL   = 0x3B404AFF,  -- hovered button (neutral)
    SNAP_B      = 0xD4A020FF,  -- snapshot B (gold)
    TOGGLE_OFF     = 0x30343BFF,  -- toggle inactive
    TOGGLE_OFF_HOV = 0x474D58FF,  -- toggle inactive hover
    VU_BLUE     = 0x4080C0FF,  -- VU meter — standard metering convention
    VU_GREEN    = 0x30C060FF,
    VU_YELLOW   = 0xD4C020FF,
    VU_ORANGE   = 0xE07020FF,
    VU_CLIP     = 0xC02020FF,
    VU_CLIP_IND = 0xFF2020FF,
    VU_BG       = 0x17181BFF,
    ADD_BTN     = 0x2C3A2AFF,  -- add (muted green)
    ADD_HOV     = 0x3D5238FF,
    REM_BTN     = 0x3E2A24FF,  -- remove (muted red)
    REM_HOV     = 0x5C3A2EFF,
  },
}

-- =============================================================================
--  UTILITY FUNCTIONS
-- =============================================================================

local function valid_track(track)
  return track and reaper.ValidatePtr(track, "MediaTrack*")
end

local function track_name(track)
  if not valid_track(track) then return "(invalid)" end
  local _, n = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  return n ~= "" and n or "(unnamed)"
end

local function set_track_name(track, name)
  if not valid_track(track) then return end
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name, true)
end

local function guid_of(track)
  return reaper.GetTrackGUID(track)
end

local function get_ext(track, key)
  if not valid_track(track) then return "" end
  local _, v = reaper.GetSetMediaTrackInfo_String(track, "P_EXT:"..key, "", false)
  return v
end

local function set_ext(track, key, val)
  if not valid_track(track) then return end
  reaper.GetSetMediaTrackInfo_String(track, "P_EXT:"..key, tostring(val), true)
end

local function track_idx(track)
  if not valid_track(track) then return 999999 end
  return reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
end

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function vol_to_db(v)
  if v <= 0 then return "-inf" end
  return string.format("%+.1f", 20 * math.log(v, 10))
end

-- REAPER native color → RGBA ImGui conversion
local function native_to_imgui(native)
  local r, g, b = reaper.ColorFromNative(native)
  return (r << 24) | (g << 16) | (b << 8) | 0xFF
end

-- Lightens an 0xRRGGBBAA color toward white by amt (0..1), for hover/active
-- button variants derived from a track's color.
local function lighten(col, amt)
  local r = (col >> 24) & 0xFF
  local g = (col >> 16) & 0xFF
  local b = (col >> 8)  & 0xFF
  r = math.min(255, math.floor(r + (255 - r) * amt))
  g = math.min(255, math.floor(g + (255 - g) * amt))
  b = math.min(255, math.floor(b + (255 - b) * amt))
  return (r << 24) | (g << 16) | (b << 8) | 0xFF
end

local function rgba(hex) return hex end

local function colored_button(ctx, label, cn, ch, ca, w, h, tcol)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        cn)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), ch)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  ca)
  local npush = 3
  if tcol then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), tcol)
    npush = 4
  end
  local clicked = reaper.ImGui_Button(ctx, label, w or 0, h or 0)
  reaper.ImGui_PopStyleColor(ctx, npush)
  return clicked
end

-- Returns the list of stereo hardware output pairs from the active audio device
local function get_hw_out_options()
  local opts = { "None" }
  local n = reaper.GetNumAudioOutputs()
  for i = 0, n - 2, 2 do
    opts[#opts+1] = "Out "..(i+1).."/"..(i+2)
  end
  if n > 0 and n % 2 ~= 0 then
    opts[#opts+1] = "Out "..n.." (mono)"
  end
  return opts
end

-- =============================================================================
--  FONTS
--  Body text + amber title (Studio Kozak house style).
-- =============================================================================

local FONT_BODY  = 13
local FONT_TITLE = 18
local fontBody   = reaper.ImGui_CreateFont("sans-serif", FONT_BODY)
local fontTitle  = reaper.ImGui_CreateFont("sans-serif", FONT_TITLE)

-- Push a font, tolerant of the ReaImGui version signature difference.
local _pf_mode
local function PushFont(ctx, f, size)
  if _pf_mode == 1 then
    reaper.ImGui_PushFont(ctx, f, size)
  elseif _pf_mode == 2 then
    reaper.ImGui_PushFont(ctx, f)
  else
    if pcall(reaper.ImGui_PushFont, ctx, f, size) then _pf_mode = 1
    else reaper.ImGui_PushFont(ctx, f); _pf_mode = 2 end
  end
end
local function PopFont(ctx) reaper.ImGui_PopFont(ctx) end

-- =============================================================================
--  PROJECT MODEL
--  All project tracks are potential sources,
--  except for the CUES folder and the cue buses themselves.
-- =============================================================================

local ProjectModel = {}
ProjectModel.__index = ProjectModel

function ProjectModel.new()
  local self = setmetatable({}, ProjectModel)
  self.sources    = {}
  self.cue_buses  = {}
  self.cue_folder = nil
  return self
end

function ProjectModel:scan()
  self.sources    = {}
  self.cue_buses  = {}
  self.cue_folder = nil

  local n = reaper.CountTracks(0)

  -- First pass: locate the CUES folder and cue buses
  for i = 0, n-1 do
    local t    = reaper.GetTrack(0, i)
    local role = get_ext(t, "SK_CBM_ROLE")
    if role == "CUE_FOLDER" then
      self.cue_folder = t
    elseif role == "CUE_BUS" then
      local g = guid_of(t)
      self.cue_buses[g] = {
        track = t,
        guid  = g,
        name  = track_name(t),
        hw_l  = tonumber(get_ext(t, "SK_CBM_HW_L")) or -1,
      }
    end
  end

  -- Second pass: all other tracks = available sources
  -- Order follows the actual track order in REAPER
  for i = 0, n-1 do
    local t    = reaper.GetTrack(0, i)
    local g    = guid_of(t)
    local role = get_ext(t, "SK_CBM_ROLE")
    if role ~= "CUE_FOLDER" and role ~= "CUE_BUS" then
      self.sources[#self.sources+1] = {
        track = t,
        guid  = g,
        name  = track_name(t),
        color = reaper.GetTrackColor(t),
      }
    end
  end
end

-- List of cue buses sorted by their order in REAPER
function ProjectModel:cue_list()
  local list = {}
  for _, cb in pairs(self.cue_buses) do
    if valid_track(cb.track) then list[#list+1] = cb end
  end
  table.sort(list, function(a, b)
    return track_idx(a.track) < track_idx(b.track)
  end)
  return list
end

-- Tracks already in a cue (have an active send to this cue)
function ProjectModel:sources_in_cue(cue_guid, routing)
  local cue = self.cue_buses[cue_guid]
  if not cue then return {} end
  local list = {}
  for _, src in ipairs(self.sources) do
    if routing:find_send(src.track, cue.track) >= 0 then
      list[#list+1] = src
    end
  end
  return list
end

-- Tracks not yet in a cue
function ProjectModel:sources_not_in_cue(cue_guid, routing)
  local cue = self.cue_buses[cue_guid]
  if not cue then return {} end
  local list = {}
  for _, src in ipairs(self.sources) do
    if routing:find_send(src.track, cue.track) < 0 then
      list[#list+1] = src
    end
  end
  return list
end

-- =============================================================================
--  ROUTING ENGINE
--  Manages sends from each track to each cue bus.
--  Mode: PRE-FADER / POST-FX — the headphone mix is independent
--  of the REAPER console fader, but receives signal after plugins.
-- =============================================================================

local RoutingEngine = {}
RoutingEngine.__index = RoutingEngine

function RoutingEngine.new(model)
  local self = setmetatable({}, RoutingEngine)
  self.model      = model
  self.send_cache = {}
  return self
end

function RoutingEngine:invalidate_cache()
  self.send_cache = {}
end

-- Finds an existing send between two tracks. Returns its index or -1.
function RoutingEngine:find_send(src_track, dst_track)
  local n = reaper.GetTrackNumSends(src_track, 0)
  for i = 0, n-1 do
    if reaper.GetTrackSendInfo_Value(src_track, 0, i, "P_DESTTRACK") == dst_track then
      return i
    end
  end
  return -1
end

local function create_send(src_track, cue_track)
  local idx = reaper.CreateTrackSend(src_track, cue_track)
  reaper.SetTrackSendInfo_Value(src_track, 0, idx, "I_SENDMODE", CFG.SEND_MODE)
  reaper.SetTrackSendInfo_Value(src_track, 0, idx, "I_SRCCHAN",  0)
  reaper.SetTrackSendInfo_Value(src_track, 0, idx, "I_DSTCHAN",  0)
  reaper.SetTrackSendInfo_Value(src_track, 0, idx, "D_VOL",  1.0)
  reaper.SetTrackSendInfo_Value(src_track, 0, idx, "D_PAN",  0.0)
  reaper.SetTrackSendInfo_Value(src_track, 0, idx, "B_MUTE", 0)
  return idx
end

function RoutingEngine:cache_valid(cue_guid, src_guid, idx)
  local cue = self.model.cue_buses[cue_guid]
  if not cue then return false end
  local src_track = nil
  for _, s in ipairs(self.model.sources) do
    if s.guid == src_guid then src_track = s.track; break end
  end
  if not src_track then return false end
  local n = reaper.GetTrackNumSends(src_track, 0)
  if idx >= n then return false end
  return reaper.GetTrackSendInfo_Value(src_track, 0, idx, "P_DESTTRACK") == cue.track
end

function RoutingEngine:get_send_idx_cached(cue_guid, src_guid)
  if not self.send_cache[cue_guid] then self.send_cache[cue_guid] = {} end
  local c = self.send_cache[cue_guid][src_guid]
  if c ~= nil then
    if self:cache_valid(cue_guid, src_guid, c) then return c end
    self.send_cache[cue_guid][src_guid] = nil
  end
  return nil
end

function RoutingEngine:get_send_for(cue_guid, src_track, src_guid)
  local cached = self:get_send_idx_cached(cue_guid, src_guid)
  if cached then return cached end
  local cue = self.model.cue_buses[cue_guid]
  if not cue then return nil end
  local idx = self:find_send(src_track, cue.track)
  if idx < 0 then return nil end
  self.send_cache[cue_guid][src_guid] = idx
  return idx
end

function RoutingEngine:get_vol(cue_guid, src)
  local idx = self:get_send_for(cue_guid, src.track, src.guid)
  if not idx then return 1.0 end
  return reaper.GetTrackSendInfo_Value(src.track, 0, idx, "D_VOL")
end

function RoutingEngine:get_pan(cue_guid, src)
  local idx = self:get_send_for(cue_guid, src.track, src.guid)
  if not idx then return 0.0 end
  return reaper.GetTrackSendInfo_Value(src.track, 0, idx, "D_PAN")
end

function RoutingEngine:get_mute(cue_guid, src)
  local idx = self:get_send_for(cue_guid, src.track, src.guid)
  if not idx then return false end
  return reaper.GetTrackSendInfo_Value(src.track, 0, idx, "B_MUTE") == 1
end

function RoutingEngine:set_vol(cue_guid, src, vol)
  local idx = self:get_send_for(cue_guid, src.track, src.guid)
  if not idx then return end
  reaper.SetTrackSendInfo_Value(src.track, 0, idx, "D_VOL", vol)
end

function RoutingEngine:set_pan(cue_guid, src, pan)
  local idx = self:get_send_for(cue_guid, src.track, src.guid)
  if not idx then return end
  reaper.SetTrackSendInfo_Value(src.track, 0, idx, "D_PAN", pan)
end

function RoutingEngine:set_mute(cue_guid, src, muted)
  local idx = self:get_send_for(cue_guid, src.track, src.guid)
  if not idx then return end
  reaper.SetTrackSendInfo_Value(src.track, 0, idx, "B_MUTE", muted and 1 or 0)
end

-- Adds a track to a cue (prevents duplicates)
function RoutingEngine:add_track_to_cue(cue_guid, src)
  local cue = self.model.cue_buses[cue_guid]
  if not cue then return false end
  if self:find_send(src.track, cue.track) >= 0 then return false end
  local idx = create_send(src.track, cue.track)
  if not self.send_cache[cue_guid] then self.send_cache[cue_guid] = {} end
  self.send_cache[cue_guid][src.guid] = idx
  return true
end

-- Removes a track from a cue
function RoutingEngine:remove_track_from_cue(cue_guid, src)
  local cue = self.model.cue_buses[cue_guid]
  if not cue then return false end
  local idx = self:find_send(src.track, cue.track)
  if idx < 0 then return false end
  reaper.RemoveTrackSend(src.track, 0, idx)
  self.send_cache[cue_guid] = nil
  return true
end

-- Resets send parameters to correct values for all sends in a cue
function RoutingEngine:repair_sends_for_cue(cue_guid)
  local cue = self.model.cue_buses[cue_guid]
  if not cue then return end
  for _, src in ipairs(self.model.sources) do
    local idx = self:find_send(src.track, cue.track)
    if idx >= 0 then
      reaper.SetTrackSendInfo_Value(src.track, 0, idx, "I_SENDMODE", CFG.SEND_MODE)
      reaper.SetTrackSendInfo_Value(src.track, 0, idx, "I_SRCCHAN",  0)
      reaper.SetTrackSendInfo_Value(src.track, 0, idx, "I_DSTCHAN",  0)
    end
  end
  self.send_cache[cue_guid] = nil
end

-- Assigns a stereo hardware output to a cue bus
function RoutingEngine:set_hw_out(cue_guid, ch_l)
  local cue = self.model.cue_buses[cue_guid]
  if not cue then return end
  local n = reaper.GetTrackNumSends(cue.track, 1)
  for i = n-1, 0, -1 do reaper.RemoveTrackSend(cue.track, 1, i) end
  if ch_l >= 0 then
    local idx = reaper.CreateTrackSend(cue.track, nil)
    reaper.SetTrackSendInfo_Value(cue.track, 1, idx, "I_DSTCHAN", ch_l)
  end
  set_ext(cue.track, "SK_CBM_HW_L", tostring(ch_l))
  cue.hw_l = ch_l
end

-- =============================================================================
--  DISPLAY ORDER
--  Per-cue, script-only ordering of the track strips shown in the mix area.
--  Purely cosmetic — it never touches track order in REAPER itself. Persisted
--  on the cue bus track via P_EXT, the same mechanism used for snapshots.
-- =============================================================================

local function get_display_order(cue)
  local raw = get_ext(cue.track, "SK_CBM_ORDER")
  if not raw or raw == "" then return {} end
  local order = {}
  for guid in raw:gmatch("[^;]+") do order[#order+1] = guid end
  return order
end

local function save_display_order(cue, ordered_srcs)
  local parts = {}
  for _, src in ipairs(ordered_srcs) do parts[#parts+1] = src.guid end
  set_ext(cue.track, "SK_CBM_ORDER", table.concat(parts, ";"))
end

-- model:sources_in_cue's list, re-ordered per the cue's saved display order.
-- Tracks with no saved position (newly added) are appended at the end, in
-- their REAPER track order.
local function ordered_sources_in_cue(cue, routing, model)
  local raw = model:sources_in_cue(cue.guid, routing)
  local order = get_display_order(cue)
  if #order == 0 then return raw end

  local by_guid = {}
  for _, src in ipairs(raw) do by_guid[src.guid] = src end

  local result, seen = {}, {}
  for _, guid in ipairs(order) do
    local src = by_guid[guid]
    if src then
      result[#result+1] = src
      seen[guid] = true
    end
  end
  for _, src in ipairs(raw) do
    if not seen[src.guid] then result[#result+1] = src end
  end
  return result
end

-- Swaps a track with its left/right neighbor in the cue's display order and
-- persists the result. direction: -1 = left, 1 = right.
local function move_track_in_cue(cue, routing, model, src_guid, direction)
  local ordered = ordered_sources_in_cue(cue, routing, model)
  local idx = nil
  for i, src in ipairs(ordered) do
    if src.guid == src_guid then idx = i; break end
  end
  if not idx then return end
  local swap_idx = idx + direction
  if swap_idx < 1 or swap_idx > #ordered then return end
  ordered[idx], ordered[swap_idx] = ordered[swap_idx], ordered[idx]
  save_display_order(cue, ordered)
end

-- =============================================================================
--  CUE MANAGER
--  Creation, deletion, duplication, renaming of cue buses.
-- =============================================================================

local CueManager = {}
CueManager.__index = CueManager

function CueManager.new(model, routing)
  local self = setmetatable({}, CueManager)
  self.model   = model
  self.routing = routing
  return self
end

-- Fixes the CUES folder hierarchy after each operation
function CueManager:repair_cue_folder_structure()
  local folder = self.model.cue_folder
  if not folder then return end
  local cues = self.model:cue_list()
  if #cues == 0 then
    if valid_track(folder) then reaper.DeleteTrack(folder) end
    self.model.cue_folder = nil
    return
  end
  reaper.SetMediaTrackInfo_Value(folder, "I_FOLDERDEPTH", 1)
  for i, cue in ipairs(cues) do
    reaper.SetMediaTrackInfo_Value(cue.track, "I_FOLDERDEPTH", i < #cues and 0 or -1)
  end
end

-- Full repair: folder, track parameters, sends
function CueManager:repair_project_structure()
  reaper.Undo_BeginBlock()
  self:repair_cue_folder_structure()
  for _, cue in pairs(self.model.cue_buses) do
    reaper.SetMediaTrackInfo_Value(cue.track, "B_MAINSEND", 0)
    reaper.SetMediaTrackInfo_Value(cue.track, "I_NCHAN", 2)
  end
  for _, cue in pairs(self.model.cue_buses) do
    self.routing:repair_sends_for_cue(cue.guid)
  end
  self.routing:invalidate_cache()
  reaper.Undo_EndBlock("CBM: Repair", -1)
end

function CueManager:ensure_cue_folder()
  if self.model.cue_folder then return self.model.cue_folder end
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local t = reaper.GetTrack(0, idx)
  set_track_name(t, "CUES")
  reaper.SetMediaTrackInfo_Value(t, "B_MAINSEND", 0)
  reaper.SetMediaTrackInfo_Value(t, "I_FOLDERDEPTH", 0)
  set_ext(t, "SK_CBM_ROLE", "CUE_FOLDER")
  self.model.cue_folder = t
  return t
end

-- Creates a new empty cue bus
function CueManager:create_cue_bus(name)
  name = name or "Cue"
  reaper.Undo_BeginBlock()
  local folder = self:ensure_cue_folder()
  local folder_track_idx = track_idx(folder) - 1
  local insert_at = folder_track_idx + 1
  local n = reaper.CountTracks(0)
  for i = folder_track_idx + 1, n - 1 do
    local t = reaper.GetTrack(0, i)
    if get_ext(t, "SK_CBM_ROLE") == "CUE_BUS" then insert_at = i + 1 else break end
  end
  reaper.InsertTrackAtIndex(insert_at, false)
  local t = reaper.GetTrack(0, insert_at)
  set_track_name(t, name)
  reaper.SetMediaTrackInfo_Value(t, "I_NCHAN", 2)
  reaper.SetMediaTrackInfo_Value(t, "B_MAINSEND", 0)
  set_ext(t, "SK_CBM_ROLE", "CUE_BUS")
  set_ext(t, "SK_CBM_HW_L", "-1")
  local g = guid_of(t)
  self.model.cue_buses[g] = { track=t, guid=g, name=name, hw_l=-1 }
  self.model:scan()
  self:repair_cue_folder_structure()
  self.routing:invalidate_cache()
  reaper.TrackList_AdjustWindows(false)
  reaper.Undo_EndBlock("CBM: Create cue bus "..name, -1)
  return g
end

function CueManager:delete_cue_bus(cue_guid)
  local cue = self.model.cue_buses[cue_guid]
  if not cue then return end
  reaper.Undo_BeginBlock()
  for _, src in ipairs(self.model.sources) do
    local idx = self.routing:find_send(src.track, cue.track)
    if idx >= 0 then reaper.RemoveTrackSend(src.track, 0, idx) end
  end
  reaper.DeleteTrack(cue.track)
  self.model.cue_buses[cue_guid] = nil
  self.routing.send_cache[cue_guid] = nil
  self.model:scan()
  self:repair_cue_folder_structure()
  self.routing:invalidate_cache()
  reaper.Undo_EndBlock("CBM: Delete cue bus", -1)
end

function CueManager:duplicate_cue_bus(src_cue_guid)
  local src_cue = self.model.cue_buses[src_cue_guid]
  if not src_cue then return nil end
  reaper.Undo_BeginBlock()
  local new_guid = self:create_cue_bus(src_cue.name.." (copy)")
  local new_cue  = self.model.cue_buses[new_guid]
  if new_cue then
    -- Carry over the source cue's color, so the copy isn't left uncolored
    -- (which also threw off the sidebar row alignment — no color meant no
    -- swatch dot, so the mute button sat one slot to the left).
    local native_col = reaper.GetTrackColor(src_cue.track)
    if native_col ~= 0 then
      reaper.SetMediaTrackInfo_Value(new_cue.track, "I_CUSTOMCOLOR", native_col)
      set_ext(new_cue.track, "SK_CBM_COLOR", get_ext(src_cue.track, "SK_CBM_COLOR"))
    end
    for _, src in ipairs(self.model.sources) do
      local old_idx = self.routing:find_send(src.track, src_cue.track)
      if old_idx >= 0 then
        self.routing:add_track_to_cue(new_guid, src)
        local vol  = reaper.GetTrackSendInfo_Value(src.track, 0, old_idx, "D_VOL")
        local pan  = reaper.GetTrackSendInfo_Value(src.track, 0, old_idx, "D_PAN")
        local mute = reaper.GetTrackSendInfo_Value(src.track, 0, old_idx, "B_MUTE")
        self.routing:set_vol(new_guid, src, vol)
        self.routing:set_pan(new_guid, src, pan)
        self.routing:set_mute(new_guid, src, mute == 1)
      end
    end
  end
  reaper.Undo_EndBlock("CBM: Duplicate cue bus", -1)
  return new_guid
end

function CueManager:rename_cue_bus(cue_guid, new_name)
  local cue = self.model.cue_buses[cue_guid]
  if not cue or new_name == "" then return end
  reaper.Undo_BeginBlock()
  set_track_name(cue.track, new_name)
  cue.name = new_name
  reaper.Undo_EndBlock("CBM: Rename cue "..new_name, -1)
end

-- Copies all mix levels from one cue to another
function CueManager:copy_mix(src_guid, dst_guid)
  local src_cue = self.model.cue_buses[src_guid]
  local dst_cue = self.model.cue_buses[dst_guid]
  if not (src_cue and dst_cue) then return end
  reaper.Undo_BeginBlock()
  for _, src in ipairs(self.model.sources) do
    local old_idx = self.routing:find_send(src.track, src_cue.track)
    if old_idx >= 0 then
      self.routing:add_track_to_cue(dst_guid, src)
      local vol  = reaper.GetTrackSendInfo_Value(src.track, 0, old_idx, "D_VOL")
      local pan  = reaper.GetTrackSendInfo_Value(src.track, 0, old_idx, "D_PAN")
      local mute = reaper.GetTrackSendInfo_Value(src.track, 0, old_idx, "B_MUTE")
      self.routing:set_vol(dst_guid, src, vol)
      self.routing:set_pan(dst_guid, src, pan)
      self.routing:set_mute(dst_guid, src, mute == 1)
    end
  end
  reaper.Undo_EndBlock("CBM: Copy mix", -1)
end

-- Resets all faders to 0 dB, pan to center, unmute all
function CueManager:reset_cue(cue_guid)
  local cue = self.model.cue_buses[cue_guid]
  if not cue then return end
  reaper.Undo_BeginBlock()
  for _, src in ipairs(self.model.sources) do
    local idx = self.routing:find_send(src.track, cue.track)
    if idx >= 0 then
      reaper.SetTrackSendInfo_Value(src.track, 0, idx, "D_VOL",  1.0)
      reaper.SetTrackSendInfo_Value(src.track, 0, idx, "D_PAN",  0.0)
      reaper.SetTrackSendInfo_Value(src.track, 0, idx, "B_MUTE", 0)
    end
  end
  reaper.Undo_EndBlock("CBM: Reset cue mix", -1)
end

-- Adds currently selected REAPER tracks to the cue
function CueManager:add_selected_tracks_to_cue(cue_guid)
  reaper.Undo_BeginBlock()
  local added = 0
  local n = reaper.CountSelectedTracks(0)
  for i = 0, n-1 do
    local t    = reaper.GetSelectedTrack(0, i)
    local g    = guid_of(t)
    local role = get_ext(t, "SK_CBM_ROLE")
    if role ~= "CUE_FOLDER" and role ~= "CUE_BUS" then
      for _, src in ipairs(self.model.sources) do
        if src.guid == g then
          if self.routing:add_track_to_cue(cue_guid, src) then added = added + 1 end
          break
        end
      end
    end
  end
  reaper.Undo_EndBlock("CBM: Add selected tracks ("..added..")", -1)
  return added
end

-- =============================================================================
--  SNAPSHOTS A / B
--  Two mix snapshots per cue, saved in the REAPER project.
--  Recall restores volumes, pans and mutes for each track.
-- =============================================================================

local SnapSystem = {}
SnapSystem.__index = SnapSystem

function SnapSystem.new(model, routing)
  local self = setmetatable({}, SnapSystem)
  self.model   = model
  self.routing = routing
  self.snaps   = {}
  return self
end

function SnapSystem:save(cue_guid, slot)
  if not self.snaps[cue_guid] then self.snaps[cue_guid] = {} end
  local cue = self.model.cue_buses[cue_guid]
  if not cue then return end
  local s = {}
  for _, src in ipairs(self.model.sources) do
    local idx = self.routing:find_send(src.track, cue.track)
    if idx >= 0 then
      s[src.guid] = {
        vol  = reaper.GetTrackSendInfo_Value(src.track, 0, idx, "D_VOL"),
        pan  = reaper.GetTrackSendInfo_Value(src.track, 0, idx, "D_PAN"),
        mute = reaper.GetTrackSendInfo_Value(src.track, 0, idx, "B_MUTE") == 1,
      }
    end
  end
  self.snaps[cue_guid][slot] = s
  local parts = {}
  for g, d in pairs(s) do
    parts[#parts+1] = g.."="..d.vol.."|"..d.pan.."|"..(d.mute and "1" or "0")
  end
  set_ext(cue.track, "SK_CBM_SNAP_"..slot, table.concat(parts, ";"))
end

function SnapSystem:recall(cue_guid, slot)
  local cue = self.model.cue_buses[cue_guid]
  if not cue then return false end
  if not (self.snaps[cue_guid] and self.snaps[cue_guid][slot]) then
    local raw = get_ext(cue.track, "SK_CBM_SNAP_"..slot)
    if not raw or raw == "" then return false end
    local s = {}
    for entry in raw:gmatch("[^;]+") do
      local g, rest = entry:match("^([^=]+)=(.+)$")
      if g then
        local v, p, m = rest:match("^([^|]+)|([^|]+)|(.+)$")
        if v then s[g] = { vol=tonumber(v) or 1, pan=tonumber(p) or 0, mute=m=="1" } end
      end
    end
    if not self.snaps[cue_guid] then self.snaps[cue_guid] = {} end
    self.snaps[cue_guid][slot] = s
  end
  local s = self.snaps[cue_guid][slot]
  if not s then return false end
  reaper.Undo_BeginBlock()
  for _, src in ipairs(self.model.sources) do
    local d = s[src.guid]
    if d then
      local idx = self.routing:find_send(src.track, cue.track)
      if idx >= 0 then
        reaper.SetTrackSendInfo_Value(src.track, 0, idx, "D_VOL",  d.vol)
        reaper.SetTrackSendInfo_Value(src.track, 0, idx, "D_PAN",  d.pan)
        reaper.SetTrackSendInfo_Value(src.track, 0, idx, "B_MUTE", d.mute and 1 or 0)
      end
    end
  end
  reaper.Undo_EndBlock("CBM: Recall snapshot "..slot, -1)
  return true
end

function SnapSystem:has(cue_guid, slot)
  if self.snaps[cue_guid] and self.snaps[cue_guid][slot] then return true end
  local cue = self.model.cue_buses[cue_guid]
  if not cue then return false end
  local raw = get_ext(cue.track, "SK_CBM_SNAP_"..slot)
  return raw ~= nil and raw ~= ""
end

-- =============================================================================
--  INTERFACE STATE
-- =============================================================================

local UI = {
  selected_cue     = nil,
  rename_guid      = nil,
  rename_buf       = "",
  rename_in_header = false,
  show_new_dlg     = false,
  new_name_buf     = "Cue 1",
  new_hw_ch        = 0,
  new_col_r        = -1,
  new_col_g        = -1,
  new_col_b        = -1,
  new_pastel_amt   = 0.0,
  copy_from_dlg    = false,
  hw_out_dlg       = false,
  hw_out_cue       = nil,
  hw_ch_sel        = 0,
  color_popover    = false,
  color_cue        = nil,
  color_pastel_amt = 0.0,
  clip_hold        = {},
  cue_master       = {},
  strip_wide       = false,   -- false = normal width, true = wide
  strip_custom_w   = 120,     -- width in wide mode (px), adjustable
  status_msg       = "",
  status_time      = 0,
}

-- Current strip width for the active Normal/Wide mode
local function strip_w()
  return UI.strip_wide and UI.strip_custom_w or 80
end

local function set_status(msg)
  UI.status_msg  = msg
  UI.status_time = reaper.time_precise()
end

-- Global volume, pan and mute for a cue (independent of individual faders)
local function get_cue_master(cue_guid)
  if not UI.cue_master[cue_guid] then
    UI.cue_master[cue_guid] = { vol = 1.0, pan = 0.0, muted = false }
  end
  return UI.cue_master[cue_guid]
end

-- Applies global volume, pan and mute directly on the cue bus track
local function apply_cue_master(cue_guid, model)
  local m   = get_cue_master(cue_guid)
  local cue = model.cue_buses[cue_guid]
  if not cue or not valid_track(cue.track) then return end
  reaper.SetMediaTrackInfo_Value(cue.track, "B_MUTE", m.muted and 1 or 0)
  reaper.SetMediaTrackInfo_Value(cue.track, "D_VOL",  m.vol)
  reaper.SetMediaTrackInfo_Value(cue.track, "D_PAN",  m.pan)
end

-- =============================================================================
--  VU-METER
--  Stereo L/R display with 5 color zones. Reads the post-fader signal from the
--  source track; the send volume, pan and mute are applied on top. A red
--  indicator at the top signals a recent clip (2 seconds).
-- =============================================================================

local VU_SEGMENTS = {
  { lo=-60, hi=-18, col_key="VU_BLUE"   },
  { lo=-18, hi=-12, col_key="VU_GREEN"  },
  { lo=-12, hi= -6, col_key="VU_YELLOW" },
  { lo= -6, hi=  0, col_key="VU_ORANGE" },
  { lo=  0, hi=  6, col_key="VU_CLIP"   },
}
local VU_DB_MIN   = -60
local VU_DB_RANGE =  66
local CLIP_HOLD_TIME = 2.0

-- vol   : send volume (0..2)
-- pan   : send pan (-1..1), applied to L and R channels
-- muted : if true, the VU shows silence (send is muted)
local function draw_vu_meter(ctx, track, h, vol, pan, muted, src_guid)
  if not valid_track(track) then return end
  vol      = vol      or 1.0
  pan      = pan      or 0.0
  muted    = muted    or false
  src_guid = src_guid or ""

  -- If the send is muted, nothing reaches the headphone mix
  if muted then
    local total_w = CFG.VU_W * 2 + CFG.VU_GAP
    local cx, cy  = reaper.ImGui_GetCursorScreenPos(ctx)
    local dl      = reaper.ImGui_GetWindowDrawList(ctx)
    reaper.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx+total_w, cy+h, rgba(CFG.COL.VU_BG))
    reaper.ImGui_Dummy(ctx, total_w, h)
    return
  end

  -- Linear pan law: pan=-1 full left, pan=0 center, pan=1 full right
  local gain_l = vol * (1.0 - math.max(pan, 0))
  local gain_r = vol * (1.0 + math.min(pan, 0))

  -- Reads the peak from the source track.
  -- Note: Track_GetPeakInfo returns the post-fader signal.
  -- If the REAPER console fader is lowered, the VU will be affected.
  -- This is an API limitation — pre-fader peak is not accessible via ReaScript.
  local peak_l = reaper.Track_GetPeakInfo(track, 0) * gain_l
  local peak_r = reaper.Track_GetPeakInfo(track, 1) * gain_r

  local function to_db(p)
    if p <= 0 then return -math.huge end
    return 20 * math.log(p, 10)
  end

  local function db_to_frac(db)
    return clamp((db - VU_DB_MIN) / VU_DB_RANGE, 0, 1)
  end

  local key_l = src_guid.."L"
  local key_r = src_guid.."R"
  local now   = reaper.time_precise()
  if peak_l >= 1.0 then UI.clip_hold[key_l] = now end
  if peak_r >= 1.0 then UI.clip_hold[key_r] = now end
  local clip_l = UI.clip_hold[key_l] and (now - UI.clip_hold[key_l]) < CLIP_HOLD_TIME
  local clip_r = UI.clip_hold[key_r] and (now - UI.clip_hold[key_r]) < CLIP_HOLD_TIME

  local total_w  = CFG.VU_W * 2 + CFG.VU_GAP
  local clip_h   = 4
  local bar_area = h - clip_h - 2
  local cx, cy   = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl       = reaper.ImGui_GetWindowDrawList(ctx)
  local bar_y0   = cy + clip_h + 2

  reaper.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx+total_w, cy+h, rgba(CFG.COL.VU_BG))

  if clip_l then
    reaper.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx+CFG.VU_W, cy+clip_h, rgba(CFG.COL.VU_CLIP_IND))
  end
  if clip_r then
    local rx = cx + CFG.VU_W + CFG.VU_GAP
    reaper.ImGui_DrawList_AddRectFilled(dl, rx, cy, rx+CFG.VU_W, cy+clip_h, rgba(CFG.COL.VU_CLIP_IND))
  end

  local function draw_channel(x, peak)
    local db_peak = to_db(peak)
    if db_peak == -math.huge then return end
    for _, seg in ipairs(VU_SEGMENTS) do
      if db_peak > seg.lo then
        local y_bot = bar_y0 + math.floor((1 - db_to_frac(seg.lo))                   * bar_area)
        local y_top = bar_y0 + math.floor((1 - db_to_frac(math.min(seg.hi, db_peak))) * bar_area)
        if y_top < y_bot then
          reaper.ImGui_DrawList_AddRectFilled(dl, x, y_top, x+CFG.VU_W, y_bot,
            rgba(CFG.COL[seg.col_key]))
        end
      end
    end
  end

  draw_channel(cx, peak_l)
  draw_channel(cx + CFG.VU_W + CFG.VU_GAP, peak_r)

  local y_0db = bar_y0 + math.floor((1 - db_to_frac(0)) * bar_area)
  reaper.ImGui_DrawList_AddLine(dl, cx, y_0db, cx+total_w, y_0db, rgba(0x8C877880), 1)

  reaper.ImGui_Dummy(ctx, total_w, h)
end

-- =============================================================================
--  FADER STRIP — HARDWARE-STYLE WIDGETS
--  Ported from SK Bus Console: DrawList-based fader (groove + tick marks + cap)
--  and a rotary pan knob, replacing the native ImGui slider / knob previously
--  used per strip. Functionality (routing, mute, VU, remove) is unchanged —
--  only the look and feel of the strip header, fader and pan control.
-- =============================================================================

local FADER_DB_MIN, FADER_DB_MAX = -60.0, 12.0
local HAS_SLIDER = reaper.DB2SLIDER and reaper.SLIDER2DB

local FADER_COL_GROOVE    = 0x141412FF
local FADER_COL_GROOVE_DK = 0x0A0A09FF
local FADER_COL_CAP_EDGE  = 0x000000FF
local FADER_COL_BEVEL_HI  = 0xFFFFFF22
local FADER_COL_BEVEL_LO  = 0x00000066
local FADER_COL_TICK      = 0x55504955
local FADER_COL_TICK_0    = 0xD9A44188
local KNOB_COL_BODY       = 0x33332FFF
local KNOB_COL_EDGE       = 0x000000FF

local STRIP_HDR_H   = 22
local ARROW_ROW_H   = 12

local function gain_to_db(g)
  if g <= 0 then return -150.0 end
  return 20.0 * math.log(g, 10)
end

local function gain_to_norm(g)
  if HAS_SLIDER then return clamp(reaper.DB2SLIDER(gain_to_db(g)) / 1000.0, 0.0, 1.0) end
  local db = clamp(gain_to_db(g), FADER_DB_MIN, FADER_DB_MAX)
  return (db - FADER_DB_MIN) / (FADER_DB_MAX - FADER_DB_MIN)
end

local function norm_to_gain(n)
  local db
  if HAS_SLIDER then db = reaper.SLIDER2DB(n * 1000.0)
  else db = FADER_DB_MIN + n * (FADER_DB_MAX - FADER_DB_MIN) end
  if db <= -150.0 then return 0.0 end
  return 10.0 ^ (db / 20.0)
end

local FADER_DEFAULT_NORM = gain_to_norm(1.0)

local function text_on(col)
  local r = (col >> 24) & 0xFF
  local g = (col >> 16) & 0xFF
  local b = (col >> 8) & 0xFF
  local lum = 0.299 * r + 0.587 * g + 0.114 * b
  return lum > 140 and CFG.COL.INK or CFG.COL.TEXT_BRIGHT
end

-- Drag state for the custom widgets, held while the mouse button is down so
-- the widget follows the cursor instead of snapping back to the live value.
local drag_hold = {}

local function fine_drag(ctx)
  if reaper.ImGui_GetKeyMods and reaper.ImGui_Mod_Ctrl then
    return (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Ctrl()) ~= 0
  end
  return false
end

-- Colored header bar (track color) with a centered, clipped name and a small
-- remove button in the top-right corner. Returns true the frame the remove
-- button is clicked. `w` is the strip's actual usable content width (already
-- net of the child window's padding).
local function sk_strip_header(ctx, dl, w, native_col, name, show_remove)
  local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
  local hdr = native_col ~= 0 and native_to_imgui(native_col) or rgba(CFG.COL.STRIP_SEL)
  reaper.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + w, cy + STRIP_HDR_H, hdr, 3)
  local tcol = text_on(hdr)
  local label_r = show_remove and (cx + w - 22) or (cx + w - 4)
  reaper.ImGui_DrawList_PushClipRect(dl, cx + 4, cy, label_r, cy + STRIP_HDR_H, true)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, name)
  local label_w = label_r - (cx + 4)
  local tx = cx + 4 + math.max(0, (label_w - tw) * 0.5)
  reaper.ImGui_DrawList_AddText(dl, tx, cy + (STRIP_HDR_H - th) * 0.5, rgba(tcol), name)
  reaper.ImGui_DrawList_PopClipRect(dl)

  local removed = false
  if show_remove then
    local bw, bh = 16, 16
    local bx, by = cx + w - bw - 3, cy + (STRIP_HDR_H - bh) * 0.5
    reaper.ImGui_SetCursorScreenPos(ctx, bx, by)
    reaper.ImGui_InvisibleButton(ctx, '##rm', bw, bh)
    local hovered = reaper.ImGui_IsItemHovered(ctx)
    if reaper.ImGui_IsItemClicked(ctx) then removed = true end
    local fill = hovered and rgba(CFG.COL.DANGER_H) or rgba(CFG.COL.DANGER)
    reaper.ImGui_DrawList_AddRectFilled(dl, bx, by, bx+bw, by+bh, fill, 3)
    reaper.ImGui_DrawList_AddRect(dl, bx, by, bx+bw, by+bh, rgba(0x000000AA), 3, 0, 1)
    reaper.ImGui_DrawList_AddLine(dl, bx+4, by+4, bx+bw-4, by+bh-4, rgba(0xFFFFFFFF), 1.6)
    reaper.ImGui_DrawList_AddLine(dl, bx+bw-4, by+4, bx+4, by+bh-4, rgba(0xFFFFFFFF), 1.6)
    if hovered then
      reaper.ImGui_SetTooltip(ctx, "Remove from this headphone mix")
    end
  end

  reaper.ImGui_SetCursorScreenPos(ctx, cx, cy)
  reaper.ImGui_Dummy(ctx, w, STRIP_HDR_H)
  return removed
end

-- Vertical fader: groove + dB tick marks + beveled cap. Drag to change,
-- Ctrl+drag for fine adjustment, double-click to reset to 0 dB.
local function sk_fader(ctx, dl, id, w, h, norm, cap_col, accent_col)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local cx = x + w * 0.5
  local cap_h = 20
  local travel = h - cap_h

  reaper.ImGui_DrawList_AddRectFilled(dl, cx - 3, y, cx + 3, y + h, rgba(FADER_COL_GROOVE), 2)
  reaper.ImGui_DrawList_AddLine(dl, cx, y + 2, cx, y + h - 2, rgba(FADER_COL_GROOVE_DK), 1)

  local ticks = { 12, 6, 0, -6, -12, -24, -48 }
  for _, db in ipairs(ticks) do
    local tn
    if HAS_SLIDER then tn = clamp(reaper.DB2SLIDER(db) / 1000.0, 0, 1)
    else tn = clamp((db - FADER_DB_MIN) / (FADER_DB_MAX - FADER_DB_MIN), 0, 1) end
    local ty = y + (1 - tn) * travel + cap_h * 0.5
    local c = (db == 0) and FADER_COL_TICK_0 or FADER_COL_TICK
    reaper.ImGui_DrawList_AddLine(dl, x + 1, ty, x + 5, ty, rgba(c), 1)
    reaper.ImGui_DrawList_AddLine(dl, x + w - 5, ty, x + w - 1, ty, rgba(c), 1)
  end

  reaper.ImGui_InvisibleButton(ctx, '##fad' .. id, w, h)
  local changed = false
  if reaper.ImGui_IsItemActivated(ctx) then drag_hold[id] = norm end
  if reaper.ImGui_IsItemActive(ctx) then
    local held = drag_hold[id] or norm
    local _, dy = reaper.ImGui_GetMouseDelta(ctx)
    if dy ~= 0 then
      local scale = fine_drag(ctx) and 0.25 or 1.0
      held = clamp(held - (dy / travel) * scale, 0, 1)
      drag_hold[id] = held
      changed = true
    end
    norm = held
  else
    drag_hold[id] = nil
  end
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    norm = FADER_DEFAULT_NORM; drag_hold[id] = nil; changed = true
  end

  local cap_y = y + (1 - norm) * travel
  local x1, x2 = x + 2, x + w - 2
  reaper.ImGui_DrawList_AddRectFilled(dl, x1, cap_y, x2, cap_y + cap_h, rgba(cap_col), 3)
  reaper.ImGui_DrawList_AddRect(dl, x1, cap_y, x2, cap_y + cap_h, rgba(FADER_COL_CAP_EDGE), 3, 0, 1)
  reaper.ImGui_DrawList_AddLine(dl, x1 + 1, cap_y + 1, x2 - 1, cap_y + 1, rgba(FADER_COL_BEVEL_HI), 1)
  reaper.ImGui_DrawList_AddLine(dl, x1 + 1, cap_y + cap_h - 1, x2 - 1, cap_y + cap_h - 1, rgba(FADER_COL_BEVEL_LO), 1)
  reaper.ImGui_DrawList_AddLine(dl, x1 + 2, cap_y + cap_h * 0.5, x2 - 2, cap_y + cap_h * 0.5, rgba(accent_col), 2)

  return norm, changed
end

-- Rotary pan knob. Drag vertically to change, Ctrl+drag for fine adjustment,
-- double-click to reset to center.
local function sk_pan_knob(ctx, dl, id, d, pan, accent_col)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local cx, cy = x + d * 0.5, y + d * 0.5
  local r = d * 0.5
  local key = id .. '#p'

  reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, r, rgba(KNOB_COL_BODY), 28)
  reaper.ImGui_DrawList_AddCircle(dl, cx, cy, r, rgba(KNOB_COL_EDGE), 28, 1)
  reaper.ImGui_DrawList_AddCircle(dl, cx, cy, r - 1, rgba(FADER_COL_BEVEL_HI), 28, 1)

  reaper.ImGui_InvisibleButton(ctx, '##pan' .. id, d, d)
  local changed = false
  if reaper.ImGui_IsItemActivated(ctx) then drag_hold[key] = pan end
  if reaper.ImGui_IsItemActive(ctx) then
    local held = drag_hold[key] or pan
    local _, dy = reaper.ImGui_GetMouseDelta(ctx)
    if dy ~= 0 then
      local scale = fine_drag(ctx) and 0.0025 or 0.01
      held = clamp(held - dy * scale, -1, 1)
      drag_hold[key] = held
      changed = true
    end
    pan = held
  else
    drag_hold[key] = nil
  end
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    pan = 0.0; drag_hold[key] = nil; changed = true
  end

  local a_min, a_max = math.rad(-135), math.rad(135)
  local ang = a_min + ((pan + 1) * 0.5) * (a_max - a_min)
  local px = cx + math.sin(ang) * (r - 3)
  local py = cy - math.cos(ang) * (r - 3)
  reaper.ImGui_DrawList_AddLine(dl, cx, cy, px, py, rgba(accent_col), 2)
  reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, 2, rgba(accent_col), 8)

  return pan, changed
end

-- Direct dB entry, independent of the fader's display curve: values below
-- -130 dB are treated as -inf (silence), and the entry is capped at +12 dB.
local function db_to_gain(db)
  if db < -130.0 then return 0.0 end
  return 10.0 ^ (math.min(db, FADER_DB_MAX) / 20.0)
end

-- Right-click popup on a fader: numeric dB entry with -/+ stepper buttons
-- (matching the SK Routing Hub stepper), replacing a plain context menu.
local db_popup_buf = {}

local function draw_db_entry_popup(ctx, popup_id, current_gain, on_apply)
  if reaper.ImGui_BeginPopupContextItem(ctx, popup_id) then
    if reaper.ImGui_IsWindowAppearing(ctx) then
      db_popup_buf[popup_id] = math.min(gain_to_db(current_gain), FADER_DB_MAX)
    end
    local val = db_popup_buf[popup_id] or 0.0

    if reaper.ImGui_Button(ctx, "-##dbminus"..popup_id, 20, 0) then
      val = math.min(val - 1.0, FADER_DB_MAX)
      on_apply(db_to_gain(val))
    end
    reaper.ImGui_SameLine(ctx, 0, 4)
    reaper.ImGui_SetNextItemWidth(ctx, 64)
    local ch, nv = reaper.ImGui_InputDouble(ctx, "##dbval"..popup_id, val, 0, 0, "%.1f")
    if ch then
      val = math.min(nv, FADER_DB_MAX)
      on_apply(db_to_gain(val))
    end
    reaper.ImGui_SameLine(ctx, 0, 4)
    if reaper.ImGui_Button(ctx, "+##dbplus"..popup_id, 20, 0) then
      val = math.min(val + 1.0, FADER_DB_MAX)
      on_apply(db_to_gain(val))
    end

    db_popup_buf[popup_id] = val
    reaper.ImGui_EndPopup(ctx)
  end
end

-- =============================================================================
--  FADER STRIP (one per track in the mix)
-- =============================================================================

local function draw_fader_strip(ctx, cue_guid, src, routing, fader_h, on_remove, can_left, can_right, on_move)
  local vol   = routing:get_vol(cue_guid, src)
  local pan   = routing:get_pan(cue_guid, src)
  local muted = routing:get_mute(cue_guid, src)
  local sid   = cue_guid..src.guid

  -- Track color is used for the header AND the fader cap, so the cursor
  -- matches the track name's color; the accent line auto-contrasts against
  -- the cap color so it stays visible whatever the hue. The strip body stays
  -- neutral, as in SK Bus Console.
  local track_col  = valid_track(src.track) and reaper.GetTrackColor(src.track) or 0
  local col_bg     = muted and rgba(CFG.COL.STRIP_MUTED) or rgba(CFG.COL.STRIP_BG)
  local cap_native = track_col ~= 0 and native_to_imgui(track_col) or 0x4A4A44FF
  local col_fader_cap
  if muted then
    local r = (cap_native >> 24) & 0xFF
    local g = (cap_native >> 16) & 0xFF
    local b = (cap_native >> 8) & 0xFF
    col_fader_cap = rgba((math.floor(r*0.4+20)<<24)|(math.floor(g*0.4+20)<<16)|(math.floor(b*0.4+20)<<8)|0xFF)
  else
    col_fader_cap = rgba(cap_native)
  end
  local col_accent = muted and rgba(CFG.COL.TEXT_DIM) or rgba(text_on(cap_native))

  local strip_h = fader_h + 150 + ARROW_ROW_H
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), col_bg)
  if reaper.ImGui_BeginChild(ctx, "strip"..sid, strip_w(), strip_h, 1,
      reaper.ImGui_WindowFlags_NoScrollbar() |
      reaper.ImGui_WindowFlags_NoScrollWithMouse()) then

    local dl = reaper.ImGui_GetWindowDrawList(ctx)

    -- Header: track-colored bar with clipped name + remove button
    local name = src.name
    local max_chars = math.max(4, math.floor((strip_w() - 26) / 7))
    if #name > max_chars then name = name:sub(1, max_chars - 1).."~" end
    local removed = sk_strip_header(ctx, dl, strip_w() - 12, track_col, name, on_remove ~= nil)
    if removed and on_remove then on_remove() end
    if reaper.ImGui_IsItemHovered(ctx) and #src.name > max_chars then
      reaper.ImGui_SetTooltip(ctx, src.name)
    end

    -- Pan knob, centered
    local knob_d = 28
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_SetCursorPosX(ctx, math.floor((strip_w() - knob_d) / 2))
    local np, pch = sk_pan_knob(ctx, dl, sid, knob_d, pan, rgba(CFG.COL.ACCENT))
    if pch then routing:set_pan(cue_guid, src, clamp(np, -1, 1)) end
    local disp_pan = pch and np or pan
    local pan_str = math.abs(disp_pan) < 0.01 and "C" or
      string.format("%s%d", disp_pan < 0 and "L" or "R", math.floor(math.abs(disp_pan)*100+0.5))
    local pan_tw = reaper.ImGui_CalcTextSize(ctx, pan_str)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
    reaper.ImGui_SetCursorPosX(ctx, math.floor((strip_w() - pan_tw) / 2))
    reaper.ImGui_Text(ctx, pan_str)
    reaper.ImGui_PopStyleColor(ctx, 1)

    -- Mute button
    reaper.ImGui_Spacing(ctx)
    local mc = muted and CFG.COL.MUTE_ON  or CFG.COL.MUTE_OFF
    local mh = muted and CFG.COL.DANGER_H or CFG.COL.TOGGLE_OFF_HOV
    if colored_button(ctx, muted and "MUTE" or "mute", mc, mh, CFG.COL.MUTE_ON,
        strip_w() - 12, 22) then
      routing:set_mute(cue_guid, src, not muted)
    end
    reaper.ImGui_Spacing(ctx)

    -- Vertical fader + VU-meter side by side
    local vu_w    = CFG.VU_W * 2 + CFG.VU_GAP
    local fader_x = math.floor((strip_w() - CFG.FADER_W - vu_w - 2) / 2)
    reaper.ImGui_SetCursorPosX(ctx, fader_x)
    local nn, fch = sk_fader(ctx, dl, sid, CFG.FADER_W, fader_h, gain_to_norm(vol), col_fader_cap, col_accent)
    local disp = vol
    if fch then disp = norm_to_gain(nn); routing:set_vol(cue_guid, src, disp) end
    draw_db_entry_popup(ctx, "vfrst"..sid, disp, function(g)
      disp = g
      routing:set_vol(cue_guid, src, g)
    end)

    reaper.ImGui_SameLine(ctx, 0, 2)
    draw_vu_meter(ctx, src.track, fader_h, vol, pan, muted, src.guid)

    -- Level in dB, centered below the fader
    local dbtxt = vol_to_db(disp).." dB"
    local dbtw  = reaper.ImGui_CalcTextSize(ctx, dbtxt)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
    reaper.ImGui_SetCursorPosX(ctx, math.floor((strip_w() - dbtw) / 2))
    reaper.ImGui_Text(ctx, dbtxt)
    reaper.ImGui_PopStyleColor(ctx, 1)

    -- Reorder arrows, in their own row below the dB value, spread to the
    -- strip's edges (left arrow near the left edge, right arrow near the
    -- right edge). Both triangles use the same vertex winding order
    -- (mirrored, not just swapped) so ImGui's anti-aliased fill renders
    -- them at identical size. Both use the SAME captured row_y (SetCursorPos,
    -- not SetCursorPosX) so the right arrow isn't pushed down onto the next
    -- line by the left arrow's InvisibleButton auto-advancing the cursor —
    -- that was clipping/killing the right arrow on every strip but the
    -- first (which has no left arrow to push it down). Display order only —
    -- never touches REAPER's track order in the project.
    local moved_left, moved_right = false, false
    local aw, ah = 7, 10
    local cw = strip_w() - 12
    local row_x, row_y = reaper.ImGui_GetCursorPos(ctx)

    if can_left then
      reaper.ImGui_SetCursorPos(ctx, 3, row_y)
      local ax, ay = reaper.ImGui_GetCursorScreenPos(ctx)
      ax, ay = math.floor(ax), math.floor(ay)
      reaper.ImGui_InvisibleButton(ctx, '##dbarl'..sid, aw, ah)
      local hov = reaper.ImGui_IsItemHovered(ctx)
      if reaper.ImGui_IsItemClicked(ctx) then moved_left = true end
      reaper.ImGui_DrawList_AddTriangleFilled(dl, ax+aw, ay, ax+aw, ay+ah, ax, ay+ah*0.5,
        hov and rgba(CFG.COL.ACCENT_H) or rgba(CFG.COL.ACCENT))
      if hov then reaper.ImGui_SetTooltip(ctx, "Move left (display only)") end
    end

    if can_right then
      reaper.ImGui_SetCursorPos(ctx, math.max(0, cw - aw - 3), row_y)
      local ax, ay = reaper.ImGui_GetCursorScreenPos(ctx)
      ax, ay = math.floor(ax), math.floor(ay)
      reaper.ImGui_InvisibleButton(ctx, '##dbarr'..sid, aw, ah)
      local hov = reaper.ImGui_IsItemHovered(ctx)
      if reaper.ImGui_IsItemClicked(ctx) then moved_right = true end
      reaper.ImGui_DrawList_AddTriangleFilled(dl, ax, ay+ah, ax, ay, ax+aw, ay+ah*0.5,
        hov and rgba(CFG.COL.ACCENT_H) or rgba(CFG.COL.ACCENT))
      if hov then reaper.ImGui_SetTooltip(ctx, "Move right (display only)") end
    end

    -- Reserve the row's height regardless of how many arrows were drawn,
    -- so the strip's total layout height stays fixed.
    reaper.ImGui_SetCursorPos(ctx, row_x, row_y)
    reaper.ImGui_Dummy(ctx, cw, ARROW_ROW_H)
    if moved_left  and on_move then on_move(-1) end
    if moved_right and on_move then on_move(1) end

    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 1)
end

-- =============================================================================
--  MASTER STRIP — leftmost strip in the mix, global headphone volume/pan/mute.
--  Pan is applied directly on the cue bus track's own D_PAN.
--  Same visual language as a track strip (header/knob/fader/dB label) but
--  with no remove button, mirroring SK Bus Console's MASTER strip.
-- =============================================================================

local function draw_master_strip(ctx, cue, model, fader_h)
  local master = get_cue_master(cue.guid)
  local muted  = master.muted
  local track_col = valid_track(cue.track) and reaper.GetTrackColor(cue.track) or 0

  local col_bg        = muted and rgba(CFG.COL.STRIP_MUTED) or rgba(CFG.COL.STRIP_BG)
  local col_fader_cap  = rgba(CFG.COL.ACCENT)
  local col_accent     = muted and rgba(CFG.COL.TEXT_DIM) or rgba(text_on(CFG.COL.ACCENT))

  local strip_h = fader_h + 150 + ARROW_ROW_H
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), col_bg)
  if reaper.ImGui_BeginChild(ctx, "strip_master"..cue.guid, strip_w(), strip_h, 1,
      reaper.ImGui_WindowFlags_NoScrollbar() |
      reaper.ImGui_WindowFlags_NoScrollWithMouse()) then

    local dl = reaper.ImGui_GetWindowDrawList(ctx)

    -- Amber frame around the whole master strip, as in SK Bus Console
    local wx, wy = reaper.ImGui_GetWindowPos(ctx)
    local ww, wh = reaper.ImGui_GetWindowSize(ctx)
    reaper.ImGui_DrawList_AddRect(dl, wx + 0.5, wy + 0.5, wx + ww - 0.5, wy + wh - 0.5,
      rgba(CFG.COL.ACCENT), 6, 0, 1.5)

    sk_strip_header(ctx, dl, strip_w() - 12, track_col, "MASTER", false)

    -- Pan knob — applied directly to the cue bus track's own D_PAN
    local knob_d = 28
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_SetCursorPosX(ctx, math.floor((strip_w() - knob_d) / 2))
    local np, pch = sk_pan_knob(ctx, dl, "master"..cue.guid, knob_d, master.pan, rgba(CFG.COL.ACCENT))
    if pch then
      master.pan = clamp(np, -1, 1)
      apply_cue_master(cue.guid, model)
    end
    local pan_str = math.abs(master.pan) < 0.01 and "C" or
      string.format("%s%d", master.pan < 0 and "L" or "R", math.floor(math.abs(master.pan)*100+0.5))
    local pan_tw = reaper.ImGui_CalcTextSize(ctx, pan_str)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
    reaper.ImGui_SetCursorPosX(ctx, math.floor((strip_w() - pan_tw) / 2))
    reaper.ImGui_Text(ctx, pan_str)
    reaper.ImGui_PopStyleColor(ctx, 1)

    -- Mute button
    reaper.ImGui_Spacing(ctx)
    local mc = muted and CFG.COL.MUTE_ON  or CFG.COL.MUTE_OFF
    local mh = muted and CFG.COL.DANGER_H or CFG.COL.TOGGLE_OFF_HOV
    if colored_button(ctx, muted and "MUTE" or "mute", mc, mh, CFG.COL.MUTE_ON,
        strip_w() - 12, 22) then
      master.muted = not master.muted
      apply_cue_master(cue.guid, model)
      set_status(master.muted and "Headphone muted." or "Headphone unmuted.")
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, "Mute / unmute the entire headphone mix")
    end
    reaper.ImGui_Spacing(ctx)

    -- Fader (no VU meter — master has no single source track to meter)
    local fader_x = math.floor((strip_w() - CFG.FADER_W) / 2)
    reaper.ImGui_SetCursorPosX(ctx, fader_x)
    local nn, fch = sk_fader(ctx, dl, "master"..cue.guid, CFG.FADER_W, fader_h,
      gain_to_norm(master.vol), col_fader_cap, col_accent)
    local disp = master.vol
    if fch then
      disp = norm_to_gain(nn)
      master.vol = disp
      apply_cue_master(cue.guid, model)
    end
    draw_db_entry_popup(ctx, "masterrst"..cue.guid, disp, function(g)
      disp = g
      master.vol = g
      apply_cue_master(cue.guid, model)
    end)

    -- Level in dB, centered below the fader
    local dbtxt = vol_to_db(disp).." dB"
    local dbtw  = reaper.ImGui_CalcTextSize(ctx, dbtxt)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
    reaper.ImGui_SetCursorPosX(ctx, math.floor((strip_w() - dbtw) / 2))
    reaper.ImGui_Text(ctx, dbtxt)
    reaper.ImGui_PopStyleColor(ctx, 1)

    -- No reorder arrows on MASTER (it's pinned first) — reserve the same
    -- row height so the strip's bottom still lines up with the others.
    reaper.ImGui_Dummy(ctx, strip_w(), ARROW_ROW_H)

    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 1)
end

-- =============================================================================
--  TOOLBAR (top of window)
-- =============================================================================

local function draw_topbar(ctx, cue_mgr, model)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), rgba(CFG.COL.TOPBAR_BG))
  if reaper.ImGui_BeginChild(ctx, "topbar", 0, CFG.TOPBAR_H, 0,
      reaper.ImGui_WindowFlags_NoScrollbar()) then

    reaper.ImGui_SetCursorPosY(ctx, 9)
    reaper.ImGui_SetCursorPosX(ctx, 8)
    PushFont(ctx, fontTitle, FONT_TITLE)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.ACCENT))
    reaper.ImGui_Text(ctx, "SK CUE BUS MANAGER")
    reaper.ImGui_PopStyleColor(ctx, 1)
    PopFont(ctx)
    reaper.ImGui_SameLine(ctx, 0, 20)
    reaper.ImGui_SetCursorPosY(ctx, 9)

    if colored_button(ctx, "+ New Cue", CFG.COL.ACCENT, CFG.COL.ACCENT_H, CFG.COL.ACCENT_A,
        0, 0, CFG.COL.INK) then
      UI.show_new_dlg = true
    end
    reaper.ImGui_SameLine(ctx, 0, 4)

    local has_cue = UI.selected_cue ~= nil and model.cue_buses[UI.selected_cue] ~= nil
    if not has_cue then reaper.ImGui_BeginDisabled(ctx) end

    if colored_button(ctx, "Duplicate", CFG.COL.STRIP_BG, CFG.COL.STRIP_SEL, CFG.COL.ACCENT) then
      local ng = cue_mgr:duplicate_cue_bus(UI.selected_cue)
      if ng then UI.selected_cue = ng; set_status("Cue duplicated.") end
    end
    reaper.ImGui_SameLine(ctx, 0, 4)
    if colored_button(ctx, "Delete", CFG.COL.REM_BTN, CFG.COL.REM_HOV, CFG.COL.DANGER) then
      cue_mgr:delete_cue_bus(UI.selected_cue)
      UI.selected_cue = nil
      set_status("Cue deleted.")
    end
    reaper.ImGui_SameLine(ctx, 0, 4)
    if not has_cue then reaper.ImGui_EndDisabled(ctx) end

    if colored_button(ctx, "Rescan", CFG.COL.STRIP_BG, CFG.COL.STRIP_SEL, CFG.COL.ACCENT2) then
      model:scan()
      cue_mgr:repair_cue_folder_structure()
      set_status("Rescan done.")
    end
    reaper.ImGui_SameLine(ctx, 0, 4)
    if colored_button(ctx, "Repair", CFG.COL.STRIP_BG, CFG.COL.STRIP_SEL, CFG.COL.ACCENT2) then
      cue_mgr:repair_project_structure()
      set_status("Structure repaired.")
    end
    reaper.ImGui_SameLine(ctx, 0, 14)

    -- Mute / Unmute all headphone mixes simultaneously
    local any_muted = false
    for _, cue in pairs(model.cue_buses) do
      if valid_track(cue.track) and get_cue_master(cue.guid).muted then
        any_muted = true; break
      end
    end
    local ma_col = any_muted and CFG.COL.MUTE_ON   or CFG.COL.MUTE_OFF
    local ma_hov = any_muted and CFG.COL.DANGER_H  or CFG.COL.TOGGLE_OFF_HOV
    local ma_lbl = any_muted and "UNMUTE ALL"      or "MUTE ALL"
    if colored_button(ctx, ma_lbl, ma_col, ma_hov, CFG.COL.MUTE_ON) then
      local new_state = not any_muted
      for _, cue in pairs(model.cue_buses) do
        if valid_track(cue.track) then
          get_cue_master(cue.guid).muted = new_state
          reaper.SetMediaTrackInfo_Value(cue.track, "B_MUTE", new_state and 1 or 0)
        end
      end
      set_status(new_state and "All headphones muted." or "All headphones unmuted.")
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, any_muted and "Unmute all headphones"
        or "Mute all headphones simultaneously")
    end

    -- Pre-fader metering toggle button (action 42076)
    reaper.ImGui_SameLine(ctx, 0, 14)
    local pre_fader_on = reaper.GetToggleCommandState(42076) == 1
    local pf_col = pre_fader_on and CFG.COL.ACCENT2   or CFG.COL.MUTE_OFF
    local pf_hov = pre_fader_on and CFG.COL.ACCENT2_H or CFG.COL.TOGGLE_OFF_HOV
    if colored_button(ctx, "VU PRE FDR", pf_col, pf_hov, CFG.COL.ACCENT2) then
      reaper.Main_OnCommand(42076, 0)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        pre_fader_on
        and "VU-meters: PRE-FADER signal (active)\nClick to switch to post-fader"
        or  "VU-meters: POST-FADER signal (active)\nClick to switch to pre-fader")
    end
    reaper.ImGui_SameLine(ctx, 0, 4)
    -- Strip width toggle + custom width input
    local sw_col = UI.strip_wide and CFG.COL.ACCENT2   or CFG.COL.MUTE_OFF
    local sw_hov = UI.strip_wide and CFG.COL.ACCENT2_H or CFG.COL.TOGGLE_OFF_HOV
    if colored_button(ctx, UI.strip_wide and "WIDE" or "wide",
        sw_col, sw_hov, CFG.COL.ACCENT2) then
      UI.strip_wide = not UI.strip_wide
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        UI.strip_wide
        and "Wide strip mode — click for normal (80px)"
        or  "Normal strip mode — click for wide")
    end
    if UI.strip_wide then
      reaper.ImGui_SameLine(ctx, 0, 4)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
      reaper.ImGui_Text(ctx, "px:")
      reaper.ImGui_PopStyleColor(ctx, 1)
      reaper.ImGui_SameLine(ctx, 0, 2)
      reaper.ImGui_SetNextItemWidth(ctx, 46)
      local ch_w, nw = reaper.ImGui_InputInt(ctx, "##stripw",
        UI.strip_custom_w, 0, 0)
      if ch_w then
        UI.strip_custom_w = math.max(80, math.min(300, nw))
        reaper.SetExtState("SK_CBM_UI", "strip_custom_w",
          tostring(UI.strip_custom_w), true)
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Strip width in wide mode (80–300 px)")
      end
    end

    -- Status message (disappears after 3 seconds)
    local elapsed = reaper.time_precise() - UI.status_time
    if elapsed < 3.0 and UI.status_msg ~= "" then
      reaper.ImGui_SameLine(ctx, 0, 16)
      local a = math.floor(clamp(1 - elapsed/3, 0, 1) * 255)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), (a << 24) | 0xD9A441)
      reaper.ImGui_Text(ctx, "✓ "..UI.status_msg)
      reaper.ImGui_PopStyleColor(ctx, 1)
    end

    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 1)
end

-- =============================================================================
--  CUE LIST (left column)
-- =============================================================================

local function draw_sidebar(ctx, cue_mgr, model)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), rgba(CFG.COL.SIDEBAR_BG))
  if reaper.ImGui_BeginChild(ctx, "sidebar", CFG.SIDEBAR_W, 0, 0) then

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
    reaper.ImGui_Text(ctx, "  HEADPHONES")
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    local cues = model:cue_list()
    if #cues == 0 then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
      reaper.ImGui_TextWrapped(ctx, "  No headphones.\n  [+ New Cue]")
      reaper.ImGui_PopStyleColor(ctx, 1)
    end

    for _, cue in ipairs(cues) do
      local is_sel = UI.selected_cue == cue.guid
      local is_ren = UI.rename_guid == cue.guid and not UI.rename_in_header

      -- Cue color indicator — always reserved (a neutral dot when no color
      -- is set) so the row stays aligned with colored cues.
      local native = reaper.GetTrackColor(cue.track)
      local col_btn = native ~= 0 and native_to_imgui(native) or rgba(CFG.COL.STRIP_SEL)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        col_btn)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), col_btn)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  col_btn)
      reaper.ImGui_Button(ctx, "##sb_col"..cue.guid, 8, 22)
      reaper.ImGui_PopStyleColor(ctx, 3)
      reaper.ImGui_SameLine(ctx, 0, 4)

      -- Stronger background for the active cue
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),
        is_sel and rgba(CFG.COL.CUE_SEL) or rgba(0))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), rgba(CFG.COL.CUE_HOVER))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),  rgba(CFG.COL.CUE_SEL))

      if is_ren then
        reaper.ImGui_SetNextItemWidth(ctx, CFG.SIDEBAR_W - 46)
        local ch, buf = reaper.ImGui_InputText(ctx, "##sbren"..cue.guid, UI.rename_buf,
          reaper.ImGui_InputTextFlags_EnterReturnsTrue() |
          reaper.ImGui_InputTextFlags_AutoSelectAll())
        if ch and buf ~= "" then
          cue_mgr:rename_cue_bus(cue.guid, buf)
          set_status("Renamed: "..buf)
        end
        if ch or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
          UI.rename_guid = nil
        end
      else
        local label = cue.name
        if cue.hw_l >= 0 then
          label = label.."\n  Out "..(cue.hw_l+1).."/"..(cue.hw_l+2)
        end
        local clicked = reaper.ImGui_Selectable(ctx, label.."##sb"..cue.guid, is_sel,
          reaper.ImGui_SelectableFlags_AllowDoubleClick(), CFG.SIDEBAR_W - 46, 34)
        if clicked then
          UI.selected_cue = cue.guid
          if reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
            UI.rename_guid      = cue.guid
            UI.rename_buf       = cue.name
            UI.rename_in_header = false
          end
        end

        -- Quick mute button in the list
        local sb_master = get_cue_master(cue.guid)
        reaper.ImGui_SameLine(ctx, 0, 4)
        local smc = sb_master.muted and CFG.COL.MUTE_ON or CFG.COL.MUTE_OFF
        local smh = sb_master.muted and CFG.COL.DANGER_H or CFG.COL.MUTE_OFF
        if colored_button(ctx, (sb_master.muted and "M" or "m").."##sbm"..cue.guid,
            smc, smh, CFG.COL.MUTE_ON, 20, 20) then
          sb_master.muted = not sb_master.muted
          if valid_track(cue.track) then
            reaper.SetMediaTrackInfo_Value(cue.track, "B_MUTE", sb_master.muted and 1 or 0)
          end
        end
        if reaper.ImGui_IsItemHovered(ctx) then
          reaper.ImGui_SetTooltip(ctx,
            sb_master.muted and "Headphone muted — click to unmute" or "Mute this headphone mix")
        end
      end

      reaper.ImGui_PopStyleColor(ctx, 3)
    end

    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 1)
end

-- =============================================================================
--  SELECTED CUE HEADER
-- =============================================================================

local function draw_cue_header(ctx, cue, cue_mgr, snap, model)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), rgba(0x22252AFF))
  if reaper.ImGui_BeginChild(ctx, "cue_hdr", 0, 50, 0,
      reaper.ImGui_WindowFlags_NoScrollbar()) then

    reaper.ImGui_SetCursorPosY(ctx, 8)
    reaper.ImGui_SetCursorPosX(ctx, 8)

    -- Color indicator — click to open the color picker
    local native = reaper.GetTrackColor(cue.track)
    if native ~= 0 then
      local col_btn = native_to_imgui(native)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        col_btn)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), col_btn)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  col_btn)
    else
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        rgba(CFG.COL.STRIP_BG))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), rgba(CFG.COL.STRIP_SEL))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  rgba(CFG.COL.STRIP_SEL))
    end
    if reaper.ImGui_Button(ctx, "##hdr_col"..cue.guid, 18, 22) then
      UI.color_popover = not UI.color_popover
      UI.color_cue     = cue.guid
    end
    reaper.ImGui_PopStyleColor(ctx, 3)
    if native == 0 then
      -- No color chosen yet — outline the swatch so it reads as a control,
      -- not just blank background.
      local dl = reaper.ImGui_GetWindowDrawList(ctx)
      local bx0, by0 = reaper.ImGui_GetItemRectMin(ctx)
      local bx1, by1 = reaper.ImGui_GetItemRectMax(ctx)
      reaper.ImGui_DrawList_AddRect(dl, bx0 + 0.5, by0 + 0.5, bx1 - 0.5, by1 - 0.5,
        rgba(CFG.COL.ACCENT), 3, 0, 1.5)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, "Change headphone color")
    end
    reaper.ImGui_SameLine(ctx, 0, 6)

    -- Color picker
    if UI.color_popover and UI.color_cue == cue.guid then
      reaper.ImGui_SetNextWindowSize(ctx, 310, 145, reaper.ImGui_Cond_Always())
      local col_visible, col_keep = reaper.ImGui_Begin(ctx, "Couleur##colpop", true,
        reaper.ImGui_WindowFlags_NoResize() | reaper.ImGui_WindowFlags_NoScrollbar())
      if not col_keep then UI.color_popover = false end
      if col_visible then
        reaper.ImGui_SetNextItemWidth(ctx, 220)
        local ch_pst, pst_val = reaper.ImGui_SliderDouble(
          ctx, "##pslider", UI.color_pastel_amt, 0.0, 100.0, "Pastel : %.0f%%")
        if ch_pst then UI.color_pastel_amt = pst_val end
        reaper.ImGui_Spacing(ctx)
        local amt = UI.color_pastel_amt / 100.0
        for i, pal in ipairs(CFG.PALETTE) do
          local r = math.floor(pal.r + (255-pal.r)*amt + 0.5)
          local g = math.floor(pal.g + (255-pal.g)*amt + 0.5)
          local b = math.floor(pal.b + (255-pal.b)*amt + 0.5)
          local col = (r<<24)|(g<<16)|(b<<8)|0xFF
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        col)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), col)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  col)
          if reaper.ImGui_Button(ctx, "##pal"..i, 24, 24) then
            reaper.SetMediaTrackInfo_Value(cue.track, "I_CUSTOMCOLOR",
              reaper.ColorToNative(r,g,b)|0x1000000)
            set_ext(cue.track, "SK_CBM_COLOR", r..","..g..","..b)
            UI.color_popover = false
          end
          reaper.ImGui_PopStyleColor(ctx, 3)
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, pal.label)
          end
          if i < #CFG.PALETTE then reaper.ImGui_SameLine(ctx, 0, 4) end
        end
        reaper.ImGui_Spacing(ctx)
        if colored_button(ctx, "Clear color",
            CFG.COL.STRIP_BG, CFG.COL.STRIP_SEL, CFG.COL.TEXT_DIM) then
          reaper.SetMediaTrackInfo_Value(cue.track, "I_CUSTOMCOLOR", 0)
          set_ext(cue.track, "SK_CBM_COLOR", "")
          UI.color_popover = false
        end
      end
      reaper.ImGui_End(ctx)
    end

    -- Headphone name — double-click to rename
    local is_ren = UI.rename_guid == cue.guid and UI.rename_in_header
    if is_ren then
      reaper.ImGui_SetNextItemWidth(ctx, 150)
      local ch, buf = reaper.ImGui_InputText(ctx, "##hdr_ren", UI.rename_buf,
        reaper.ImGui_InputTextFlags_EnterReturnsTrue() |
        reaper.ImGui_InputTextFlags_AutoSelectAll())
      if ch and buf ~= "" then
        cue_mgr:rename_cue_bus(cue.guid, buf)
        set_status("Renamed: "..buf)
      end
      if ch or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
        UI.rename_guid = nil
      end
    else
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_BRIGHT))
      reaper.ImGui_Text(ctx, cue.name)
      reaper.ImGui_PopStyleColor(ctx, 1)
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Double-click to rename")
      end
      if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
        UI.rename_guid      = cue.guid
        UI.rename_buf       = cue.name
        UI.rename_in_header = true
      end
    end
    reaper.ImGui_SameLine(ctx, 0, 12)

    -- Assigned hardware output
    local hw_lbl = cue.hw_l >= 0
      and ("Out "..(cue.hw_l+1).."/"..(cue.hw_l+2)) or "No HW Output"
    local hw_on  = cue.hw_l >= 0
    local hw_col = hw_on and CFG.COL.ACCENT2 or CFG.COL.TOGGLE_OFF
    local hw_txt = hw_on and CFG.COL.INK    or nil
    if colored_button(ctx, " "..hw_lbl.." ##hw", hw_col, CFG.COL.ACCENT2_H, CFG.COL.ACCENT2_A,
        0, 0, hw_txt) then
      UI.hw_out_dlg = true
      UI.hw_out_cue = cue.guid
      UI.hw_ch_sel  = math.max(0, cue.hw_l)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, "Hardware output for this headphone mix")
    end
    -- Open native REAPER routing window for this cue bus
    if colored_button(ctx, "I/O", CFG.COL.STRIP_BG, CFG.COL.STRIP_SEL, CFG.COL.ACCENT2) then
      reaper.SetOnlyTrackSelected(cue.track)
      reaper.Main_OnCommand(40293, 0) -- Track: View routing and I/O
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, "Open routing / I/O window for this cue bus")
    end
    reaper.ImGui_SameLine(ctx, 0, 10)

    if colored_button(ctx, "Copy from…", CFG.COL.STRIP_BG, CFG.COL.STRIP_SEL, CFG.COL.ACCENT) then
      UI.copy_from_dlg = true
    end
    reaper.ImGui_SameLine(ctx, 0, 4)
    if colored_button(ctx, "Reset", CFG.COL.REM_BTN, CFG.COL.REM_HOV, CFG.COL.DANGER) then
      cue_mgr:reset_cue(cue.guid)
      set_status("Mix reset.")
    end
    reaper.ImGui_SameLine(ctx, 0, 10)

    -- Snapshot A
    local has_a = snap:has(cue.guid, "A")
    if colored_button(ctx, has_a and "> A" or "@ A",
        has_a and CFG.COL.ACCENT or CFG.COL.STRIP_BG,
        CFG.COL.STRIP_SEL, CFG.COL.ACCENT, 0, 0, has_a and CFG.COL.INK or nil) then
      if has_a then snap:recall(cue.guid, "A"); set_status("Snapshot A recalled.")
      else           snap:save(cue.guid, "A");  set_status("Snapshot A saved.") end
    end
    if reaper.ImGui_IsItemClicked(ctx, 1) then
      snap:save(cue.guid, "A"); set_status("Snapshot A saved.")
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, "Left-click: save or recall\nRight-click: always save")
    end
    reaper.ImGui_SameLine(ctx, 0, 4)

    -- Snapshot B
    local has_b = snap:has(cue.guid, "B")
    if colored_button(ctx, has_b and "> B" or "@ B",
        has_b and CFG.COL.SNAP_B or CFG.COL.STRIP_BG,
        CFG.COL.STRIP_SEL, CFG.COL.SNAP_B, 0, 0, has_b and CFG.COL.INK or nil) then
      if has_b then snap:recall(cue.guid, "B"); set_status("Snapshot B recalled.")
      else           snap:save(cue.guid, "B");  set_status("Snapshot B saved.") end
    end
    if reaper.ImGui_IsItemClicked(ctx, 1) then
      snap:save(cue.guid, "B"); set_status("Snapshot B saved.")
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, "Left-click: save or recall\nRight-click: always save")
    end
    reaper.ImGui_SameLine(ctx, 0, 10)

    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 1)
end

-- =============================================================================
--  MAIN AREA: available tracks + headphone mix
-- =============================================================================

local function draw_main_zone(ctx, cue, cue_mgr, routing, snap, model)
  draw_cue_header(ctx, cue, cue_mgr, snap, model)
  reaper.ImGui_Separator(ctx)

  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)

  -- Left zone: tracks available to add to the headphone mix
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), rgba(CFG.COL.PANEL_BG))
  if reaper.ImGui_BeginChild(ctx, "zone_avail", CFG.AVAIL_W, avail_h - 4, 1) then

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
    reaper.ImGui_Text(ctx, "  AVAILABLE TRACKS")
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    if colored_button(ctx, "+ Add REAPER selection",
        CFG.COL.ADD_BTN, CFG.COL.ADD_HOV, CFG.COL.ACCENT2, CFG.AVAIL_W - 10, 0) then
      local n = cue_mgr:add_selected_tracks_to_cue(cue.guid)
      set_status(n.." piste(s) added.")
    end
    reaper.ImGui_Spacing(ctx)

    local available = model:sources_not_in_cue(cue.guid, routing)
    if #available == 0 then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
      reaper.ImGui_Text(ctx, "  (all tracks\n   are in this headphone mix)")
      reaper.ImGui_PopStyleColor(ctx, 1)
    end

    for _, src in ipairs(available) do
      local base = (src.color and src.color ~= 0) and native_to_imgui(src.color) or CFG.COL.ADD_BTN
      if colored_button(ctx, "+##add"..src.guid,
          base, lighten(base, 0.25), lighten(base, 0.4), 22, 20, text_on(base)) then
        routing:add_track_to_cue(cue.guid, src)
        set_status("Added: "..src.name)
      end
      reaper.ImGui_SameLine(ctx, 0, 4)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_LABEL))
      reaper.ImGui_Text(ctx, src.name)
      reaper.ImGui_PopStyleColor(ctx, 1)
    end

    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SameLine(ctx, 0, 4)

  -- Right zone: headphone mix with faders
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), rgba(CFG.COL.BG))
  if reaper.ImGui_BeginChild(ctx, "zone_mix", avail_w - CFG.AVAIL_W - 4, avail_h - 4, 0,
      reaper.ImGui_WindowFlags_HorizontalScrollbar()) then

    local in_cue = ordered_sources_in_cue(cue, routing, model)

    if #in_cue == 0 then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
      reaper.ImGui_TextWrapped(ctx,
        "No tracks in this headphone mix.\n\n"..
        "Add tracks from the\n"..
        "\"Available tracks\" zone on the left.")
      reaper.ImGui_PopStyleColor(ctx, 1)
    else
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
      reaper.ImGui_Text(ctx, "  MIX — "..#in_cue.." track(s)   (double-click fader/pan = reset)")
      reaper.ImGui_PopStyleColor(ctx, 1)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Spacing(ctx)

      -- Fader height: fill the remaining height exactly, so the strips'
      -- bottom aligns with the "Available tracks" panel next to them. Must
      -- stay in sync with the strip_h = fader_h + 150 + ARROW_ROW_H used
      -- in the strips.
      local _, mix_avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
      local fader_h = math.max(60, mix_avail_h - 150 - ARROW_ROW_H)

      draw_master_strip(ctx, cue, model, fader_h)
      reaper.ImGui_SameLine(ctx, 0, 16)

      local removed, move_req = nil, nil
      for i, src in ipairs(in_cue) do
        local src_ref = src
        draw_fader_strip(ctx, cue.guid, src, routing, fader_h, function()
          removed = src_ref
        end, i > 1, i < #in_cue, function(dir)
          move_req = { guid = src_ref.guid, dir = dir }
        end)
        if i < #in_cue then reaper.ImGui_SameLine(ctx, 0, CFG.STRIP_PAD) end
      end
      if removed then
        routing:remove_track_from_cue(cue.guid, removed)
        set_status("Removed: "..removed.name)
      end
      if move_req then
        move_track_in_cue(cue, routing, model, move_req.guid, move_req.dir)
      end
    end

    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 1)
end

-- =============================================================================
--  WELCOME SCREEN
-- =============================================================================

local function draw_welcome(ctx)
  local w, h = reaper.ImGui_GetContentRegionAvail(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), rgba(CFG.COL.PANEL_BG))
  if reaper.ImGui_BeginChild(ctx, "welcome", w, h, 0) then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_SetCursorPosX(ctx, 20)
    PushFont(ctx, fontTitle, FONT_TITLE)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.ACCENT))
    reaper.ImGui_Text(ctx, "HEADPHONES MONITORING")
    reaper.ImGui_PopStyleColor(ctx, 1)
    PopFont(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    local lines = {
      "QUICK START",
      "",
      "1.  Click [+ New Cue] to create a headphone mix.",
      "    Choose its color and hardware output at creation.",
      "",
      "2.  Select the headphone mix in the left list.",
      "",
      "3.  In 'Available tracks':",
      "      [+]  add a track to this headphone mix",
      "      [+ Add REAPER selection]  add the selected tracks",
      "",
      "4.  Mix in the right area:",
      "      Vertical fader       drag = volume (double-click: reset to 0 dB)",
      "      Pan knob             drag = pan (double-click: center)",
      "      MUTE                 mute this track in this headphone mix",
      "      [x]                  remove track from headphone mix (top-right of strip)",
      "      Master               global headphone volume",
      "",
      "SNAPSHOTS A / B",
      "      Left-click: save if empty, recall if existing",
      "      Right-click: always save",
      "",
      "MUTE ALL",
      "      Mutes or unmutes all headphone mixes simultaneously.",
      "",
      "REPAIR",
      "      If the script seems out of sync with REAPER, click Repair.",
    }
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_LABEL))
    for _, l in ipairs(lines) do
      reaper.ImGui_SetCursorPosX(ctx, 20)
      reaper.ImGui_Text(ctx, l)
    end
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 1)
end

-- =============================================================================
--  SECONDARY DIALOGS
-- =============================================================================

local function draw_new_cue_dialog(ctx, cue_mgr, model, routing)
  if not UI.show_new_dlg then return end
  reaper.ImGui_SetNextWindowSize(ctx, 360, 210, reaper.ImGui_Cond_Always())
  local open, keep = reaper.ImGui_Begin(ctx, "New headphone mix##newdlg", true,
    reaper.ImGui_WindowFlags_NoResize())
  if not keep then UI.show_new_dlg = false end
  if not open then return end

  reaper.ImGui_Text(ctx, "Name:")
  reaper.ImGui_SameLine(ctx, 0, 6)
  reaper.ImGui_SetNextItemWidth(ctx, 240)
  local ch, buf = reaper.ImGui_InputText(ctx, "##newname", UI.new_name_buf,
    reaper.ImGui_InputTextFlags_AutoSelectAll())
  if ch then UI.new_name_buf = buf end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Color picker
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
  reaper.ImGui_Text(ctx, "Color:")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SameLine(ctx, 0, 6)
  reaper.ImGui_SetNextItemWidth(ctx, 160)
  local ch_pst, pst_val = reaper.ImGui_SliderDouble(
    ctx, "##npslider", UI.new_pastel_amt, 0.0, 100.0, "Pastel : %.0f%%")
  if ch_pst then UI.new_pastel_amt = pst_val end
  reaper.ImGui_Spacing(ctx)

  local amt    = UI.new_pastel_amt / 100.0
  local no_col = UI.new_col_r == -1
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
    no_col and rgba(CFG.COL.MUTE_OFF) or rgba(CFG.COL.STRIP_BG))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), rgba(CFG.COL.TOGGLE_OFF_HOV))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  rgba(CFG.COL.TOGGLE_OFF_HOV))
  if reaper.ImGui_Button(ctx, no_col and "x##nc" or " ##nc", 24, 24) then
    UI.new_col_r = -1; UI.new_col_g = -1; UI.new_col_b = -1
  end
  reaper.ImGui_PopStyleColor(ctx, 3)
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, "No color")
  end
  reaper.ImGui_SameLine(ctx, 0, 6)

  for i, pal in ipairs(CFG.PALETTE) do
    local r = math.floor(pal.r + (255-pal.r)*amt + 0.5)
    local g = math.floor(pal.g + (255-pal.g)*amt + 0.5)
    local b = math.floor(pal.b + (255-pal.b)*amt + 0.5)
    local col    = (r<<24)|(g<<16)|(b<<8)|0xFF
    local is_sel = (UI.new_col_r == r and UI.new_col_g == g and UI.new_col_b == b)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        col)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), col)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  col)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),
      is_sel and rgba(0xFFFFFFFF) or rgba(0x00000000))
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), is_sel and 2.0 or 0.0)
    if reaper.ImGui_Button(ctx, "##npal"..i, 24, 24) then
      UI.new_col_r = r; UI.new_col_g = g; UI.new_col_b = b
    end
    reaper.ImGui_PopStyleVar(ctx, 1)
    reaper.ImGui_PopStyleColor(ctx, 4)
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, pal.label)
    end
    if i < #CFG.PALETTE then reaper.ImGui_SameLine(ctx, 0, 4) end
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Hardware output
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
  reaper.ImGui_Text(ctx, "HW Output:")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SameLine(ctx, 0, 6)
  local hw_opts = get_hw_out_options()
  reaper.ImGui_SetNextItemWidth(ctx, 200)
  if reaper.ImGui_BeginCombo(ctx, "##newhw", hw_opts[UI.new_hw_ch+1] or "None") then
    for i, opt in ipairs(hw_opts) do
      if reaper.ImGui_Selectable(ctx, opt, (i-1)==UI.new_hw_ch) then
        UI.new_hw_ch = i-1
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  reaper.ImGui_Spacing(ctx)

  if colored_button(ctx, " Create ", CFG.COL.ACCENT, CFG.COL.ACCENT_H, CFG.COL.ACCENT_A,
      120, 28, CFG.COL.INK) then
    if UI.new_name_buf ~= "" then
      local g   = cue_mgr:create_cue_bus(UI.new_name_buf)
      local cue = model.cue_buses[g]
      if cue and UI.new_col_r >= 0 then
        reaper.SetMediaTrackInfo_Value(cue.track, "I_CUSTOMCOLOR",
          reaper.ColorToNative(UI.new_col_r, UI.new_col_g, UI.new_col_b)|0x1000000)
      end
      if cue and UI.new_hw_ch > 0 then
        local ch_hw = (UI.new_hw_ch-1)*2
        routing:set_hw_out(g, ch_hw)
        cue.hw_l = ch_hw
      end
      UI.selected_cue = g
      set_status("Headphone mix created: "..UI.new_name_buf)
      local n = 0
      for _ in pairs(model.cue_buses) do n = n+1 end
      UI.new_name_buf = "Cue "..(n+1)
      UI.new_col_r    = -1
      UI.new_hw_ch    = 0
      UI.show_new_dlg = false
    end
  end
  reaper.ImGui_SameLine(ctx, 0, 8)
  if colored_button(ctx, " Cancel ", CFG.COL.STRIP_BG, CFG.COL.STRIP_SEL,
      CFG.COL.TEXT_DIM, 100, 28) then
    UI.show_new_dlg = false
  end

  reaper.ImGui_End(ctx)
end

local function draw_copy_from_dialog(ctx, cue_mgr, model)
  if not UI.copy_from_dlg or not UI.selected_cue then return end

  -- Size the window to the actual content: title/header chrome + one row
  -- per selectable cue + the Cancel button, instead of a fixed guess.
  local other_count = 0
  for _, cue in ipairs(model:cue_list()) do
    if cue.guid ~= UI.selected_cue then other_count = other_count + 1 end
  end
  local win_w = 260
  local win_h = clamp(70 + math.max(other_count, 1) * 22 + 46, 150, 420)
  reaper.ImGui_SetNextWindowSize(ctx, win_w, win_h, reaper.ImGui_Cond_Always())

  local open, keep = reaper.ImGui_Begin(ctx, "Copy mix from…##cpydlg", true,
    reaper.ImGui_WindowFlags_NoResize())
  if not keep then UI.copy_from_dlg = false end
  if open then
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    reaper.ImGui_Text(ctx, "Choose source:")
    reaper.ImGui_Spacing(ctx)
    if other_count == 0 then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
      reaper.ImGui_Text(ctx, "(no other headphone mix)")
      reaper.ImGui_PopStyleColor(ctx, 1)
    end
    for _, cue in ipairs(model:cue_list()) do
      if cue.guid ~= UI.selected_cue then
        local native = reaper.GetTrackColor(cue.track)
        local swatch = native ~= 0 and native_to_imgui(native) or CFG.COL.STRIP_SEL
        local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
        local r = 5
        reaper.ImGui_DrawList_AddCircleFilled(dl, cx + r, cy + 9, r, rgba(swatch), 16)
        reaper.ImGui_DrawList_AddCircle(dl, cx + r, cy + 9, r, rgba(0x00000099), 16, 1)
        reaper.ImGui_Dummy(ctx, r * 2 + 6, 18)
        reaper.ImGui_SameLine(ctx, 0, 2)
        if reaper.ImGui_Selectable(ctx, cue.name.."##cp"..cue.guid, false) then
          cue_mgr:copy_mix(cue.guid, UI.selected_cue)
          set_status("Mix copied from "..cue.name)
          UI.copy_from_dlg = false
        end
      end
    end
    reaper.ImGui_Spacing(ctx)
    if colored_button(ctx, " Cancel ", CFG.COL.STRIP_BG, CFG.COL.STRIP_SEL,
        CFG.COL.TEXT_DIM, 100, 28) then
      UI.copy_from_dlg = false
    end
    reaper.ImGui_End(ctx)
  end
end

local function draw_hw_out_dialog(ctx, routing, model)
  if not UI.hw_out_dlg or not UI.hw_out_cue then return end
  reaper.ImGui_SetNextWindowSize(ctx, 260, 200, reaper.ImGui_Cond_Always())
  local open, keep = reaper.ImGui_Begin(ctx, "Hardware output##hwdlg", true,
    reaper.ImGui_WindowFlags_NoResize())
  if not keep then UI.hw_out_dlg = false end
  if open then
    reaper.ImGui_Text(ctx, "Stereo output pair:")
    reaper.ImGui_Spacing(ctx)
    local opts = get_hw_out_options()
    opts[1] = "None (disabled)"
    reaper.ImGui_SetNextItemWidth(ctx, 230)
    if reaper.ImGui_BeginCombo(ctx, "##hwcombo", opts[UI.hw_ch_sel+1] or "None") then
      for i, opt in ipairs(opts) do
        if reaper.ImGui_Selectable(ctx, opt, (i-1)==UI.hw_ch_sel) then
          UI.hw_ch_sel = i-1
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    reaper.ImGui_Spacing(ctx)
    if colored_button(ctx, " Apply ", CFG.COL.ACCENT2, CFG.COL.ACCENT2_H, CFG.COL.ACCENT2_A,
        110, 26, CFG.COL.INK) then
      local ch = UI.hw_ch_sel == 0 and -1 or (UI.hw_ch_sel-1)*2
      routing:set_hw_out(UI.hw_out_cue, ch)
      local cue = model.cue_buses[UI.hw_out_cue]
      if cue then cue.hw_l = ch end
      set_status("Hardware output updated.")
      UI.hw_out_dlg = false
    end
    reaper.ImGui_SameLine(ctx)
    if colored_button(ctx, " Cancel ", CFG.COL.STRIP_BG, CFG.COL.STRIP_SEL,
        CFG.COL.TEXT_DIM, 100, 26) then
      UI.hw_out_dlg = false
    end
    reaper.ImGui_End(ctx)
  end
end

-- =============================================================================
--  GLOBAL INTERFACE STYLE
-- =============================================================================

-- Full Studio Kozak theme pushed globally so that built-in widgets
-- (combos, inputs, sliders, checkboxes, popups) inherit the house style.
local THEME_COLORS = {
  { reaper.ImGui_Col_WindowBg(),         CFG.COL.BG          },
  { reaper.ImGui_Col_PopupBg(),          0x24272CFF          },
  { reaper.ImGui_Col_Text(),             CFG.COL.TEXT_BRIGHT },
  { reaper.ImGui_Col_TextDisabled(),     CFG.COL.TEXT_DIM    },
  { reaper.ImGui_Col_FrameBg(),          0x2A2D33FF          },
  { reaper.ImGui_Col_FrameBgHovered(),   0x353942FF          },
  { reaper.ImGui_Col_FrameBgActive(),    0x3E434DFF          },
  { reaper.ImGui_Col_Button(),           CFG.COL.MUTE_OFF    },
  { reaper.ImGui_Col_ButtonHovered(),    CFG.COL.STRIP_SEL   },
  { reaper.ImGui_Col_ButtonActive(),     0x474D58FF          },
  { reaper.ImGui_Col_CheckMark(),        CFG.COL.ACCENT      },
  { reaper.ImGui_Col_SliderGrab(),       CFG.COL.ACCENT      },
  { reaper.ImGui_Col_SliderGrabActive(), CFG.COL.ACCENT_H    },
  { reaper.ImGui_Col_Header(),           0x33373FFF          },
  { reaper.ImGui_Col_HeaderHovered(),    0x3F444EFF          },
  { reaper.ImGui_Col_HeaderActive(),     0x4A505BFF          },
  { reaper.ImGui_Col_Separator(),        CFG.COL.SEP         },
  { reaper.ImGui_Col_Border(),           0x35393FFF          },
  { reaper.ImGui_Col_TitleBg(),          CFG.COL.TOPBAR_BG   },
  { reaper.ImGui_Col_TitleBgActive(),    0x24272CFF          },
  { reaper.ImGui_Col_ScrollbarBg(),      CFG.COL.SIDEBAR_BG  },
  { reaper.ImGui_Col_ScrollbarGrab(),    0x474D58FF          },
}

local function push_style(ctx)
  for _, c in ipairs(THEME_COLORS) do
    reaper.ImGui_PushStyleColor(ctx, c[1], rgba(c[2]))
  end
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 6)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(),  6)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),  5)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_GrabRounding(),   5)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_PopupRounding(),  6)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),    4, 4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),  6, 6)
  return #THEME_COLORS, 7
end

local function pop_style(ctx, nc, nv)
  reaper.ImGui_PopStyleColor(ctx, nc)
  reaper.ImGui_PopStyleVar(ctx, nv)
end

-- =============================================================================
--  INITIALIZATION AND MAIN LOOP
-- =============================================================================

-- Minimum window width: guarantees the MASTER strip plus 8 track strips (at
-- normal, non-wide width) are visible together without horizontal scrolling.
local MIN_STRIPS_VISIBLE = 4
local MIN_MIX_ZONE_W = 80                                 -- MASTER strip
                     + 16                                 -- gap after MASTER
                     + MIN_STRIPS_VISIBLE * 80             -- track strips
                     + (MIN_STRIPS_VISIBLE - 1) * CFG.STRIP_PAD
                     + 24                                  -- child padding + scrollbar margin
local MIN_WINDOW_W = CFG.SIDEBAR_W + 1 + CFG.AVAIL_W + 4 + MIN_MIX_ZONE_W + 20

local ctx = reaper.ImGui_CreateContext(CFG.SCRIPT_NAME)
reaper.ImGui_Attach(ctx, fontBody)
reaper.ImGui_Attach(ctx, fontTitle)

local model        = ProjectModel.new()
local routing      = RoutingEngine.new(model)
local cue_mgr      = CueManager.new(model, routing)
local snap         = SnapSystem.new(model, routing)

model:scan()
cue_mgr:repair_cue_folder_structure()

-- Restore strip width preference from previous session
local _saved_w = tonumber(reaper.GetExtState("SK_CBM_UI", "strip_custom_w"))
if _saved_w then
  UI.strip_custom_w = math.max(80, math.min(300, _saved_w))
end

local open = true
-- Automatic project change detection
-- REAPER increments this counter on every modification (track added,
-- deleted, renamed...). Compared each frame to trigger auto-rescan.
local last_project_state = reaper.GetProjectStateChangeCount(0)

local function loop()
  if not open then return end

  -- Auto-rescan when the project changes
  local current_state = reaper.GetProjectStateChangeCount(0)
  if current_state ~= last_project_state then
    last_project_state = current_state
    model:scan()
    routing:invalidate_cache()
    cue_mgr:repair_cue_folder_structure()
    -- Check that the selected cue still exists
    if UI.selected_cue and not model.cue_buses[UI.selected_cue] then
      UI.selected_cue = nil
    end
  end

  local nc, nv = push_style(ctx)
  PushFont(ctx, fontBody, FONT_BODY)
  reaper.ImGui_SetNextWindowSize(ctx, CFG.WINDOW_W, CFG.WINDOW_H, reaper.ImGui_Cond_FirstUseEver())
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, MIN_WINDOW_W, 400, 1000000, 1000000)
  -- The title bar's collapse/close buttons are drawn inside Begin() itself
  -- and use the generic Button colors, so give those visible hover/active
  -- feedback here (same amber as the "+ New Cue" button) before Begin runs.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        rgba(CFG.COL.MUTE_OFF))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), rgba(CFG.COL.ACCENT_H))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  rgba(CFG.COL.ACCENT_A))
  local visible, keep = reaper.ImGui_Begin(ctx,
    CFG.SCRIPT_NAME, true,
    reaper.ImGui_WindowFlags_NoScrollbar() |
    reaper.ImGui_WindowFlags_NoScrollWithMouse())
  reaper.ImGui_PopStyleColor(ctx, 3)
  if not keep then open = false end

  if visible then
    draw_topbar(ctx, cue_mgr, model)

    local content_h = select(2, reaper.ImGui_GetContentRegionAvail(ctx))

    draw_sidebar(ctx, cue_mgr, model)
    reaper.ImGui_SameLine(ctx, 0, 0)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), rgba(CFG.COL.SEP))
    if reaper.ImGui_BeginChild(ctx, "vsep", 1, content_h, 0) then
      reaper.ImGui_EndChild(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_SameLine(ctx, 0, 0)

    local main_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), rgba(CFG.COL.BG))
    if reaper.ImGui_BeginChild(ctx, "main", main_w, content_h, 0) then
      local cue = UI.selected_cue and model.cue_buses[UI.selected_cue]
      if cue then
        draw_main_zone(ctx, cue, cue_mgr, routing, snap, model)
      else
        draw_welcome(ctx)
      end
      reaper.ImGui_EndChild(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx, 1)

    reaper.ImGui_End(ctx)
  end

  draw_new_cue_dialog(ctx, cue_mgr, model, routing)
  draw_copy_from_dialog(ctx, cue_mgr, model)
  draw_hw_out_dialog(ctx, routing, model)

  PopFont(ctx)
  pop_style(ctx, nc, nv)

  if open then reaper.defer(loop) end
end

reaper.defer(loop)
