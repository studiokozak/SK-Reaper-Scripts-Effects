-- @description SK Balance Control
-- @author Stephan (Studio Kozak)
-- @provides [main] .
-- @about
--   A mixing console that lets you build your own custom bank of faders.
--
--   The left panel lists every track in the project, and every one of its
--   outgoing sends underneath it. Tick the checkbox next to a track or a
--   send to show it as a strip in the right panel - untick to remove it.
--   Strips appear in the order you checked them and stay there until you
--   uncheck them (or the underlying track/send is deleted).
--
--   Each strip has mute, solo, phase, pan and volume controls, exactly
--   like SK Bus Console. Right-click a fader to type an exact dB value.
--   A send strip also has a routing-type menu (Post-Fader / Pre-FX /
--   Pre-Fader). Soloing a send mutes that send's owner track's other
--   sends until you un-solo or uncheck it.
--
--   Clicking a strip's header selects the underlying track (or, for a
--   send strip, the destination track it points to).
--
--   LINK: the chain icon on a strip gangs it with other linked strips,
--   whatever their mix of tracks and sends. Moving one linked fader or
--   pan moves all the others by the same amount, keeping their balance -
--   the whole group stops together if any one of them reaches its limit.
--   Muting, soloing or flipping phase on a linked strip does the same to
--   the rest of the group. The toolbar's "Link all" button links or
--   unlinks every visible strip at once. Right-click an active link icon
--   to make it "inverse" (blue): it then mirrors the group instead of
--   following it.
--
--   SNAPSHOTS: the toolbar's A/B/C/D buttons save or recall the whole
--   bank - which tracks/sends are checked, plus their fader/pan/mute/
--   phase/type balance. Right-click a slot to save into it, left-click to
--   recall it, Ctrl+right-click to clear it. Saved with the project.
--
--   Type in the filter box to narrow the left-panel list by name.
--
--   Requires ReaImGui (SWS recommended).

-- Stop here if ReaImGui isn't installed.
if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "This script requires ReaImGui.\n\nInstall it via ReaPack:\nExtensions > ReaPack > Browse packages > 'ReaImGui: ReaScript binding for Dear ImGui'.",
    "SK Balance Control", 0)
  return
end

-- =============================================================================
-- Colors (Studio Kozak dark / amber theme)
-- =============================================================================
local COL_BG        = 0x1C1C1AFF
local COL_PANEL     = 0x2A2A27FF
local COL_PANEL_HI  = 0x3A3A35FF
local COL_TEXT      = 0xD9D3C4FF
local COL_TEXT_DIM  = 0x8A857AFF
local COL_ACCENT    = 0xE0A030FF
local COL_INK       = 0x1A1A18FF
local COL_EDGE      = 0x14141288

local COL_GROOVE    = 0x141412FF
local COL_GROOVE_DK = 0x0A0A09FF
local COL_CAP       = 0x4A4A44FF
local COL_CAP_EDGE  = 0x000000FF
local COL_BEVEL_HI  = 0xFFFFFF22
local COL_BEVEL_LO  = 0x00000066

local COL_KNOB      = 0x33332FFF
local COL_KNOB_EDGE = 0x000000FF
local COL_BTN       = 0x33332FFF
local COL_BTN_EDGE  = 0x000000AA

local COL_CHECK_BG     = 0x6E685DFF  -- unchecked checklist box fill (lighter than panel)
local COL_CHECK_BORDER = 0xC9C3B4FF  -- unchecked checklist box border

local COL_MUTE      = 0xC0402FFF
local COL_SOLO      = 0xE0A030FF
local COL_PHASE     = 0x3B8FB0FF
local COL_LINK      = 0xE0A030FF
local COL_LINK_INV  = 0x4A90D9FF  -- link icon color when "inverse"

local COL_HDR_DEF   = 0x555049FF
local COL_ENV_V     = 0x5FC26BFF  -- accent green, used for the Sends toggle and send rows
local COL_TICK      = 0x55504955
local COL_TICK_0    = 0xE0A03088
local COL_DIM       = 0x0E0E0CB0

local TXT_DARK      = 0x141412FF
local TXT_LIGHT     = 0xF0ECE0FF

-- =============================================================================
-- Sizes and spacing for one strip
-- =============================================================================
local SW          = 66
local SH          = 409     -- recalculated every frame to fill the window
local SH_MIN      = 380
local STRIP_GAP   = 6
local PAD         = 8

local HDR_H       = 28
local ORIGIN_H    = 14       -- room for the origin-track name row on a send strip
local TYPE_H      = 18       -- room for the send-type menu on a send strip
local KNOB_D      = 32
local KNOB_Y      = HDR_H + ORIGIN_H + TYPE_H + 6
local PANLBL_Y    = KNOB_Y + KNOB_D + 1
local BTN_W       = 16
local BTN_ROW_GAP = 3        -- gap between the M/S/P row and the Link row
local BTN_H       = 16
local BTN_GAP     = 4
local BTN_Y       = PANLBL_Y + 14
local FADER_W     = 22
local FADER_H     = 200
local FADER_Y     = BTN_Y + BTN_H + BTN_ROW_GAP + BTN_H + 6
local DBLBL_Y     = FADER_Y + FADER_H + 2

local LEFT_W      = 260      -- width of the track/send checklist panel
local PANEL_GAP   = 6
local ROW_H       = 20       -- height of one row in the left-panel checklist

-- =============================================================================
-- Window and fonts
-- =============================================================================
local ctx = reaper.ImGui_CreateContext('SK Balance Control')

local NEW_FONT_API = reaper.ImGui_CreateFontFromFile ~= nil

local function make_font(size, bold, italic)
  local flags = 0
  if bold and reaper.ImGui_FontFlags_Bold then flags = flags | reaper.ImGui_FontFlags_Bold() end
  if italic and reaper.ImGui_FontFlags_Italic then flags = flags | reaper.ImGui_FontFlags_Italic() end
  local f
  if NEW_FONT_API then f = reaper.ImGui_CreateFont('sans-serif', flags)
  else f = reaper.ImGui_CreateFont('sans-serif', size, flags) end
  if f and reaper.ImGui_Attach then reaper.ImGui_Attach(ctx, f) end
  return f
end

local FONT           = make_font(13, false)
local FONT_SM        = make_font(11, false)
local FONT_ITALIC    = make_font(13, false, true)
local FONT_HDR       = make_font(14, true)

local function push_font(f, size)
  if not (f and reaper.ImGui_PushFont) then return false end
  if NEW_FONT_API then reaper.ImGui_PushFont(ctx, f, size)
  else reaper.ImGui_PushFont(ctx, f) end
  return true
end
local function pop_font(pushed)
  if pushed then reaper.ImGui_PopFont(ctx) end
end

-- =============================================================================
-- Volume and pan math
-- =============================================================================
local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi else return v end
end

local HAS_SLIDER = reaper.DB2SLIDER and reaper.SLIDER2DB
-- Fader travel goes from -130dB up to +12dB. Every fader, the dB entry
-- popup, and the Link math all use this same range.
local DB_MIN, DB_MAX = -130.0, 12.0
local SLIDER_MIN = HAS_SLIDER and reaper.DB2SLIDER(DB_MIN) or nil
local SLIDER_MAX = HAS_SLIDER and reaper.DB2SLIDER(DB_MAX) or nil

local function gain_to_db(g)
  if g <= 0 then return -150.0 end
  return 20.0 * math.log(g, 10)
end

-- Converts a dB value to a fader position between 0 and 1.
local function db_to_norm(db)
  db = clamp(db, DB_MIN, DB_MAX)
  if HAS_SLIDER then
    local s = reaper.DB2SLIDER(db)
    return clamp((s - SLIDER_MIN) / (SLIDER_MAX - SLIDER_MIN), 0.0, 1.0)
  end
  return (db - DB_MIN) / (DB_MAX - DB_MIN)
end

local function gain_to_norm(g)
  return db_to_norm(gain_to_db(g))
end

local function norm_to_gain(n)
  local db
  if HAS_SLIDER then
    local s = SLIDER_MIN + clamp(n, 0.0, 1.0) * (SLIDER_MAX - SLIDER_MIN)
    db = reaper.SLIDER2DB(s)
  else
    db = DB_MIN + clamp(n, 0.0, 1.0) * (DB_MAX - DB_MIN)
  end
  db = clamp(db, DB_MIN, DB_MAX)
  return 10.0 ^ (db / 20.0)
end

local DEFAULT_NORM = gain_to_norm(1.0)

local function db_to_gain(db)
  db = clamp(db, DB_MIN, DB_MAX)
  return 10.0 ^ (db / 20.0)
end

local function fmt_db(g)
  local db = gain_to_db(g)
  if db <= -144.0 then return "-inf" end
  if db > -0.05 and db < 0.05 then return "0.0" end
  if db > 0 then return string.format("+%.1f", db) end
  return string.format("%.1f", db)
end

local function fmt_pan(p)
  if math.abs(p) < 0.005 then return "C" end
  local pct = math.floor(math.abs(p) * 100 + 0.5)
  return (p < 0 and "L" or "R") .. pct
end

local function native_to_imgui(nc)
  if nc == 0 then return COL_HDR_DEF end
  local r, g, b = reaper.ColorFromNative(nc)
  return (r << 24) | (g << 16) | (b << 8) | 0xFF
end

-- Picks dark or light text depending on how bright the background is.
local function text_on(col)
  local r = (col >> 24) & 0xFF
  local g = (col >> 16) & 0xFF
  local b = (col >> 8) & 0xFF
  local lum = 0.299 * r + 0.587 * g + 0.114 * b
  return lum > 140 and TXT_DARK or TXT_LIGHT
end

local function track_label(tr)
  local _, name = reaper.GetTrackName(tr)
  if name and name ~= "" then return name end
  local n = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
  return "Track " .. n
end

-- True while Ctrl is held, for finer/slower dragging.
local function fine_drag()
  if reaper.ImGui_GetKeyMods and reaper.ImGui_Mod_Ctrl then
    return (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Ctrl()) ~= 0
  end
  return false
end

local function lc(s) return (s or ""):lower() end

-- =============================================================================
-- Reading and writing a track's own outgoing sends
-- =============================================================================
local function sget(tr, idx, k) return reaper.GetTrackSendInfo_Value(tr, 0, idx, k) end
local function sset(tr, idx, k, v) reaper.SetTrackSendInfo_Value(tr, 0, idx, k, v) end

local function set_mute_flag(tr, idx, on)
  local want = on and 1 or 0
  if math.floor(sget(tr, idx, "B_MUTE") + 0.5) ~= want then sset(tr, idx, "B_MUTE", want) end
end

-- Finds the destination track of an outgoing send.
local function get_send_dest(tr, idx)
  local dest = reaper.GetTrackSendInfo_Value(tr, 0, idx, "P_DESTTRACK")
  if type(dest) == "userdata" and reaper.ValidatePtr2(0, dest, "MediaTrack*") then return dest end
  if reaper.BR_GetMediaTrackSendInfo_Track then
    local d = reaper.BR_GetMediaTrackSendInfo_Track(tr, 0, idx, 1)
    if d and reaper.ValidatePtr2(0, d, "MediaTrack*") then return d end
  end
  return nil
end

local function find_track_by_guid(guid)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    if reaper.GetTrackGUID(tr) == guid then return tr end
  end
  return nil
end

local function find_send_index_by_dest(owner, dest_guid)
  local n = reaper.GetTrackNumSends(owner, 0)
  for i = 0, n - 1 do
    local peer = get_send_dest(owner, i)
    if peer and reaper.GetTrackGUID(peer) == dest_guid then return i end
  end
  return nil
end

-- True if the track has children routed into it.
local function is_folder(tr)
  return reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") > 0
end

-- Returns the direct children of a folder track (not grandchildren).
local function get_folder_children(parent)
  local children = {}
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

-- Tracks that either send into `tr`, or (if `tr` is a folder) sit inside it.
local function get_related_sources(tr)
  local list, seen = {}, {}
  local nrecv = reaper.GetTrackNumSends(tr, -1)
  for i = 0, nrecv - 1 do
    local src = reaper.GetTrackSendInfo_Value(tr, -1, i, "P_SRCTRACK")
    if type(src) == "userdata" and src and reaper.ValidatePtr2(0, src, "MediaTrack*") then
      local g = reaper.GetTrackGUID(src)
      if not seen[g] then seen[g] = true; list[#list + 1] = src end
    end
  end
  if is_folder(tr) then
    for _, c in ipairs(get_folder_children(tr)) do
      local g = reaper.GetTrackGUID(c)
      if not seen[g] then seen[g] = true; list[#list + 1] = c end
    end
  end
  return list
end

-- Tracks that `tr` sends into, plus its folder parent (if it's nested
-- inside one) - the reverse of get_related_sources, for moving up
-- the routing/folder hierarchy instead of down.
local function get_related_destinations(tr)
  local list, seen = {}, {}
  local n = reaper.GetTrackNumSends(tr, 0)
  for i = 0, n - 1 do
    local dest = get_send_dest(tr, i)
    if dest then
      local g = reaper.GetTrackGUID(dest)
      if not seen[g] then seen[g] = true; list[#list + 1] = dest end
    end
  end
  local parent = reaper.GetParentTrack(tr)
  if parent then
    local g = reaper.GetTrackGUID(parent)
    if not seen[g] then seen[g] = true; list[#list + 1] = parent end
  end
  return list
end

-- =============================================================================
-- Solo and mute state for sends (REAPER has no built-in send solo)
-- =============================================================================
local S = {}
local managed_buses = {}    -- owner tracks currently under solo control
local prev_soloing = {}

local function getstate(key)
  local st = S[key]
  if not st then st = { solo = false, umute = false }; S[key] = st end
  return st
end

-- Restores an owner track's sends to their real mute state and clears its
-- solo data.
local function restore_bus(entry)
  local owner = entry.tr
  if not reaper.ValidatePtr2(0, owner, "MediaTrack*") then return end
  local oguid = reaper.GetTrackGUID(owner)
  local n = reaper.GetTrackNumSends(owner, 0)
  for i = 0, n - 1 do
    local peer = get_send_dest(owner, i)
    if peer then
      local key = oguid .. '>' .. reaper.GetTrackGUID(peer)
      local st = S[key]
      if st then set_mute_flag(owner, i, st.umute) end
      S[key] = nil
    end
  end
  prev_soloing[oguid] = nil
end

local function restore_all()
  for _, entry in pairs(managed_buses) do restore_bus(entry) end
  managed_buses = {}
end

-- Forces the real mute state of an owner track's sends while any of them
-- is soloed, and restores their user-chosen mutes once solo clears.
local function enforce_solo(owner, oguid, sends, soloing)
  if soloing then
    managed_buses[oguid] = { tr = owner }
    for _, s in ipairs(sends) do
      set_mute_flag(owner, s.idx, not getstate(s.key).solo)
    end
    prev_soloing[oguid] = true
  else
    if prev_soloing[oguid] then
      for _, s in ipairs(sends) do set_mute_flag(owner, s.idx, getstate(s.key).umute) end
      prev_soloing[oguid] = false
      managed_buses[oguid] = nil
    end
    for _, s in ipairs(sends) do getstate(s.key).umute = sget(owner, s.idx, "B_MUTE") > 0.5 end
  end
end

-- =============================================================================
-- Link groups: strips ganged together via their own "L" toggle
-- =============================================================================
local g_link_delta = nil          -- this frame's fader move, in dB
local g_link_source_key = nil
local g_pan_link_delta = nil      -- this frame's pan-knob move
local g_pan_link_source_key = nil
-- link_set[key] holds each strip's link state: off, "normal", or "inverse"
local link_set = {}
local g_link_all_requested = false  -- set when "Link all" is clicked
local g_link_all_lit = false        -- whether every visible strip is linked

-- Last known volume (dB) / pan value we ourselves wrote for each visible
-- key, so we can tell a REAPER-side move (mixer, automation) apart from
-- one the script just made, and still cascade it through a Link group.
local last_vol_db = {}
local last_pan_val = {}

-- +1 for normal, -1 for inverse, used to combine two strips' orientations.
local function link_sign(key)
  return (link_set[key] == "inverse") and -1 or 1
end

-- Moves a whole linked group together by a relative amount (fader dB or
-- pan), stopping the whole group the instant any one member would hit its
-- limit, so they never drift out of balance with each other.
local function apply_linked_group(fader_targets, source_key, raw_delta, lo, hi, get_value, set_value, write_source)
  if not (raw_delta and raw_delta ~= 0 and source_key) then return end
  if not link_set[source_key] then return end

  local source_entry, participants = nil, {}
  for _, t in ipairs(fader_targets) do
    if t.key == source_key then source_entry = t
    elseif t.linked then participants[#participants + 1] = t end
  end
  if not source_entry then return end

  local src_new = get_value(source_entry)
  if not src_new then return end
  local src_old = src_new - raw_delta

  local max_allowed = math.abs(raw_delta)
  local olds, signs = { [source_entry] = src_old }, { [source_entry] = 1 }
  local function note(old_v, sign)
    if (raw_delta > 0) == (sign > 0) then
      max_allowed = math.min(max_allowed, math.max(0, hi - old_v))
    else
      max_allowed = math.min(max_allowed, math.max(0, old_v - lo))
    end
  end
  note(src_old, 1)
  for _, t in ipairs(participants) do
    local v = get_value(t)
    if v then
      local s = link_sign(t.key) * link_sign(source_key)
      olds[t] = v; signs[t] = s
      note(v, s)
    end
  end

  local eff = (raw_delta > 0 and 1 or -1) * max_allowed
  if write_source ~= false then
    set_value(source_entry, clamp(src_old + eff, lo, hi))
  end
  for _, t in ipairs(participants) do
    if olds[t] then set_value(t, clamp(olds[t] + eff * signs[t], lo, hi)) end
  end
end

-- =============================================================================
-- Fader and pan knob widgets
-- =============================================================================
local drag_hold = {}    -- value held while a fader/knob is being dragged
local dbedit_buf = {}   -- text typed into the right-click dB popup

local FADER_HINT_TEXT = "Ctrl = fine   |   double-click = reset"

-- Draws a fader and handles dragging, double-click reset, and the
-- right-click dB entry popup. Returns:
--   norm        current position (0 to 1)
--   changed     true the frame the value actually moved
--   drag_delta  how much it moved this frame (used by Link)
--   active      true while the fader is being held, even if not moving
local function fader(dl, id, x, y, w, h, norm, accent)
  local cx = x + w * 0.5
  local cap_h = 20
  local travel = h - cap_h

  reaper.ImGui_DrawList_AddRectFilled(dl, cx - 3, y, cx + 3, y + h, COL_GROOVE, 2)
  reaper.ImGui_DrawList_AddLine(dl, cx, y + 2, cx, y + h - 2, COL_GROOVE_DK, 1)

  local ticks = { 12, 6, 0, -6, -12, -24, -48 }
  for _, db in ipairs(ticks) do
    local tn = db_to_norm(db)
    local ty = y + (1 - tn) * travel + cap_h * 0.5
    local c = (db == 0) and COL_TICK_0 or COL_TICK
    reaper.ImGui_DrawList_AddLine(dl, x + 1, ty, x + 5, ty, c, 1)
    reaper.ImGui_DrawList_AddLine(dl, x + w - 5, ty, x + w - 1, ty, c, 1)
  end

  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, '##fad' .. id, w, h)
  local changed = false
  local active = false
  local drag_delta = nil
  if reaper.ImGui_IsItemActivated(ctx) then drag_hold[id] = norm end
  if reaper.ImGui_IsItemActive(ctx) then
    active = true
    local held = drag_hold[id] or norm
    local _, dy = reaper.ImGui_GetMouseDelta(ctx)
    if dy ~= 0 then
      local scale = fine_drag() and 0.25 or 1.0
      local new_held = clamp(held - (dy / travel) * scale, 0, 1)
      drag_delta = new_held - held
      held = new_held
      drag_hold[id] = held
      changed = true
    end
    norm = held
  else
    drag_hold[id] = nil
  end
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    drag_delta = DEFAULT_NORM - norm
    norm = DEFAULT_NORM; drag_hold[id] = nil; changed = true
  end
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 1) then
    reaper.ImGui_OpenPopup(ctx, '##dbedit' .. id)
  end
  if reaper.ImGui_BeginPopup and reaper.ImGui_InputDouble and reaper.ImGui_BeginPopup(ctx, '##dbedit' .. id) then
    if reaper.ImGui_IsWindowAppearing(ctx) then
      dbedit_buf[id] = gain_to_db(norm_to_gain(norm))
      if reaper.ImGui_SetKeyboardFocusHere then reaper.ImGui_SetKeyboardFocusHere(ctx) end
    end
    reaper.ImGui_SetNextItemWidth(ctx, 90)
    local rv, newv = reaper.ImGui_InputDouble(ctx, '##dbval' .. id, dbedit_buf[id], 0.5, 0.5, '%.1f')
    if rv then
      dbedit_buf[id] = newv
      local gain = db_to_gain(newv)
      local new_norm = gain_to_norm(gain)
      drag_delta = new_norm - norm
      norm = new_norm
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

  if reaper.ImGui_IsItemHovered(ctx) and not active and reaper.ImGui_SetTooltip then
    local mx, my = reaper.ImGui_GetMousePos(ctx)
    if mx >= x1 and mx <= x2 and my >= cap_y and my <= cap_y + cap_h then
      reaper.ImGui_SetTooltip(ctx, FADER_HINT_TEXT)
    end
  end

  return norm, changed, drag_delta, active
end

-- Same idea as fader() above, but a pan knob (-1 to 1).
local function pan_knob(dl, id, x, y, d, pan)
  local cx, cy = x + d * 0.5, y + d * 0.5
  local r = d * 0.5
  local key = id .. '#p'

  reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, r, COL_KNOB, 28)
  reaper.ImGui_DrawList_AddCircle(dl, cx, cy, r, COL_KNOB_EDGE, 28, 1)
  reaper.ImGui_DrawList_AddCircle(dl, cx, cy, r - 1, COL_BEVEL_HI, 28, 1)

  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, '##pan' .. id, d, d)
  local changed = false
  local active = false
  local drag_delta = nil
  if reaper.ImGui_IsItemActivated(ctx) then drag_hold[key] = pan end
  if reaper.ImGui_IsItemActive(ctx) then
    active = true
    local held = drag_hold[key] or pan
    local _, dy = reaper.ImGui_GetMouseDelta(ctx)
    if dy ~= 0 then
      local scale = fine_drag() and 0.0025 or 0.01
      local new_held = clamp(held - dy * scale, -1, 1)
      drag_delta = new_held - held
      held = new_held
      drag_hold[key] = held
      changed = true
    end
    pan = held
  else
    drag_hold[key] = nil
  end
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    drag_delta = 0.0 - pan
    pan = 0.0; drag_hold[key] = nil; changed = true
  end
  if reaper.ImGui_IsItemHovered(ctx) and not active and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, FADER_HINT_TEXT)
  end

  local a_min, a_max = math.rad(-135), math.rad(135)
  local ang = a_min + ((pan + 1) * 0.5) * (a_max - a_min)
  local px = cx + math.sin(ang) * (r - 3)
  local py = cy - math.cos(ang) * (r - 3)
  reaper.ImGui_DrawList_AddLine(dl, cx, cy, px, py, COL_ACCENT, 2)
  reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, 2, COL_ACCENT, 8)

  return pan, changed, drag_delta, active
end

-- =============================================================================
-- Buttons and icons
-- =============================================================================
local function button_frame(dl, x, y, w, h, on, on_col)
  local bg = on and on_col or COL_BTN
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + h, bg, 3)
  reaper.ImGui_DrawList_AddLine(dl, x + 1, y + 1, x + w - 1, y + 1, COL_BEVEL_HI, 1)
  reaper.ImGui_DrawList_AddLine(dl, x + 1, y + h - 1, x + w - 1, y + h - 1, COL_BEVEL_LO, 1)
  reaper.ImGui_DrawList_AddRect(dl, x, y, x + w, y + h, COL_BTN_EDGE, 3, 0, 1)
end

-- Fake glow effect behind a lit button (ReaImGui can't blur).
local GLOW_RINGS = { { 7, 0x14 }, { 4, 0x28 }, { 2, 0x40 } }
local function draw_glow(dl, x, y, w, h, col)
  local rgb = col & 0xFFFFFF00
  for _, ring in ipairs(GLOW_RINGS) do
    local ext, a = ring[1], ring[2]
    reaper.ImGui_DrawList_AddRectFilled(dl, x - ext, y - ext, x + w + ext, y + h + ext, rgb | a, 3 + ext)
  end
end

-- A custom checklist row: a small checkbox square, an optional colored
-- dot, an optional dim prefix (e.g. "->"), and a label - in that order,
-- left to right - with the WHOLE row clickable (not just the tiny
-- checkbox), so ticking a track or a send on the left is easy to hit.
-- Checkbox and dot always sit at the same x regardless of the prefix, so
-- rows stay vertically aligned. Pass italic=true to render the label in
-- italics (used for a send's destination name). Returns:
--   clicked        true the frame the row is left-clicked
--   right_clicked  true the frame the row is right-clicked
local function checklist_row(dl, id, x, y, w, h, checked, dot_col, text, text_col, prefix, italic, check_col)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, '##row' .. id, w, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local clicked = reaper.ImGui_IsItemClicked(ctx, 0)
  local right_clicked = reaper.ImGui_IsItemClicked(ctx, 1)
  if hovered then
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + h, 0xFFFFFF12, 3)
  end

  local sq = 14
  local sy = y + (h - sq) * 0.5
  if checked then
    local cc = check_col or COL_ACCENT
    draw_glow(dl, x, sy, sq, sq, cc)
    reaper.ImGui_DrawList_AddRectFilled(dl, x, sy, x + sq, sy + sq, cc, 3)
    reaper.ImGui_DrawList_AddRect(dl, x, sy, x + sq, sy + sq, COL_BTN_EDGE, 3, 0, 1)
  else
    reaper.ImGui_DrawList_AddRectFilled(dl, x, sy, x + sq, sy + sq, COL_CHECK_BG, 3)
    reaper.ImGui_DrawList_AddRect(dl, x, sy, x + sq, sy + sq, COL_CHECK_BORDER, 3, 0, 1.3)
  end

  local tx = x + sq + 8
  local pf = push_font(FONT, 13)
  if dot_col then
    reaper.ImGui_DrawList_AddCircleFilled(dl, tx + 4, y + h * 0.5, 4, dot_col, 16)
    tx = tx + 14
  end
  if prefix then
    local ptw, pth = reaper.ImGui_CalcTextSize(ctx, prefix)
    reaper.ImGui_DrawList_AddText(dl, tx, y + (h - pth) * 0.5, COL_TEXT_DIM, prefix)
    tx = tx + ptw + 6
  end
  pop_font(pf)

  local pf2 = push_font(italic and FONT_ITALIC or FONT, 13)
  reaper.ImGui_DrawList_PushClipRect(dl, tx, y, x + w, y + h, true)
  local _, th = reaper.ImGui_CalcTextSize(ctx, text)
  reaper.ImGui_DrawList_AddText(dl, tx, y + (h - th) * 0.5, text_col or COL_TEXT, text)
  pop_font(pf2)
  reaper.ImGui_DrawList_PopClipRect(dl)

  return clicked, right_clicked
end

-- A plain on/off button with a text label. Also usable as a momentary
-- action button by always passing on=false.
local function toggle_button(dl, id, x, y, w, h, label, on, on_col)
  if on then draw_glow(dl, x, y, w, h, on_col) end
  button_frame(dl, x, y, w, h, on, on_col)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, label)
  local tcol = on and COL_INK or COL_TEXT
  reaper.ImGui_DrawList_AddText(dl, x + (w - tw) * 0.5, y + (h - th) * 0.5, tcol, label)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, '##' .. id, w, h)
  return reaper.ImGui_IsItemClicked(ctx)
end

-- The phase-flip button (circle with a diagonal line).
local function phase_button(dl, id, x, y, w, h, on)
  if on then draw_glow(dl, x, y, w, h, COL_PHASE) end
  button_frame(dl, x, y, w, h, on, COL_PHASE)
  local cx, cy = x + w * 0.5, y + h * 0.5
  local r = math.min(w, h) * 0.5 - 4
  local col = on and COL_INK or COL_TEXT
  reaper.ImGui_DrawList_AddCircle(dl, cx, cy, r, col, 16, 1.4)
  reaper.ImGui_DrawList_AddLine(dl, cx - r * 0.8, cy + r * 0.8, cx + r * 0.8, cy - r * 0.8, col, 1.4)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, '##' .. id, w, h)
  return reaper.ImGui_IsItemClicked(ctx)
end

-- The chain-link (Link) toggle. Left click toggles it on/off, right click
-- flips a linked strip between "normal" and "inverse".
local function link_button(dl, id, x, y, w, h, state)
  local on = state and true or false
  local inverse = state == "inverse"
  local col_on = inverse and COL_LINK_INV or COL_LINK
  if on then draw_glow(dl, x, y, w, h, col_on) end
  button_frame(dl, x, y, w, h, on, col_on)
  local cx, cy = x + w * 0.5, y + h * 0.5
  local col = on and TXT_DARK or COL_TEXT
  local r = math.min(w, h) * 0.21
  local off = r * 0.85
  local ysign = inverse and -1 or 1
  reaper.ImGui_DrawList_AddCircle(dl, cx - off, cy - off * 0.5 * ysign, r, col, 12, 1.5)
  reaper.ImGui_DrawList_AddCircle(dl, cx + off, cy + off * 0.5 * ysign, r, col, 12, 1.5)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, '##' .. id, w, h)
  return reaper.ImGui_IsItemClicked(ctx, 0), reaper.ImGui_IsItemClicked(ctx, 1)
end

-- One snapshot slot button (A/B/C/D). Left click recalls it, right click
-- saves the current bank into it. Lit when that slot has data saved.
local function snapshot_button(dl, id, x, y, w, h, label, lit)
  if lit then draw_glow(dl, x, y, w, h, COL_ACCENT) end
  button_frame(dl, x, y, w, h, lit, COL_ACCENT)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, label)
  local tcol = lit and TXT_DARK or COL_TEXT
  reaper.ImGui_DrawList_AddText(dl, x + (w - tw) * 0.5, y + (h - th) * 0.5, tcol, label)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, '##' .. id, w, h)
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, "Left click: recall\nRight click: save\nCtrl + right click: clear")
  end
  return reaper.ImGui_IsItemClicked(ctx, 0), reaper.ImGui_IsItemClicked(ctx, 1)
end

-- The toolbar's "Link all" button (bigger version of the link icon).
local function link_all_button(dl, id, x, y, on)
  local label = "Link all"
  local pf = push_font(FONT, 13)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, label)
  local h = reaper.ImGui_GetFrameHeight and reaper.ImGui_GetFrameHeight(ctx) or 22
  local icon_d, pad, gap = 16, 8, 6
  local w = pad * 2 + icon_d + gap + tw
  if on then draw_glow(dl, x, y, w, h, COL_LINK) end
  button_frame(dl, x, y, w, h, on, COL_LINK)
  local col = on and TXT_DARK or COL_TEXT
  local icx, icy = x + pad + icon_d * 0.5, y + h * 0.5
  local r = icon_d * 0.24
  local off = r * 0.85
  reaper.ImGui_DrawList_AddCircle(dl, icx - off, icy - off * 0.5, r, col, 12, 1.6)
  reaper.ImGui_DrawList_AddCircle(dl, icx + off, icy + off * 0.5, r, col, 12, 1.6)
  reaper.ImGui_DrawList_AddText(dl, x + pad + icon_d + gap, y + (h - th) * 0.5, col, label)
  pop_font(pf)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, '##' .. id, w, h)
  return reaper.ImGui_IsItemClicked(ctx), w
end

-- A plain momentary action button (e.g. "All" / "None"), sized to its
-- label. Gives visual feedback three ways: a hover highlight, an accent
-- fill while the mouse is held down, and a brief accent flash right after
-- the click so a quick click is still noticeable once released.
local action_flash = {}  -- id -> time_precise() the flash ends
local function action_button(dl, id, x, y, label, min_w)
  local pf = push_font(FONT, 13)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, label)
  local h = reaper.ImGui_GetFrameHeight and reaper.ImGui_GetFrameHeight(ctx) or 22
  local pad = 10
  local w = math.max(pad * 2 + tw, min_w or 0)

  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, '##' .. id, w, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local active = reaper.ImGui_IsItemActive(ctx)
  local clicked = reaper.ImGui_IsItemClicked(ctx)
  if clicked then action_flash[id] = reaper.time_precise() + 0.18 end
  local flashing = action_flash[id] and reaper.time_precise() < action_flash[id]
  local lit = active or flashing

  if lit then draw_glow(dl, x, y, w, h, COL_ACCENT) end
  button_frame(dl, x, y, w, h, lit or hovered, lit and COL_ACCENT or COL_PANEL_HI)
  local tcol = lit and TXT_DARK or COL_TEXT
  reaper.ImGui_DrawList_AddText(dl, x + (w - tw) * 0.5, y + (h - th) * 0.5, tcol, label)
  pop_font(pf)

  return clicked, w
end

-- =============================================================================
-- Shared pieces of a strip: header, labels, button positions
-- =============================================================================
-- Draws a strip's colored name header. A left click on it is reported
-- back (used to isolate this strip - see on_isolate in render_strip); a
-- right click opens the same context menu as a track's row on the left.
local function draw_header(dl, x, y, color_tr, name, id)
  local hdr = native_to_imgui(reaper.GetTrackColor(color_tr))
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + SW, y + HDR_H, hdr, 3)
  local tcol = text_on(hdr)
  reaper.ImGui_DrawList_PushClipRect(dl, x + 3, y, x + SW - 3, y + HDR_H, true)
  local pf = push_font(FONT_SM, 11)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, name)
  reaper.ImGui_DrawList_AddText(dl, x + math.max(3, (SW - tw) * 0.5), y + (HDR_H - th) * 0.5, tcol, name)
  pop_font(pf)
  reaper.ImGui_DrawList_PopClipRect(dl)

  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, '##hdr' .. id, SW, HDR_H)
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, "Click: keep only this strip\nRight-click: more options")
  end
  return reaper.ImGui_IsItemClicked(ctx, 0), reaper.ImGui_IsItemClicked(ctx, 1)
end

-- The small row under a send strip's header, showing where the send comes
-- from: the owner track's color dot and name.
local function draw_origin_row(dl, x, y, owner_tr)
  local dot_col = native_to_imgui(reaper.GetTrackColor(owner_tr))
  local name = track_label(owner_tr)
  local cy = y + ORIGIN_H * 0.5
  reaper.ImGui_DrawList_AddCircleFilled(dl, x + 7, cy, 3, dot_col, 12)
  reaper.ImGui_DrawList_PushClipRect(dl, x + 13, y, x + SW - 2, y + ORIGIN_H, true)
  local pf = push_font(FONT_SM, 11)
  local _, th = reaper.ImGui_CalcTextSize(ctx, name)
  reaper.ImGui_DrawList_AddText(dl, x + 13, cy - th * 0.5, TXT_LIGHT, name)
  pop_font(pf)
  reaper.ImGui_DrawList_PopClipRect(dl)
end

local function draw_panlabel(dl, x, y, txt)
  local pf = push_font(FONT_SM, 11)
  local tw = reaper.ImGui_CalcTextSize(ctx, txt)
  reaper.ImGui_DrawList_AddText(dl, x + (SW - tw) * 0.5, y + PANLBL_Y, COL_TEXT_DIM, txt)
  pop_font(pf)
end

local function draw_dblabel(dl, x, y, txt)
  local pf = push_font(FONT_SM, 11)
  local tw = reaper.ImGui_CalcTextSize(ctx, txt)
  reaper.ImGui_DrawList_AddText(dl, x + (SW - tw) * 0.5, y + DBLBL_Y, COL_TEXT, txt)
  pop_font(pf)
end

-- x position of the i-th of the 3 small buttons (M/S/P) on a strip.
local function button_x(x, i)
  local total = 3 * BTN_W + 2 * BTN_GAP
  return x + (SW - total) * 0.5 + i * (BTN_W + BTN_GAP)
end

-- =============================================================================
-- Send-type dropdown: Post-Fader / Pre-FX / Pre-Fader
-- =============================================================================
local SEND_MODE_ORDER = { 0, 1, 3 }
local SEND_MODE_SHORT = { [0] = "PST", [1] = "PFX", [3] = "PFD" }
local SEND_MODE_FULL  = { [0] = "Post-Fader", [1] = "Pre-FX", [3] = "Pre-Fader (Post-FX)" }

local function send_type_combo(id, x, y, w, tr, idx, key, all_visible, mark_dirty)
  local cur = math.floor(sget(tr, idx, "I_SENDMODE") + 0.5)
  local preview = SEND_MODE_SHORT[cur] or "PST"

  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_SetNextItemWidth(ctx, w)
  local pf = push_font(FONT_SM, 11)
  if reaper.ImGui_BeginCombo(ctx, '##sendtype' .. id, preview, 0) then
    for _, v in ipairs(SEND_MODE_ORDER) do
      local sel = (v == cur)
      if reaper.ImGui_Selectable(ctx, SEND_MODE_FULL[v], sel) then
        if v ~= cur then
          sset(tr, idx, "I_SENDMODE", v)
          if link_set[key] then
            for _, m in ipairs(all_visible) do
              if m.key ~= key and m.kind == "send" and link_set[m.key] then
                sset(m.owner, m.idx, "I_SENDMODE", v)
              end
            end
          end
          mark_dirty()
        end
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  pop_font(pf)
end

-- =============================================================================
-- Shared actions (phase, solo, mute) that work on both a track strip and
-- a send strip
-- =============================================================================
local function get_phase(m)
  if m.kind == "track" then return reaper.GetMediaTrackInfo_Value(m.track, "B_PHASE") > 0.5
  else return sget(m.owner, m.idx, "B_PHASE") > 0.5 end
end
local function set_phase(m, v)
  if m.kind == "track" then reaper.SetMediaTrackInfo_Value(m.track, "B_PHASE", v and 1 or 0)
  else sset(m.owner, m.idx, "B_PHASE", v and 1 or 0) end
end
local function get_solo(m)
  if m.kind == "track" then return reaper.GetMediaTrackInfo_Value(m.track, "I_SOLO") > 0.5
  else return getstate(m.key).solo end
end
local function set_solo(m, v)
  if m.kind == "track" then reaper.SetMediaTrackInfo_Value(m.track, "I_SOLO", v and 2 or 0)
  else getstate(m.key).solo = v end
end
local function get_mute(m, owner_soloing)
  if m.kind == "track" then return reaper.GetMediaTrackInfo_Value(m.track, "B_MUTE") > 0.5
  else
    local soloing = owner_soloing[reaper.GetTrackGUID(m.owner)]
    local st = getstate(m.key)
    local phys = sget(m.owner, m.idx, "B_MUTE") > 0.5
    return soloing and st.umute or ((not soloing) and phys)
  end
end
local function set_mute(m, v, owner_soloing)
  if m.kind == "track" then reaper.CSurf_OnMuteChangeEx(m.track, v and 1 or 0, false)
  else
    local soloing = owner_soloing[reaper.GetTrackGUID(m.owner)]
    if soloing then getstate(m.key).umute = v
    else set_mute_flag(m.owner, m.idx, v) end
  end
end

-- =============================================================================
-- One strip: a track's own fader, or one of its outgoing sends.
-- =============================================================================
local function render_strip(dl, x, y, id, m, all_visible, owner_soloing, mark_dirty, on_isolate, on_context_menu)
  local key = m.key
  local self_linked = link_set[key] or false
  local self_sign = link_sign(key)

  local color_tr, label
  if m.kind == "track" then
    color_tr, label = m.track, track_label(m.track)
  else
    color_tr, label = m.peer, track_label(m.peer)
  end
  local hdr_clicked, hdr_rclicked = draw_header(dl, x, y, color_tr, label, id)
  if hdr_clicked and on_isolate then
    on_isolate(key)
  end
  if on_context_menu then
    on_context_menu(id, color_tr, key, hdr_rclicked, m)
  end

  if m.kind == "send" then
    draw_origin_row(dl, x, y + HDR_H, m.owner)
    send_type_combo(id, x + 3, y + HDR_H + ORIGIN_H, SW - 6, m.owner, m.idx, key, all_visible, mark_dirty)
  end

  local uivol, uipan
  if m.kind == "track" then
    uivol, uipan = reaper.GetMediaTrackInfo_Value(m.track, "D_VOL"), reaper.GetMediaTrackInfo_Value(m.track, "D_PAN")
    local ok, v, p = reaper.GetTrackUIVolPan(m.track)
    if ok then uivol, uipan = v, p end
  else
    uivol, uipan = sget(m.owner, m.idx, "D_VOL"), sget(m.owner, m.idx, "D_PAN")
    local ok, v, p = reaper.GetTrackSendUIVolPan(m.owner, m.idx)
    if ok then uivol, uipan = v, p end
  end

  -- Remember this strip's current values before touching anything, so we
  -- can later tell whether it was moved directly in REAPER (mixer,
  -- arrange view) instead of through this script.
  m.raw_vol_db = gain_to_db(uivol)
  m.raw_pan = uipan

  local kx = x + (SW - KNOB_D) * 0.5
  local np, pch, pdelta, pacv = pan_knob(dl, id, kx, y + KNOB_Y, KNOB_D, uipan)
  if pch or pacv then
    if m.kind == "track" then reaper.CSurf_OnPanChangeEx(m.track, np, false, false)
    else reaper.CSurf_OnSendPanChange(m.owner, m.idx, np, false) end
  end
  if pch then mark_dirty() end
  if pdelta then g_pan_link_delta = pdelta; g_pan_link_source_key = key end
  draw_panlabel(dl, x, y, fmt_pan((pch or pacv) and np or uipan))

  local by = y + BTN_Y
  local mute_shown = get_mute(m, owner_soloing)
  if toggle_button(dl, id .. 'M', button_x(x, 0), by, BTN_W, BTN_H, "M", mute_shown, COL_MUTE) then
    local newv = not mute_shown
    set_mute(m, newv, owner_soloing)
    if self_linked then
      for _, m2 in ipairs(all_visible) do
        if m2.key ~= key and link_set[m2.key] then
          local v2
          if link_sign(m2.key) * self_sign > 0 then v2 = newv else v2 = not newv end
          set_mute(m2, v2, owner_soloing)
        end
      end
    end
    mark_dirty()
  end
  local solo = get_solo(m)
  if toggle_button(dl, id .. 'S', button_x(x, 1), by, BTN_W, BTN_H, "S", solo, COL_SOLO) then
    local newv = not solo
    set_solo(m, newv)
    if self_linked then
      for _, m2 in ipairs(all_visible) do
        if m2.key ~= key and link_set[m2.key] then
          local v2
          if link_sign(m2.key) * self_sign > 0 then v2 = newv else v2 = not newv end
          set_solo(m2, v2)
        end
      end
    end
    mark_dirty()
  end
  local phase = get_phase(m)
  if phase_button(dl, id .. 'P', button_x(x, 2), by, BTN_W, BTN_H, phase) then
    local newv = not phase
    set_phase(m, newv)
    if self_linked then
      for _, m2 in ipairs(all_visible) do
        if m2.key ~= key and link_set[m2.key] then
          local v2
          if link_sign(m2.key) * self_sign > 0 then v2 = newv else v2 = not newv end
          set_phase(m2, v2)
        end
      end
    end
    mark_dirty()
  end
  local link_clicked, link_right_clicked = link_button(dl, id .. 'L', button_x(x, 1), by + BTN_H + BTN_ROW_GAP, BTN_W, BTN_H, link_set[key])
  if link_clicked then
    if self_linked then link_set[key] = nil else link_set[key] = "normal" end
    mark_dirty()
  elseif link_right_clicked and self_linked then
    link_set[key] = (link_set[key] == "inverse") and "normal" or "inverse"; mark_dirty()
  end

  local fx = x + (SW - FADER_W) * 0.5
  local nn, fch, fdelta, facv = fader(dl, id, fx, y + FADER_Y, FADER_W, FADER_H, gain_to_norm(uivol), native_to_imgui(reaper.GetTrackColor(color_tr)))
  local disp = uivol
  if fch or facv then
    disp = norm_to_gain(nn)
    if m.kind == "track" then reaper.CSurf_OnVolumeChangeEx(m.track, disp, false, false)
    else reaper.CSurf_OnSendVolumeChange(m.owner, m.idx, disp, false) end
  end
  if fch then mark_dirty() end
  -- the fader move is tracked in dB rather than raw fader position, so a
  -- linked group keeps its relative balance even though REAPER's own
  -- fader curve isn't a straight line in dB
  if fdelta then
    g_link_delta = gain_to_db(disp) - gain_to_db(uivol)
    g_link_source_key = key
  end
  draw_dblabel(dl, x, y, fmt_db(disp))

  if m.kind == "send" and owner_soloing[reaper.GetTrackGUID(m.owner)] and not getstate(key).solo then
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y + HDR_H, x + SW, y + SH, COL_DIM, 3)
  end
end

-- =============================================================================
-- Selection: which tracks/sends are checked, and in what order
-- =============================================================================
local selected = {}         -- key -> true
local selected_order = {}   -- ordered list of keys

local function set_selected(key, on)
  local changed = false
  if on then
    if not selected[key] then
      selected[key] = true
      selected_order[#selected_order + 1] = key
      changed = true
    end
  else
    if selected[key] then
      selected[key] = nil
      for i, k in ipairs(selected_order) do
        if k == key then table.remove(selected_order, i); break end
      end
      last_vol_db[key] = nil
      last_pan_val[key] = nil
      changed = true
    end
  end
  if changed then
    -- any change to what's checked resets every link group - a link
    -- group's meaning depends on exactly which strips are on screen
    link_set = {}
    g_link_all_lit = false
  end
end

local function clear_selection()
  selected = {}
  selected_order = {}
  link_set = {}
  g_link_all_lit = false
end

-- Checks every track and every one of its outgoing sends in the project.
local function select_all_items(include_sends)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local guid = reaper.GetTrackGUID(tr)
    set_selected(guid, true)
    if include_sends then
      local ns = reaper.GetTrackNumSends(tr, 0)
      for si = 0, ns - 1 do
        local peer = get_send_dest(tr, si)
        if peer then set_selected(guid .. '>' .. reaper.GetTrackGUID(peer), true) end
      end
    end
  end
end

-- Right-click context menu actions on a track's checklist row.
-- 0) checks the tracks `tr` sends into, plus its folder parent - the
--    reverse of (1), for moving up the hierarchy instead of down.
local function select_destinations(tr)
  for _, p in ipairs(get_related_destinations(tr)) do
    set_selected(reaper.GetTrackGUID(p), true)
  end
end

-- 1) checks the tracks that send into `tr`, or (if `tr` is a folder) sit
--    inside it.
local function select_sources(tr)
  for _, c in ipairs(get_related_sources(tr)) do
    set_selected(reaper.GetTrackGUID(c), true)
  end
end

-- 2) checks the sends feeding into `tr` (its receives) - the specific
--    send items themselves, not the tracks that own them.
local function select_track_receives(tr)
  local guid = reaper.GetTrackGUID(tr)
  local n = reaper.GetTrackNumSends(tr, -1)
  for i = 0, n - 1 do
    local src = reaper.GetTrackSendInfo_Value(tr, -1, i, "P_SRCTRACK")
    if type(src) == "userdata" and src and reaper.ValidatePtr2(0, src, "MediaTrack*") then
      set_selected(reaper.GetTrackGUID(src) .. '>' .. guid, true)
    end
  end
end

-- 3) checks `tr`'s own outgoing sends.
local function select_track_sends(tr)
  local guid = reaper.GetTrackGUID(tr)
  local n = reaper.GetTrackNumSends(tr, 0)
  for i = 0, n - 1 do
    local peer = get_send_dest(tr, i)
    if peer then set_selected(guid .. '>' .. reaper.GetTrackGUID(peer), true) end
  end
end

-- 4) checks the outgoing sends of `tr`'s child tracks (same definition as
--    select_sources), except any of those sends that go back to `tr`.
local function select_sources_sends(tr)
  local self_guid = reaper.GetTrackGUID(tr)
  for _, c in ipairs(get_related_sources(tr)) do
    local cguid = reaper.GetTrackGUID(c)
    local n = reaper.GetTrackNumSends(c, 0)
    for i = 0, n - 1 do
      local peer = get_send_dest(c, i)
      if peer and reaper.GetTrackGUID(peer) ~= self_guid then
        set_selected(cguid .. '>' .. reaper.GetTrackGUID(peer), true)
      end
    end
  end
end

-- =============================================================================
-- Snapshots: 4 quick slots (A/B/C/D) that store the whole bank - which
-- tracks/sends are checked, plus their fader/pan/mute/phase/type balance
-- =============================================================================
local SNAPSHOT_SLOTS = { "A", "B", "C", "D" }
local SNAPSHOT_SECTION = "SK_BALANCE_CONTROL_SNAP"

local function snapshot_exists(slot)
  local ok, data = reaper.GetProjExtState(0, SNAPSHOT_SECTION, slot)
  return ok and data ~= ""
end

local function snapshot_save(slot)
  local lines = {}
  for _, key in ipairs(selected_order) do
    local a, b = key:match("^(.-)>(.+)$")
    local vol, pan, mute, phase, sendmode
    if a then
      -- send: a = owner guid, b = dest guid
      local owner = find_track_by_guid(a)
      local idx = owner and find_send_index_by_dest(owner, b)
      if owner and idx then
        local ok, v, p = reaper.GetTrackSendUIVolPan(owner, idx)
        vol = ok and v or sget(owner, idx, "D_VOL")
        pan = ok and p or sget(owner, idx, "D_PAN")
        mute = sget(owner, idx, "B_MUTE") > 0.5
        phase = sget(owner, idx, "B_PHASE") > 0.5
        sendmode = math.floor(sget(owner, idx, "I_SENDMODE") + 0.5)
        lines[#lines + 1] = string.format("S,%s,%s,%.6f,%.6f,%d,%d,%d", a, b, vol, pan, mute and 1 or 0, phase and 1 or 0, sendmode)
      end
    else
      local tr = find_track_by_guid(key)
      if tr then
        local ok, v, p = reaper.GetTrackUIVolPan(tr)
        vol = ok and v or reaper.GetMediaTrackInfo_Value(tr, "D_VOL")
        pan = ok and p or reaper.GetMediaTrackInfo_Value(tr, "D_PAN")
        mute = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") > 0.5
        phase = reaper.GetMediaTrackInfo_Value(tr, "B_PHASE") > 0.5
        lines[#lines + 1] = string.format("T,%s,,%.6f,%.6f,%d,%d,-1", key, vol, pan, mute and 1 or 0, phase and 1 or 0)
      end
    end
  end
  reaper.SetProjExtState(0, SNAPSHOT_SECTION, slot, table.concat(lines, ";"))
end

local function snapshot_clear(slot)
  reaper.SetProjExtState(0, SNAPSHOT_SECTION, slot, "")
end

-- Rebuilds the checked bank from a saved slot and applies the saved
-- fader/pan/mute/phase/type balance. Any saved entry whose track/send can
-- no longer be found (deleted since) is silently skipped.
local function snapshot_recall(slot)
  local ok, data = reaper.GetProjExtState(0, SNAPSHOT_SECTION, slot)
  if not ok or data == "" then return end
  clear_selection()
  for entry in data:gmatch("[^;]+") do
    local kind, a, b, vol, pan, mute, phase, sendmode = entry:match("^([TS]),([^,]*),([^,]*),([^,]+),([^,]+),([^,]+),([^,]+),(-?%d+)$")
    if kind == "T" then
      local tr = find_track_by_guid(a)
      if tr then
        vol, pan, mute, phase = tonumber(vol), tonumber(pan), tonumber(mute), tonumber(phase)
        reaper.CSurf_OnVolumeChangeEx(tr, vol, false, false)
        reaper.CSurf_OnPanChangeEx(tr, pan, false, false)
        reaper.CSurf_OnMuteChangeEx(tr, mute, false)
        reaper.SetMediaTrackInfo_Value(tr, "B_PHASE", phase)
        set_selected(a, true)
      end
    elseif kind == "S" then
      local owner = find_track_by_guid(a)
      local idx = owner and find_send_index_by_dest(owner, b)
      if owner and idx then
        vol, pan, mute, phase, sendmode = tonumber(vol), tonumber(pan), tonumber(mute), tonumber(phase), tonumber(sendmode)
        reaper.CSurf_OnSendVolumeChange(owner, idx, vol, false)
        reaper.CSurf_OnSendPanChange(owner, idx, pan, false)
        set_mute_flag(owner, idx, mute == 1)
        sset(owner, idx, "B_PHASE", phase)
        if sendmode and sendmode >= 0 then sset(owner, idx, "I_SENDMODE", sendmode) end
        set_selected(a .. '>' .. b, true)
      end
    end
  end
  reaper.TrackList_AdjustWindows(false)
end

-- =============================================================================
-- Drawing one frame
-- =============================================================================
local g_dirty = false
local function mark_dirty() g_dirty = true end
local g_filter = ""
local g_show_sends = false  -- toggled by the "Sends" button in the left panel
local g_right_panel_offset_x = nil  -- right panel's left edge, used to line up the toolbar buttons with it

local function draw_toolbar()
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local title_x, row_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local btn_h = reaper.ImGui_GetFrameHeight and reaper.ImGui_GetFrameHeight(ctx) or 22

  local pf = push_font(FONT_HDR, 14)
  local title_tw, title_th = reaper.ImGui_CalcTextSize(ctx, "SK BALANCE CONTROL")
  reaper.ImGui_TextColored(ctx, COL_ACCENT, "SK BALANCE CONTROL")
  pop_font(pf)

  -- lines up with the left edge of the right panel itself, so the
  -- toolbar buttons don't drift if the panel scrolls sideways
  local win_x = reaper.ImGui_GetWindowPos(ctx)
  local x = (g_right_panel_offset_x and (win_x + g_right_panel_offset_x)) or (title_x + title_tw + 24)
  local y = row_y

  local clicked, w = link_all_button(dl, 'linkall', x, y, g_link_all_lit)
  if clicked then g_link_all_requested = true end
  x = x + w + 16

  for _, slot in ipairs(SNAPSHOT_SLOTS) do
    local lit = snapshot_exists(slot)
    local lclick, rclick = snapshot_button(dl, 'snap' .. slot, x, y, btn_h, btn_h, slot, lit)
    if lclick then snapshot_recall(slot)
    elseif rclick then
      if fine_drag() then snapshot_clear(slot)
      else snapshot_save(slot) end
    end
    x = x + btn_h + 4
  end

  reaper.ImGui_SetCursorScreenPos(ctx, title_x, row_y + math.max(title_th, btn_h))
  reaper.ImGui_Separator(ctx)
end

-- A clearly visible full-width separator line for the context-menu popups
-- (the default one barely shows up against this dark theme).
local function menu_separator()
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local w = reaper.ImGui_GetContentRegionAvail(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_AddLine(dl, x, y + 3, x + w, y + 3, COL_TEXT_DIM, 1)
  reaper.ImGui_Dummy(ctx, w, 7)
end

-- Left panel: every track, with its outgoing sends listed underneath it.
local function draw_left_panel()
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  local rv, newf = reaper.ImGui_InputTextWithHint(ctx, '##filter', "Filter by name...", g_filter)
  if rv then g_filter = newf end

  do
    local dl0 = reaper.ImGui_GetWindowDrawList(ctx)
    local bx, by = reaper.ImGui_GetCursorScreenPos(ctx)
    local btn_h = reaper.ImGui_GetFrameHeight and reaper.ImGui_GetFrameHeight(ctx) or 22
    local pf0 = push_font(FONT, 13)
    local tw_all = reaper.ImGui_CalcTextSize(ctx, "All")
    local tw_none = reaper.ImGui_CalcTextSize(ctx, "None")
    local tw_sends = reaper.ImGui_CalcTextSize(ctx, "Sends")
    pop_font(pf0)
    local btn_w = math.max(tw_all, tw_none, tw_sends) + 20
    local clicked, w = action_button(dl0, 'selall', bx, by, "All", btn_w)
    if clicked then select_all_items(g_show_sends) end
    bx = bx + w + 6
    clicked, w = action_button(dl0, 'selnone', bx, by, "None", btn_w)
    if clicked then clear_selection() end
    bx = bx + w + 6
    if toggle_button(dl0, 'togsends', bx, by, btn_w, btn_h, "Sends", g_show_sends, COL_ENV_V) then
      g_show_sends = not g_show_sends
      link_set = {}
      g_link_all_lit = false
    end
  end
  reaper.ImGui_Spacing(ctx)

  -- the track/send list scrolls in its own area, so the filter box and
  -- the All/None/Sends buttons above always stay in view
  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  if reaper.ImGui_BeginChild(ctx, 'left_list', avail_w, avail_h, 0, 0) then
    local f = lc(g_filter)
    local n = reaper.CountTracks(0)
    if n == 0 then
      reaper.ImGui_TextColored(ctx, COL_TEXT_DIM, "No tracks in this project.")
    else
      local dl = reaper.ImGui_GetWindowDrawList(ctx)
      for i = 0, n - 1 do
        local tr = reaper.GetTrack(0, i)
        local guid = reaper.GetTrackGUID(tr)
        local name = track_label(tr)
        local ns = reaper.GetTrackNumSends(tr, 0)

        -- a track stays visible if its own name matches the filter, or if
        -- one of its sends does, so a matching send is never hidden
        local self_match = f == "" or lc(name):find(f, 1, true) ~= nil
        local any_send_match = false
        if f ~= "" and not self_match then
          for si = 0, ns - 1 do
            local peer = get_send_dest(tr, si)
            if peer and lc(track_label(peer)):find(f, 1, true) then any_send_match = true; break end
          end
        end
        if self_match or any_send_match then
          local row_avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
          local rx, ry = reaper.ImGui_GetCursorScreenPos(ctx)
          local col = native_to_imgui(reaper.GetTrackColor(tr))
          local row_clicked, row_rclicked = checklist_row(dl, 't' .. guid, rx, ry, row_avail_w, ROW_H, selected[guid] == true, col, name)
          if row_clicked then
            set_selected(guid, not (selected[guid] == true))
          end
          local popup_id = '##trackctx' .. guid
          if row_rclicked then reaper.ImGui_OpenPopup(ctx, popup_id) end
          if reaper.ImGui_BeginPopup(ctx, popup_id) then
            reaper.ImGui_TextColored(ctx, COL_TEXT_DIM, name)
            menu_separator()
            if reaper.ImGui_Selectable(ctx, "Select destinations") then select_destinations(tr) end
            if reaper.ImGui_Selectable(ctx, "Select sources") then select_sources(tr) end
            menu_separator()
            if reaper.ImGui_Selectable(ctx, "Select this track's receives") then select_track_receives(tr); g_show_sends = true end
            if reaper.ImGui_Selectable(ctx, "Select this track's sends") then select_track_sends(tr); g_show_sends = true end
            if reaper.ImGui_Selectable(ctx, "Select sources' sends (except to this track)") then select_sources_sends(tr); g_show_sends = true end
            reaper.ImGui_EndPopup(ctx)
          end

          if g_show_sends then
            for si = 0, ns - 1 do
              local peer = get_send_dest(tr, si)
              if peer then
                local pname = track_label(peer)
                local send_match = f == "" or self_match or lc(pname):find(f, 1, true) ~= nil
                if send_match then
                  local skey = guid .. '>' .. reaper.GetTrackGUID(peer)
                  local srx, sry = reaper.ImGui_GetCursorScreenPos(ctx)
                  local sw = reaper.ImGui_GetContentRegionAvail(ctx)
                  local dest_col = native_to_imgui(reaper.GetTrackColor(peer))
                  if checklist_row(dl, 's' .. skey, srx, sry, sw, ROW_H, selected[skey] == true, dest_col, pname, COL_TEXT_DIM, "->", true, COL_ENV_V) then
                    set_selected(skey, not (selected[skey] == true))
                  end
                end
              end
            end
          end
        end
      end
    end
    reaper.ImGui_EndChild(ctx)
  end
end

-- Right panel: one strip per checked track/send, in the order checked.
local function draw_right_panel()
  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  -- rebuild the list of visible strips from the checked keys, dropping
  -- any whose track/send no longer exists
  local visible = {}
  local stale = {}
  for _, key in ipairs(selected_order) do
    local a, b = key:match("^(.-)>(.+)$")
    if a then
      if g_show_sends then
        local owner = find_track_by_guid(a)
        local idx = owner and find_send_index_by_dest(owner, b)
        if owner and idx then
          local peer = get_send_dest(owner, idx)
          if peer then
            visible[#visible + 1] = { key = key, kind = "send", owner = owner, idx = idx, peer = peer, widget_id = "m" .. #visible }
          else stale[#stale + 1] = key end
        else stale[#stale + 1] = key end
      end
      -- when Sends is off, a checked send stays checked but hidden, so
      -- it reappears if Sends is switched back on
    else
      local tr = find_track_by_guid(key)
      if tr then
        visible[#visible + 1] = { key = key, kind = "track", track = tr, widget_id = "m" .. #visible }
      else stale[#stale + 1] = key end
    end
  end
  for _, key in ipairs(stale) do set_selected(key, false) end

  if #visible == 0 then
    -- nothing shown right now: reset any leftover link state so it
    -- doesn't silently resurface on strips checked back in later
    if next(link_set) ~= nil then link_set = {} end
    g_link_all_lit = false
    reaper.ImGui_TextColored(ctx, COL_TEXT_DIM, "Tick a track or a send on the left to add it here.")
    return
  end

  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local ox, oy = reaper.ImGui_GetCursorScreenPos(ctx)
  ox, oy = ox + PAD, oy + PAD

  -- fill the available height, keeping room at the bottom for labels/buttons
  local total_w = PAD * 2 + #visible * SW + math.max(0, #visible - 1) * STRIP_GAP
  local reserve = (total_w > avail_w) and 18 or 0
  SH = math.max(SH_MIN, math.floor(avail_h - PAD * 2 - reserve))
  local bottom_reserve = 24
  FADER_H = math.max(120, SH - FADER_Y - bottom_reserve)
  DBLBL_Y = FADER_Y + FADER_H + 2

  -- gather every distinct owner track among the visible sends, and its
  -- full set of outgoing sends (not just the ones shown here): soloing
  -- one send strip should still mute that owner's other sends, shown or not
  local owners_seen = {}
  for _, m in ipairs(visible) do
    if m.kind == "send" then
      local oguid = reaper.GetTrackGUID(m.owner)
      if not owners_seen[oguid] then
        local list = {}
        local n = reaper.GetTrackNumSends(m.owner, 0)
        for i = 0, n - 1 do
          local peer = get_send_dest(m.owner, i)
          if peer then
            list[#list + 1] = { idx = i, key = oguid .. '>' .. reaper.GetTrackGUID(peer) }
          end
        end
        owners_seen[oguid] = { owner = m.owner, sends = list }
      end
    end
  end
  local owner_soloing = {}
  for oguid, data in pairs(owners_seen) do
    local sol = false
    for _, s in ipairs(data.sends) do if getstate(s.key).solo then sol = true; break end end
    owner_soloing[oguid] = sol
  end

  g_link_delta = nil
  g_link_source_key = nil
  g_pan_link_delta = nil
  g_pan_link_source_key = nil
  -- true once a move is detected coming from outside the script (see
  -- below) rather than from a drag inside it; tells apply_linked_group
  -- not to write the source strip back, since REAPER already holds that
  -- value live and re-writing it while the user is still moving it would
  -- look jerky
  local link_delta_is_external = false
  local pan_link_delta_is_external = false

  local function on_isolate(key)
    clear_selection()
    set_selected(key, true)
  end

  local function on_context_menu(id, tr, key, right_clicked, m)
    local popup_id = '##stripctx' .. id
    if right_clicked then reaper.ImGui_OpenPopup(ctx, popup_id) end
    if reaper.ImGui_BeginPopup(ctx, popup_id) then
      reaper.ImGui_TextColored(ctx, COL_TEXT_DIM, track_label(tr))
      menu_separator()
      if reaper.ImGui_Selectable(ctx, "Hide this track") then set_selected(key, false) end
      menu_separator()
      if reaper.ImGui_Selectable(ctx, "Select destinations") then select_destinations(tr) end
      if reaper.ImGui_Selectable(ctx, "Select sources") then
        if m.kind == "send" then
          -- this strip is one specific send: its "source" is just the
          -- owner track of that send, not every track feeding the
          -- destination
          set_selected(reaper.GetTrackGUID(m.owner), true)
        else
          select_sources(tr)
        end
      end
      menu_separator()
      if reaper.ImGui_Selectable(ctx, "Select this track's receives") then select_track_receives(tr); g_show_sends = true end
      if reaper.ImGui_Selectable(ctx, "Select this track's sends") then select_track_sends(tr); g_show_sends = true end
      if reaper.ImGui_Selectable(ctx, "Select sources' sends (except to this track)") then select_sources_sends(tr); g_show_sends = true end
      reaper.ImGui_EndPopup(ctx)
    end
  end

  local x = ox
  for _, m in ipairs(visible) do
    render_strip(dl, x, oy, m.widget_id, m, visible, owner_soloing, mark_dirty, on_isolate, on_context_menu)
    m.linked = link_set[m.key] or false
    if m.kind == "track" then
      m.get_vol = function() local ok, v = reaper.GetTrackUIVolPan(m.track); return gain_to_db(ok and v or reaper.GetMediaTrackInfo_Value(m.track, "D_VOL")) end
      m.get_pan = function() local ok, _, p = reaper.GetTrackUIVolPan(m.track); return ok and p or reaper.GetMediaTrackInfo_Value(m.track, "D_PAN") end
    else
      m.get_vol = function() local ok, v = reaper.GetTrackSendUIVolPan(m.owner, m.idx); return ok and gain_to_db(v) or nil end
      m.get_pan = function() local ok, _, p = reaper.GetTrackSendUIVolPan(m.owner, m.idx); return ok and p or nil end
    end
    x = x + SW + STRIP_GAP
  end

  -- A strip only reports a move when it's dragged inside this script. If
  -- a linked strip was instead moved directly in REAPER (mixer, arrange
  -- automation, a control surface...), catch the gap between what we
  -- last saw and what's there now, and feed it into the same Link
  -- machinery as a drag inside the script.
  if not g_link_delta and not g_dirty then
    for _, m in ipairs(visible) do
      if link_set[m.key] then
        local last_db = last_vol_db[m.key]
        if last_db and math.abs(m.raw_vol_db - last_db) > 0.02 then
          g_link_delta = m.raw_vol_db - last_db
          g_link_source_key = m.key
          link_delta_is_external = true
          break
        end
      end
    end
  end
  if not g_pan_link_delta and not g_dirty then
    for _, m in ipairs(visible) do
      if link_set[m.key] then
        local last_p = last_pan_val[m.key]
        if last_p and math.abs(m.raw_pan - last_p) > 0.002 then
          g_pan_link_delta = m.raw_pan - last_p
          g_pan_link_source_key = m.key
          pan_link_delta_is_external = true
          break
        end
      end
    end
  end

  -- "Link all" bulk toggle: link everything visible, or unlink it all if
  -- it's already fully linked.
  if g_link_all_requested then
    local all_on = #visible > 0
    for _, m in ipairs(visible) do
      if not link_set[m.key] then all_on = false; break end
    end
    for _, m in ipairs(visible) do
      if all_on then link_set[m.key] = nil
      elseif not link_set[m.key] then link_set[m.key] = "normal" end
    end
    mark_dirty()
    g_link_all_requested = false
  end

  do
    local all_on = #visible > 0
    for _, m in ipairs(visible) do
      if not link_set[m.key] then all_on = false; break end
    end
    g_link_all_lit = all_on
  end

  -- apply a linked fader drag to the rest of the group
  apply_linked_group(visible, g_link_source_key, g_link_delta, DB_MIN, DB_MAX,
    function(m) return m.get_vol() end,
    function(m, db)
      local gain = db_to_gain(db)
      if m.kind == "track" then reaper.CSurf_OnVolumeChangeEx(m.track, gain, false, false)
      else reaper.CSurf_OnSendVolumeChange(m.owner, m.idx, gain, false) end
      drag_hold[m.widget_id] = db_to_norm(db)
    end, not link_delta_is_external)

  -- same, for a linked pan-knob drag
  apply_linked_group(visible, g_pan_link_source_key, g_pan_link_delta, -1, 1,
    function(m)
      if m.kind == "track" then
        local ok, _, p = reaper.GetTrackUIVolPan(m.track)
        return ok and p or reaper.GetMediaTrackInfo_Value(m.track, "D_PAN")
      else
        local ok, _, p = reaper.GetTrackSendUIVolPan(m.owner, m.idx)
        return ok and p or nil
      end
    end,
    function(m, pan)
      if m.kind == "track" then reaper.CSurf_OnPanChangeEx(m.track, pan, false, false)
      else reaper.CSurf_OnSendPanChange(m.owner, m.idx, pan, false) end
      drag_hold[m.widget_id .. '#p'] = pan
    end, not pan_link_delta_is_external)

  -- refresh what we remember for each visible strip now that this
  -- frame's move has landed, so next frame's comparison starts clean
  for _, m in ipairs(visible) do
    local v = m.get_vol and m.get_vol()
    if v then last_vol_db[m.key] = v end
    local p = m.get_pan and m.get_pan()
    if p then last_pan_val[m.key] = p end
  end

  if g_link_delta or g_pan_link_delta then mark_dirty() end

  -- enforce solo per owner, and put back the mute state of any owner
  -- that no longer has a visible send strip
  for oguid, data in pairs(owners_seen) do
    enforce_solo(data.owner, oguid, data.sends, owner_soloing[oguid])
  end
  for guid, entry in pairs(managed_buses) do
    if not owners_seen[guid] then
      restore_bus(entry)
      managed_buses[guid] = nil
    end
  end

  reaper.ImGui_SetCursorScreenPos(ctx, ox, oy)
  reaper.ImGui_Dummy(ctx, (x - ox) + PAD, SH)
end

local function push_theme_base()
  local list = {
    { reaper.ImGui_Col_WindowBg,             COL_BG },
    { reaper.ImGui_Col_Text,                 COL_TEXT },
    { reaper.ImGui_Col_FrameBg,              COL_PANEL },
    { reaper.ImGui_Col_FrameBgHovered,       COL_PANEL_HI },
    { reaper.ImGui_Col_FrameBgActive,        COL_PANEL_HI },
    { reaper.ImGui_Col_CheckMark,            COL_ACCENT },
    { reaper.ImGui_Col_Border,               COL_EDGE },
    { reaper.ImGui_Col_Separator,            COL_EDGE },
    { reaper.ImGui_Col_ScrollbarBg,          COL_BG },
    { reaper.ImGui_Col_ScrollbarGrab,        COL_PANEL_HI },
    { reaper.ImGui_Col_ScrollbarGrabHovered, COL_ACCENT },
    { reaper.ImGui_Col_ScrollbarGrabActive,  COL_ACCENT },
    { reaper.ImGui_Col_TitleBg,              COL_BG },
    { reaper.ImGui_Col_TitleBgActive,        COL_PANEL },
    { reaper.ImGui_Col_Header,               COL_PANEL_HI },
    { reaper.ImGui_Col_HeaderHovered,        0x4A4A44FF },
    { reaper.ImGui_Col_HeaderActive,         COL_PANEL_HI },
  }
  local pushed = 0
  for _, e in ipairs(list) do
    if e[1] then reaper.ImGui_PushStyleColor(ctx, e[1](), e[2]); pushed = pushed + 1 end
  end
  return pushed
end

-- Applied only after the window is opened, so REAPER's own close button
-- keeps its normal look instead of the console's amber theme.
local function push_theme_buttons()
  local list = {
    { reaper.ImGui_Col_Button,               COL_PANEL_HI },
    { reaper.ImGui_Col_ButtonHovered,        0x4A4A44FF },
    { reaper.ImGui_Col_ButtonActive,         COL_ACCENT },
  }
  local pushed = 0
  for _, e in ipairs(list) do
    if e[1] then reaper.ImGui_PushStyleColor(ctx, e[1](), e[2]); pushed = pushed + 1 end
  end
  return pushed
end

local CHILD_HSCROLL = reaper.ImGui_WindowFlags_HorizontalScrollbar and
                      reaper.ImGui_WindowFlags_HorizontalScrollbar() or 0

-- Runs once per frame while the console window is open.
local function loop()
  local npushed = push_theme_base()
  if reaper.ImGui_SetNextWindowSizeConstraints then
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, 1000, 560, 1000000, 1000000)
  end
  if reaper.ImGui_SetNextWindowSize then
    reaper.ImGui_SetNextWindowSize(ctx, 1000, 560, reaper.ImGui_Cond_FirstUseEver())
  end
  local visible, open = reaper.ImGui_Begin(ctx, 'SK Balance Control', true, 0)
  if visible then
    local nbtn = push_theme_buttons()
    local pf = push_font(FONT, 13)
    draw_toolbar()

    local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), COL_PANEL)
    if reaper.ImGui_BeginChild(ctx, 'left', LEFT_W, avail_h, 0, 0) then
      draw_left_panel()
      reaper.ImGui_EndChild(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx, 1)

    reaper.ImGui_SameLine(ctx, 0, PANEL_GAP)

    local rp_x = reaper.ImGui_GetCursorScreenPos(ctx)
    local cur_win_x = reaper.ImGui_GetWindowPos(ctx)
    g_right_panel_offset_x = rp_x - cur_win_x
    if reaper.ImGui_BeginChild(ctx, 'right', 0, avail_h, 0, CHILD_HSCROLL) then
      draw_right_panel()
      reaper.ImGui_EndChild(ctx)
    end

    -- forward Space to Play/Stop, since ReaImGui otherwise swallows it
    -- while the console window is focused
    if reaper.ImGui_IsKeyPressed and reaper.ImGui_Key_Space
       and reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows())
       and not reaper.ImGui_IsAnyItemActive(ctx)
       and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Space(), false) then
      reaper.Main_OnCommand(40044, 0)  -- Transport: Play/stop
    end

    local enter_pressed = reaper.ImGui_IsKeyPressed and reaper.ImGui_Key_Enter and
      (reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter()) or
       (reaper.ImGui_Key_KeypadEnter and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter())))
    if g_dirty and (reaper.ImGui_IsMouseReleased(ctx, 0) or enter_pressed) then
      if reaper.Undo_OnStateChange2 then reaper.Undo_OnStateChange2(0, "SK Balance Control: adjust")
      elseif reaper.Undo_OnStateChange then reaper.Undo_OnStateChange("SK Balance Control: adjust") end
      g_dirty = false
    end

    pop_font(pf)
    reaper.ImGui_PopStyleColor(ctx, nbtn)
    reaper.ImGui_End(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, npushed)

  if open then
    reaper.defer(loop)
  else
    restore_all()  -- put back real mute/volume before closing
  end
end

reaper.atexit(restore_all)
reaper.defer(loop)
