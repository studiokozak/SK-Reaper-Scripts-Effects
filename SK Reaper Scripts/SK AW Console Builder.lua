-- =============================================================================
--  SK AW Console Builder
--  Studio Kozak — Stéphan JEDRASIAK
-- =============================================================================
--  Builds an Airwindows Console summing system around the selected tracks,
--  no manual routing needed:
--
--    1. A SUMMING track is created, with its own channel pair per selected
--       track (track 1 -> channels 1-2, track 2 -> channels 3-4, and so
--       on). Each selected track sends its signal to that pair.
--
--    2. A Console Channel instance is inserted on SUMMING for each
--       selected track, with its in/out pins mapped only to its own pair,
--       and renamed after the source track.
--
--    3. A Console Bus instance goes right after, still on SUMMING: its
--       input pins read from ALL pairs at once (the pin connector does
--       the summing), and its output pins overwrite pair 1 with the
--       final, already-summed mix.
--
--    4. A BUS track is created, with a single send from SUMMING's pair 1.
-- =============================================================================

local SCRIPT_NAME = "SK AW Console Builder"
local WIN_W, WIN_H = 870, 620
local COL_LEFT_W   = 240

-- ============================================================
--  IMGUI SETUP
-- ============================================================
local ctx  = reaper.ImGui_CreateContext(SCRIPT_NAME)
local font = reaper.ImGui_CreateFont("sans-serif", 14)
reaper.ImGui_Attach(ctx, font)
local font_title = reaper.ImGui_CreateFont("sans-serif", 20)
reaper.ImGui_Attach(ctx, font_title)

-- ============================================================
--  COLOR PALETTE
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
--  PERSISTENCE (ExtState) — remembers the plugin choices across
--  sessions, even after closing REAPER.
-- ============================================================
local EXT_SECTION = "SK_ConsoleBuilder"

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
--  STATE
-- ============================================================
local state = {
  status_msg       = "",
  status_timer     = 0,
  alert_msg        = nil,

  channel_fx_name  = load_str("channel_fx_name", ""),
  bus_fx_name      = load_str("bus_fx_name", ""),
  console_name     = "",
  bus_name         = "",

  test_channel_msg = nil,
  test_bus_msg     = nil,
}

-- ============================================================
--  TRACK HELPERS
-- ============================================================
local function tname(t)
  if not t or not reaper.ValidatePtr(t, "MediaTrack*") then return "?" end
  local _, n = reaper.GetTrackName(t) ; return n
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

-- Mirrors REAPER's native track selection — single source of truth, works both ways.
local function get_checked_tracks(all_tracks)
  local out = {}
  for _, t in ipairs(all_tracks) do
    if reaper.IsTrackSelected(t) then out[#out+1] = t end
  end
  return out
end

-- Channel pair (1-based) -> raw I_SRCCHAN / I_DSTCHAN value (0, 2, 4...).
local function enc_pair(pair_1based) return (pair_1based - 1) * 2 end

local function set_status(msg)
  state.status_msg   = msg
  state.status_timer = reaper.time_precise() + 4.0
end

-- ============================================================
--  RESOLVING A PLUGIN NAME
--  Temporarily loads the plugin on a hidden track to check the
--  name's valid, and grabs the exact name REAPER uses internally
--  (handy if you typed a shortened version).
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
  reaper.Undo_EndBlock("SK AWCB: test plugin", -1)
  reaper.PreventUIRefresh(-1)
  if resolved then return resolved, nil end
  return nil, "Plugin not found"
end

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

-- ============================================================
--  CONFIG (plugins + track names)
-- ============================================================
local function text_input(id, value, width)
  reaper.ImGui_SetNextItemWidth(ctx, width or 220)
  local changed, nv = reaper.ImGui_InputText(ctx, "##"..id, value)
  if changed then return nv, true end
  return value, false
end

local function draw_fx_row(label, key, msg_key)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
  reaper.ImGui_Text(ctx, label)
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SameLine(ctx, 140, 0)

  local nv, changed = text_input(key, state[key], 320)
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

local function draw_config()
  sec_title("Airwindows Console plugins")
  draw_fx_row("Console Channel:", "channel_fx_name", "test_channel_msg")
  reaper.ImGui_Spacing(ctx)
  draw_fx_row("Console Bus:",     "bus_fx_name",     "test_bus_msg")
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
  reaper.ImGui_TextWrapped(ctx,
    "Exact name as shown in the FX Browser.\n"..
    "Click Test to verify the name and lock it in its exact form.")
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)
  section_divider()

  sec_title("Track names")
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
  reaper.ImGui_Text(ctx, "SUMMING track:")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SameLine(ctx, 140, 0)
  local nv1, ch1 = text_input("console_name", state.console_name, 200)
  if ch1 then state.console_name = nv1 end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
  reaper.ImGui_Text(ctx, "BUS track:")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SameLine(ctx, 140, 0)
  local nv2, ch2 = text_input("bus_name", state.bus_name, 200)
  if ch2 then state.bus_name = nv2 end
end

-- ============================================================
--  EYE ICON — toggles the track's visibility in REAPER's TCP
-- ============================================================
local function draw_eye_btn(uid, visible)
  local bw, bh = 18, 18
  local clicked = reaper.ImGui_InvisibleButton(ctx, "##eye_"..uid, bw, bh)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMin(ctx)
  local x2, y2 = reaper.ImGui_GetItemRectMax(ctx)
  local cx, cy = (x1 + x2) * 0.5, (y1 + y2) * 0.5
  local dl  = reaper.ImGui_GetWindowDrawList(ctx)
  local col = hovered and C.white or (visible and C.text_dim or 0x666666FF)
  if visible then
    -- open eye: circle + pupil
    reaper.ImGui_DrawList_AddCircle(dl, cx, cy, 5, col, 0, 1.3)
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, 1.7, col)
  else
    -- closed eye: just a line
    reaper.ImGui_DrawList_AddLine(dl, cx-5, cy, cx+5, cy, col, 1.3)
  end
  return clicked, hovered
end

-- ============================================================
--  LEFT COLUMN: every track in the project, with a checkbox
-- ============================================================
local function draw_left(all_tracks)
  local child_ok = reaper.ImGui_BeginChild(ctx, "left", COL_LEFT_W, 0, 0)
  if not child_ok then
    reaper.ImGui_EndChild(ctx)
    return
  end

  sec_title(#all_tracks .. " track(s) in project")

  if btn("All##chk_all", 90) then
    for _, t in ipairs(all_tracks) do reaper.SetTrackSelected(t, true) end
  end
  reaper.ImGui_SameLine(ctx, 0, 4)
  if btn("None##chk_none", 90) then
    for _, t in ipairs(all_tracks) do reaper.SetTrackSelected(t, false) end
  end
  reaper.ImGui_Spacing(ctx)
  section_divider()

  local list_ok = reaper.ImGui_BeginChild(ctx, "track_checklist", 0, 0, 0)
  if list_ok then
    for _, t in ipairs(all_tracks) do
      local ptr     = tostring(t)
      local checked = reaper.IsTrackSelected(t)

      local dc = rcolor(t)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        dc)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), dc)
      reaper.ImGui_Button(ctx, "##tb_"..ptr, 6, 18)
      reaper.ImGui_PopStyleColor(ctx, 2)
      reaper.ImGui_SameLine(ctx, 0, 4)

      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),    0xBBBBBBFF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),   0x444444FF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(), 0xDDDDDDFF)
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1)
      local _, nv = reaper.ImGui_Checkbox(ctx, "##chk_"..ptr, checked)
      if nv ~= nil then
        reaper.SetTrackSelected(t, nv)
      end
      reaper.ImGui_PopStyleVar(ctx, 1)
      reaper.ImGui_PopStyleColor(ctx, 3)

      reaper.ImGui_SameLine(ctx, 0, 4)
      local vis_now = reaper.GetMediaTrackInfo_Value(t, "B_SHOWINTCP") > 0.5
      local eye_clicked, eye_hovered = draw_eye_btn(ptr, vis_now)
      if eye_clicked then
        local nv2 = vis_now and 0 or 1
        reaper.SetMediaTrackInfo_Value(t, "B_SHOWINTCP", nv2)
        reaper.SetMediaTrackInfo_Value(t, "B_SHOWINMIXER", nv2)
        reaper.TrackList_AdjustWindows(false)
      end
      if eye_hovered then
        reaper.ImGui_SetTooltip(ctx, vis_now and "Hide track in REAPER" or "Show track in REAPER")
      end

      reaper.ImGui_SameLine(ctx, 0, 4)
      reaper.ImGui_Text(ctx, tname(t))
    end
  end
  reaper.ImGui_EndChild(ctx)

  reaper.ImGui_EndChild(ctx)
end

-- ============================================================
--  SUMMARY (right column) — no need to re-list the tracks, they're
--  already visible via the checked boxes on the left.
-- ============================================================
local function draw_preview(checked)
  section_divider()
  if #checked == 0 then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
    reaper.ImGui_Text(ctx, "<- Check tracks in the list on the left.")
    reaper.ImGui_PopStyleColor(ctx, 1)
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
    reaper.ImGui_Text(ctx, string.format("%d track(s) checked", #checked))
    reaper.ImGui_PopStyleColor(ctx, 1)

    for i, t in ipairs(checked) do
      reaper.ImGui_SameLine(ctx, 0, i == 1 and 8 or 3)
      local fc = rcolor(t)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        fc)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), fc)
      reaper.ImGui_Button(ctx, "##pcol"..i, 6, 14)
      reaper.ImGui_PopStyleColor(ctx, 2)
    end
  end
  reaper.ImGui_Spacing(ctx)
end

-- ============================================================
--  BUILDING THE CONSOLE SYSTEM
-- ============================================================
local function alert(msg)
  state.alert_msg = msg
  reaper.ImGui_OpenPopup(ctx, "Notice##alert_popup")
end

local function track_name_exists(name)
  for _, t in ipairs(get_all_tracks()) do
    if tname(t) == name then return true end
  end
  return false
end

local function chan_bits(chan0)
  if chan0 < 32 then return (1 << chan0), 0
  else return 0, (1 << (chan0 - 32)) end
end

-- Combines the bitmasks of several channels (0-based) into one pin:
-- REAPER automatically sums every channel mapped to the same pin.
local function combine_bits(channels)
  local lo, hi = 0, 0
  for _, c in ipairs(channels) do
    local l, h = chan_bits(c)
    lo = lo | l
    hi = hi | h
  end
  return lo, hi
end

local function build_console(checked)
  if #checked == 0 then return end

  if state.channel_fx_name == "" or state.bus_fx_name == "" then
    alert("Configure and test both plugins (Console Channel and Console Bus) before building.")
    return
  end
  if state.console_name == "" or state.bus_name == "" then
    alert("Enter a name for the SUMMING track and for the BUS track.")
    return
  end
  if track_name_exists(state.console_name) then
    alert("A track named \""..state.console_name.."\" already exists in the project. Rename it or choose another name before building.")
    return
  end
  if track_name_exists(state.bus_name) then
    alert("A track named \""..state.bus_name.."\" already exists in the project. Rename it or choose another name before building.")
    return
  end

  -- `checked` is already in project order (built by looping over get_all_tracks()).
  local n = #checked
  local last_idx = math.floor(reaper.GetMediaTrackInfo_Value(checked[n], "IP_TRACKNUMBER")) -- 1-based

  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()

  -- SUMMING track, right after the last selected track.
  reaper.InsertTrackAtIndex(last_idx, true)
  local console_tr = reaper.GetTrack(0, last_idx)
  reaper.GetSetMediaTrackInfo_String(console_tr, "P_NAME", state.console_name, true)
  reaper.SetMediaTrackInfo_Value(console_tr, "I_NCHAN", n * 2)

  -- Sends from the checked tracks to SUMMING, one channel pair per track.
  for i, src in ipairs(checked) do
    local si = reaper.CreateTrackSend(src, console_tr)
    reaper.SetTrackSendInfo_Value(src, 0, si, "I_SENDMODE", 0) -- post-fader / post-FX
    reaper.SetTrackSendInfo_Value(src, 0, si, "D_VOL",      1.0)
    reaper.SetTrackSendInfo_Value(src, 0, si, "D_PAN",      0.0)
    reaper.SetTrackSendInfo_Value(src, 0, si, "I_SRCCHAN",  0)   -- source track's normal output
    reaper.SetTrackSendInfo_Value(src, 0, si, "I_DSTCHAN",  enc_pair(i))
    reaper.SetTrackSendInfo_Value(src, 0, si, "B_MONO",     0)
    reaper.SetTrackSendInfo_Value(src, 0, si, "B_PHASE",    0)
    reaper.SetTrackSendInfo_Value(src, 0, si, "B_MUTE",     0)
    reaper.SetMediaTrackInfo_Value(src, "B_MAINSEND", 0) -- cuts the source track's send to master
  end

  -- Console Channel instances on SUMMING: one per source track, in/out
  -- pins mapped to its own channel pair, renamed after the source.
  for i, src in ipairs(checked) do
    local fx_idx = reaper.TrackFX_AddByName(console_tr, state.channel_fx_name, false, 1)
    if fx_idx >= 0 then
      reaper.TrackFX_SetOpen(console_tr, fx_idx, false)
      local _, num_in, num_out = reaper.TrackFX_GetIOSize(console_tr, fx_idx)
      local ch_l = enc_pair(i) -- 0-based
      local ch_r = ch_l + 1
      local lo_l, hi_l = chan_bits(ch_l)
      local lo_r, hi_r = chan_bits(ch_r)
      if num_in  and num_in  >= 1 then reaper.TrackFX_SetPinMappings(console_tr, fx_idx, 0, 0, lo_l, hi_l) end
      if num_in  and num_in  >= 2 then reaper.TrackFX_SetPinMappings(console_tr, fx_idx, 0, 1, lo_r, hi_r) end
      if num_out and num_out >= 1 then reaper.TrackFX_SetPinMappings(console_tr, fx_idx, 1, 0, lo_l, hi_l) end
      if num_out and num_out >= 2 then reaper.TrackFX_SetPinMappings(console_tr, fx_idx, 1, 1, lo_r, hi_r) end
      reaper.TrackFX_SetNamedConfigParm(console_tr, fx_idx, "renamed_name", tname(src))
    end
  end

  -- Console Bus instance, right after the Channel instances, on the
  -- SUMMING track itself: its input pins are mapped to ALL pairs at
  -- once (the pin connector does the summing), and its output pins
  -- overwrite pair 1 (channels 1-2), which then carries the final,
  -- already-summed mix.
  local left_chans, right_chans = {}, {}
  for i = 1, n do
    left_chans[#left_chans+1]  = enc_pair(i)
    right_chans[#right_chans+1] = enc_pair(i) + 1
  end
  local lo_l, hi_l = combine_bits(left_chans)
  local lo_r, hi_r = combine_bits(right_chans)

  local bus_fx_idx = reaper.TrackFX_AddByName(console_tr, state.bus_fx_name, false, 1)
  if bus_fx_idx >= 0 then
    reaper.TrackFX_SetOpen(console_tr, bus_fx_idx, false)
    local _, bnum_in, bnum_out = reaper.TrackFX_GetIOSize(console_tr, bus_fx_idx)
    if bnum_in  and bnum_in  >= 1 then reaper.TrackFX_SetPinMappings(console_tr, bus_fx_idx, 0, 0, lo_l, hi_l) end
    if bnum_in  and bnum_in  >= 2 then reaper.TrackFX_SetPinMappings(console_tr, bus_fx_idx, 0, 1, lo_r, hi_r) end
    if bnum_out and bnum_out >= 1 then
      local lo0, hi0 = chan_bits(0)
      reaper.TrackFX_SetPinMappings(console_tr, bus_fx_idx, 1, 0, lo0, hi0)
    end
    if bnum_out and bnum_out >= 2 then
      local lo1, hi1 = chan_bits(1)
      reaper.TrackFX_SetPinMappings(console_tr, bus_fx_idx, 1, 1, lo1, hi1)
    end
    reaper.TrackFX_SetNamedConfigParm(console_tr, bus_fx_idx, "renamed_name", state.bus_name)
  end

  -- BUS track, right after SUMMING.
  local bus_idx = last_idx + 1
  reaper.InsertTrackAtIndex(bus_idx, true)
  local bus_tr = reaper.GetTrack(0, bus_idx)
  reaper.GetSetMediaTrackInfo_String(bus_tr, "P_NAME", state.bus_name, true)

  -- Just one send from SUMMING to BUS: pair 1 already carries the mix
  -- summed by Console Bus.
  local si = reaper.CreateTrackSend(console_tr, bus_tr)
  reaper.SetTrackSendInfo_Value(console_tr, 0, si, "I_SENDMODE", 0)
  reaper.SetTrackSendInfo_Value(console_tr, 0, si, "D_VOL",      1.0)
  reaper.SetTrackSendInfo_Value(console_tr, 0, si, "D_PAN",      0.0)
  reaper.SetTrackSendInfo_Value(console_tr, 0, si, "I_SRCCHAN",  0)
  reaper.SetTrackSendInfo_Value(console_tr, 0, si, "I_DSTCHAN",  0)
  reaper.SetTrackSendInfo_Value(console_tr, 0, si, "B_MONO",     0)
  reaper.SetTrackSendInfo_Value(console_tr, 0, si, "B_PHASE",    0)
  reaper.SetTrackSendInfo_Value(console_tr, 0, si, "B_MUTE",     0)
  reaper.SetMediaTrackInfo_Value(console_tr, "B_MAINSEND", 0) -- cuts SUMMING's send to master

  reaper.TrackFX_Show(console_tr, 0, 0) -- closes the FX chain window in case REAPER popped it open
  reaper.TrackFX_Show(bus_tr, 0, 0)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK AWCB: Build console ("..n.." tracks)", -1)
  reaper.PreventUIRefresh(-1)

  set_status(string.format("Console built: %d track(s) -> %s -> %s", n, state.console_name, state.bus_name))
  state.console_name = ""
  state.bus_name      = ""
end

-- ============================================================
--  BUILD BUTTON + ALERT POPUP
-- ============================================================
local function draw_build(checked)
  reaper.ImGui_Spacing(ctx)
  if #checked > 0 then
    if col_btn("Build Console##build", C.new_trk, C.new_trk_h, 200, 34) then
      build_console(checked)
    end
  end

  if reaper.ImGui_BeginPopupModal(ctx, "Notice##alert_popup", nil, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    reaper.ImGui_PushTextWrapPos(ctx, 380)
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
end

-- ============================================================
--  RIGHT COLUMN: config + summary + build button
-- ============================================================
local function draw_right(checked)
  local child_ok = reaper.ImGui_BeginChild(ctx, "right", 0, 0, 0)
  if not child_ok then
    reaper.ImGui_EndChild(ctx)
    return
  end

  draw_config()
  draw_preview(checked)
  draw_build(checked)

  reaper.ImGui_EndChild(ctx)
end

-- ============================================================
--  MAIN LOOP
-- ============================================================
local function loop()
  local all     = get_all_tracks()
  local checked = get_checked_tracks(all)

  local nc, nv = push_style()

  reaper.ImGui_SetNextWindowSize(ctx, WIN_W, WIN_H, reaper.ImGui_Cond_FirstUseEver())
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, 870, 460, 9999, 9999)

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

    -- Two-column area, sits above the status bar.
    local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    local status_h = 34
    local cols_ok = reaper.ImGui_BeginChild(ctx, "cols", 0, avail_h - status_h, 0)
    if cols_ok then
      draw_left(all)
      reaper.ImGui_SameLine(ctx, 0, 8)
      draw_right(checked)
    end
    reaper.ImGui_EndChild(ctx)

    reaper.ImGui_Separator(ctx)
    local msg = reaper.time_precise() < state.status_timer
      and state.status_msg
      or  "Ready."
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
--  START
-- ============================================================
reaper.defer(loop)
