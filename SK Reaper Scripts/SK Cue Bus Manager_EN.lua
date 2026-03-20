-- =============================================================================
--  SK Cue Bus Manager  v1.0
--  Studio Kozak — https://github.com/StudioKozak
-- =============================================================================
--
--  Integrated headphone monitoring console for REAPER.
--  Creates and manages independent headphone mixes for each musician,
--  directly from a dedicated interface without using native REAPER routing.
--
--  Requirement: ReaImGui (install via ReaPack)
--
--  QUICK START
--  ─────────────────
--  1. Click [+ New Cue] to create a headphone mix.
--     Choose its color and hardware output in the creation dialog.
--
--  2. Select the cue in the left list.
--
--  3. In "Available tracks", click [+] to send a track to the headphone mix.
--     Or select tracks in REAPER and click [+ Add REAPER selection].
--
--  4. Mix in the right area:
--     - Vertical fader     : individual volume (right-click = reset / cut)
--     - Horizontal slider : pan (right-click = center)
--     - MUTE              : mute this track in this headphone mix
--     - [x]               : remove track from headphone mix
--     - Master            : global headphone volume, independent of individual faders
--
--  SNAPSHOTS A / B
--  ───────────────
--  Each headphone mix has two mix snapshots.
--  Left-click : save if empty, recall if existing.
--  Right-click : always save (overwrites existing snapshot).
--
--  STRIP COLORS
--  ────────────────────
--  Strips automatically inherit the color assigned
--  to each track in REAPER. No setup required.
--
--  VU-METERS
--  ──────────
--  Each strip shows a stereo L/R VU-meter, post-fader.
--  Blue < -18 dBFS · Green -18 to -12 · Yellow -12 to -6 · Orange -6 to 0 · Red > 0
--  A bright red bar at the top signals a recent clip (2 seconds).
--
--  REPAIR
--  ──────
--  If something seems out of sync between the script and REAPER,
--  click [Repair] to restore everything automatically.
--
-- =============================================================================

-- Check that ReaImGui is installed
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
  VERSION     = "1.0",
  WINDOW_W    = 1200,
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

  COL = {
    BG          = 0x1A1A1EFF,
    SIDEBAR_BG  = 0x141418FF,
    TOPBAR_BG   = 0x0E0E12FF,
    PANEL_BG    = 0x18181EFF,
    STRIP_BG    = 0x222228FF,
    STRIP_MUTED = 0x1C1420FF,
    FADER_RAIL  = 0x2A2A36FF,
    FADER_GRAB  = 0x5A8FE0FF,
    FADER_MUTED = 0x804040FF,
    MUTE_ON     = 0xC04040FF,
    MUTE_OFF    = 0x363648FF,
    ACCENT      = 0x5A8FE0FF,
    ACCENT2     = 0x40C8A0FF,
    DANGER      = 0xC03030FF,
    TEXT_DIM    = 0x808090FF,
    TEXT_BRIGHT = 0xE8E8F0FF,
    TEXT_LABEL  = 0xAABBCCFF,
    SEP         = 0x303040FF,
    CUE_SEL     = 0x2E3D5AFF,
    CUE_HOVER   = 0x242434FF,
    STRIP_SEL   = 0x2A2A36FF,
    SNAP_B      = 0xD4A020FF,
    VU_BLUE     = 0x4080C0FF,
    VU_GREEN    = 0x30C060FF,
    VU_YELLOW   = 0xD4C020FF,
    VU_ORANGE   = 0xE07020FF,
    VU_CLIP     = 0xC02020FF,
    VU_CLIP_IND = 0xFF2020FF,
    VU_BG       = 0x141418FF,
    ADD_BTN     = 0x284828FF,
    ADD_HOV     = 0x3A6A3AFF,
    REM_BTN     = 0x482828FF,
    REM_HOV     = 0x6A3A3AFF,
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

local function rgba(hex) return hex end

local function colored_button(ctx, label, cn, ch, ca, w, h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        cn)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), ch)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  ca)
  local clicked = reaper.ImGui_Button(ctx, label, w or 0, h or 0)
  reaper.ImGui_PopStyleColor(ctx, 3)
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
  status_msg       = "",
  status_time      = 0,
}

local function set_status(msg)
  UI.status_msg  = msg
  UI.status_time = reaper.time_precise()
end

-- Global volume and mute for a cue (independent of individual faders)
local function get_cue_master(cue_guid)
  if not UI.cue_master[cue_guid] then
    UI.cue_master[cue_guid] = { vol = 1.0, muted = false }
  end
  return UI.cue_master[cue_guid]
end

-- Applies global volume and mute directly on the cue bus track
local function apply_cue_master(cue_guid, model)
  local m   = get_cue_master(cue_guid)
  local cue = model.cue_buses[cue_guid]
  if not cue or not valid_track(cue.track) then return end
  reaper.SetMediaTrackInfo_Value(cue.track, "B_MUTE", m.muted and 1 or 0)
  reaper.SetMediaTrackInfo_Value(cue.track, "D_VOL",  m.vol)
end

-- =============================================================================
--  VU-METER
--  Stereo L/R post-fader display with 5 color zones.
--  A red indicator at the top signals a recent clip (2 seconds).
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

local function draw_vu_meter(ctx, track, h, vol_scale, src_guid)
  if not valid_track(track) then return end
  vol_scale = vol_scale or 1.0
  src_guid  = src_guid  or ""

  local peak_l = reaper.Track_GetPeakInfo(track, 0) * vol_scale
  local peak_r = reaper.Track_GetPeakInfo(track, 1) * vol_scale

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
  reaper.ImGui_DrawList_AddLine(dl, cx, y_0db, cx+total_w, y_0db, rgba(0x80808060), 1)

  reaper.ImGui_Dummy(ctx, total_w, h)
end

-- =============================================================================
--  TOOLBAR (top of window)
-- =============================================================================

local function draw_topbar(ctx, cue_mgr, model)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), rgba(CFG.COL.TOPBAR_BG))
  if reaper.ImGui_BeginChild(ctx, "topbar", 0, CFG.TOPBAR_H, 0,
      reaper.ImGui_WindowFlags_NoScrollbar()) then

    reaper.ImGui_SetCursorPosY(ctx, 7)
    reaper.ImGui_SetCursorPosX(ctx, 8)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.ACCENT))
    reaper.ImGui_Text(ctx, "SK CUE BUS MANAGER  v"..CFG.VERSION)
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_SameLine(ctx, 0, 20)

    if colored_button(ctx, "+ New Cue", CFG.COL.ACCENT, 0x7AAFFFFF, 0x3A6FC0FF) then
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
    local ma_col = any_muted and CFG.COL.MUTE_ON  or CFG.COL.MUTE_OFF
    local ma_hov = any_muted and 0xD05050FF        or 0x505068FF
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

    -- Status message (disappears after 3 seconds)
    local elapsed = reaper.time_precise() - UI.status_time
    if elapsed < 3.0 and UI.status_msg ~= "" then
      reaper.ImGui_SameLine(ctx, 0, 16)
      local a = math.floor(clamp(1 - elapsed/3, 0, 1) * 255)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), (a << 24) | 0x40C8A0)
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
      reaper.ImGui_TextWrapped(ctx, "  Aucun casque.\n  [+ New Cue]")
      reaper.ImGui_PopStyleColor(ctx, 1)
    end

    for _, cue in ipairs(cues) do
      local is_sel = UI.selected_cue == cue.guid
      local is_ren = UI.rename_guid == cue.guid and not UI.rename_in_header

      -- Cue color indicator
      local native = reaper.GetTrackColor(cue.track)
      if native ~= 0 then
        local col_btn = native_to_imgui(native)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        col_btn)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), col_btn)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  col_btn)
        reaper.ImGui_Button(ctx, "##sb_col"..cue.guid, 8, 22)
        reaper.ImGui_PopStyleColor(ctx, 3)
        reaper.ImGui_SameLine(ctx, 0, 4)
      end

      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),
        is_sel and rgba(CFG.COL.CUE_SEL) or rgba(0))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), rgba(CFG.COL.CUE_HOVER))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),  rgba(CFG.COL.CUE_HOVER))

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
        local smh = sb_master.muted and 0xD05050FF or 0x404050FF
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
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), rgba(0x1C1C24FF))
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
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, "Change headphone color")
    end
    reaper.ImGui_SameLine(ctx, 0, 6)

    -- Color picker
    if UI.color_popover and UI.color_cue == cue.guid then
      reaper.ImGui_SetNextWindowSize(ctx, 310, 105, reaper.ImGui_Cond_Always())
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
    local hw_col = cue.hw_l >= 0 and CFG.COL.ACCENT2 or 0x505060FF
    if colored_button(ctx, " "..hw_lbl.." ##hw", hw_col, 0x50D0A0FF, 0x30A080FF) then
      UI.hw_out_dlg = true
      UI.hw_out_cue = cue.guid
      UI.hw_ch_sel  = math.max(0, cue.hw_l)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, "Hardware output for this headphone mix")
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
        CFG.COL.STRIP_SEL, CFG.COL.ACCENT) then
      if has_a then snap:recall(cue.guid, "A"); set_status("Snapshot A recalled.")
      else           snap:save(cue.guid, "A");  set_status("Snapshot A saved.") end
    end
    if reaper.ImGui_IsItemClicked(ctx, 1) then
      snap:save(cue.guid, "A"); set_status("Snapshot A saved.")
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, "Clic gauche : sauvegarder ou rappeler\nClic droit : toujours sauvegarder")
    end
    reaper.ImGui_SameLine(ctx, 0, 4)

    -- Snapshot B
    local has_b = snap:has(cue.guid, "B")
    if colored_button(ctx, has_b and "> B" or "@ B",
        has_b and CFG.COL.SNAP_B or CFG.COL.STRIP_BG,
        CFG.COL.STRIP_SEL, CFG.COL.SNAP_B) then
      if has_b then snap:recall(cue.guid, "B"); set_status("Snapshot B recalled.")
      else           snap:save(cue.guid, "B");  set_status("Snapshot B saved.") end
    end
    if reaper.ImGui_IsItemClicked(ctx, 1) then
      snap:save(cue.guid, "B"); set_status("Snapshot B saved.")
    end
    reaper.ImGui_SameLine(ctx, 0, 10)

    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 1)
end

-- =============================================================================
--  FADER STRIP (one per track in the mix)
-- =============================================================================

local function draw_fader_strip(ctx, cue_guid, src, routing, fader_h, on_remove)
  local vol   = routing:get_vol(cue_guid, src)
  local pan   = routing:get_pan(cue_guid, src)
  local muted = routing:get_mute(cue_guid, src)
  local sid   = cue_guid..src.guid

  -- Strip color derived from the track color in REAPER
  local track_col = valid_track(src.track) and reaper.GetTrackColor(src.track) or 0
  local has_color = track_col ~= 0
  local col_bg, col_fader_grab, col_accent_dim

  if has_color then
    local r, g, b = reaper.ColorFromNative(track_col)
    local br = math.floor(r * 0.18 + 26)
    local bg_ = math.floor(g * 0.18 + 26)
    local bb  = math.floor(b * 0.18 + 26)
    col_bg = muted
      and ((math.floor(r*0.10+20)<<24)|(math.floor(g*0.06+18)<<16)|(math.floor(b*0.10+22)<<8)|0xFF)
      or  ((br<<24)|(bg_<<16)|(bb<<8)|0xFF)
    local sat = muted and 0.45 or 0.85
    col_fader_grab = (math.floor(r*sat+255*(1-sat)*0.3)<<24)
                   | (math.floor(g*sat+255*(1-sat)*0.3)<<16)
                   | (math.floor(b*sat+255*(1-sat)*0.3)<<8)
                   | 0xFF
    col_accent_dim = (math.floor(r*0.7+80)<<24)
                   | (math.floor(g*0.7+80)<<16)
                   | (math.floor(b*0.7+80)<<8)
                   | 0xFF
  else
    col_bg         = muted and rgba(CFG.COL.STRIP_MUTED) or rgba(CFG.COL.STRIP_BG)
    col_fader_grab = muted and rgba(CFG.COL.FADER_MUTED) or rgba(CFG.COL.FADER_GRAB)
    col_accent_dim = rgba(CFG.COL.TEXT_LABEL)
  end

  local strip_h = fader_h + 130
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), col_bg)
  if reaper.ImGui_BeginChild(ctx, "strip"..sid, CFG.STRIP_W, strip_h, 1,
      reaper.ImGui_WindowFlags_NoScrollbar() |
      reaper.ImGui_WindowFlags_NoScrollWithMouse()) then

    -- Remove button + track name
    local name = src.name
    if #name > 7 then name = name:sub(1,6).."~" end
    if on_remove then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        rgba(CFG.COL.REM_BTN))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), rgba(CFG.COL.REM_HOV))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  rgba(CFG.COL.DANGER))
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 0, 0)
      if reaper.ImGui_Button(ctx, "x##rem"..sid, 16, 16) then on_remove() end
      reaper.ImGui_PopStyleVar(ctx, 1)
      reaper.ImGui_PopStyleColor(ctx, 3)
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Remove "..src.name.." from this headphone mix")
      end
      reaper.ImGui_SameLine(ctx, 0, 3)
    end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), col_accent_dim)
    reaper.ImGui_Text(ctx, name)
    reaper.ImGui_PopStyleColor(ctx, 1)

    -- Level in dB
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
    reaper.ImGui_SetCursorPosX(ctx, 2)
    reaper.ImGui_Text(ctx, vol_to_db(vol).." dB")
    reaper.ImGui_PopStyleColor(ctx, 1)

    -- Vertical fader + VU-meter side by side
    local vu_w    = CFG.VU_W * 2 + CFG.VU_GAP
    local fader_x = math.floor((CFG.STRIP_W - CFG.FADER_W - vu_w - 2) / 2)
    reaper.ImGui_SetCursorPosX(ctx, fader_x)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),         rgba(CFG.COL.FADER_RAIL))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrab(),      col_fader_grab)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrabActive(),col_fader_grab)
    local ch_v, nv = reaper.ImGui_VSliderDouble(ctx, "##vf"..sid, CFG.FADER_W, fader_h, vol, 0.0, 2.0, "")
    reaper.ImGui_PopStyleColor(ctx, 3)
    if reaper.ImGui_BeginPopupContextItem(ctx, "vfrst"..sid) then
      if reaper.ImGui_MenuItem(ctx, "Reset to 0 dB")  then nv = 1.0; ch_v = true end
      if reaper.ImGui_MenuItem(ctx, "Cut audio") then nv = 0.0; ch_v = true end
      reaper.ImGui_EndPopup(ctx)
    end
    if ch_v then routing:set_vol(cue_guid, src, clamp(nv, 0, 2)) end

    reaper.ImGui_SameLine(ctx, 0, 2)
    draw_vu_meter(ctx, src.track, fader_h, vol, src.guid)

    -- Pan
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),         rgba(0x141418FF))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(),  rgba(0x1E1E24FF))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrab(),      rgba(0xFFFFFFFF))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrabActive(),rgba(CFG.COL.ACCENT2))
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_GrabMinSize(), 10)
    reaper.ImGui_SetNextItemWidth(ctx, CFG.STRIP_W - 6)
    local ch_p, np = reaper.ImGui_SliderDouble(ctx, "##pan"..sid, pan, -1.0, 1.0, "")
    reaper.ImGui_PopStyleVar(ctx, 1)
    reaper.ImGui_PopStyleColor(ctx, 4)
    if reaper.ImGui_BeginPopupContextItem(ctx, "panrst"..sid) then
      if reaper.ImGui_MenuItem(ctx, "Center pan") then np = 0.0; ch_p = true end
      reaper.ImGui_EndPopup(ctx)
    end
    if ch_p then routing:set_pan(cue_guid, src, clamp(np, -1, 1)) end

    -- Pan value centered below the slider
    local pan_str = math.abs(pan) < 0.01 and "C" or
      string.format("%s%d", pan < 0 and "L" or "R", math.floor(math.abs(pan)*100+0.5))
    local txt_w = reaper.ImGui_CalcTextSize(ctx, pan_str)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
    reaper.ImGui_SetCursorPosX(ctx, math.floor((CFG.STRIP_W - txt_w) / 2))
    reaper.ImGui_Text(ctx, pan_str)
    reaper.ImGui_PopStyleColor(ctx, 1)

    -- Mute button
    reaper.ImGui_Spacing(ctx)
    local mc = muted and CFG.COL.MUTE_ON or CFG.COL.MUTE_OFF
    local mh = muted and 0xD05050FF or 0x505068FF
    if colored_button(ctx, muted and "MUTE" or "mute", mc, mh, CFG.COL.MUTE_ON,
        CFG.STRIP_W - 6, 22) then
      routing:set_mute(cue_guid, src, not muted)
    end

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
      reaper.ImGui_Text(ctx, "  (toutes les pistes\n   sont dans ce casque)")
      reaper.ImGui_PopStyleColor(ctx, 1)
    end

    for _, src in ipairs(available) do
      if colored_button(ctx, "+##add"..src.guid,
          CFG.COL.ADD_BTN, CFG.COL.ADD_HOV, CFG.COL.ACCENT2, 22, 20) then
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

    local in_cue = model:sources_in_cue(cue.guid, routing)

    if #in_cue == 0 then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
      reaper.ImGui_TextWrapped(ctx,
        "None piste dans ce casque.\n\n"..
        "Ajoutez des pistes depuis la zone\n"..
        "\"Available tracks\" on the left.")
      reaper.ImGui_PopStyleColor(ctx, 1)
    else
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
      reaper.ImGui_Text(ctx, "  MIX — "..#in_cue.." track(s)   (right-click on fader/pan = reset)")
      reaper.ImGui_PopStyleColor(ctx, 1)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Spacing(ctx)

      -- Global headphone control bar
      local master = get_cue_master(cue.guid)
      local mc = master.muted and CFG.COL.MUTE_ON or CFG.COL.MUTE_OFF
      local mh = master.muted and 0xD05050FF or 0x505068FF
      if colored_button(ctx, master.muted and "CUE MUTE" or "cue mute",
          mc, mh, CFG.COL.MUTE_ON, 70, CFG.MASTER_H) then
        master.muted = not master.muted
        apply_cue_master(cue.guid, model)
        set_status(master.muted and "Headphone muted." or "Headphone unmuted.")
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Mute / unmute the entire headphone mix")
      end
      reaper.ImGui_SameLine(ctx, 0, 8)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
      reaper.ImGui_Text(ctx, "Master:")
      reaper.ImGui_PopStyleColor(ctx, 1)
      reaper.ImGui_SameLine(ctx, 0, 4)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),
        rgba(CFG.COL.FADER_RAIL))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrab(),
        rgba(master.muted and CFG.COL.FADER_MUTED or CFG.COL.ACCENT))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrabActive(),
        rgba(CFG.COL.ACCENT))
      reaper.ImGui_SetNextItemWidth(ctx, 160)
      local ch_m, nvm = reaper.ImGui_SliderDouble(ctx, "##master"..cue.guid,
        master.vol, 0.0, 2.0, vol_to_db(master.vol).." dB")
      reaper.ImGui_PopStyleColor(ctx, 3)
      if reaper.ImGui_BeginPopupContextItem(ctx, "masterrst"..cue.guid) then
        if reaper.ImGui_MenuItem(ctx, "Reset master to 0 dB") then nvm = 1.0; ch_m = true end
        if reaper.ImGui_MenuItem(ctx, "Cut master")    then nvm = 0.0; ch_m = true end
        reaper.ImGui_EndPopup(ctx)
      end
      if ch_m then
        master.vol = clamp(nvm, 0, 2)
        apply_cue_master(cue.guid, model)
      end
      reaper.ImGui_SameLine(ctx, 0, 8)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.TEXT_DIM))
      reaper.ImGui_Text(ctx, "(right-click = reset)")
      reaper.ImGui_PopStyleColor(ctx, 1)
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Spacing(ctx)

      -- Fader height calculated from available space
      local _, mix_avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
      local fader_h = math.max(60, mix_avail_h - 144)

      local removed = nil
      for i, src in ipairs(in_cue) do
        local src_ref = src
        draw_fader_strip(ctx, cue.guid, src, routing, fader_h, function()
          removed = src_ref
        end)
        if i < #in_cue then reaper.ImGui_SameLine(ctx, 0, CFG.STRIP_PAD) end
      end
      if removed then
        routing:remove_track_from_cue(cue.guid, removed)
        set_status("Removed: "..removed.name)
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
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), rgba(CFG.COL.ACCENT))
    reaper.ImGui_Text(ctx, "Welcome to SK Cue Bus Manager v"..CFG.VERSION)
    reaper.ImGui_PopStyleColor(ctx, 1)
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
      "      Vertical fader       volume (right-click: reset / cut)",
      "      Horizontal slider    pan (right-click: center)",
      "      MUTE                 mute this track in this headphone mix",
      "      [x]                  remove track from headphone mix",
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
--  FENÊTRES SECONDAIRES
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
    no_col and rgba(0x404050FF) or rgba(CFG.COL.STRIP_BG))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), rgba(0x505060FF))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  rgba(0x505060FF))
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

  if colored_button(ctx, " Create ", CFG.COL.ACCENT, 0x7AAFFFFF, 0x3A6FC0FF, 120, 28) then
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
  reaper.ImGui_SetNextWindowSize(ctx, 280, 180, reaper.ImGui_Cond_Always())
  local open, keep = reaper.ImGui_Begin(ctx, "Copy mix from…##cpydlg", true,
    reaper.ImGui_WindowFlags_NoResize())
  if not keep then UI.copy_from_dlg = false end
  if open then
    reaper.ImGui_Text(ctx, "Choose source:")
    reaper.ImGui_Spacing(ctx)
    for _, cue in ipairs(model:cue_list()) do
      if cue.guid ~= UI.selected_cue then
        if reaper.ImGui_Selectable(ctx, cue.name.."##cp"..cue.guid, false) then
          cue_mgr:copy_mix(cue.guid, UI.selected_cue)
          set_status("Mix copied from "..cue.name)
          UI.copy_from_dlg = false
        end
      end
    end
    if colored_button(ctx, " Cancel ", CFG.COL.STRIP_BG, CFG.COL.STRIP_SEL, CFG.COL.TEXT_DIM) then
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
    if colored_button(ctx, " Apply ", CFG.COL.ACCENT2, 0x50D0A0FF, 0x30A080FF, 110, 26) then
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

local function push_style(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(),      rgba(CFG.COL.BG))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBg(),       rgba(0x0E0E12FF))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgActive(), rgba(0x18182AFF))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        rgba(CFG.COL.SEP))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(),     rgba(CFG.COL.SEP))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          rgba(CFG.COL.TEXT_BRIGHT))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarBg(),   rgba(0x12121AFF))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrab(), rgba(0x404058FF))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(),       rgba(0x1A1A26FF))
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(),  4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),  3)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),    4, 4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),  6, 6)
  return 9, 5
end

local function pop_style(ctx, nc, nv)
  reaper.ImGui_PopStyleColor(ctx, nc)
  reaper.ImGui_PopStyleVar(ctx, nv)
end

-- =============================================================================
--  INITIALIZATION AND MAIN LOOP
-- =============================================================================

local ctx  = reaper.ImGui_CreateContext(CFG.SCRIPT_NAME)
local font = reaper.ImGui_CreateFont("sans-serif", 13)
reaper.ImGui_Attach(ctx, font)

local model        = ProjectModel.new()
local routing      = RoutingEngine.new(model)
local cue_mgr      = CueManager.new(model, routing)
local snap         = SnapSystem.new(model, routing)

model:scan()
cue_mgr:repair_cue_folder_structure()

local open = true

local function loop()
  if not open then return end

  local nc, nv = push_style(ctx)
  reaper.ImGui_SetNextWindowSize(ctx, CFG.WINDOW_W, CFG.WINDOW_H, reaper.ImGui_Cond_Always())
  local visible, keep = reaper.ImGui_Begin(ctx,
    CFG.SCRIPT_NAME.." v"..CFG.VERSION, true,
    reaper.ImGui_WindowFlags_NoScrollbar() |
    reaper.ImGui_WindowFlags_NoScrollWithMouse())
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

  pop_style(ctx, nc, nv)

  draw_new_cue_dialog(ctx, cue_mgr, model, routing)
  draw_copy_from_dialog(ctx, cue_mgr, model)
  draw_hw_out_dialog(ctx, routing, model)

  if open then reaper.defer(loop) end
end

reaper.defer(loop)
