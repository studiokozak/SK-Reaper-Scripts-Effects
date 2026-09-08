-- @description SK DocShadrach's Analog Ecosystem Companion
-- @author Studio Kozak
-- @version 1.0
-- @about
--   Sets up the analog console workflow designed by DocShadrach around
--   two plugins: The Analog Molecule and The Hot Summer.
--
--   Huge thanks to DocShadrach for this fantastic work. The plugins,
--   the console workflow they define, and everything else tied to their
--   design remain his by right.
--
--   For each track you route, the script can:
--   - Add The Analog Molecule to individual tracks
--   - Create up to 8 group buses with The Analog Molecule and The Hot Summer,
--     routed together
--   - Create a Mix Bus (or use your own) with The Analog Molecule and
--     The Hot Summer set up as the master stage
--
--   Tracks can be routed to a bus either with sends or by placing them
--   inside a folder, and everything can also be built from scratch in
--   one click.

local SCRIPT_NAME = "SK DocShadrach's Analog Ecosystem Companion"
local WIN_W, WIN_H = 1140, 640
local COL_LEFT_W   = 220
local ACTION_BTN_W, ACTION_BTN_H = 230, 32

local MAX_GROUPS_HARDCAP = 8

local AM_PARAM_TOPO  = 1
local HS_PARAM_TOPO  = 0
local HS_PARAM_MODE  = 1
local HS_PARAM_STEM  = 2

local DEFAULT_TRACK_COLOR = "REAPER_DEFAULT"
local DEFAULT_GROUP_COLORS = {
  DEFAULT_TRACK_COLOR, DEFAULT_TRACK_COLOR, DEFAULT_TRACK_COLOR, DEFAULT_TRACK_COLOR,
  DEFAULT_TRACK_COLOR, DEFAULT_TRACK_COLOR, DEFAULT_TRACK_COLOR, DEFAULT_TRACK_COLOR,
}

local GROUP_MOL_GUID_KEY   = "SK_DEC_GROUP_MOL_GUID"
local GROUP_SUM_GUID_KEY   = "SK_DEC_GROUP_SUM_GUID"
local MIXBUS_SUM_GUID_KEY  = "SK_DEC_MIXBUS_SUM_GUID"
local MIXBUS_MOL_GUID_KEY  = "SK_DEC_MIXBUS_MOL_GUID"
local CHANNEL_MOL_GUID_KEY = "SK_DEC_CHANNEL_MOL_GUID"

-- ============================================================
--  COLOR SWATCHES
-- ============================================================
local CP_PALETTE = {
  { 0.85, 0.25, 0.25 }, { 0.90, 0.55, 0.20 }, { 0.85, 0.75, 0.15 },
  { 0.25, 0.70, 0.30 }, { 0.20, 0.65, 0.75 }, { 0.30, 0.40, 0.85 },
  { 0.60, 0.25, 0.85 }, { 0.85, 0.25, 0.65 },
  { 0.3782, 0.5910, 0.6863 },
  { 0.9160, 0.8319, 0.6807 },
}

local function cp_pastel(r, g, b, t)
  return r + (1-r)*t, g + (1-g)*t, b + (1-b)*t
end

-- ============================================================
--  WINDOW SETUP
-- ============================================================
local ctx  = reaper.ImGui_CreateContext(SCRIPT_NAME)
local font = reaper.ImGui_CreateFont("sans-serif", 14)
reaper.ImGui_Attach(ctx, font)
local font_title = reaper.ImGui_CreateFont("sans-serif", 20)
reaper.ImGui_Attach(ctx, font_title)

-- ============================================================
--  INTERFACE COLORS
-- ============================================================
local C = {
  bg         = 0x1A1A1AFF,
  bg_panel   = 0x222222FF,
  bg_item    = 0x2A2A2AFF,
  bg_sel     = 0x2E3A4AFF,
  bg_header  = 0x181818FF,
  border     = 0x3A3A3AFF,
  text       = 0xF0F0F0FF,
  text_dim   = 0xBBBBBBFF,
  white      = 0xFFFFFFFF,
  accent     = 0x4A8FCAFF,
  accent_dim = 0x2A5A8AFF,
  sep        = 0x2E2E2EFF,
  new_trk    = 0x2A5A2AFF,
  new_trk_h  = 0x3A7A3AFF,
  title      = 0xE8A23DFF,
  ok_txt     = 0x6ACB6AFF,
  err_txt    = 0xE07A7AFF,
}

-- ============================================================
--  SAVED SETTINGS
-- ============================================================
local EXT_SECTION = "SK_DocShadrachCompanion"

local function load_str(key, default)
  if reaper.HasExtState(EXT_SECTION, key) then
    local v = reaper.GetExtState(EXT_SECTION, key)
    if v ~= "" then return v end
  end
  return default
end
local function save_str(key, value)
  reaper.SetExtState(EXT_SECTION, key, value or "", true)
end

-- ============================================================
--  SCRIPT SETTINGS
-- ============================================================
local state = {
  status_msg   = "",
  status_timer = 0,
  alert_msg    = nil,
  confirm_msg  = nil,
  pending      = nil,

  molecule_fx_name = load_str("molecule_fx_name", ""),
  summer_fx_name   = load_str("summer_fx_name", ""),
  test_molecule_msg = nil,
  test_summer_msg   = nil,

  mode = load_str("route_mode", "FOLDER"),

  num_groups = tonumber(load_str("num_groups", "8")) or 8,
  target_group = 1,
  also_channel_molecule = true,

  mixbus_name  = load_str("mixbus_name", "Mix Bus"),
  mixbus_color = load_str("mixbus_color", DEFAULT_TRACK_COLOR),
  mixbus_guid  = load_str("mixbus_track_guid", ""),

  cp_pastel = tonumber(load_str("cp_pastel", "0.3")) or 0.3,
  color_picker_target = nil,
  want_open_color_popup = false,

  assign_popup_target = nil,
  want_open_assign_popup = false,

  new_track_name  = "",
  new_track_count = 1,
  new_track_color = DEFAULT_TRACK_COLOR,
  new_track_route = false,
  new_track_target_group = 1,

  rename_track_ptr  = nil,
  rename_track_buf  = "",
  rename_just_opened = false,

  groups = {},
}
if state.num_groups < 1 then state.num_groups = 1 end
if state.num_groups > MAX_GROUPS_HARDCAP then state.num_groups = MAX_GROUPS_HARDCAP end

for i = 1, MAX_GROUPS_HARDCAP do
  state.groups[i] = {
    name  = load_str("group_name_"..i, "Group "..i),
    color = load_str("group_color_"..i, DEFAULT_GROUP_COLORS[i] or "888888"),
    guid  = load_str("group_track_guid_"..i, ""),
  }
end

-- ============================================================
--  TRACK INFORMATION
-- ============================================================
local function get_track_name(t)
  if not t or not reaper.ValidatePtr(t, "MediaTrack*") then return "?" end
  local _, name = reaper.GetSetMediaTrackInfo_String(t, "P_NAME", "", false)
  return name
end

local function tname(t)
  local n = get_track_name(t)
  if n == "" then return "(unnamed)" end
  return n
end

local function rcolor(t)
  if not t or not reaper.ValidatePtr(t, "MediaTrack*") then return 0x888888FF end
  local c = reaper.GetTrackColor(t)
  if c == 0 then return 0x888888FF end
  local r = (c >> 16) & 0xFF
  local g = (c >>  8) & 0xFF
  local b =  c        & 0xFF
  return (r << 24) | (g << 16) | (b << 8) | 0xFF
end

local function get_all_tracks()
  local t = {}
  for i = 0, reaper.CountTracks(0)-1 do t[#t+1] = reaper.GetTrack(0,i) end
  return t
end

local function get_checked_tracks(all_tracks)
  local out = {}
  for _, t in ipairs(all_tracks) do
    if reaper.IsTrackSelected(t) then out[#out+1] = t end
  end
  return out
end

local function find_track_by_name(name)
  for i = 0, reaper.CountTracks(0)-1 do
    local t = reaper.GetTrack(0,i)
    if get_track_name(t) == name then return t end
  end
  return nil
end

local function get_track_guid(track)
  local ok, guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
  if ok then return guid end
  return ""
end

local function find_track_by_guid(guid)
  if not guid or guid == "" then return nil end
  for i = 0, reaper.CountTracks(0)-1 do
    local t = reaper.GetTrack(0, i)
    if get_track_guid(t) == guid then return t end
  end
  return nil
end

local function resolve_group_track(idx)
  local g = state.groups[idx]
  if g.guid and g.guid ~= "" then
    local t = find_track_by_guid(g.guid)
    if t then return t end
  end
  return find_track_by_name(g.name)
end

local function resolve_mixbus_track()
  if state.mixbus_guid and state.mixbus_guid ~= "" then
    local t = find_track_by_guid(state.mixbus_guid)
    if t then return t end
  end
  return find_track_by_name(state.mixbus_name)
end

local function set_status(msg)
  state.status_msg   = msg
  state.status_timer = reaper.time_precise() + 5.0
end

-- ============================================================
--  COLORS
-- ============================================================
local function hex_to_rgb01(hex)
  hex = hex or "888888"
  local r = (tonumber(hex:sub(1,2),16) or 136) / 255
  local g = (tonumber(hex:sub(3,4),16) or 136) / 255
  local b = (tonumber(hex:sub(5,6),16) or 136) / 255
  return r, g, b
end

local function rgb01_to_hex(r,g,b)
  return string.format("%02X%02X%02X",
    math.floor(r*255+0.5), math.floor(g*255+0.5), math.floor(b*255+0.5))
end

local function set_track_color_hex(track, hex)
  if hex == DEFAULT_TRACK_COLOR then
    reaper.SetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR", 0)
    return
  end
  local r,g,b = hex_to_rgb01(hex)
  reaper.SetTrackColor(track, reaper.ColorToNative(math.floor(r*255+0.5), math.floor(g*255+0.5), math.floor(b*255+0.5)) | 0x1000000)
end

-- ============================================================
--  FINDING A PLUGIN BY NAME
-- ============================================================
local function resolve_fx_name(raw_name)
  if not raw_name or raw_name == "" then return nil, "Empty name." end
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  local tmp_idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(tmp_idx, false)
  local tmp = reaper.GetTrack(0, tmp_idx)
  reaper.SetMediaTrackInfo_Value(tmp, "B_SHOWINTCP", 0)
  reaper.SetMediaTrackInfo_Value(tmp, "B_SHOWINMIXER", 0)
  local fx_idx = reaper.TrackFX_AddByName(tmp, raw_name, false, 1)
  local resolved = nil
  if fx_idx >= 0 then
    local ok, fxname = reaper.TrackFX_GetFXName(tmp, fx_idx, "")
    if ok then resolved = fxname end
  end
  reaper.DeleteTrack(tmp)
  reaper.Undo_EndBlock("SK DEC: test plugin", -1)
  reaper.PreventUIRefresh(-1)
  if resolved then return resolved, nil end
  return nil, "Plugin not found"
end

-- ============================================================
--  PLUGIN SETUP
-- ============================================================
local function find_fx_by_name(track, fx_name)
  if not fx_name or fx_name == "" then return -1 end
  return reaper.TrackFX_AddByName(track, fx_name, false, 0)
end

local function store_fx_guid(track, ext_key, fx_idx)
  local guid = reaper.TrackFX_GetFXGUID(track, fx_idx)
  if guid then
    reaper.GetSetMediaTrackInfo_String(track, "P_EXT:"..ext_key, guid, true)
  end
end

local function find_fx_by_stored_guid(track, ext_key)
  local ok, guid = reaper.GetSetMediaTrackInfo_String(track, "P_EXT:"..ext_key, "", false)
  if not ok or guid == "" then return -1 end
  local count = reaper.TrackFX_GetCount(track)
  for i = 0, count-1 do
    if reaper.TrackFX_GetFXGUID(track, i) == guid then return i end
  end
  return -1
end

local function find_or_fallback(track, ext_key, fx_name)
  local idx = find_fx_by_stored_guid(track, ext_key)
  if idx >= 0 then return idx end
  return find_fx_by_name(track, fx_name)
end

local function add_fx_end(track, fx_name)
  local idx = reaper.TrackFX_AddByName(track, fx_name, false, 1)
  if idx >= 0 then reaper.TrackFX_SetOpen(track, idx, false) end
  return idx
end

local function move_fx_to_position(track, idx, dest)
  if idx == dest or idx < 0 then return idx end
  reaper.TrackFX_CopyToTrack(track, idx, track, dest, true)
  return dest
end

local function chan_bits(chan0) return (1 << chan0) end

local function pin_master_summer_inputs(track, fx_idx)
  for p = 0, 17 do
    reaper.TrackFX_SetPinMappings(track, fx_idx, 0, p, chan_bits(p), 0)
  end
  reaper.TrackFX_SetPinMappings(track, fx_idx, 1, 0, chan_bits(0), 0)
  reaper.TrackFX_SetPinMappings(track, fx_idx, 1, 1, chan_bits(1), 0)
end

local function enc_group_pair(idx0) return 2 + idx0*2 end

local function count_group_sources(grp_tr)
  if not grp_tr or not reaper.ValidatePtr(grp_tr, "MediaTrack*") then return 0, 0 end
  local folder_count = 0
  local grp_idx = math.floor(reaper.GetMediaTrackInfo_Value(grp_tr, "IP_TRACKNUMBER")) - 1
  if reaper.GetMediaTrackInfo_Value(grp_tr, "I_FOLDERDEPTH") >= 1 then
    local depth = 1
    local i = grp_idx + 1
    local total = reaper.CountTracks(0)
    while depth > 0 and i < total do
      local t = reaper.GetTrack(0, i)
      folder_count = folder_count + 1
      depth = depth + reaper.GetMediaTrackInfo_Value(t, "I_FOLDERDEPTH")
      i = i + 1
    end
  end
  local send_count = reaper.GetTrackNumSends(grp_tr, -1)
  return folder_count, send_count
end

-- ============================================================
--  BUILDING GROUPS AND THE MIX BUS
-- ============================================================
local function check_group(idx0, name)
  local track = resolve_group_track(idx0 + 1)
  if not track then return "new", nil end
  local has_mol = find_or_fallback(track, GROUP_MOL_GUID_KEY, state.molecule_fx_name) >= 0
  local has_sum = find_or_fallback(track, GROUP_SUM_GUID_KEY, state.summer_fx_name) >= 0
  if has_mol and has_sum then return "complete", track end
  return "needs_fx", track
end

local function check_mixbus(name)
  local track = resolve_mixbus_track()
  if not track then return "new", nil end
  local has_sum = find_or_fallback(track, MIXBUS_SUM_GUID_KEY, state.summer_fx_name) >= 0
  local has_mol = find_or_fallback(track, MIXBUS_MOL_GUID_KEY, state.molecule_fx_name) >= 0
  if has_sum and has_mol then return "complete", track end
  return "needs_fx", track
end

local function apply_group(idx0, name, color)
  local idx = idx0 + 1
  local g = state.groups[idx]
  local track = resolve_group_track(idx)
  if not track then
    local pos = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(pos, true)
    track = reaper.GetTrack(0, pos)
  end
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name, true)
  set_track_color_hex(track, color)

  local guid = get_track_guid(track)
  if g.guid ~= guid then
    g.guid = guid
    save_str("group_track_guid_"..idx, guid)
  end

  local mol_idx = find_or_fallback(track, GROUP_MOL_GUID_KEY, state.molecule_fx_name)
  if mol_idx < 0 then
    mol_idx = add_fx_end(track, state.molecule_fx_name)
    if mol_idx >= 0 then move_fx_to_position(track, mol_idx, 0) end
  end
  if mol_idx >= 0 then
    reaper.TrackFX_SetParam(track, mol_idx, AM_PARAM_TOPO, 1)
    reaper.TrackFX_SetNamedConfigParm(track, mol_idx, "renamed_name", name.."_AM Bus")
    store_fx_guid(track, GROUP_MOL_GUID_KEY, mol_idx)
  end

  local sum_idx = find_or_fallback(track, GROUP_SUM_GUID_KEY, state.summer_fx_name)
  if sum_idx < 0 then
    sum_idx = add_fx_end(track, state.summer_fx_name)
  end
  if sum_idx >= 0 then
    reaper.TrackFX_SetParam(track, sum_idx, HS_PARAM_TOPO, 0)
    reaper.TrackFX_SetParam(track, sum_idx, HS_PARAM_STEM, idx0)
    reaper.TrackFX_SetNamedConfigParm(track, sum_idx, "renamed_name", name.."_HS Bus")
    store_fx_guid(track, GROUP_SUM_GUID_KEY, sum_idx)
  end

  return track
end

local function apply_mixbus(name, color)
  local track = resolve_mixbus_track()
  if not track then
    local pos = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(pos, true)
    track = reaper.GetTrack(0, pos)
  end
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name, true)
  set_track_color_hex(track, color)

  local guid = get_track_guid(track)
  if state.mixbus_guid ~= guid then
    state.mixbus_guid = guid
    save_str("mixbus_track_guid", guid)
  end
  if reaper.GetMediaTrackInfo_Value(track, "I_NCHAN") < 18 then
    reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", 18)
  end

  local sum_idx = find_or_fallback(track, MIXBUS_SUM_GUID_KEY, state.summer_fx_name)
  if sum_idx < 0 then
    sum_idx = add_fx_end(track, state.summer_fx_name)
    if sum_idx >= 0 then
      move_fx_to_position(track, sum_idx, 0)
      sum_idx = 0
    end
  end
  if sum_idx >= 0 then
    reaper.TrackFX_SetParam(track, sum_idx, HS_PARAM_TOPO, 1)
    local cur_mode = reaper.TrackFX_GetParam(track, sum_idx, HS_PARAM_MODE)
    if not cur_mode or math.floor(cur_mode + 0.5) == 4 then
      reaper.TrackFX_SetParam(track, sum_idx, HS_PARAM_MODE, 0)
    end
    pin_master_summer_inputs(track, sum_idx)
    reaper.TrackFX_SetNamedConfigParm(track, sum_idx, "renamed_name", name.."_HS Master")
    store_fx_guid(track, MIXBUS_SUM_GUID_KEY, sum_idx)
  end

  local mol_idx = find_or_fallback(track, MIXBUS_MOL_GUID_KEY, state.molecule_fx_name)
  if mol_idx < 0 then
    mol_idx = add_fx_end(track, state.molecule_fx_name)
  end
  if mol_idx >= 0 then
    reaper.TrackFX_SetParam(track, mol_idx, AM_PARAM_TOPO, 2)
    local fresh_sum_idx = find_or_fallback(track, MIXBUS_SUM_GUID_KEY, state.summer_fx_name)
    if fresh_sum_idx >= 0 then
      move_fx_to_position(track, mol_idx, fresh_sum_idx + 1)
      mol_idx = fresh_sum_idx + 1
    end
    reaper.TrackFX_SetNamedConfigParm(track, mol_idx, "renamed_name", name.."_AM Master")
    store_fx_guid(track, MIXBUS_MOL_GUID_KEY, mol_idx)
  end

  return track
end

local function ensure_group_to_mixbus_send(group_tr, mixbus_tr, idx0)
  local nsends = reaper.GetTrackNumSends(group_tr, 0)
  for i = 0, nsends-1 do
    local dest = reaper.GetTrackSendInfo_Value(group_tr, 0, i, "P_DESTTRACK")
    if dest == mixbus_tr then
      reaper.SetTrackSendInfo_Value(group_tr, 0, i, "I_SRCCHAN", 0)
      reaper.SetTrackSendInfo_Value(group_tr, 0, i, "I_DSTCHAN", enc_group_pair(idx0))
      reaper.SetMediaTrackInfo_Value(group_tr, "B_MAINSEND", 0)
      return
    end
  end
  local si = reaper.CreateTrackSend(group_tr, mixbus_tr)
  reaper.SetTrackSendInfo_Value(group_tr, 0, si, "I_SENDMODE", 0)
  reaper.SetTrackSendInfo_Value(group_tr, 0, si, "D_VOL", 1.0)
  reaper.SetTrackSendInfo_Value(group_tr, 0, si, "D_PAN", 0.0)
  reaper.SetTrackSendInfo_Value(group_tr, 0, si, "I_SRCCHAN", 0)
  reaper.SetTrackSendInfo_Value(group_tr, 0, si, "I_DSTCHAN", enc_group_pair(idx0))
  reaper.SetTrackSendInfo_Value(group_tr, 0, si, "B_MONO", 0)
  reaper.SetTrackSendInfo_Value(group_tr, 0, si, "B_PHASE", 0)
  reaper.SetTrackSendInfo_Value(group_tr, 0, si, "B_MUTE", 0)
  reaper.SetMediaTrackInfo_Value(group_tr, "B_MAINSEND", 0)
end

-- ============================================================
--  ROUTING TRACKS TO A BUS
-- ============================================================
local function has_send_to(src, dst)
  local n = reaper.GetTrackNumSends(src, 0)
  for i = 0, n-1 do
    local d = reaper.GetTrackSendInfo_Value(src, 0, i, "P_DESTTRACK")
    if d == dst then return true end
  end
  return false
end

local function assign_sends(grp_tr, checked)
  for _, src in ipairs(checked) do
    if src ~= grp_tr and not has_send_to(src, grp_tr) then
      local si = reaper.CreateTrackSend(src, grp_tr)
      reaper.SetTrackSendInfo_Value(src, 0, si, "I_SENDMODE", 0)
      reaper.SetTrackSendInfo_Value(src, 0, si, "D_VOL", 1.0)
      reaper.SetTrackSendInfo_Value(src, 0, si, "D_PAN", 0.0)
      reaper.SetTrackSendInfo_Value(src, 0, si, "I_SRCCHAN", 0)
      reaper.SetTrackSendInfo_Value(src, 0, si, "I_DSTCHAN", 0)
      reaper.SetTrackSendInfo_Value(src, 0, si, "B_MONO", 0)
      reaper.SetTrackSendInfo_Value(src, 0, si, "B_PHASE", 0)
      reaper.SetTrackSendInfo_Value(src, 0, si, "B_MUTE", 0)
      reaper.SetMediaTrackInfo_Value(src, "B_MAINSEND", 0)
    end
  end
end

local function get_folder_children_list(grp_tr)
  local list = {}
  local grp_idx = math.floor(reaper.GetMediaTrackInfo_Value(grp_tr, "IP_TRACKNUMBER")) - 1
  if reaper.GetMediaTrackInfo_Value(grp_tr, "I_FOLDERDEPTH") < 1 then return list end
  local depth = 1
  local i = grp_idx + 1
  local total = reaper.CountTracks(0)
  while depth > 0 and i < total do
    local t = reaper.GetTrack(0, i)
    list[#list+1] = t
    depth = depth + reaper.GetMediaTrackInfo_Value(t, "I_FOLDERDEPTH")
    i = i + 1
  end
  return list
end

local function get_last_child(grp_tr)
  local list = get_folder_children_list(grp_tr)
  if #list == 0 then return nil end
  return list[#list]
end

local function assign_folder(grp_tr, checked, dest_chan_offset)
  dest_chan_offset = dest_chan_offset or 0
  local list = {}
  for _, t in ipairs(checked) do
    if t ~= grp_tr then list[#list+1] = t end
  end
  if #list == 0 then return end

  local last_child = get_last_child(grp_tr)
  local grp_idx = math.floor(reaper.GetMediaTrackInfo_Value(grp_tr, "IP_TRACKNUMBER")) - 1
  local inherited_close = 0
  if not last_child then
    local grp_depth_before = reaper.GetMediaTrackInfo_Value(grp_tr, "I_FOLDERDEPTH")
    inherited_close = math.min(grp_depth_before, 0)
  end

  local insert_pos
  if last_child then
    insert_pos = math.floor(reaper.GetMediaTrackInfo_Value(last_child, "IP_TRACKNUMBER"))
  else
    insert_pos = grp_idx + 1
  end

  local is_moved = {}
  for _, t in ipairs(list) do is_moved[t] = true end

  local prev_sel = {}
  for i = 0, reaper.CountTracks(0)-1 do
    local tt = reaper.GetTrack(0, i)
    prev_sel[tt] = reaper.IsTrackSelected(tt)
    reaper.SetTrackSelected(tt, is_moved[tt] or false)
  end

  reaper.ReorderSelectedTracks(insert_pos, 0)

  for tt, sel in pairs(prev_sel) do
    if not is_moved[tt] then reaper.SetTrackSelected(tt, sel) end
  end
  for _, t in ipairs(list) do reaper.SetTrackSelected(t, false) end

  reaper.SetMediaTrackInfo_Value(grp_tr, "I_FOLDERDEPTH", 1)
  if last_child then
    local d = reaper.GetMediaTrackInfo_Value(last_child, "I_FOLDERDEPTH")
    if d < 0 then reaper.SetMediaTrackInfo_Value(last_child, "I_FOLDERDEPTH", d + 1) end
  end

  local new_last, new_last_idx = nil, -1
  for _, t in ipairs(list) do
    local idx = math.floor(reaper.GetMediaTrackInfo_Value(t, "IP_TRACKNUMBER"))
    if idx > new_last_idx then new_last_idx = idx; new_last = t end
  end
  if new_last then
    local d = reaper.GetMediaTrackInfo_Value(new_last, "I_FOLDERDEPTH")
    reaper.SetMediaTrackInfo_Value(new_last, "I_FOLDERDEPTH", d - 1 + inherited_close)
  end

  for _, t in ipairs(list) do
    reaper.SetMediaTrackInfo_Value(t, "B_MAINSEND", 1)
    reaper.SetMediaTrackInfo_Value(t, "C_MAINSEND_OFFS", dest_chan_offset)
  end
end

local function ensure_group_in_mixbus_folder(group_tr, mixbus_tr, idx0)
  local children = get_folder_children_list(mixbus_tr)
  local already_child = false
  for _, ct in ipairs(children) do
    if ct == group_tr then already_child = true break end
  end
  if already_child then
    reaper.SetMediaTrackInfo_Value(group_tr, "B_MAINSEND", 1)
    reaper.SetMediaTrackInfo_Value(group_tr, "C_MAINSEND_OFFS", enc_group_pair(idx0))
  else
    assign_folder(mixbus_tr, { group_tr }, enc_group_pair(idx0))
  end
end

local function ensure_group_to_mixbus_link(group_tr, mixbus_tr, idx0)
  if state.mode == "FOLDER" then
    local n = reaper.GetTrackNumSends(group_tr, 0)
    for i = n-1, 0, -1 do
      local d = reaper.GetTrackSendInfo_Value(group_tr, 0, i, "P_DESTTRACK")
      if d == mixbus_tr then reaper.RemoveTrackSend(group_tr, 0, i) end
    end
    ensure_group_in_mixbus_folder(group_tr, mixbus_tr, idx0)
  else
    ensure_group_to_mixbus_send(group_tr, mixbus_tr, idx0)
  end
end

local function remove_from_folder(grp_tr, t)
  local children = get_folder_children_list(grp_tr)
  local t_pos = nil
  for idx, ct in ipairs(children) do
    if ct == t then t_pos = idx break end
  end
  if not t_pos then return end
  local is_last = (t_pos == #children)

  if #children == 1 then
    reaper.SetMediaTrackInfo_Value(grp_tr, "I_FOLDERDEPTH", 0)
    reaper.SetMediaTrackInfo_Value(t, "I_FOLDERDEPTH", 0)
  elseif is_last then
    local new_last = children[#children - 1]
    local d = reaper.GetMediaTrackInfo_Value(new_last, "I_FOLDERDEPTH")
    reaper.SetMediaTrackInfo_Value(new_last, "I_FOLDERDEPTH", d - 1)
    reaper.SetMediaTrackInfo_Value(t, "I_FOLDERDEPTH", 0)
  else
    reaper.SetMediaTrackInfo_Value(t, "I_FOLDERDEPTH", 0)
  end

  local remaining = get_folder_children_list(grp_tr)
  local move_after_pos
  if #remaining > 0 then
    move_after_pos = math.floor(reaper.GetMediaTrackInfo_Value(remaining[#remaining], "IP_TRACKNUMBER"))
  else
    move_after_pos = math.floor(reaper.GetMediaTrackInfo_Value(grp_tr, "IP_TRACKNUMBER"))
  end

  local prev_sel = {}
  for i = 0, reaper.CountTracks(0)-1 do
    local tt = reaper.GetTrack(0, i)
    prev_sel[tt] = reaper.IsTrackSelected(tt)
    reaper.SetTrackSelected(tt, false)
  end
  reaper.SetTrackSelected(t, true)
  reaper.ReorderSelectedTracks(move_after_pos, 0)
  for tt, sel in pairs(prev_sel) do
    if tt ~= t then reaper.SetTrackSelected(tt, sel) end
  end
  reaper.SetTrackSelected(t, false)

  reaper.SetMediaTrackInfo_Value(t, "B_MAINSEND", 1)
  reaper.SetMediaTrackInfo_Value(t, "C_MAINSEND_OFFS", 0)
end

local function get_track_group_assignment(t)
  for i = 1, state.num_groups do
    local g = state.groups[i]
    local grp_tr = resolve_group_track(i)
    if grp_tr and grp_tr ~= t then
      if has_send_to(t, grp_tr) then
        return { idx = i, name = g.name, color = g.color, track = grp_tr, mode = "SENDS" }
      end
      local children = get_folder_children_list(grp_tr)
      for _, ct in ipairs(children) do
        if ct == t then
          return { idx = i, name = g.name, color = g.color, track = grp_tr, mode = "FOLDER" }
        end
      end
    end
  end
  return nil
end

local function unassign_track(t)
  local a = get_track_group_assignment(t)
  if not a then return false end
  if a.mode == "SENDS" then
    local n = reaper.GetTrackNumSends(t, 0)
    for i = n-1, 0, -1 do
      local d = reaper.GetTrackSendInfo_Value(t, 0, i, "P_DESTTRACK")
      if d == a.track then reaper.RemoveTrackSend(t, 0, i) end
    end
    reaper.SetMediaTrackInfo_Value(t, "B_MAINSEND", 1)
  else
    remove_from_folder(a.track, t)
  end
  return true
end

local function reassign_track(t, new_idx)
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  unassign_track(t)
  local g = state.groups[new_idx]
  local mixbus_tr = apply_mixbus(state.mixbus_name, state.mixbus_color)
  local grp_tr    = apply_group(new_idx-1, g.name, g.color)
  ensure_group_to_mixbus_link(grp_tr, mixbus_tr, new_idx-1)
  if state.mode == "FOLDER" then
    assign_folder(grp_tr, { t })
  else
    assign_sends(grp_tr, { t })
  end
  reaper.SetTrackSelected(t, false)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK DEC: Reassign track to "..g.name, -1)
  reaper.PreventUIRefresh(-1)
  set_status(tname(t).." reassigned to "..g.name..".")
end
local function open_confirm(msg)
  state.confirm_msg = msg
  reaper.ImGui_OpenPopup(ctx, "Confirm##confirm_popup")
end

local function open_alert(msg)
  state.alert_msg = msg
  reaper.ImGui_OpenPopup(ctx, "Notice##alert_popup")
end

local function collect_needs_fx(checks)
  local names = {}
  for _, c in ipairs(checks) do
    if c.status == "needs_fx" then names[#names+1] = c.label end
  end
  return names
end

local function apply_build_scratch()
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  local mixbus_tr = apply_mixbus(state.mixbus_name, state.mixbus_color)
  for i = 1, state.num_groups do
    local g = state.groups[i]
    local grp_tr = apply_group(i-1, g.name, g.color)
    ensure_group_to_mixbus_link(grp_tr, mixbus_tr, i-1)
  end
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK DEC: Build full console from scratch", -1)
  reaper.PreventUIRefresh(-1)
  set_status(string.format("Full console built: %d group(s) + %s.", state.num_groups, state.mixbus_name))
end

local function do_build_scratch()
  if state.molecule_fx_name == "" or state.summer_fx_name == "" then
    open_alert("Configure and test both plugins (The Analog Molecule and The Hot Summer) before building.")
    return
  end
  local checks = {}
  for i = 1, state.num_groups do
    checks[#checks+1] = { status = check_group(i-1, state.groups[i].name), label = state.groups[i].name }
  end
  checks[#checks+1] = { status = check_mixbus(state.mixbus_name), label = state.mixbus_name }

  local needs = collect_needs_fx(checks)
  if #needs > 0 then
    state.pending = { kind = "build_scratch" }
    open_confirm("These tracks already exist but are missing required plugins:\n- "..table.concat(needs, "\n- ").."\n\nAdd the missing plugins now?")
  else
    apply_build_scratch()
  end
end

local function apply_route(checked, gi)
  gi = gi or state.target_group
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()

  local g = state.groups[gi]
  local mixbus_tr = apply_mixbus(state.mixbus_name, state.mixbus_color)
  local grp_tr    = apply_group(gi-1, g.name, g.color)
  ensure_group_to_mixbus_link(grp_tr, mixbus_tr, gi-1)

  if state.also_channel_molecule then
    for _, src in ipairs(checked) do
      local has_ch = find_or_fallback(src, CHANNEL_MOL_GUID_KEY, state.molecule_fx_name) >= 0
      if not has_ch then
        local idx = reaper.TrackFX_AddByName(src, state.molecule_fx_name, false, 1)
        if idx >= 0 then
          reaper.TrackFX_SetOpen(src, idx, false)
          reaper.TrackFX_SetParam(src, idx, AM_PARAM_TOPO, 0)
          move_fx_to_position(src, idx, 0)
          reaper.TrackFX_SetNamedConfigParm(src, 0, "renamed_name", get_track_name(src).."_AM Channel")
          store_fx_guid(src, CHANNEL_MOL_GUID_KEY, 0)
        end
      end
    end
    reaper.gmem_attach("AnalogMoleculeHybrid")
    reaper.gmem_write(11, math.random(1000))
    reaper.gmem_write(1, 0)
    reaper.gmem_write(0, (reaper.gmem_read(0) or 0) + 1)
  end

  if state.mode == "FOLDER" then
    assign_folder(grp_tr, checked)
  else
    assign_sends(grp_tr, checked)
  end

  for _, t in ipairs(checked) do
    reaper.SetTrackSelected(t, false)
  end

  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK DEC: Route tracks to "..g.name, -1)
  reaper.PreventUIRefresh(-1)
  set_status(string.format("%d track(s) routed to %s.", #checked, g.name))
end

local function get_bus_role(t)
  local guid = get_track_guid(t)
  if state.mixbus_guid ~= "" and guid == state.mixbus_guid then return "mixbus" end
  for i = 1, MAX_GROUPS_HARDCAP do
    if state.groups[i].guid ~= "" and guid == state.groups[i].guid then return "group", i end
  end
  local tname_now = get_track_name(t)
  if tname_now == state.mixbus_name then return "mixbus" end
  for i = 1, MAX_GROUPS_HARDCAP do
    if tname_now == state.groups[i].name then return "group", i end
  end
  return nil
end

local function is_bus_track(t)
  return get_bus_role(t) ~= nil
end

local function filter_out_bus_tracks(list)
  local out = {}
  for _, t in ipairs(list) do
    if not is_bus_track(t) then out[#out+1] = t end
  end
  return out
end

local function do_route(checked, gi)
  gi = gi or state.target_group
  checked = filter_out_bus_tracks(checked)
  if #checked == 0 then return end
  if state.molecule_fx_name == "" or state.summer_fx_name == "" then
    open_alert("Configure and test both plugins (The Analog Molecule and The Hot Summer) before routing.")
    return
  end
  local g = state.groups[gi]
  local checks = {
    { status = check_group(gi-1, g.name), label = g.name },
    { status = check_mixbus(state.mixbus_name), label = state.mixbus_name },
  }
  local needs = collect_needs_fx(checks)
  if #needs > 0 then
    state.pending = { kind = "route", checked = checked, gi = gi }
    open_confirm("These tracks already exist but are missing required plugins:\n- "..table.concat(needs, "\n- ").."\n\nAdd the missing plugins now?")
  else
    apply_route(checked, gi)
  end
end

-- ============================================================
--  INTERFACE BUTTONS AND LABELS
-- ============================================================
local function draw_centered_label(vis, txt_col)
  if not vis or vis == "" then return end
  local x1, y1 = reaper.ImGui_GetItemRectMin(ctx)
  local x2, y2 = reaper.ImGui_GetItemRectMax(ctx)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, vis)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local tx = math.floor((x1 + x2 - tw) * 0.5 + 0.5)
  local ty = math.floor((y1 + y2 - th) * 0.5 + 0.5)
  reaper.ImGui_DrawList_AddText(dl, tx, ty, txt_col or C.text, vis)
end

local function label_vis(label)
  local v = label:match("^(.-)##")
  if v == nil then return label end
  return v
end

local BTN_PAD_X = 8
local function auto_btn_size(vis, w, h)
  local bw, bh = w, h
  if not bw then
    local tw = reaper.ImGui_CalcTextSize(ctx, vis)
    bw = tw + BTN_PAD_X
  end
  if not bh then bh = reaper.ImGui_GetFrameHeight(ctx) end
  return bw, bh
end

local function btn(label, w, h)
  local vis = label_vis(label)
  local bw, bh = auto_btn_size(vis, w, h)
  local r = reaper.ImGui_Button(ctx, "##"..label, bw, bh)
  draw_centered_label(vis, C.text)
  return r
end

local function col_btn(label, col, hov, w, h)
  local vis = label_vis(label)
  local bw, bh = auto_btn_size(vis, w, h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        col)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), hov or col)
  local r = reaper.ImGui_Button(ctx, "##"..label, bw, bh)
  reaper.ImGui_PopStyleColor(ctx, 2)
  draw_centered_label(vis, C.white)
  return r
end

local BORDER_BTN_THICKNESS = 3.0
local function bordered_target_btn(label, border_col, active, w, h)
  local vis = label_vis(label)
  local bw, bh = auto_btn_size(vis, w, h)
  local clicked = reaper.ImGui_InvisibleButton(ctx, "##"..label, bw, bh)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local x1, y1  = reaper.ImGui_GetItemRectMin(ctx)
  local x2, y2  = reaper.ImGui_GetItemRectMax(ctx)
  local dl      = reaper.ImGui_GetWindowDrawList(ctx)

  reaper.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, hovered and 0x363636FF or C.bg_item, 3)
  if active then
    local inset = BORDER_BTN_THICKNESS * 0.5
    reaper.ImGui_DrawList_AddRect(dl, x1+inset, y1+inset, x2-inset, y2-inset, border_col, 3, 0, BORDER_BTN_THICKNESS)
  else
    reaper.ImGui_DrawList_AddRect(dl, x1, y1, x2, y2, C.border, 3, 0, 1.0)
  end

  draw_centered_label(vis, C.text)
  return clicked
end

local function section_divider()
  local x1, y   = reaper.ImGui_GetCursorScreenPos(ctx)
  local availw  = reaper.ImGui_GetContentRegionAvail(ctx)
  local dl      = reaper.ImGui_GetWindowDrawList(ctx)
  local yy      = math.floor(y + 3) + 0.5
  reaper.ImGui_DrawList_AddLine(dl, x1, yy, x1 + availw, yy, 0x707070FF, 2.0)
  reaper.ImGui_Dummy(ctx, availw, 8)
end

local function sec_title(label)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.white)
  reaper.ImGui_Text(ctx, label)
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)
end

local function push_style()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(),         C.bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(),          C.bg_panel)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),          C.bg_item)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(),   0x363636FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),    0x404040FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),           C.accent_dim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),    C.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),     0x5AAFEFFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),           C.bg_sel)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(),    0x3A4A5AFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),     C.accent_dim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),             C.text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(),          C.bg_panel)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),           C.border)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrab(),       C.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrabActive(), 0x5AAFEFFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(),        C.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarBg(),      C.bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrab(),    C.border)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBg(),          C.bg_header)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgActive(),    C.bg_header)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(),        C.sep)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),  3)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),    5, 3)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),   4, 3)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),  8, 8)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarSize(),  10)
  return 22, 6
end

local function pop_style(nc, nv)
  reaper.ImGui_PopStyleColor(ctx, nc)
  reaper.ImGui_PopStyleVar(ctx, nv)
end

local function text_input(id, value, width)
  reaper.ImGui_SetNextItemWidth(ctx, width or 200)
  local changed, nv = reaper.ImGui_InputText(ctx, "##"..id, value)
  if changed then return nv, true end
  return value, false
end

-- ============================================================
--  COLOR PICKER
-- ============================================================
local function color_swatch_button(id, hex)
  local r, g, b = hex_to_rgb01(hex)
  local col32 = (math.floor(r*255+0.5) << 24)
              | (math.floor(g*255+0.5) << 16)
              | (math.floor(b*255+0.5) <<  8)
              | 0xFF
  local sw = 24
  local clicked = reaper.ImGui_InvisibleButton(ctx, "##swatch_"..id, sw, sw)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local rx, ry  = reaper.ImGui_GetItemRectMin(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_AddRectFilled(dl, rx, ry, rx+sw, ry+sw, col32, 3)
  reaper.ImGui_DrawList_AddRect(dl, rx, ry, rx+sw, ry+sw, hovered and 0xFFFFFFFF or C.border, 3)
  return clicked
end

local function draw_color_picker_popup()
  if reaper.ImGui_BeginPopup(ctx, "Pick Color##color_popup") then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
    reaper.ImGui_Text(ctx, "Pick a color")
    reaper.ImGui_PopStyleColor(ctx, 1)

    reaper.ImGui_SetNextItemWidth(ctx, 300)
    local pc, pv = reaper.ImGui_SliderDouble(ctx, "##cp_pastel_dec",
      state.cp_pastel, 0.0, 1.0,
      "Pastel: "..math.floor(state.cp_pastel*100+0.5).."%%")
    if pc then
      state.cp_pastel = pv
      save_str("cp_pastel", tostring(pv))
    end
    reaper.ImGui_Spacing(ctx)

    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local pt = state.cp_pastel
    local per_row = #CP_PALETTE
    local gap = 5
    local sw = 26

    for i, c in ipairs(CP_PALETTE) do
      local r, g, b = cp_pastel(c[1], c[2], c[3], pt)
      local col32 = (math.floor(r*255+0.5) << 24)
                  | (math.floor(g*255+0.5) << 16)
                  | (math.floor(b*255+0.5) <<  8)
                  | 0xFF
      local clicked = reaper.ImGui_InvisibleButton(ctx, "##cp_pick_"..i, sw, sw)
      local hovered = reaper.ImGui_IsItemHovered(ctx)
      local rx, ry  = reaper.ImGui_GetItemRectMin(ctx)
      reaper.ImGui_DrawList_AddRectFilled(dl, rx, ry, rx+sw, ry+sw, col32, 3)
      if hovered then
        reaper.ImGui_DrawList_AddRect(dl, rx-1, ry-1, rx+sw+1, ry+sw+1, 0xFFFFFFFF, 3)
      end
      if clicked then
        local hex = rgb01_to_hex(r, g, b)
        local tgt = state.color_picker_target
        if tgt then
          if tgt.kind == "group" then
            state.groups[tgt.idx].color = hex
            save_str("group_color_"..tgt.idx, hex)
            local existing = resolve_group_track(tgt.idx)
            if existing then
              set_track_color_hex(existing, hex)
              reaper.TrackList_AdjustWindows(false)
            end
          elseif tgt.kind == "mixbus" then
            state.mixbus_color = hex
            save_str("mixbus_color", hex)
            local existing = resolve_mixbus_track()
            if existing then
              set_track_color_hex(existing, hex)
              reaper.TrackList_AdjustWindows(false)
            end
          elseif tgt.kind == "track" then
            if reaper.ValidatePtr(tgt.track, "MediaTrack*") then
              set_track_color_hex(tgt.track, hex)
              reaper.TrackList_AdjustWindows(false)
            end
          end
        end
        state.color_picker_target = nil
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      if i % per_row ~= 0 and i < #CP_PALETTE then
        reaper.ImGui_SameLine(ctx, 0, gap)
      end
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

local function draw_assignment_popup()
  if reaper.ImGui_BeginPopup(ctx, "Track Assignment##assign_popup") then
    local t = state.assign_popup_target
    if t and reaper.ValidatePtr(t, "MediaTrack*") then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.white)
      reaper.ImGui_Text(ctx, tname(t))
      reaper.ImGui_PopStyleColor(ctx, 1)

      local a = get_track_group_assignment(t)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
      if a then
        reaper.ImGui_Text(ctx, "Currently: "..a.name.." ("..a.mode..")")
      else
        reaper.ImGui_Text(ctx, "Not assigned to any group.")
      end
      reaper.ImGui_PopStyleColor(ctx, 1)
      reaper.ImGui_Spacing(ctx)

      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
      reaper.ImGui_Text(ctx, "Reassign to:")
      reaper.ImGui_PopStyleColor(ctx, 1)
      for i = 1, state.num_groups do
        local g = state.groups[i]
        local r, gg, b = hex_to_rgb01(g.color)
        local col32 = (math.floor(r*255+0.5) << 24) | (math.floor(gg*255+0.5) << 16) | (math.floor(b*255+0.5) << 8) | 0xFF
        if i > 1 then reaper.ImGui_SameLine(ctx, 0, 4) end
        local is_current = a and a.idx == i
        if col_btn(tostring(i)..(is_current and " *" or "").."##assign_grp_"..i, col32, col32, 30, 26) then
          if not is_current then
            reassign_track(t, i)
          end
          reaper.ImGui_CloseCurrentPopup(ctx)
        end
      end

      if a then
        reaper.ImGui_Spacing(ctx)
        local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
        if col_btn("Remove assignment##remove_assign", C.accent_dim, C.accent, avail_w, 28) then
          reaper.PreventUIRefresh(1)
          reaper.Undo_BeginBlock()
          unassign_track(t)
          reaper.TrackList_AdjustWindows(false)
          reaper.Undo_EndBlock("SK DEC: Remove track assignment", -1)
          reaper.PreventUIRefresh(-1)
          set_status(tname(t).." unassigned.")
          reaper.ImGui_CloseCurrentPopup(ctx)
        end
      end
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

-- ============================================================
--  PLUGIN SETUP FIELDS
-- ============================================================
local function draw_fx_row(label, key, msg_key)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
  reaper.ImGui_Text(ctx, label)
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SameLine(ctx, 160, 0)

  local nv, changed = text_input(key, state[key], 340)
  if changed then
    state[key] = nv
    state[msg_key] = nil
    save_str(key, nv)
  end

  reaper.ImGui_SameLine(ctx, 0, 6)
  if btn("Test##test_"..key) then
    local resolved, err = resolve_fx_name(state[key])
    if resolved then
      state[key] = resolved
      save_str(key, resolved)
      state[msg_key] = { ok = true, txt = "OK" }
    else
      state[msg_key] = { ok = false, txt = err }
    end
  end

  if state[msg_key] then
    reaper.ImGui_SameLine(ctx, 0, 8)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
      state[msg_key].ok and C.ok_txt or C.err_txt)
    reaper.ImGui_Text(ctx, state[msg_key].txt)
    reaper.ImGui_PopStyleColor(ctx, 1)
  end
end

-- ============================================================
--  SENDS / FOLDER SWITCH
-- ============================================================
local function draw_mode_toggle()
  local seg_w = 70
  local seg_h = reaper.ImGui_GetFrameHeight(ctx)
  local function seg(label, key)
    local active = state.mode == key
    local col = active and C.accent or C.bg_item
    local hov = active and C.accent or 0x363636FF
    if col_btn(label.."##mode_"..key, col, hov, seg_w, seg_h) then
      if state.mode ~= key then
        state.mode = key
        save_str("route_mode", key)
      end
    end
  end
  seg("SENDS", "SENDS")
  reaper.ImGui_SameLine(ctx, 0, 4)
  seg("FOLDER", "FOLDER")
end

-- ============================================================
--  LEFT PANEL: TRACK LIST
-- ============================================================
local function draw_left(all_tracks)
  local child_ok = reaper.ImGui_BeginChild(ctx, "left", COL_LEFT_W, 0, 0)
  if not child_ok then reaper.ImGui_EndChild(ctx); return end

  sec_title(#all_tracks .. " track(s) in project")

  if col_btn("+ Add##add_tr", C.new_trk, C.new_trk_h, 90) then
    reaper.ImGui_OpenPopup(ctx, "Add track(s)")
  end
  reaper.ImGui_SameLine(ctx, 0, 4)
  if btn("None##chk_none", 90) then
    for _, t in ipairs(all_tracks) do reaper.SetTrackSelected(t, false) end
  end
  reaper.ImGui_Spacing(ctx)
  section_divider()

  if reaper.ImGui_BeginPopupModal(ctx, "Add track(s)", nil,
      reaper.ImGui_WindowFlags_AlwaysAutoResize()) then

    reaper.ImGui_Text(ctx, "Number of tracks to create:")
    if btn("-##ntr_minus", 26) then
      if state.new_track_count > 1 then state.new_track_count = state.new_track_count - 1 end
    end
    reaper.ImGui_SameLine(ctx, 0, 6)
    reaper.ImGui_Text(ctx, tostring(state.new_track_count))
    reaper.ImGui_SameLine(ctx, 0, 6)
    if btn("+##ntr_plus", 26) then
      state.new_track_count = state.new_track_count + 1
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, "Name mask:")
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
    reaper.ImGui_Text(ctx, "  Leave empty for auto name. The REAPER track")
    reaper.ImGui_Text(ctx, "  number will be appended automatically.")
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Spacing(ctx)
    local ntn, ntc = text_input("new_track_name", state.new_track_name, 260)
    if ntc then state.new_track_name = ntn end

    if state.new_track_name ~= "" then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
      local preview_count = math.min(state.new_track_count, 4)
      for i = 1, preview_count do
        local preview_name = state.new_track_count == 1
          and state.new_track_name
          or  string.format("%s %d", state.new_track_name, i)
        reaper.ImGui_Text(ctx, "  -> " .. preview_name)
      end
      if state.new_track_count > 4 then
        reaper.ImGui_Text(ctx, string.format("  ... (%d tracks)", state.new_track_count))
      end
      reaper.ImGui_PopStyleColor(ctx, 1)
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    reaper.ImGui_Text(ctx, "Color:")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 200)
    local ntrpp, ntrpv = reaper.ImGui_SliderDouble(ctx, "##ntr_pastel",
      state.cp_pastel, 0.0, 1.0,
      "Pastel: "..math.floor(state.cp_pastel*100+0.5).."%%")
    if ntrpp then
      state.cp_pastel = ntrpv
      save_str("cp_pastel", tostring(ntrpv))
    end
    reaper.ImGui_Spacing(ctx)

    local ntrdraw = reaper.ImGui_GetWindowDrawList(ctx)
    local ntrpt   = state.cp_pastel
    for i, c in ipairs(CP_PALETTE) do
      local r, g, b = cp_pastel(c[1], c[2], c[3], ntrpt)
      local col32 = (math.floor(r*255+0.5) << 24)
                  | (math.floor(g*255+0.5) << 16)
                  | (math.floor(b*255+0.5) <<  8)
                  | 0xFF
      local clicked = reaper.ImGui_InvisibleButton(ctx, "##ntrp_"..i, 24, 24)
      local hovered = reaper.ImGui_IsItemHovered(ctx)
      local rx, ry  = reaper.ImGui_GetItemRectMin(ctx)
      reaper.ImGui_DrawList_AddRectFilled(ntrdraw, rx, ry, rx+24, ry+24, col32, 3)
      local hexc = rgb01_to_hex(r, g, b)
      if state.new_track_color == hexc then
        reaper.ImGui_DrawList_AddRect(ntrdraw, rx-2, ry-2, rx+26, ry+26, 0xFFFFFFFF, 3)
      elseif hovered then
        reaper.ImGui_DrawList_AddRect(ntrdraw, rx-1, ry-1, rx+25, ry+25, 0xAAAAAAFF, 3)
      end
      if clicked then
        state.new_track_color = hexc
      end
      if i < #CP_PALETTE then reaper.ImGui_SameLine(ctx, 0, 4) end
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    local _, ntr_route_nv = reaper.ImGui_Checkbox(ctx, "Route new track(s) to bus##ntr_route", state.new_track_route)
    if ntr_route_nv ~= nil then state.new_track_route = ntr_route_nv end

    if state.new_track_route then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
      reaper.ImGui_Text(ctx, "Target group:")
      reaper.ImGui_PopStyleColor(ctx, 1)
      reaper.ImGui_SameLine(ctx, 110, 0)
      for i = 1, state.num_groups do
        local active = state.new_track_target_group == i
        local r, g, b = hex_to_rgb01(state.groups[i].color)
        local border_col = (math.floor(r*255+0.5) << 24) | (math.floor(g*255+0.5) << 16) | (math.floor(b*255+0.5) << 8) | 0xFF
        if i > 1 then reaper.ImGui_SameLine(ctx, 0, 4) end
        if bordered_target_btn(tostring(i).."##ntr_target_"..i, border_col, active, 26, 26) then
          state.new_track_target_group = i
        end
      end
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    local ntr_lbl = state.new_track_count > 1
      and string.format("Create %d tracks##ntr_ok", state.new_track_count)
      or  "Create 1 track##ntr_ok"
    if col_btn(ntr_lbl, C.new_trk, C.new_trk_h) then
      reaper.PreventUIRefresh(1)
      reaper.Undo_BeginBlock()
      local base_insert = reaper.CountTracks(0)
      local created_tracks = {}
      for i = 1, state.new_track_count do
        local insert_at = base_insert + (i - 1)
        reaper.InsertTrackAtIndex(insert_at, true)
        local new_tr = reaper.GetTrack(0, insert_at)
        if state.new_track_name ~= "" then
          local track_name = state.new_track_count == 1
            and state.new_track_name
            or  string.format("%s %d", state.new_track_name, i)
          reaper.GetSetMediaTrackInfo_String(new_tr, "P_NAME", track_name, true)
        end
        set_track_color_hex(new_tr, state.new_track_color)
        created_tracks[#created_tracks+1] = new_tr
      end
      reaper.TrackList_AdjustWindows(false)
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("SK DEC: Create tracks", -1)
      reaper.PreventUIRefresh(-1)
      set_status(string.format("%d track(s) created.", state.new_track_count))

      local route_now    = state.new_track_route
      local route_target = state.new_track_target_group

      state.new_track_name  = ""
      state.new_track_count = 1
      state.new_track_color = DEFAULT_TRACK_COLOR
      state.new_track_route = false
      reaper.ImGui_CloseCurrentPopup(ctx)

      if route_now then
        do_route(created_tracks, route_target)
      end
    end
    reaper.ImGui_SameLine(ctx, 0, 8)
    if btn("Cancel##ntr_no") then
      state.new_track_name  = ""
      state.new_track_count = 1
      state.new_track_color = DEFAULT_TRACK_COLOR
      state.new_track_route = false
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end

  local list_ok = reaper.ImGui_BeginChild(ctx, "track_checklist", 0, 0, 0)
  if list_ok then
    for _, t in ipairs(all_tracks) do
      local ptr     = tostring(t)
      local checked = reaper.IsTrackSelected(t)

      local dc = rcolor(t)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        dc)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), dc)
      local track_swatch_clicked = reaper.ImGui_Button(ctx, "##tb_"..ptr, 10, 18)
      reaper.ImGui_PopStyleColor(ctx, 2)
      if track_swatch_clicked then
        state.color_picker_target = { kind = "track", track = t }
        state.want_open_color_popup = true
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Click to pick a color")
      end
      reaper.ImGui_SameLine(ctx, 0, 4)

      local assignment = get_track_group_assignment(t)
      local is_bus = is_bus_track(t)
      local disable_chk = assignment ~= nil or is_bus

      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),    0xBBBBBBFF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),   0x444444FF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(), 0xDDDDDDFF)
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1)
      if disable_chk then reaper.ImGui_BeginDisabled(ctx, true) end
      local _, nv = reaper.ImGui_Checkbox(ctx, "##chk_"..ptr, checked)
      if disable_chk then
        reaper.ImGui_EndDisabled(ctx)
      elseif nv ~= nil then
        reaper.SetTrackSelected(t, nv)
      end
      reaper.ImGui_PopStyleVar(ctx, 1)
      reaper.ImGui_PopStyleColor(ctx, 3)
      if assignment and reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Assigned to "..assignment.name.." — remove the assignment first")
      end

      reaper.ImGui_SameLine(ctx, 0, 4)
      local dot_clicked = reaper.ImGui_InvisibleButton(ctx, "##assigndot_"..ptr, 18, 18)
      if assignment then
        local drx, dry = reaper.ImGui_GetItemRectMin(ctx)
        local dcx, dcy = drx + 9, dry + 9
        local ddl = reaper.ImGui_GetWindowDrawList(ctx)
        local ar, ag, ab = hex_to_rgb01(assignment.color)
        local acol32 = (math.floor(ar*255+0.5) << 24) | (math.floor(ag*255+0.5) << 16) | (math.floor(ab*255+0.5) << 8) | 0xFF
        reaper.ImGui_DrawList_AddCircleFilled(ddl, dcx, dcy, 5, acol32)
        if reaper.ImGui_IsItemHovered(ctx) then
          reaper.ImGui_SetTooltip(ctx, "Assigned to "..assignment.name.." ("..assignment.mode..") — click to change")
        end
        if dot_clicked then
          state.assign_popup_target = t
          state.want_open_assign_popup = true
        end
      end

      reaper.ImGui_SameLine(ctx, 0, 4)
      if state.rename_track_ptr == t then
        reaper.ImGui_SetNextItemWidth(ctx, -1)
        local flags = reaper.ImGui_InputTextFlags_EnterReturnsTrue()
                    | reaper.ImGui_InputTextFlags_AutoSelectAll()
        if state.rename_just_opened then
          reaper.ImGui_SetKeyboardFocusHere(ctx)
          state.rename_just_opened = false
        end
        local confirmed, rnv = reaper.ImGui_InputText(ctx, "##rename_"..ptr, state.rename_track_buf, flags)
        if rnv ~= nil then state.rename_track_buf = rnv end
        if confirmed or (not reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsItemDeactivated(ctx)) then
          local new_name = state.rename_track_buf
          local role, role_idx = get_bus_role(t)

          reaper.Undo_BeginBlock()
          reaper.GetSetMediaTrackInfo_String(t, "P_NAME", new_name, true)

          if role == "mixbus" then
            local sum_idx = find_or_fallback(t, MIXBUS_SUM_GUID_KEY, state.summer_fx_name)
            if sum_idx >= 0 then
              reaper.TrackFX_SetNamedConfigParm(t, sum_idx, "renamed_name", new_name.."_HS Master")
            end
            local mol_idx = find_or_fallback(t, MIXBUS_MOL_GUID_KEY, state.molecule_fx_name)
            if mol_idx >= 0 then
              reaper.TrackFX_SetNamedConfigParm(t, mol_idx, "renamed_name", new_name.."_AM Master")
            end
            state.mixbus_name = new_name
            save_str("mixbus_name", new_name)
          elseif role == "group" then
            local mol_idx = find_or_fallback(t, GROUP_MOL_GUID_KEY, state.molecule_fx_name)
            if mol_idx >= 0 then
              reaper.TrackFX_SetNamedConfigParm(t, mol_idx, "renamed_name", new_name.."_AM Bus")
            end
            local sum_idx = find_or_fallback(t, GROUP_SUM_GUID_KEY, state.summer_fx_name)
            if sum_idx >= 0 then
              reaper.TrackFX_SetNamedConfigParm(t, sum_idx, "renamed_name", new_name.."_HS Bus")
            end
            state.groups[role_idx].name = new_name
            save_str("group_name_"..role_idx, new_name)
          else
            local ch_idx = find_or_fallback(t, CHANNEL_MOL_GUID_KEY, state.molecule_fx_name)
            if ch_idx >= 0 then
              reaper.TrackFX_SetNamedConfigParm(t, ch_idx, "renamed_name", new_name.."_AM Channel")
            end
          end

          reaper.Undo_EndBlock("SK DEC: Rename track", -1)
          set_status("Track renamed.")
          state.rename_track_ptr = nil
          state.rename_track_buf = ""
        end
        if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
          state.rename_track_ptr = nil
          state.rename_track_buf = ""
        end
      else
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),        0x00000000)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), 0x00000000)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),  0x00000000)
        if reaper.ImGui_Selectable(ctx, tname(t).."##namesel_"..ptr, false,
            reaper.ImGui_SelectableFlags_AllowDoubleClick()) then
          if reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
            state.rename_track_ptr   = t
            state.rename_track_buf   = tname(t)
            state.rename_just_opened = true
          end
        end
        reaper.ImGui_PopStyleColor(ctx, 3)
      end
    end
  end
  reaper.ImGui_EndChild(ctx)
  reaper.ImGui_EndChild(ctx)
end

-- ============================================================
--  RIGHT PANEL
-- ============================================================
local function draw_plugins_and_structure()
  sec_title("DocShadrach plugins")
  draw_fx_row("The Analog Molecule:", "molecule_fx_name", "test_molecule_msg")
  reaper.ImGui_Spacing(ctx)
  draw_fx_row("The Hot Summer:", "summer_fx_name", "test_summer_msg")
  reaper.ImGui_Spacing(ctx)
  section_divider()

  sec_title("Console structure")
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
  reaper.ImGui_Text(ctx, "Number of groups:")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SameLine(ctx, 160, 0)
  if btn("-##ng_minus", 26) then
    if state.num_groups > 1 then
      state.num_groups = state.num_groups - 1
      save_str("num_groups", tostring(state.num_groups))
      if state.target_group > state.num_groups then state.target_group = state.num_groups end
    end
  end
  reaper.ImGui_SameLine(ctx, 0, 6)
  reaper.ImGui_Text(ctx, tostring(state.num_groups))
  reaper.ImGui_SameLine(ctx, 0, 6)
  if btn("+##ng_plus", 26) then
    if state.num_groups < MAX_GROUPS_HARDCAP then
      state.num_groups = state.num_groups + 1
      save_str("num_groups", tostring(state.num_groups))
    end
  end
  reaper.ImGui_SameLine(ctx, 0, 10)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
  reaper.ImGui_Text(ctx, "(max "..MAX_GROUPS_HARDCAP..")")
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
  reaper.ImGui_Text(ctx, "Routing mode:")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SameLine(ctx, 160, 0)
  draw_mode_toggle()
end

local function reset_groups_and_mixbus()
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()

  for i = 1, MAX_GROUPS_HARDCAP do
    local new_name = "Group "..i
    local existing = resolve_group_track(i)
    if existing then
      reaper.GetSetMediaTrackInfo_String(existing, "P_NAME", new_name, true)
      reaper.SetMediaTrackInfo_Value(existing, "I_CUSTOMCOLOR", 0)
    end
    state.groups[i].name  = new_name
    state.groups[i].color = DEFAULT_GROUP_COLORS[i] or "888888"
    save_str("group_name_"..i, new_name)
    save_str("group_color_"..i, state.groups[i].color)
  end

  local new_mix_name = "Mix Bus"
  local existing_mix = resolve_mixbus_track()
  if existing_mix then
    reaper.GetSetMediaTrackInfo_String(existing_mix, "P_NAME", new_mix_name, true)
    reaper.SetMediaTrackInfo_Value(existing_mix, "I_CUSTOMCOLOR", 0)
  end
  state.mixbus_name  = new_mix_name
  state.mixbus_color = DEFAULT_TRACK_COLOR
  save_str("mixbus_name", new_mix_name)
  save_str("mixbus_color", state.mixbus_color)

  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK DEC: Reset group & Mix Bus names/colors", -1)
  reaper.PreventUIRefresh(-1)
  set_status("Group and Mix Bus names/colors reset to defaults.")
end

local function draw_groups_mixbus_panel()
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.white)
  reaper.ImGui_Text(ctx, "Groups & Mix Bus")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SameLine(ctx, 0, 10)
  if btn("Reset##reset_groups", 60) then
    reset_groups_and_mixbus()
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, "Reset group/Mix Bus names and colors to defaults")
  end
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)
  local groups_child_ok = reaper.ImGui_BeginChild(ctx, "groups_cfg", 0, 235, 0)
  if groups_child_ok then
    for i = 1, state.num_groups do
      local g = state.groups[i]
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
      reaper.ImGui_Text(ctx, "Group "..i..":")
      reaper.ImGui_PopStyleColor(ctx, 1)
      reaper.ImGui_SameLine(ctx, 90, 0)

      local nv, ch = text_input("group_name_"..i, g.name, 180)
      if ch then
        g.name = nv
        save_str("group_name_"..i, nv)
      end

      reaper.ImGui_SameLine(ctx, 0, 8)
      if color_swatch_button("group_"..i, g.color) then
        state.color_picker_target = { kind = "group", idx = i }
        state.want_open_color_popup = true
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Click to pick a color")
      end

      reaper.ImGui_SameLine(ctx, 0, 10)
      local grp_tr = resolve_group_track(i)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
      if not grp_tr then
        reaper.ImGui_Text(ctx, "(not created yet)")
      else
        local folder_count, send_count = count_group_sources(grp_tr)
        local total = folder_count + send_count
        if total == 0 then
          reaper.ImGui_Text(ctx, "no track assigned")
        else
          local parts = {}
          if folder_count > 0 then parts[#parts+1] = folder_count.." in folder" end
          if send_count > 0 then parts[#parts+1] = send_count.." via send" end
          reaper.ImGui_Text(ctx, total.." track(s) — "..table.concat(parts, ", "))
        end
      end
      reaper.ImGui_PopStyleColor(ctx, 1)
    end
  end
  reaper.ImGui_EndChild(ctx)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
  reaper.ImGui_Text(ctx, "Mix Bus:")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SameLine(ctx, 90, 0)
  local mnv, mch = text_input("mixbus_name", state.mixbus_name, 180)
  if mch then
    state.mixbus_name = mnv
    save_str("mixbus_name", mnv)
  end
  reaper.ImGui_SameLine(ctx, 0, 8)
  if color_swatch_button("mixbus", state.mixbus_color) then
    state.color_picker_target = { kind = "mixbus" }
    state.want_open_color_popup = true
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, "Click to pick a color")
  end

  reaper.ImGui_SameLine(ctx, 0, 10)
  local mixbus_tr = resolve_mixbus_track()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
  if not mixbus_tr then
    reaper.ImGui_Text(ctx, "(not created yet)")
  else
    local connected = reaper.GetTrackNumSends(mixbus_tr, -1)
    reaper.ImGui_Text(ctx, connected.." group(s) connected")
  end
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)
  if col_btn("Build Groups & Mix Bus##build_scratch", C.new_trk, C.new_trk_h, ACTION_BTN_W, ACTION_BTN_H) then
    do_build_scratch()
  end
end

local function draw_route_panel(checked)
  sec_title("Route selected tracks")

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
  reaper.ImGui_Text(ctx, "Target group:")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SameLine(ctx, 110, 0)
  for i = 1, state.num_groups do
    local active = state.target_group == i
    local r, g, b = hex_to_rgb01(state.groups[i].color)
    local border_col = (math.floor(r*255+0.5) << 24) | (math.floor(g*255+0.5) << 16) | (math.floor(b*255+0.5) << 8) | 0xFF
    if i > 1 then reaper.ImGui_SameLine(ctx, 0, 4) end
    if bordered_target_btn(tostring(i).."##target_"..i, border_col, active, 26, 26) then
      state.target_group = i
    end
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
  reaper.ImGui_Text(ctx, string.format("%d track(s) checked -> %s", #checked, state.groups[state.target_group].name))
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)
  local _, nv = reaper.ImGui_Checkbox(ctx, "Also insert & randomize Channel Molecule on selected tracks", state.also_channel_molecule)
  if nv ~= nil then state.also_channel_molecule = nv end

  reaper.ImGui_Spacing(ctx)
  if #checked > 0 then
    if col_btn("Route Checked Tracks##route_btn", C.new_trk, C.new_trk_h, ACTION_BTN_W, ACTION_BTN_H) then
      do_route(checked)
    end
  end
end

local function draw_popups()
  if reaper.ImGui_BeginPopupModal(ctx, "Notice##alert_popup", nil, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    reaper.ImGui_PushTextWrapPos(ctx, 420)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.white)
    reaper.ImGui_Text(ctx, state.alert_msg or "")
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_PopTextWrapPos(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    if btn("OK##alert_ok") then
      state.alert_msg = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end

  if reaper.ImGui_BeginPopupModal(ctx, "Confirm##confirm_popup", nil, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    reaper.ImGui_PushTextWrapPos(ctx, 420)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.white)
    reaper.ImGui_Text(ctx, state.confirm_msg or "")
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_PopTextWrapPos(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    if col_btn("Yes, complete it##confirm_yes", C.new_trk, C.new_trk_h, 160, 28) then
      local pending = state.pending
      state.pending = nil
      state.confirm_msg = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
      if pending then
        if pending.kind == "build_scratch" then apply_build_scratch()
        elseif pending.kind == "route" then apply_route(pending.checked, pending.gi) end
      end
    end
    reaper.ImGui_SameLine(ctx, 0, 8)
    if btn("Cancel##confirm_cancel") then
      state.pending = nil
      state.confirm_msg = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

local function draw_right(checked)
  local child_ok = reaper.ImGui_BeginChild(ctx, "right", 0, 0, 0)
  if not child_ok then reaper.ImGui_EndChild(ctx); return end

  draw_plugins_and_structure()
  section_divider()

  local _, twocol_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local twocol_ok = reaper.ImGui_BeginChild(ctx, "twocol", 0, twocol_h, 0)
  if twocol_ok then
    local left_w = 400
    local sep_w  = 16

    local left_ok = reaper.ImGui_BeginChild(ctx, "route_col", left_w, 0, 0)
    if left_ok then draw_route_panel(checked) end
    reaper.ImGui_EndChild(ctx)

    reaper.ImGui_SameLine(ctx, 0, 0)
    local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    reaper.ImGui_DrawList_AddLine(dl, sx + sep_w/2, sy, sx + sep_w/2, sy + twocol_h, C.border, 1.5)
    reaper.ImGui_Dummy(ctx, sep_w, twocol_h)
    reaper.ImGui_SameLine(ctx, 0, 0)

    local right_ok = reaper.ImGui_BeginChild(ctx, "groups_col", 500, 0, 0)
    if right_ok then draw_groups_mixbus_panel() end
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_EndChild(ctx)

  draw_popups()

  reaper.ImGui_EndChild(ctx)
end

-- ============================================================
--  MAIN WINDOW
-- ============================================================
local function loop()
  local all     = get_all_tracks()
  local checked = filter_out_bus_tracks(get_checked_tracks(all))

  local nc, nv = push_style()

  reaper.ImGui_SetNextWindowSize(ctx, WIN_W, WIN_H, reaper.ImGui_Cond_FirstUseEver())
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, 1140, 640, 9999, 9999)

  local vis, open = reaper.ImGui_Begin(ctx, SCRIPT_NAME, true, reaper.ImGui_WindowFlags_NoCollapse())

  if vis then
    reaper.ImGui_PushFont(ctx, font, 14)

    reaper.ImGui_PushFont(ctx, font_title, 20)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.title)
    reaper.ImGui_Text(ctx, SCRIPT_NAME)
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_PopFont(ctx)
    reaper.ImGui_Spacing(ctx)
    section_divider()

    local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    local status_h = 34
    local cols_ok = reaper.ImGui_BeginChild(ctx, "cols", 0, avail_h - status_h, 0)
    if cols_ok then
      draw_left(all)
      reaper.ImGui_SameLine(ctx, 0, 8)
      draw_right(checked)
    end
    reaper.ImGui_EndChild(ctx)

    if state.want_open_color_popup then
      reaper.ImGui_OpenPopup(ctx, "Pick Color##color_popup")
      state.want_open_color_popup = false
    end
    draw_color_picker_popup()

    if state.want_open_assign_popup then
      reaper.ImGui_OpenPopup(ctx, "Track Assignment##assign_popup")
      state.want_open_assign_popup = false
    end
    draw_assignment_popup()

    reaper.ImGui_Separator(ctx)
    local msg = reaper.time_precise() < state.status_timer and state.status_msg or "Ready."
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
    reaper.ImGui_Text(ctx, "  "..msg)
    reaper.ImGui_PopStyleColor(ctx, 1)

    reaper.ImGui_PopFont(ctx)
  end

  reaper.ImGui_End(ctx)
  pop_style(nc, nv)
  if open then reaper.defer(loop) end
end

-- ============================================================
--  STARTUP
-- ============================================================
for i = 0, reaper.CountTracks(0)-1 do
  reaper.SetTrackSelected(reaper.GetTrack(0, i), false)
end

reaper.defer(loop)
