--[[
@description SK Extended VCA
@author Stephan (Studio Kozak)
@version 1.0.2
@provides [main] .
@about
  A VCA fader that controls the volume of one or more tracks together
  with selected sends on their child tracks, without changing what those
  children feed into their own bus.

  It works as a relative offset: every assigned track and send keeps its
  own level, and the VCA fader adds or removes decibels on top. You can
  still mix each element by hand at any time, your moves are picked up
  automatically.

  Assigning elements
  Select a bus or folder track in Reaper, open the assignment panel and
  press +. Its child tracks and their sends are listed, tick whatever
  the VCA should control.

  Automating a VCA
  The faders in this window do not record automation. To automate a VCA,
  link it to a regular Reaper track with the L button: that track's own
  volume, moved by hand or by an automation envelope, becomes the VCA
  offset. The envelope must be in Read (or Touch, Latch, Write while
  recording the move) to be heard during playback.

  Project tabs
  VCAs are stored inside the project, and each project tab keeps its
  own. Switching tabs shows that tab's VCAs.

  Running in the background
  The window has no close button on purpose, so it cannot be shut by
  accident. The power button in the toolbar stops the VCAs, the dash
  next to it only shrinks the window down to its toolbar.

  Requires ReaImGui, available through ReaPack.
@changelog
  v1.0.2
  - Fixes a crash when restoring the window after reducing it, which
    happened on some screens depending on display scaling.
  - The reduced window now fits the toolbar exactly, without a scrollbar.
  - If the window runs into a problem, it is rebuilt on the next redraw
    while the VCAs keep working, and the problem is written in the
    Reaper console.
]]--

local reaper = reaper

-- ============================================================
-- Startup
-- ============================================================

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "This script requires ReaImGui.\n\nInstall it via ReaPack:\nExtensions > ReaPack > Browse packages > 'ReaImGui: ReaScript binding for Dear ImGui'.",
    "SK Extended VCA", 0)
  return
end

-- The VCAs keep working after the window is put aside, so running the
-- action again brings that window back instead of starting a second
-- copy. The running copy signs in regularly; if it stopped answering it
-- is gone, and a fresh one starts.
local RUNSTATE_SECTION = 'SK_ExtendedVCA_UI'
local HEARTBEAT_TIMEOUT = 2.0

do
  local alive = false
  if reaper.GetExtState(RUNSTATE_SECTION, 'running') == '1' then
    local hb = tonumber(reaper.GetExtState(RUNSTATE_SECTION, 'heartbeat'))
    alive = hb ~= nil and (reaper.time_precise() - hb) < HEARTBEAT_TIMEOUT
  end
  if alive then
    reaper.SetExtState(RUNSTATE_SECTION, 'want_show', '1', false)
    return
  end
end

reaper.SetExtState(RUNSTATE_SECTION, 'running', '1', false)
reaper.SetExtState(RUNSTATE_SECTION, 'heartbeat', tostring(reaper.time_precise()), false)

-- Keeps the toolbar button lit while the VCAs are active.
local _, _, ao_sectionID, ao_cmdID = reaper.get_action_context()
local function set_toolbar_state(on)
  if ao_cmdID and ao_cmdID ~= -1 then
    reaper.SetToggleCommandState(ao_sectionID, ao_cmdID, on and 1 or 0)
    reaper.RefreshToolbar2(ao_sectionID, ao_cmdID)
  end
end

-- ============================================================
-- Colours and sizes
-- ============================================================

local COL_BG        = 0x1C1C1AFF
local COL_PANEL     = 0x2A2A27FF
local COL_PANEL_HI  = 0x3A3A35FF
local COL_TEXT      = 0xD9D3C4FF
local COL_TEXT_DIM  = 0x8A857AFF
local COL_ACCENT    = 0xE0A030FF
local COL_EDGE      = 0x14141288

local COL_GROOVE    = 0x141412FF
local COL_GROOVE_DK = 0x0A0A09FF
local COL_CAP       = 0x4A4A44FF
local COL_CAP_EDGE  = 0x000000FF
local COL_BEVEL_HI  = 0xFFFFFF22
local COL_BEVEL_LO  = 0x00000066

local COL_BTN       = 0x33332FFF
local COL_BTN_EDGE  = 0x000000AA

local COL_MUTE      = 0xC0402FFF
local COL_BROKEN    = 0xC0503080 -- red veil over a strip whose track is missing

local COL_HDR_DEF   = 0x555049FF
local COL_TICK      = 0x55504955
local COL_TICK_0    = 0xE0A03088

local TXT_DARK      = 0x141412FF
local TXT_LIGHT     = 0xF0ECE0FF

-- Sizes of one channel strip and of the panels around it.
local SW          = 74
local SH          = 300
local SH_MIN      = 200
local STRIP_GAP   = 6
local MASTER_GAP  = 18
local PAD         = 8

local HDR_H       = 26
local SRC_H       = 18
local BTN_W       = 22
local BTN_H       = 20
local BTN_GAP     = 6
local BTN_Y       = HDR_H + SRC_H + 6
local FADER_W     = 24
local FADER_H     = 200
local FADER_Y     = BTN_Y + BTN_H + 8
local DBLBL_Y     = FADER_Y + FADER_H + 2

local LEFT_W      = 232
local PANEL_GAP   = 6
local ROW_H       = 24

-- ============================================================
-- Window and fonts
-- ============================================================

local NEW_FONT_API = reaper.ImGui_CreateFontFromFile ~= nil
local ctx

-- ReaImGui throws the window away when something goes badly wrong in
-- it. This tells whether the one in hand is still usable.
local function ctx_valid()
  if not reaper.ImGui_ValidatePtr then return ctx ~= nil end
  return ctx ~= nil and reaper.ImGui_ValidatePtr(ctx, 'ImGui_Context*')
end

reaper.atexit(function()
  reaper.SetExtState(RUNSTATE_SECTION, 'running', '0', false)
  reaper.SetExtState(RUNSTATE_SECTION, 'heartbeat', '0', false)
  set_toolbar_state(false)
  if reaper.ImGui_DestroyContext and ctx_valid() then reaper.ImGui_DestroyContext(ctx) end
end)

-- ============================================================
-- Safety net
-- ============================================================

-- The window is redrawn from scratch many times per second. If anything
-- goes wrong halfway through a redraw, everything opened during it is
-- closed again here, the problem is written once in the Reaper console,
-- and the VCAs carry on working.
local stk = { child = 0, color = 0, font = 0 }

-- A panel lying entirely out of view is skipped by ReaImGui, and in
-- that case it must not be closed either. Only a panel really opened is
-- counted, and closed.
local function ui_begin_child(id, w, h, cflags, wflags)
  local ok = reaper.ImGui_BeginChild(ctx, id, w, h, cflags, wflags)
  if ok then stk.child = stk.child + 1 end
  return ok
end

local function ui_end_child()
  if stk.child > 0 then
    stk.child = stk.child - 1
    reaper.ImGui_EndChild(ctx)
  end
end

local function ui_push_color(col, val)
  reaper.ImGui_PushStyleColor(ctx, col, val)
  stk.color = stk.color + 1
end

local function ui_pop_color(n)
  n = math.min(n or 1, stk.color)
  if n > 0 then
    stk.color = stk.color - n
    reaper.ImGui_PopStyleColor(ctx, n)
  end
end

local function ui_unwind()
  while stk.child > 0 do stk.child = stk.child - 1; pcall(reaper.ImGui_EndChild, ctx) end
  while stk.font  > 0 do stk.font  = stk.font  - 1; pcall(reaper.ImGui_PopFont, ctx) end
  if stk.color > 0 then
    local n = stk.color
    stk.color = 0
    pcall(reaper.ImGui_PopStyleColor, ctx, n)
  end
end

local last_err
local function report_error(err)
  err = tostring(err)
  if err == last_err then return end
  last_err = err
  reaper.ShowConsoleMsg('[SK Extended VCA] ' .. err .. '\n')
end

-- Message boxes stop everything while they are open, so they are asked
-- once the window has finished being drawn rather than in the middle.
local pending_dialogs = {}

local function ask(msg, mbtype, fn)
  pending_dialogs[#pending_dialogs + 1] = { msg = msg, type = mbtype or 0, fn = fn }
end

local function flush_pending_dialogs()
  if #pending_dialogs == 0 then return end
  local queue = pending_dialogs
  pending_dialogs = {}
  for _, d in ipairs(queue) do
    local r = reaper.ShowMessageBox(d.msg, 'SK Extended VCA', d.type)
    if d.fn then
      local ok, err = pcall(d.fn, r)
      if not ok then report_error(err) end
    end
  end
end

local function make_font(size, bold)
  local flags = (bold and reaper.ImGui_FontFlags_Bold) and reaper.ImGui_FontFlags_Bold() or 0
  local f
  if NEW_FONT_API then f = reaper.ImGui_CreateFont('sans-serif', flags)
  else f = reaper.ImGui_CreateFont('sans-serif', size, flags) end
  if f and reaper.ImGui_Attach then reaper.ImGui_Attach(ctx, f) end
  return f
end

local FONT, FONT_SM, FONT_HDR
local drag_hold = {}
local dbedit_buf = {}

-- Builds the window, fonts included. Called once at startup, and again
-- if the window ever breaks down, while the VCAs carry on underneath.
local function create_ui_context()
  ctx = reaper.ImGui_CreateContext('SK Extended VCA')
  FONT     = make_font(13, false)
  FONT_SM  = make_font(11, false)
  FONT_HDR = make_font(14, true)
  stk.child, stk.color, stk.font = 0, 0, 0
  drag_hold, dbedit_buf = {}, {}
end

create_ui_context()

local function push_font(f, size)
  if not (f and reaper.ImGui_PushFont) then return false end
  if NEW_FONT_API then reaper.ImGui_PushFont(ctx, f, size)
  else reaper.ImGui_PushFont(ctx, f) end
  stk.font = stk.font + 1
  return true
end

local function pop_font(pushed)
  if pushed and stk.font > 0 then
    stk.font = stk.font - 1
    reaper.ImGui_PopFont(ctx)
  end
end

-- ============================================================
-- Volume values
-- ============================================================

-- Reaper stores volumes as a raw factor, the mixer shows decibels, and
-- a fader needs a position between bottom and top. These convert
-- between the three.

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi else return v end
end

local NEG_INF_DB = -150.0
local MAX_DB     = 24.0

local function AMP2DB(amp)
  if amp <= 0.0000000298 then return NEG_INF_DB end
  return 20.0 * math.log(amp, 10)
end

local function DB2AMP(db)
  if db <= NEG_INF_DB then return 0.0 end
  if db > MAX_DB then db = MAX_DB end
  return 10.0 ^ (db / 20.0)
end

local function ClampDB(db)
  if db < NEG_INF_DB then return NEG_INF_DB end
  if db > MAX_DB then return MAX_DB end
  return db
end

local HAS_SLIDER = reaper.DB2SLIDER and reaper.SLIDER2DB
local WIDGET_DB_MIN, WIDGET_DB_MAX = -60.0, MAX_DB

local function db_to_norm(db)
  if HAS_SLIDER then return clamp(reaper.DB2SLIDER(db) / 1000.0, 0.0, 1.0) end
  return clamp((db - WIDGET_DB_MIN) / (WIDGET_DB_MAX - WIDGET_DB_MIN), 0.0, 1.0)
end

local function norm_to_db(n)
  if HAS_SLIDER then return reaper.SLIDER2DB(n * 1000.0) end
  return WIDGET_DB_MIN + n * (WIDGET_DB_MAX - WIDGET_DB_MIN)
end

local function fmt_db(db)
  if db <= NEG_INF_DB + 1 then return "-inf" end
  if db > -0.05 and db < 0.05 then return "0.0" end
  if db > 0 then return string.format("+%.1f", db) end
  return string.format("%.1f", db)
end

local function native_to_imgui(nc)
  if nc == 0 then return COL_HDR_DEF end
  local r, g, b = reaper.ColorFromNative(nc)
  return (r << 24) | (g << 16) | (b << 8) | 0xFF
end

-- Dark text on a light track colour, light text on a dark one.
local function text_on(col)
  local r = (col >> 24) & 0xFF
  local g = (col >> 16) & 0xFF
  local b = (col >> 8) & 0xFF
  local lum = 0.299 * r + 0.587 * g + 0.114 * b
  return lum > 140 and TXT_DARK or TXT_LIGHT
end

-- ============================================================
-- Finding tracks and sends
-- ============================================================

-- A track can only be touched while its own project tab is the one on
-- screen. Everything below checks that first, so a VCA never reaches
-- for a track that belongs to another tab or has been deleted.
local function valid_track(tr)
  return tr ~= nil and tr ~= 0 and reaper.ValidatePtr2(0, tr, 'MediaTrack*')
end

local function track_label(tr)
  if not valid_track(tr) then return "(missing)" end
  local _, name = reaper.GetTrackName(tr)
  if name and name ~= "" then return name end
  local n = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
  return "Track " .. n
end

local function fine_drag()
  if reaper.ImGui_GetKeyMods and reaper.ImGui_Mod_Ctrl then
    return (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Ctrl()) ~= 0
  end
  return false
end

-- Reaper gives every track a permanent identity code. A VCA remembers
-- that code rather than the track's position, so renaming, moving or
-- reordering tracks never breaks an assignment. This keeps a shortcut
-- from codes to tracks, rebuilt whenever the project changes.
local guidCache, guidCacheProj, guidCacheCount = {}, nil, -1

local function RebuildGuidCache()
  guidCache = {}
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    guidCache[reaper.GetTrackGUID(tr)] = tr
  end
  guidCacheProj = reaper.EnumProjects(-1)
  guidCacheCount = n
end

local function ResolveTrackByGUID(guid)
  if not guid then return nil end
  local curProj, curCount = reaper.EnumProjects(-1), reaper.CountTracks(0)
  if curProj ~= guidCacheProj or curCount ~= guidCacheCount then RebuildGuidCache() end
  local tr = guidCache[guid]
  if valid_track(tr) then return tr end
  RebuildGuidCache()
  tr = guidCache[guid]
  if valid_track(tr) then return tr end
  return nil
end

-- Sends have no identity code of their own, so one is recognised by its
-- source track, its destination track, and its rank among the sends
-- going to that same destination.
local function FindSendByOrdinal(srcTrack, dstTrack, ordinal)
  if not (valid_track(srcTrack) and valid_track(dstTrack) and ordinal) then return nil end
  local n, seen = reaper.GetTrackNumSends(srcTrack, 0), 0
  for i = 0, n - 1 do
    if reaper.GetTrackSendInfo_Value(srcTrack, 0, i, 'P_DESTTRACK') == dstTrack then
      seen = seen + 1
      if seen == ordinal then return i end
    end
  end
  return nil
end

local function OrdinalOfSend(srcTrack, sendidx)
  if not valid_track(srcTrack) then return nil, nil end
  local dstTrack = reaper.GetTrackSendInfo_Value(srcTrack, 0, sendidx, 'P_DESTTRACK')
  if not valid_track(dstTrack) then return nil, nil end
  local n, seen = reaper.GetTrackNumSends(srcTrack, 0), 0
  for i = 0, sendidx do
    if reaper.GetTrackSendInfo_Value(srcTrack, 0, i, 'P_DESTTRACK') == dstTrack then seen = seen + 1 end
  end
  return dstTrack, seen
end

local function get_folder_children(parent)
  local children = {}
  if not valid_track(parent) then return children end
  local n = reaper.CountTracks(0)
  local pidx = nil
  for i = 0, n - 1 do
    if reaper.GetTrack(0, i) == parent then pidx = i; break end
  end
  if not pidx then return children end
  local parent_depth = 0
  for i = 0, pidx - 1 do
    parent_depth = parent_depth + reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, i), "I_FOLDERDEPTH")
  end
  local d = parent_depth + reaper.GetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH")
  for i = pidx + 1, n - 1 do
    if d <= parent_depth then break end
    local tr = reaper.GetTrack(0, i)
    if d == parent_depth + 1 then children[#children + 1] = tr end
    d = d + reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
  end
  return children
end

local function GetTrackSendsInfo(track)
  local out = {}
  if not valid_track(track) then return out end
  local n = reaper.GetTrackNumSends(track, 0)
  for i = 0, n - 1 do
    local dt = reaper.GetTrackSendInfo_Value(track, 0, i, 'P_DESTTRACK')
    if valid_track(dt) then
      local _, destName = reaper.GetTrackName(dt)
      out[#out + 1] = { idx = i, destTrack = dt, destName = destName }
    end
  end
  return out
end

local function get_send_sources(dest)
  local out = {}
  if not valid_track(dest) then return out end
  local n = reaper.GetTrackNumSends(dest, -1)
  for i = 0, n - 1 do
    local src = reaper.GetTrackSendInfo_Value(dest, -1, i, 'P_SRCTRACK')
    if valid_track(src) then out[#out + 1] = src end
  end
  return out
end

-- A bus gathers its tracks either as a folder or through sends. Both
-- ways are listed here, so the assignment panel finds the children of a
-- flat bus just as well as those of a folder.
local function get_bus_children(parent)
  local children = get_folder_children(parent)
  local seen = {}
  for _, c in ipairs(children) do seen[c] = true end
  for _, src in ipairs(get_send_sources(parent)) do
    if not seen[src] then
      children[#children + 1] = src
      seen[src] = true
    end
  end
  return children
end

-- ============================================================
-- The VCAs
-- ============================================================

local vcas = {}
local nextVcaId = 1
local active_vca = nil
local pickerParentTracks = {}

local function SetActiveVCA(v)
  if active_vca ~= v then pickerParentTracks = {} end
  active_vca = v
end

local function NewVCA(name)
  local v = {
    id = nextVcaId, name = name or ('VCA ' .. nextVcaId),
    fader_db = 0.0, muted = false,
    tracks = {}, sends = {},
    master_guid = nil,
  }
  nextVcaId = nextVcaId + 1
  vcas[#vcas + 1] = v
  SetActiveVCA(v)
  return v
end

-- An element joins a VCA at whatever level it already has. That level
-- is stored, and the VCA fader is added on top of it from then on.
local function AddTrackToVCA(vca, track)
  if not valid_track(track) then return end
  local guid = reaper.GetTrackGUID(track)
  if guid == vca.master_guid then return end
  for _, t in ipairs(vca.tracks) do if t.guid == guid then return end end
  local curDb = AMP2DB(reaper.GetMediaTrackInfo_Value(track, 'D_VOL'))
  vca.tracks[#vca.tracks + 1] = {
    guid = guid, local_db = ClampDB(curDb - vca.fader_db),
    last_written_db = curDb, broken = false,
  }
end

local function AddSendToVCA(vca, srcTrack, sendidx)
  if not valid_track(srcTrack) then return end
  local dstTrack, ordinal = OrdinalOfSend(srcTrack, sendidx)
  if not dstTrack then return end
  local srcGuid, dstGuid = reaper.GetTrackGUID(srcTrack), reaper.GetTrackGUID(dstTrack)
  for _, s in ipairs(vca.sends) do
    if s.srcGuid == srcGuid and s.dstGuid == dstGuid and s.ordinal == ordinal then return end
  end
  local curDb = AMP2DB(reaper.GetTrackSendInfo_Value(srcTrack, 0, sendidx, 'D_VOL'))
  vca.sends[#vca.sends + 1] = {
    srcGuid = srcGuid, dstGuid = dstGuid, ordinal = ordinal,
    local_db = ClampDB(curDb - vca.fader_db), last_written_db = curDb, broken = false,
  }
end

local function RemoveTrackFromVCA(vca, guid)
  for i = #vca.tracks, 1, -1 do if vca.tracks[i].guid == guid then table.remove(vca.tracks, i) end end
end

local function RemoveSendFromVCA(vca, srcGuid, dstGuid, ordinal)
  for i = #vca.sends, 1, -1 do
    local s = vca.sends[i]
    if s.srcGuid == srcGuid and s.dstGuid == dstGuid and s.ordinal == ordinal then table.remove(vca.sends, i) end
  end
end

local function IsTrackAssignedToVCA(vca, guid)
  for _, t in ipairs(vca.tracks) do if t.guid == guid then return true end end
  return false
end

-- ============================================================
-- The engine
-- ============================================================

-- Runs constantly. For every assigned element it writes the stored
-- level plus the VCA offset, and notices any move made by hand in the
-- mixer, which then becomes the new stored level.
--
-- An element whose track cannot be found is marked in red and left
-- alone, never removed: it is usually only out of reach for a moment,
-- during an undo or while another project tab is on screen. Removing an
-- element stays a click on the x above its fader.

local EPS_DB = 0.005
local g_dirty = false
local function mark_dirty() g_dirty = true end

local function EngineUpdateTrack(vca, entry)
  local track = ResolveTrackByGUID(entry.guid)
  if not track then entry.broken = true; return end
  entry.broken = false

  local actualDb = AMP2DB(reaper.GetMediaTrackInfo_Value(track, 'D_VOL'))
  if math.abs(actualDb - entry.last_written_db) > EPS_DB then
    entry.local_db = ClampDB(actualDb - vca.fader_db)
  end
  local targetDb = vca.muted and NEG_INF_DB or ClampDB(entry.local_db + vca.fader_db)
  if math.abs(targetDb - actualDb) > EPS_DB then
    reaper.CSurf_OnVolumeChangeEx(track, DB2AMP(targetDb), false, false)
    mark_dirty()
  end
  entry.last_written_db = targetDb
end

local function EngineUpdateSend(vca, entry)
  local srcTrack = ResolveTrackByGUID(entry.srcGuid)
  local dstTrack = ResolveTrackByGUID(entry.dstGuid)
  if not srcTrack or not dstTrack then entry.broken = true; return end
  local sendidx = FindSendByOrdinal(srcTrack, dstTrack, entry.ordinal)
  if not sendidx then entry.broken = true; return end
  entry.broken = false

  local actualDb = AMP2DB(reaper.GetTrackSendInfo_Value(srcTrack, 0, sendidx, 'D_VOL'))
  if math.abs(actualDb - entry.last_written_db) > EPS_DB then
    entry.local_db = ClampDB(actualDb - vca.fader_db)
  end
  local targetDb = vca.muted and NEG_INF_DB or ClampDB(entry.local_db + vca.fader_db)
  if math.abs(targetDb - actualDb) > EPS_DB then
    reaper.CSurf_OnSendVolumeChange(srcTrack, sendidx, DB2AMP(targetDb), false)
    mark_dirty()
  end
  entry.last_written_db = targetDb
end

-- Reads the linked track the way it sounds, so an automation envelope
-- moving that track is followed during playback.
local function GetMasterTrackVol(mt)
  local ok, vol = reaper.GetTrackUIVolPan(mt)
  if ok then return vol end
  return reaper.GetMediaTrackInfo_Value(mt, 'D_VOL')
end

-- When a VCA is linked to a track, that track's volume and mute take
-- over from the fader in this window. The link is dropped if the linked
-- track is also one of the VCA's own targets, which would otherwise
-- send the level spinning.
local function EngineSyncMasterTrack(vca)
  if not vca.master_guid then return end
  local mt = ResolveTrackByGUID(vca.master_guid)
  if not mt then return end
  if IsTrackAssignedToVCA(vca, vca.master_guid) then
    vca.master_guid = nil
    return
  end
  vca.fader_db = ClampDB(AMP2DB(GetMasterTrackVol(mt)))
  vca.muted = reaper.GetMediaTrackInfo_Value(mt, 'B_MUTE') == 1
end

local function EngineUpdateVCA(vca)
  EngineSyncMasterTrack(vca)
  for _, t in ipairs(vca.tracks) do EngineUpdateTrack(vca, t) end
  for _, s in ipairs(vca.sends) do EngineUpdateSend(vca, s) end
end

local function run_engine()
  for _, vca in ipairs(vcas) do EngineUpdateVCA(vca) end
end

-- ============================================================
-- Saving and loading
-- ============================================================

-- VCAs live inside the project file. Each project tab has its own set,
-- so switching tabs puts the current set back where it came from and
-- brings up the one belonging to the tab now on screen.

local EXT_SECTION = 'SK_ExtendedVCA'

local function split(s, sep)
  local t, pos = {}, 1
  while pos <= #s + 1 do
    local a, b = string.find(s, sep, pos, true)
    if a then t[#t + 1] = string.sub(s, pos, a - 1); pos = b + 1
    else t[#t + 1] = string.sub(s, pos); break end
  end
  return t
end

local function SerializeVCA(v)
  local trackParts, sendParts = {}, {}
  for _, t in ipairs(v.tracks) do trackParts[#trackParts + 1] = string.format('%s:%.4f', t.guid, t.local_db) end
  for _, s in ipairs(v.sends) do
    sendParts[#sendParts + 1] = string.format('%s>%s>%d:%.4f', s.srcGuid, s.dstGuid, s.ordinal, s.local_db)
  end
  return table.concat({
    tostring(v.id), v.name, string.format('%.4f', v.fader_db), v.muted and '1' or '0',
    table.concat(trackParts, ','), table.concat(sendParts, ','), v.master_guid or '',
  }, '|')
end

local function DeserializeVCA(line)
  local parts = split(line, '|')
  if #parts < 6 then return nil end
  local v = {
    id = tonumber(parts[1]) or nextVcaId, name = parts[2],
    fader_db = tonumber(parts[3]) or 0.0, muted = parts[4] == '1',
    tracks = {}, sends = {},
    master_guid = (parts[7] and parts[7] ~= '') and parts[7] or nil,
  }
  if parts[5] ~= '' then
    for item in string.gmatch(parts[5], '([^,]+)') do
      local guid, db = string.match(item, '^(.-):(.+)$')
      if guid then v.tracks[#v.tracks + 1] = { guid = guid, local_db = tonumber(db) or 0.0, last_written_db = -999, broken = false } end
    end
  end
  if parts[6] ~= '' then
    for item in string.gmatch(parts[6], '([^,]+)') do
      local head, db = string.match(item, '^(.-):(.+)$')
      if head then
        local srcGuid, dstGuid, ordinal = string.match(head, '^(.-)>(.-)>(%d+)$')
        if srcGuid then
          v.sends[#v.sends + 1] = {
            srcGuid = srcGuid, dstGuid = dstGuid, ordinal = tonumber(ordinal),
            local_db = tonumber(db) or 0.0, last_written_db = -999, broken = false,
          }
        end
      end
    end
  end
  return v
end

local function SaveState(proj, quiet)
  proj = proj or 0
  if proj ~= 0 and not reaper.ValidatePtr(proj, 'ReaProject*') then return end
  reaper.SetProjExtState(proj, EXT_SECTION, 'count', tostring(#vcas))
  for i, v in ipairs(vcas) do reaper.SetProjExtState(proj, EXT_SECTION, 'vca_' .. i, SerializeVCA(v)) end
  reaper.SetProjExtState(proj, EXT_SECTION, 'nextId', tostring(nextVcaId))
  if not quiet then reaper.MarkProjectDirty(proj) end
end

local function LoadState(proj)
  proj = proj or 0
  vcas = {}
  local ok, countStr = reaper.GetProjExtState(proj, EXT_SECTION, 'count')
  local count = (ok and tonumber(countStr)) or 0
  for i = 1, count do
    local ok2, line = reaper.GetProjExtState(proj, EXT_SECTION, 'vca_' .. i)
    if ok2 and line ~= '' then
      local v = DeserializeVCA(line)
      if v then vcas[#vcas + 1] = v end
    end
  end
  local ok3, nid = reaper.GetProjExtState(proj, EXT_SECTION, 'nextId')
  if ok3 and tonumber(nid) then nextVcaId = tonumber(nid) end
  if #vcas == 0 then nextVcaId = 1 end
  SetActiveVCA(vcas[1])
end

local cur_proj = reaper.EnumProjects(-1)

local function SyncActiveProject()
  local p = reaper.EnumProjects(-1)
  if p == cur_proj then return end
  if cur_proj and reaper.ValidatePtr(cur_proj, 'ReaProject*') then
    SaveState(cur_proj, true)
  end
  cur_proj = p
  pickerParentTracks = {}
  RebuildGuidCache()
  LoadState(p)
end

-- ============================================================
-- Faders, buttons and labels
-- ============================================================

-- Vertical fader. Hold Ctrl for a finer move, double-click to return to
-- 0 dB, right-click to type a value.
local function fader(dl, id, x, y, w, h, db, accent)
  local norm = db_to_norm(db)
  local cx = x + w * 0.5
  local cap_h = 20
  local travel = h - cap_h

  reaper.ImGui_DrawList_AddRectFilled(dl, cx - 3, y, cx + 3, y + h, COL_GROOVE, 2)
  reaper.ImGui_DrawList_AddLine(dl, cx, y + 2, cx, y + h - 2, COL_GROOVE_DK, 1)

  local ticks = { 12, 0, -12, -24, -48 }
  for _, tdb in ipairs(ticks) do
    local tn = db_to_norm(tdb)
    local ty = y + (1 - tn) * travel + cap_h * 0.5
    local c = (tdb == 0) and COL_TICK_0 or COL_TICK
    reaper.ImGui_DrawList_AddLine(dl, x + 1, ty, x + 5, ty, c, 1)
    reaper.ImGui_DrawList_AddLine(dl, x + w - 5, ty, x + w - 1, ty, c, 1)
  end

  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, '##fad' .. id, w, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local changed, active = false, false
  if reaper.ImGui_IsItemActivated(ctx) then drag_hold[id] = norm end
  if reaper.ImGui_IsItemActive(ctx) then
    active = true
    local held = drag_hold[id] or norm
    local _, dy = reaper.ImGui_GetMouseDelta(ctx)
    if dy ~= 0 then
      local scale = fine_drag() and 0.25 or 1.0
      held = clamp(held - (dy / travel) * scale, 0, 1)
      drag_hold[id] = held
      changed = true
    end
    norm = held
    db = norm_to_db(norm)
  else
    drag_hold[id] = nil
  end

  if hovered and not active and reaper.ImGui_SetTooltip then
    local cap_y = y + (1 - norm) * travel
    local mx, my = reaper.ImGui_GetMousePos(ctx)
    if mx >= x + 2 and mx <= x + w - 2 and my >= cap_y and my <= cap_y + cap_h then
      reaper.ImGui_SetTooltip(ctx, "Ctrl = fine\nDouble-click = 0dB\nRight-click = type dB")
    end
  end
  if hovered and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    db = 0.0; norm = db_to_norm(0.0); drag_hold[id] = nil; changed = true
  end
  if hovered and reaper.ImGui_IsMouseClicked(ctx, 1) then
    reaper.ImGui_OpenPopup(ctx, '##dbedit' .. id)
  end
  if reaper.ImGui_BeginPopup and reaper.ImGui_InputDouble and reaper.ImGui_BeginPopup(ctx, '##dbedit' .. id) then
    if reaper.ImGui_IsWindowAppearing(ctx) then
      dbedit_buf[id] = db
      if reaper.ImGui_SetKeyboardFocusHere then reaper.ImGui_SetKeyboardFocusHere(ctx) end
    end
    reaper.ImGui_SetNextItemWidth(ctx, 90)
    local rv, newv = reaper.ImGui_InputDouble(ctx, '##dbval' .. id, dbedit_buf[id] or db, 0.5, 0.5, '%.1f')
    if rv then
      dbedit_buf[id] = newv
      db = clamp(newv, WIDGET_DB_MIN, WIDGET_DB_MAX)
      norm = db_to_norm(db)
      changed = true
    end
    reaper.ImGui_EndPopup(ctx)
  end

  local cap_y = y + (1 - norm) * travel
  local x1, x2 = x + 2, x + w - 2
  reaper.ImGui_DrawList_AddRectFilled(dl, x1, cap_y, x2, cap_y + cap_h, COL_CAP, 3)
  reaper.ImGui_DrawList_AddRect(dl, x1, cap_y, x2, cap_y + cap_h, COL_CAP_EDGE, 3, 0, 1)
  reaper.ImGui_DrawList_AddLine(dl, x1 + 1, cap_y + 1, x2 - 1, cap_y + 1, COL_BEVEL_HI, 1)
  reaper.ImGui_DrawList_AddLine(dl, x1 + 1, cap_y + cap_h - 1, x2 - 1, cap_y + cap_h - 1, COL_BEVEL_LO, 1)
  reaper.ImGui_DrawList_AddLine(dl, x1 + 2, cap_y + cap_h * 0.5, x2 - 2, cap_y + cap_h * 0.5, accent, 2)

  return db, changed
end

local function button_frame(dl, x, y, w, h, on, on_col)
  local bg = on and on_col or COL_BTN
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + h, bg, 3)
  reaper.ImGui_DrawList_AddLine(dl, x + 1, y + 1, x + w - 1, y + 1, COL_BEVEL_HI, 1)
  reaper.ImGui_DrawList_AddLine(dl, x + 1, y + h - 1, x + w - 1, y + h - 1, COL_BEVEL_LO, 1)
  reaper.ImGui_DrawList_AddRect(dl, x, y, x + w, y + h, COL_BTN_EDGE, 3, 0, 1)
end

local GLOW_RINGS = { { 7, 0x14 }, { 4, 0x28 }, { 2, 0x40 } }
local function draw_glow(dl, x, y, w, h, col)
  local rgb = col & 0xFFFFFF00
  for _, ring in ipairs(GLOW_RINGS) do
    local ext, a = ring[1], ring[2]
    reaper.ImGui_DrawList_AddRectFilled(dl, x - ext, y - ext, x + w + ext, y + h + ext, rgb | a, 3 + ext)
  end
end

local function toggle_button(dl, id, x, y, w, h, label, on, on_col, tooltip)
  if on then draw_glow(dl, x, y, w, h, on_col) end
  button_frame(dl, x, y, w, h, on, on_col)
  local pf = push_font(FONT_SM, 12)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, label)
  local tcol = on and TXT_DARK or COL_TEXT
  reaper.ImGui_DrawList_AddText(dl, x + (w - tw) * 0.5, y + (h - th) * 0.5, tcol, label)
  pop_font(pf)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, '##' .. id, w, h)
  if tooltip and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, tooltip)
  end
  return reaper.ImGui_IsItemClicked(ctx)
end

-- Toolbar buttons light up briefly when clicked, since actions like
-- Save give no other sign that they happened.
local ICON_FLASH_S = 0.15
local icon_flash_until = {}

local function icon_button(dl, id, x, y, w, h, draw_icon, tooltip)
  local flashing = icon_flash_until[id] and reaper.time_precise() < icon_flash_until[id]
  button_frame(dl, x, y, w, h, flashing, COL_ACCENT)
  draw_icon(dl, x + w * 0.5, y + h * 0.5, math.min(w, h) * 0.5 - 5, flashing and TXT_DARK or COL_TEXT)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, '##' .. id, w, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  if hovered then
    reaper.ImGui_DrawList_AddRect(dl, x, y, x + w, y + h, COL_ACCENT, 3, 0, 1)
    if tooltip and reaper.ImGui_SetTooltip then reaper.ImGui_SetTooltip(ctx, tooltip) end
  end
  local clicked = reaper.ImGui_IsItemClicked(ctx)
  if clicked then icon_flash_until[id] = reaper.time_precise() + ICON_FLASH_S end
  return clicked
end

local function icon_toggle_button(dl, id, x, y, w, h, draw_icon, on, tooltip)
  if on then draw_glow(dl, x, y, w, h, COL_ACCENT) end
  button_frame(dl, x, y, w, h, on, COL_ACCENT)
  draw_icon(dl, x + w * 0.5, y + h * 0.5, math.min(w, h) * 0.5 - 5, on and TXT_DARK or COL_TEXT)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, '##' .. id, w, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  if hovered then
    reaper.ImGui_DrawList_AddRect(dl, x, y, x + w, y + h, COL_ACCENT, 3, 0, 1)
    if tooltip and reaper.ImGui_SetTooltip then reaper.ImGui_SetTooltip(ctx, tooltip) end
  end
  return reaper.ImGui_IsItemClicked(ctx)
end

local function icon_checkbox(dl, id, x, y, size, checked)
  local bg = checked and COL_ACCENT or COL_PANEL_HI
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + size, y + size, bg, 3)
  local edge = checked and COL_ACCENT or COL_TEXT_DIM
  reaper.ImGui_DrawList_AddRect(dl, x, y, x + size, y + size, edge, 3, 0, 1.5)
  if checked then
    local col = TXT_DARK
    reaper.ImGui_DrawList_AddLine(dl, x + size * 0.22, y + size * 0.55, x + size * 0.42, y + size * 0.75, col, 2)
    reaper.ImGui_DrawList_AddLine(dl, x + size * 0.42, y + size * 0.75, x + size * 0.8, y + size * 0.25, col, 2)
  end
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, '##' .. id, size, size)
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_DrawList_AddRect(dl, x, y, x + size, y + size, COL_ACCENT, 3, 0, 1)
  end
  return reaper.ImGui_IsItemClicked(ctx)
end

local function draw_header(dl, x, y, color_tr, name)
  local hdr = valid_track(color_tr) and native_to_imgui(reaper.GetTrackColor(color_tr)) or COL_HDR_DEF
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + SW, y + HDR_H, hdr, 3)
  local tcol = text_on(hdr)
  reaper.ImGui_DrawList_PushClipRect(dl, x + 3, y, x + SW - 3, y + HDR_H, true)
  local pf = push_font(FONT_SM, 11)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, name)
  reaper.ImGui_DrawList_AddText(dl, x + math.max(3, (SW - tw) * 0.5), y + (HDR_H - th) * 0.5, tcol, name)
  pop_font(pf)
  reaper.ImGui_DrawList_PopClipRect(dl)
end

local function draw_dblabel(dl, x, y, txt)
  local pf = push_font(FONT_SM, 11)
  local tw = reaper.ImGui_CalcTextSize(ctx, txt)
  reaper.ImGui_DrawList_AddText(dl, x + (SW - tw) * 0.5, y + DBLBL_Y, COL_TEXT, txt)
  pop_font(pf)
end

local function button_x(x, i, count)
  local total = count * BTN_W + (count - 1) * BTN_GAP
  return x + (SW - total) * 0.5 + i * (BTN_W + BTN_GAP)
end

-- Track colour dot in front of a name.
local function draw_color_dot_line(dl, color_track, text, text_col)
  local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
  local dotR = 4
  local lh = reaper.ImGui_GetTextLineHeight and reaper.ImGui_GetTextLineHeight(ctx) or 14
  if valid_track(color_track) then
    local col = native_to_imgui(reaper.GetTrackColor(color_track))
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx + dotR, cy + lh * 0.5, dotR, col, 12)
    reaper.ImGui_DrawList_AddCircle(dl, cx + dotR, cy + lh * 0.5, dotR, 0x00000099, 12, 1)
  end
  reaper.ImGui_Dummy(ctx, dotR * 2 + 6, lh)
  reaper.ImGui_SameLine(ctx, 0, 4)
  if text_col then reaper.ImGui_TextColored(ctx, text_col, text)
  else reaper.ImGui_Text(ctx, text) end
end

-- ============================================================
-- Icons
-- ============================================================

local function icon_plus(dl, cx, cy, r, col)
  reaper.ImGui_DrawList_AddLine(dl, cx - r, cy, cx + r, cy, col, 2)
  reaper.ImGui_DrawList_AddLine(dl, cx, cy - r, cx, cy + r, col, 2)
end

local function icon_folder(dl, cx, cy, r, col)
  local w, h = r * 1.7, r * 1.15
  local x0, y0 = cx - w * 0.5, cy - h * 0.35
  reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0 + 2, x0 + w, y0 + h, col, 1)
  reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0 - 2, x0 + w * 0.55, y0 + 3, col, 1)
end

local function icon_group(dl, cx, cy, r, col)
  local rr = r * 0.55
  local off = rr * 0.85
  reaper.ImGui_DrawList_AddCircle(dl, cx - off, cy - off * 0.5, rr, col, 12, 1.6)
  reaper.ImGui_DrawList_AddCircle(dl, cx + off, cy + off * 0.5, rr, col, 12, 1.6)
end

local function icon_pencil(dl, cx, cy, r, col)
  local x1, y1 = cx - r * 0.7, cy + r * 0.7
  local x2, y2 = cx + r * 0.5, cy - r * 0.5
  reaper.ImGui_DrawList_AddLine(dl, x1, y1, x2, y2, col, 2.2)
  reaper.ImGui_DrawList_AddLine(dl, x1, y1, x1 + r * 0.28, y1 - r * 0.05, col, 2.2)
  reaper.ImGui_DrawList_AddLine(dl, x2 - r * 0.15, y2 - r * 0.15, x2 + r * 0.15, y2 + r * 0.15, col, 2.2)
end

local function icon_trash(dl, cx, cy, r, col)
  local w, h = r * 1.1, r * 1.3
  local x0, y0 = cx - w * 0.5, cy - h * 0.35
  reaper.ImGui_DrawList_AddLine(dl, x0 - 2, y0, x0 + w + 2, y0, col, 2)
  reaper.ImGui_DrawList_AddLine(dl, cx - w * 0.2, y0 - 4, cx + w * 0.2, y0 - 4, col, 1.6)
  reaper.ImGui_DrawList_AddRect(dl, x0, y0 + 3, x0 + w, y0 + h, col, 1, 0, 1.6)
  reaper.ImGui_DrawList_AddLine(dl, cx - w * 0.2, y0 + 7, cx - w * 0.2, y0 + h - 3, col, 1.2)
  reaper.ImGui_DrawList_AddLine(dl, cx + w * 0.2, y0 + 7, cx + w * 0.2, y0 + h - 3, col, 1.2)
end

local function icon_save(dl, cx, cy, r, col)
  local s = r * 1.3
  local x0, y0 = cx - s * 0.5, cy - s * 0.5
  reaper.ImGui_DrawList_AddRect(dl, x0, y0, x0 + s, y0 + s, col, 1, 0, 1.6)
  reaper.ImGui_DrawList_AddRectFilled(dl, x0 + s * 0.25, y0, x0 + s * 0.75, y0 + s * 0.28, col, 0)
  reaper.ImGui_DrawList_AddRect(dl, x0 + s * 0.2, y0 + s * 0.5, x0 + s * 0.8, y0 + s * 0.92, col, 0, 0, 1.2)
end

local function icon_list(dl, cx, cy, r, col)
  local w = r * 1.4
  for i = 0, 2 do
    local yy = cy - r * 0.55 + i * (r * 0.55)
    reaper.ImGui_DrawList_AddLine(dl, cx - w * 0.5, yy, cx - w * 0.5 + w * (0.9 - i * 0.15), yy, col, 1.8)
  end
end

local function icon_power(dl, cx, cy, r, col)
  reaper.ImGui_DrawList_AddCircle(dl, cx, cy + r * 0.1, r * 0.75, col, 16, 1.8)
  reaper.ImGui_DrawList_AddLine(dl, cx, cy - r * 0.8, cx, cy + r * 0.05, col, 1.8)
end

local function icon_minimize(dl, cx, cy, r, col)
  reaper.ImGui_DrawList_AddLine(dl, cx - r * 0.8, cy, cx + r * 0.8, cy, col, 2.2)
end

-- ============================================================
-- Channel strips
-- ============================================================

-- The VCA's own strip, on the left of the row. Its fader is the offset,
-- not a track volume. M mutes everything the VCA controls, L links the
-- VCA to a Reaper track so it can be automated.
local function render_vca_master_strip(dl, x, y, vca)
  local masterTrack = vca.master_guid and ResolveTrackByGUID(vca.master_guid) or nil
  local displayName = masterTrack and track_label(masterTrack) or vca.name
  draw_header(dl, x, y, masterTrack, displayName)
  reaper.ImGui_DrawList_AddRect(dl, x - 1, y - 1, x + SW + 1, y + SH + 1, COL_ACCENT, 3, 0, 1)

  local by = y + BTN_Y
  if toggle_button(dl, 'vcaM' .. vca.id, button_x(x, 0, 2), by, BTN_W, BTN_H, "M", vca.muted, COL_MUTE) then
    if masterTrack then
      reaper.CSurf_OnMuteChangeEx(masterTrack, vca.muted and 0 or 1, false)
    else
      vca.muted = not vca.muted
    end
    mark_dirty()
  end

  local link_on = masterTrack ~= nil
  if toggle_button(dl, 'vcaL' .. vca.id, button_x(x, 1, 2), by, BTN_W, BTN_H, "L", link_on, COL_ACCENT, "L = link master") then
    if link_on then
      vca.master_guid = nil
      mark_dirty()
    else
      local sel = reaper.GetSelectedTrack(0, 0)
      if sel and IsTrackAssignedToVCA(vca, reaper.GetTrackGUID(sel)) then
        ask("'" .. track_label(sel) .. "' is already an assigned target of '" .. vca.name .. "'.\n" ..
            "Linking the master to one of its own targets would create a feedback loop.\n" ..
            "Select a different (unassigned) track first.", 0)
      elseif sel then
        vca.master_guid = reaper.GetTrackGUID(sel)
        mark_dirty()
      else
        ask("No track selected.\nCreate a new master track for '" .. vca.name .. "'?", 4, function(r)
          if r ~= 6 then return end
          local idx = reaper.CountTracks(0)
          reaper.InsertTrackAtIndex(idx, true)
          local tr = reaper.GetTrack(0, idx)
          if not valid_track(tr) then return end
          reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', vca.name .. ' (VCA master)', true)
          vca.master_guid = reaper.GetTrackGUID(tr)
          mark_dirty()
        end)
      end
    end
  end

  local fx = x + (SW - FADER_W) * 0.5
  local db = masterTrack and AMP2DB(GetMasterTrackVol(masterTrack)) or vca.fader_db
  local newdb, fch = fader(dl, 'vca' .. vca.id, fx, y + FADER_Y, FADER_W, FADER_H, db, COL_ACCENT)
  if fch then
    newdb = clamp(newdb, WIDGET_DB_MIN, WIDGET_DB_MAX)
    if masterTrack then
      reaper.CSurf_OnVolumeChangeEx(masterTrack, DB2AMP(newdb), false, false)
    else
      vca.fader_db = newdb
    end
    mark_dirty()
  end
  draw_dblabel(dl, x, y, fmt_db(db))

  if vca.master_guid and not masterTrack then
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y + HDR_H, x + SW, y + SH, COL_BROKEN, 3)
  end
end

-- An assigned track, showing its real volume. The x removes it from the
-- VCA and leaves it at its current level.
local function render_track_strip(dl, x, y, entry, id, on_remove)
  local tr = ResolveTrackByGUID(entry.guid)
  draw_header(dl, x, y, tr, tr and track_label(tr) or "(missing)")

  if toggle_button(dl, id .. 'x', button_x(x, 0, 1), y + BTN_Y, BTN_W, BTN_H, "x", false, COL_MUTE) then
    on_remove()
  end

  local actualDb = tr and AMP2DB(reaper.GetMediaTrackInfo_Value(tr, 'D_VOL')) or NEG_INF_DB
  local fx = x + (SW - FADER_W) * 0.5
  local accent = tr and native_to_imgui(reaper.GetTrackColor(tr)) or COL_ACCENT
  local newdb, fch = fader(dl, id, fx, y + FADER_Y, FADER_W, FADER_H, actualDb, accent)
  if fch and tr then
    reaper.CSurf_OnVolumeChangeEx(tr, DB2AMP(clamp(newdb, WIDGET_DB_MIN, WIDGET_DB_MAX)), false, false)
    mark_dirty()
  end
  draw_dblabel(dl, x, y, fmt_db(actualDb))

  if entry.broken then
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y + HDR_H, x + SW, y + SH, COL_BROKEN, 3)
  end
end

-- An assigned send, named after where it goes, with the track it comes
-- from written underneath.
local function render_send_strip(dl, x, y, entry, id, on_remove)
  local srcTrack = ResolveTrackByGUID(entry.srcGuid)
  local dstTrack = ResolveTrackByGUID(entry.dstGuid)
  draw_header(dl, x, y, dstTrack, dstTrack and track_label(dstTrack) or "(missing)")

  local pf = push_font(FONT_SM, 11)
  local srcLabel = srcTrack and track_label(srcTrack) or "?"
  local tw, th = reaper.ImGui_CalcTextSize(ctx, srcLabel)
  local dotR, gap = 4, 5
  local start_x = x + math.max(2, (SW - (dotR * 2 + gap + tw)) * 0.5)
  local mid_y = y + HDR_H + SRC_H * 0.5
  reaper.ImGui_DrawList_PushClipRect(dl, x + 2, y + HDR_H, x + SW - 2, y + HDR_H + SRC_H, true)
  if srcTrack then
    local dotcol = native_to_imgui(reaper.GetTrackColor(srcTrack))
    reaper.ImGui_DrawList_AddCircleFilled(dl, start_x + dotR, mid_y, dotR, dotcol, 12)
    reaper.ImGui_DrawList_AddCircle(dl, start_x + dotR, mid_y, dotR, 0x00000099, 12, 1)
  end
  reaper.ImGui_DrawList_AddText(dl, start_x + dotR * 2 + gap, mid_y - th * 0.5, 0xFFFFFFFF, srcLabel)
  reaper.ImGui_DrawList_PopClipRect(dl)
  pop_font(pf)

  if toggle_button(dl, id .. 'x', button_x(x, 0, 1), y + BTN_Y, BTN_W, BTN_H, "x", false, COL_MUTE) then
    on_remove()
  end

  local sendidx = (srcTrack and dstTrack) and FindSendByOrdinal(srcTrack, dstTrack, entry.ordinal) or nil
  local actualDb = sendidx and AMP2DB(reaper.GetTrackSendInfo_Value(srcTrack, 0, sendidx, 'D_VOL')) or NEG_INF_DB
  local fx = x + (SW - FADER_W) * 0.5
  local accent = dstTrack and native_to_imgui(reaper.GetTrackColor(dstTrack)) or COL_ACCENT
  local newdb, fch = fader(dl, id, fx, y + FADER_Y, FADER_W, FADER_H, actualDb, accent)
  if fch and sendidx then
    reaper.CSurf_OnSendVolumeChange(srcTrack, sendidx, DB2AMP(clamp(newdb, WIDGET_DB_MIN, WIDGET_DB_MAX)), false)
    mark_dirty()
  end
  draw_dblabel(dl, x, y, fmt_db(actualDb))

  if entry.broken then
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y + HDR_H, x + SW, y + SH, COL_BROKEN, 3)
  end
end

-- ============================================================
-- Left panel: the list of VCAs
-- ============================================================

local function draw_left_panel()
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  if #vcas == 0 then
    reaper.ImGui_TextColored(ctx, COL_TEXT_DIM, "No VCA yet. Use '+ New VCA'.")
    return
  end
  for i, v in ipairs(vcas) do
    local sel = (v == active_vca)
    local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
    if reaper.ImGui_Selectable(ctx, '##vcarow' .. i, sel, 0, 0, ROW_H) then
      SetActiveVCA(v)
    end
    local midy = cy + ROW_H * 0.5
    local dotcol = v.muted and COL_MUTE or COL_ACCENT
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx + 10, midy, 4, dotcol, 16)
    reaper.ImGui_DrawList_AddCircle(dl, cx + 10, midy, 4, 0x00000099, 16, 1)

    -- a linked VCA goes by the name of the track it follows
    local mt = v.master_guid and ResolveTrackByGUID(v.master_guid) or nil
    local name = mt and track_label(mt) or v.name
    local tcol = sel and COL_ACCENT or COL_TEXT
    local name_x = cx + 24
    reaper.ImGui_DrawList_PushClipRect(dl, name_x, cy, cx + LEFT_W - 40, cy + ROW_H, true)
    local _, th = reaper.ImGui_CalcTextSize(ctx, name)
    reaper.ImGui_DrawList_AddText(dl, name_x, midy - th * 0.5, tcol, name)
    reaper.ImGui_DrawList_PopClipRect(dl)

    local dbtxt = fmt_db(v.fader_db)
    local dtw = reaper.ImGui_CalcTextSize(ctx, dbtxt)
    reaper.ImGui_DrawList_AddText(dl, cx + LEFT_W - 34 - dtw, midy - th * 0.5, COL_TEXT_DIM, dbtxt)
  end
end

-- ============================================================
-- Right panel: the strips of the selected VCA
-- ============================================================

local function draw_strips_row()
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  if not active_vca then
    reaper.ImGui_TextColored(ctx, COL_TEXT_DIM, "Select or create a VCA.")
    return
  end
  local vca = active_vca

  local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local ox, oy = reaper.ImGui_GetCursorScreenPos(ctx)
  ox, oy = ox + PAD, oy + PAD

  -- strips are as tall as the window allows and follow it when resized
  SH = math.max(SH_MIN, math.floor(avail_h - PAD * 2))
  FADER_H = math.max(100, SH - FADER_Y - 22)
  DBLBL_Y = FADER_Y + FADER_H + 2

  local x = ox
  render_vca_master_strip(dl, x, oy, vca)
  x = x + SW + MASTER_GAP

  for i, t in ipairs(vca.tracks) do
    render_track_strip(dl, x, oy, t, 'trk' .. i, function() RemoveTrackFromVCA(vca, t.guid) end)
    x = x + SW + STRIP_GAP
  end
  for i, s in ipairs(vca.sends) do
    render_send_strip(dl, x, oy, s, 'snd' .. i, function() RemoveSendFromVCA(vca, s.srcGuid, s.dstGuid, s.ordinal) end)
    x = x + SW + STRIP_GAP
  end
  if #vca.tracks + #vca.sends == 0 then
    reaper.ImGui_DrawList_AddText(dl, x, oy + HDR_H, COL_TEXT_DIM, "(no element assigned -- use the Assignation panel)")
  end

  reaper.ImGui_SetCursorScreenPos(ctx, ox, oy)
  reaper.ImGui_Dummy(ctx, (x - ox) + PAD, SH)
end

-- ============================================================
-- Assignment panel
-- ============================================================

-- Takes the place of the VCA list when the list button in the toolbar
-- is on. Plus adds the tracks selected in Reaper to the VCA, the folder
-- button lists the children of those tracks and their sends, and the
-- rings button ticks every send heading to the same destination at
-- once.

local group_select_mode = false

local function draw_assignment_panel()
  if not active_vca then
    reaper.ImGui_TextColored(ctx, COL_TEXT_DIM, "Select or create a VCA first.")
    return
  end
  local vca = active_vca
  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  local bs = 28
  local bx, by = reaper.ImGui_GetCursorScreenPos(ctx)
  if icon_button(dl, 'addtrk', bx, by, bs, bs, icon_plus, 'Add selected track(s) as VCA target(s)') then
    local n = reaper.CountSelectedTracks(0)
    for i = 0, n - 1 do AddTrackToVCA(vca, reaper.GetSelectedTrack(0, i)) end
    mark_dirty()
  end
  if icon_button(dl, 'inspect', bx + bs + 8, by, bs, bs, icon_folder, 'Inspect children of all selected tracks') then
    local list = {}
    local n = reaper.CountSelectedTracks(0)
    for i = 0, n - 1 do list[#list + 1] = reaper.GetSelectedTrack(0, i) end
    pickerParentTracks = list
  end
  if icon_toggle_button(dl, 'groupsel', bx + (bs + 8) * 2, by, bs, bs, icon_group, group_select_mode,
      'Group select: checking one send also checks/unchecks every other send going to the same destination') then
    group_select_mode = not group_select_mode
  end
  reaper.ImGui_SetCursorScreenPos(ctx, bx, by + bs + 10)

  local validParents = {}
  for _, p in ipairs(pickerParentTracks) do
    if valid_track(p) then validParents[#validParents + 1] = p end
  end
  pickerParentTracks = validParents

  if #pickerParentTracks > 0 then
    local names = {}
    for _, p in ipairs(pickerParentTracks) do names[#names + 1] = track_label(p) end
    reaper.ImGui_Text(ctx, 'Sends on children of: ' .. table.concat(names, ', '))

    local children, seen = {}, {}
    for _, p in ipairs(pickerParentTracks) do
      for _, c in ipairs(get_bus_children(p)) do
        if not seen[c] then children[#children + 1] = c; seen[c] = true end
      end
    end

    for _, child in ipairs(children) do
      draw_color_dot_line(dl, child, track_label(child), COL_ACCENT)
      local sends = GetTrackSendsInfo(child)
      if #sends == 0 then
        reaper.ImGui_TextDisabled(ctx, '  (no sends)')
      end
      for _, sInfo in ipairs(sends) do
        local srcGuid = reaper.GetTrackGUID(child)
        local _, ordinal = OrdinalOfSend(child, sInfo.idx)
        local dstGuid = valid_track(sInfo.destTrack) and reaper.GetTrackGUID(sInfo.destTrack) or nil
        if ordinal and dstGuid then
          local checked = false
          for _, s in ipairs(vca.sends) do
            if s.srcGuid == srcGuid and s.dstGuid == dstGuid and s.ordinal == ordinal then checked = true end
          end
          local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
          local clicked = icon_checkbox(dl, srcGuid .. dstGuid .. tostring(sInfo.idx), cx, cy, 16, checked)
          reaper.ImGui_SameLine(ctx)
          draw_color_dot_line(dl, sInfo.destTrack, '-> ' .. sInfo.destName)
          if clicked then
            local newVal = not checked
            if group_select_mode then
              for _, c2 in ipairs(children) do
                local c2Guid = reaper.GetTrackGUID(c2)
                for _, s2Info in ipairs(GetTrackSendsInfo(c2)) do
                  if reaper.GetTrackGUID(s2Info.destTrack) == dstGuid then
                    if newVal then AddSendToVCA(vca, c2, s2Info.idx)
                    else
                      local _, ord2 = OrdinalOfSend(c2, s2Info.idx)
                      if ord2 then RemoveSendFromVCA(vca, c2Guid, dstGuid, ord2) end
                    end
                  end
                end
              end
            else
              if newVal then AddSendToVCA(vca, child, sInfo.idx)
              else RemoveSendFromVCA(vca, srcGuid, dstGuid, ordinal) end
            end
            mark_dirty()
          end
        end
      end
    end
  else
    reaper.ImGui_TextColored(ctx, COL_TEXT_DIM, "Select folders / busses")
    reaper.ImGui_TextColored(ctx, COL_TEXT_DIM, "track(s) in Reaper, then click on +.")
  end
end

-- ============================================================
-- Toolbar
-- ============================================================

local show_assign_panel = false
local rename_buf = ""
local want_quit = false
local is_minimized = false
local last_full_w, last_full_h = 980, 640
local pending_resize = nil
local MIN_WINDOW_H = 92
-- Height of the reduced window, measured from the toolbar itself when
-- reducing, since it depends on fonts and display scaling.
local minimized_h = MIN_WINDOW_H

local function draw_toolbar()
  local pf = push_font(FONT_HDR, 14)
  local title_w = reaper.ImGui_CalcTextSize(ctx, "SK EXTENDED VCA")
  reaper.ImGui_TextColored(ctx, COL_ACCENT, "SK EXTENDED VCA")
  pop_font(pf)

  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local bs, gap = 28, 6
  local bx, by = reaper.ImGui_GetCursorScreenPos(ctx)

  if icon_button(dl, 'newvca', bx, by, bs, bs, icon_plus, 'Create a new VCA') then NewVCA() end

  local x2 = bx + bs + gap
  if icon_button(dl, 'renamevca', x2, by, bs, bs, icon_pencil, 'Rename the active VCA') and active_vca then
    rename_buf = active_vca.name
    reaper.ImGui_OpenPopup(ctx, 'rename_vca_popup')
  end

  local x3 = x2 + bs + gap
  local assign_tooltip = show_assign_panel and 'Close the Assignation panel' or 'Assign tracks and sends to the active VCA'
  if icon_toggle_button(dl, 'assignvca', x3, by, bs, bs, icon_list, show_assign_panel, assign_tooltip) then
    show_assign_panel = not show_assign_panel
  end

  local x4 = x3 + bs + gap
  if icon_button(dl, 'savevca', x4, by, bs, bs, icon_save, 'Save all VCAs to the project') then
    SaveState(cur_proj)
  end

  local x5 = x4 + bs + gap
  if icon_button(dl, 'delvca', x5, by, bs, bs, icon_trash, 'Delete the active VCA') and active_vca then
    local target = active_vca
    ask("Delete VCA '" .. target.name .. "'?\nThis cannot be undone.", 4, function(r)
      if r ~= 6 then return end
      for i, v in ipairs(vcas) do if v == target then table.remove(vcas, i); break end end
      if active_vca == target then SetActiveVCA(vcas[1]) end
      if #vcas == 0 then nextVcaId = 1 end
      mark_dirty()
    end)
  end

  local x6 = x5 + bs + gap
  local minimize_tooltip = is_minimized and 'Restore the window' or 'Reduce the window'
  if icon_toggle_button(dl, 'minimizevca', x6, by, bs, bs, icon_minimize, is_minimized, minimize_tooltip) then
    if is_minimized then
      pending_resize = { w = last_full_w, h = last_full_h }
    else
      local content_w = math.max(title_w, (x6 + bs + gap + bs) - bx)
      -- the reduced window ends just below the toolbar's separator line,
      -- plus the window's own bottom margin
      local _, wy = reaper.ImGui_GetWindowPos(ctx)
      local pad_y = 8
      if reaper.ImGui_GetStyleVar and reaper.ImGui_StyleVar_WindowPadding then
        local _, py = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding())
        if py then pad_y = py end
      end
      minimized_h = math.ceil((by + bs + 8 + 1) - wy + pad_y + 2)
      pending_resize = { w = content_w + 24, h = minimized_h }
    end
    is_minimized = not is_minimized
  end

  local x7 = x6 + bs + gap
  if icon_button(dl, 'quitvca', x7, by, bs, bs, icon_power,
      'Quit: stop the VCA engine and close (assigned tracks/sends keep their current levels)') then
    ask("Stop the SK Extended VCA engine?\nVCAs will no longer apply their offset until the script is run again.",
      4, function(r) if r == 6 then want_quit = true end end)
  end

  reaper.ImGui_SetCursorScreenPos(ctx, bx, by + bs + 8)
  reaper.ImGui_Separator(ctx)
end

local function draw_rename_popup()
  if reaper.ImGui_BeginPopup(ctx, 'rename_vca_popup') then
    reaper.ImGui_Text(ctx, 'VCA name:')
    if reaper.ImGui_IsWindowAppearing(ctx) and reaper.ImGui_SetKeyboardFocusHere then
      reaper.ImGui_SetKeyboardFocusHere(ctx)
    end
    reaper.ImGui_SetNextItemWidth(ctx, 220)
    local rv, newv = reaper.ImGui_InputText(ctx, '##renamevca', rename_buf, 0)
    if rv then rename_buf = newv end
    local enter_pressed = reaper.ImGui_IsKeyPressed and reaper.ImGui_Key_Enter
      and (reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter())
        or (reaper.ImGui_Key_KeypadEnter and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter())))
    local ok_clicked = reaper.ImGui_Button(ctx, 'OK')
    if (ok_clicked or enter_pressed) and active_vca and rename_buf ~= '' then
      active_vca.name = rename_buf
      mark_dirty()
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, 'Cancel') then reaper.ImGui_CloseCurrentPopup(ctx) end
    reaper.ImGui_EndPopup(ctx)
  end
end

-- ============================================================
-- Window theme
-- ============================================================

local function push_theme_base()
  local list = {
    { reaper.ImGui_Col_WindowBg, COL_BG }, { reaper.ImGui_Col_Text, COL_TEXT },
    { reaper.ImGui_Col_FrameBg, COL_PANEL }, { reaper.ImGui_Col_FrameBgHovered, COL_PANEL_HI },
    { reaper.ImGui_Col_FrameBgActive, COL_PANEL_HI }, { reaper.ImGui_Col_CheckMark, COL_ACCENT },
    { reaper.ImGui_Col_Border, COL_EDGE }, { reaper.ImGui_Col_Separator, COL_EDGE },
    { reaper.ImGui_Col_ScrollbarBg, COL_BG }, { reaper.ImGui_Col_ScrollbarGrab, COL_PANEL_HI },
    { reaper.ImGui_Col_ScrollbarGrabHovered, COL_ACCENT }, { reaper.ImGui_Col_ScrollbarGrabActive, COL_ACCENT },
    { reaper.ImGui_Col_TitleBg, COL_BG }, { reaper.ImGui_Col_TitleBgActive, COL_PANEL },
    { reaper.ImGui_Col_Header, COL_PANEL_HI }, { reaper.ImGui_Col_HeaderHovered, 0x4A4A44FF },
    { reaper.ImGui_Col_HeaderActive, COL_PANEL_HI },
  }
  local pushed = 0
  for _, e in ipairs(list) do
    if e[1] then reaper.ImGui_PushStyleColor(ctx, e[1](), e[2]); pushed = pushed + 1 end
  end
  return pushed
end

local function push_theme_buttons()
  local list = {
    { reaper.ImGui_Col_Button, COL_PANEL_HI }, { reaper.ImGui_Col_ButtonHovered, 0x4A4A44FF },
    { reaper.ImGui_Col_ButtonActive, COL_ACCENT },
  }
  local pushed = 0
  for _, e in ipairs(list) do
    if e[1] then ui_push_color(e[1](), e[2]); pushed = pushed + 1 end
  end
  return pushed
end

local CHILD_HSCROLL = reaper.ImGui_WindowFlags_HorizontalScrollbar and reaper.ImGui_WindowFlags_HorizontalScrollbar() or 0

-- ============================================================
-- Drawing the window
-- ============================================================

local function draw_frame()
  -- a click on reduce or restore only resizes the window on the next
  -- redraw, so this one keeps the layout it started with
  local minimized_now = is_minimized

  local nbtn = push_theme_buttons()
  local pf = push_font(FONT, 13)
  draw_toolbar()
  draw_rename_popup()

  if not minimized_now then
    if reaper.ImGui_GetWindowSize then
      last_full_w, last_full_h = reaper.ImGui_GetWindowSize(ctx)
    end

    local _, strips_h = reaper.ImGui_GetContentRegionAvail(ctx)
    strips_h = math.max(strips_h, SH_MIN + PAD * 2)

    -- each panel is closed only if it was really opened
    ui_push_color(reaper.ImGui_Col_ChildBg(), COL_PANEL)
    if ui_begin_child('left', LEFT_W, strips_h, 0, 0) then
      if show_assign_panel then
        if active_vca then
          reaper.ImGui_TextColored(ctx, COL_ACCENT, active_vca.name)
          reaper.ImGui_Separator(ctx)
        end
        draw_assignment_panel()
      else
        draw_left_panel()
      end
      ui_end_child()
    end
    ui_pop_color(1)

    reaper.ImGui_SameLine(ctx, 0, PANEL_GAP)

    if ui_begin_child('right', 0, strips_h, 0, CHILD_HSCROLL) then
      draw_strips_row()
      ui_end_child()
    end
  end

  -- one undo point per mouse move, added when the button is released
  if g_dirty and reaper.ImGui_IsMouseReleased(ctx, 0) then
    if reaper.Undo_OnStateChange2 then reaper.Undo_OnStateChange2(0, "SK Extended VCA: adjust")
    elseif reaper.Undo_OnStateChange then reaper.Undo_OnStateChange("SK Extended VCA: adjust") end
    g_dirty = false
  end

  -- the space bar would otherwise be swallowed by this window, so it is
  -- passed on to Reaper's play/stop, unless a name or value is being typed
  if reaper.ImGui_IsKeyPressed and reaper.ImGui_Key_Space
      and reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows())
      and not reaper.ImGui_IsAnyItemActive(ctx)
      and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Space(), false) then
    reaper.Main_OnCommand(40044, 0)
  end

  pop_font(pf)
  ui_pop_color(nbtn)
end

-- ============================================================
-- Main loop
-- ============================================================

local function loop()
  set_toolbar_state(true)
  reaper.SetExtState(RUNSTATE_SECTION, 'heartbeat', tostring(reaper.time_precise()), false)
  SyncActiveProject()

  -- the window broke down at some point: build a fresh one
  if not ctx_valid() then create_ui_context() end

  -- the action was run again: bring the window back to the front
  if reaper.GetExtState(RUNSTATE_SECTION, 'want_show') == '1' then
    reaper.SetExtState(RUNSTATE_SECTION, 'want_show', '0', false)
    if is_minimized then
      pending_resize = { w = last_full_w, h = last_full_h }
      is_minimized = false
    end
    if reaper.ImGui_SetNextWindowFocus then reaper.ImGui_SetNextWindowFocus(ctx) end
  end

  local npushed = push_theme_base()
  if reaper.ImGui_SetNextWindowSizeConstraints then
    if is_minimized then
      reaper.ImGui_SetNextWindowSizeConstraints(ctx, 150, minimized_h, 1000000, minimized_h + 40)
    else
      reaper.ImGui_SetNextWindowSizeConstraints(ctx, 980, 640, 1000000, 1000000)
    end
  end
  if reaper.ImGui_SetNextWindowSize then
    reaper.ImGui_SetNextWindowSize(ctx, 980, 640, reaper.ImGui_Cond_FirstUseEver())
  end
  if pending_resize and reaper.ImGui_SetNextWindowSize then
    reaper.ImGui_SetNextWindowSize(ctx, pending_resize.w, pending_resize.h, reaper.ImGui_Cond_Always())
    pending_resize = nil
  end

  local begin_flags = reaper.ImGui_WindowFlags_NoCollapse and reaper.ImGui_WindowFlags_NoCollapse() or 0
  local visible = reaper.ImGui_Begin(ctx, 'SK Extended VCA##skvca3', nil, begin_flags)
  if visible then
    local ok, err = pcall(draw_frame)
    -- the problem is written down first, before anything else can fail
    if not ok then report_error(err) end
    -- if the window was thrown away meanwhile, there is nothing left to
    -- close: a fresh one is built on the next redraw
    if ctx_valid() then
      ui_unwind()
      reaper.ImGui_End(ctx)
    end
  end
  if ctx_valid() then reaper.ImGui_PopStyleColor(ctx, npushed) end

  -- the VCAs keep working whether the window is open, shrunk or hidden
  local eok, eerr = pcall(run_engine)
  if not eok then report_error(eerr) end

  flush_pending_dialogs()

  if want_quit then
    SaveState(cur_proj)
    return
  end
  reaper.defer(loop)
end

LoadState(cur_proj)
reaper.defer(loop)
