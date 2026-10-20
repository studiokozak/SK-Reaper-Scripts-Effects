-- @description SK SP Chopper
-- @author Studio Kozak
-- @version 1.0
-- @provides [main] .
-- @about
--   Chops one audio item into up to sixteen slices, one per pad of a
--   Roland SP-404MKII bank.
--
--   Slices can follow the transients, the project grid or simply be equal.
--   The markers can then be moved by hand on the waveform, added or removed,
--   and every slice can be auditioned from a 4x4 pad grid before anything is
--   cut. Slices under 100 ms are flagged, as the SP may refuse them.
--
--   SEND TO KIT and ALL TO KIT put chops in SK SP Kit Builder without cutting
--   the item. SAVE AS WAV writes one chop to a folder of your choice. CHOP
--   splits the item in REAPER, names the slices 01 to 16 and leaves them
--   selected.
--
--   Requirements (all installable with ReaPack):
--     - ReaImGui: required, draws the window.
--     - SWS extension: optional. Plays a chop on its own through the item's
--       track. Without it, chops are played through REAPER's transport.
--     - js_ReaScriptAPI: optional. Opens the standard Save window for
--       SAVE AS WAV. Without it, a small window asks for the folder and name.
--   Processing settings for SAVE AS WAV come from SK SP Kit Builder.

local reaper = reaper

if not reaper.ImGui_CreateContext then
  reaper.MB("ReaImGui is required. Please install it via ReaPack.", "Missing dependency", 0)
  return
end

-------------------------------------------------------------------------------
-- Fixed values
-------------------------------------------------------------------------------

local PADS      = 16        -- pads in one bank of the SP
local MIN_LEN   = 0.100     -- seconds: the SP may refuse anything shorter
local MIN_SLICE = 0.005     -- seconds: two markers are never closer than this

local HOP_SEC   = 0.0058    -- the item is measured in steps of about 6 ms
local BUDGET    = 0.012     -- seconds spent reading the item at each refresh
                            -- of the window, so that it stays responsive

local WAVE_W, WAVE_H = 640, 120   -- size of the waveform, in pixels
local OVER_H    = 22        -- height of the whole-item strip below it
local MIN_VIEW  = 0.02      -- seconds: strongest zoom
local ZOOM_STEP = 1.5       -- zoom factor of the - and + buttons

-- Layout: four equal columns across the width of the waveform. Every
-- control lines up with them, so edges match from top to bottom.
local GAP    = 8
local COL_W  = (WAVE_W - 3 * GAP) / 4              -- 154 pixels
local HALF_W = COL_W * 2 + GAP                     -- 316 pixels
local PAD_W,  PAD_H  = (HALF_W - 3 * GAP) / 4, 44  -- 4 pads span two columns
local BTN_H  = 34
local ACT_H  = 40

local EXT_SECTION = "Studio Kozak SP Chopper"      -- name the settings are saved under

-------------------------------------------------------------------------------
-- Settings, remembered between sessions
-------------------------------------------------------------------------------

local cfg = {
  mode      = 1,     -- 1 transients, 2 grid, 3 equal
  sens      = 60,    -- sensitivity, 0 to 100
  floor_db  = -45,   -- sounds quieter than this are not hits
  min_gap   = 80,    -- ms between two hits, at least
  max_chops = 16,
  div       = 3,     -- grid division, from the list below
  slices    = 8,     -- number of equal slices
  fade_ms   = 2.0,   -- short fades against clicks
}

local function load_cfg()
  for k, v in pairs(cfg) do
    local raw = tonumber(reaper.GetExtState(EXT_SECTION, k))
    if raw then cfg[k] = raw end
  end
end

local function save_cfg()
  for k, v in pairs(cfg) do
    reaper.SetExtState(EXT_SECTION, k, tostring(v), true)
  end
end

load_cfg()

-- Grid divisions, in beats. 0 means one bar, whatever the time signature.
local DIVS = {
  { "1 bar", 0 }, { "1/2", 2 }, { "1/4", 1 }, { "1/8", 0.5 }, { "1/16", 0.25 },
}

-------------------------------------------------------------------------------
-- Small tools
-------------------------------------------------------------------------------

-- A length as "250 ms" or "1.25 s".
local function fmt_len(sec)
  if sec < 1 then return string.format("%d ms", math.floor(sec * 1000 + 0.5)) end
  return string.format("%.2f s", sec)
end

-- Keeps a value between a minimum and a maximum.
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- Name of the take, without its file extension.
local function default_name(take)
  local _, nm = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  nm = nm:gsub("%.%a%a%a%a?$", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if nm == "" then nm = "Chop" end
  return nm
end

-------------------------------------------------------------------------------
-- The item being chopped
-------------------------------------------------------------------------------

local cur      = nil     -- the selected item
local cur_msg  = ""      -- why there is no item to chop
local ana      = nil     -- what was measured on the item
local points   = { 0 }   -- markers: where each chop starts, in seconds
local pts_sig  = nil     -- settings the markers were last placed with
local truncated = false  -- more hits found than pads allowed
local edited    = false  -- markers moved by hand
local sel_pad  = 1       -- selected chop
local ui_name  = ""      -- name given to the chops
local view     = { start = 0, len = 1 }   -- part of the item shown, in seconds
local status, status_col, status_time = "", nil, 0   -- message at the bottom

local COL_OK   = 0x88FF88FF
local COL_WARN = 0xE6B75AFF
local COL_ERR  = 0xE05A4AFF

local function set_status(msg, col)
  status, status_col, status_time = msg, col, reaper.time_precise()
end

-- Stops reading the item.
local function cancel_analysis()
  if ana and ana.acc then
    reaper.DestroyAudioAccessor(ana.acc)
    ana.acc = nil
  end
  ana = nil
end

-- Backup way of reading the item: the overview files REAPER keeps to draw
-- its own waveforms. Only used if the normal reading returns silence.
local function read_peaks(a, take, len)
  local src  = reaper.GetMediaItemTake_Source(take)
  local nch  = math.max(1, math.min(2, reaper.GetMediaSourceNumChannels(src)))
  local offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if rate <= 0 then rate = 1 end

  local pr    = 1 / HOP_SEC                     -- measurements per second
  local total = math.max(1, math.ceil(len * pr))
  local CH    = 2048
  local buf   = reaper.new_array(CH * nch * 2)
  local db, peak = {}, {}
  a.db, a.peak, a.nh_total, a.hop_sec = db, peak, total, HOP_SEC

  local pos = 0
  while pos < total do
    local n = math.min(CH, total - pos)
    buf.clear()
    reaper.PCM_Source_GetPeaks(src, pr / rate, offs + (pos / pr) * rate, nch, n, 0, buf)
    local t = buf.table(1, n * nch * 2)
    local mins = n * nch                        -- highest values first, then lowest
    for i = 0, n - 1 do
      local m = 0
      for c = 1, nch do
        local hi = t[i * nch + c] or 0
        local lo = t[mins + i * nch + c] or 0
        if hi < 0 then hi = -hi end
        if lo < 0 then lo = -lo end
        if hi > m then m = hi end
        if lo > m then m = lo end
      end
      peak[#peak + 1] = m
      db[#db + 1]     = 20 * math.log(m + 1e-9, 10)
    end
    pos = pos + n
  end
end

-- True if anything louder than silence was found.
local function has_signal(peak)
  for i = 1, #peak do if peak[i] > 0 then return true end end
  return false
end

-- Prepares the reading of the item. Its loudness, measured step by step,
-- is used to find the hits; its peaks are used to draw the waveform.
local function start_analysis(take, len, key)
  cancel_analysis()
  local src = reaper.GetMediaItemTake_Source(take)
  local nch = math.max(1, math.min(2, reaper.GetMediaSourceNumChannels(src)))
  local sr  = reaper.GetMediaSourceSampleRate(src)
  if not sr or sr <= 0 then sr = 44100 end      -- read at the file's own sample rate
  local hop   = math.max(16, math.floor(sr * HOP_SEC + 0.5))
  local total = math.max(0, math.floor(len * sr))

  ana = {
    key = key, db = {}, peak = {}, done = false, progress = 0,
    hop_sec  = hop / sr,
    nh_total = math.max(1, math.ceil(total / hop)),
    acc = reaper.CreateTakeAudioAccessor(take),
    take = take, len = len,
    sr = sr, nch = nch, hop = hop, total = total, block = hop * 64,
    pos = 0, sum = 0, mx = 0, cnt = 0,
  }
  ana.buf = reaper.new_array(ana.block * 2)
end

-- Reads the next part of the item for a short moment, then hands back to
-- the window. Answers true once the whole item is read.
local function read_next_part(a)
  local t_end = reaper.time_precise() + BUDGET
  local buf, sr, nch, hop = a.buf, a.sr, a.nch, a.hop
  local db, peak = a.db, a.peak
  local sum, mx, cnt = a.sum, a.mx, a.cnt

  while a.pos < a.total do
    local n = math.min(a.block, a.total - a.pos)
    buf.clear()
    reaper.GetAudioAccessorSamples(a.acc, sr, nch, a.pos / sr, n, buf)
    local t = buf.table(1, n * nch)
    for f = 0, n - 1 do
      local s = t[f * nch + 1] or 0
      if nch == 2 then s = (s + (t[f * nch + 2] or 0)) * 0.5 end
      sum = sum + s * s
      local v = (s < 0) and -s or s
      if v > mx then mx = v end
      cnt = cnt + 1
      if cnt == hop then
        db[#db + 1]     = 20 * math.log(math.sqrt(sum / cnt) + 1e-9, 10)
        peak[#peak + 1] = mx
        sum, mx, cnt = 0, 0, 0
      end
    end
    a.pos = a.pos + n
    a.progress = a.pos / math.max(1, a.total)
    if reaper.time_precise() >= t_end then
      a.sum, a.mx, a.cnt = sum, mx, cnt
      return false
    end
  end

  if cnt > 0 then
    db[#db + 1]     = 20 * math.log(math.sqrt(sum / cnt) + 1e-9, 10)
    peak[#peak + 1] = mx
  end
  reaper.DestroyAudioAccessor(a.acc)
  a.acc = nil
  return true
end

-- Called at each refresh of the window until the item is fully read.
local function run_analysis()
  if not ana or ana.done then return end
  if not (cur and reaper.ValidatePtr2(0, cur.take, "MediaItem_Take*")) then
    cancel_analysis()
    return
  end
  if read_next_part(ana) then
    if not has_signal(ana.peak) then
      read_peaks(ana, ana.take, ana.len)
      if not has_signal(ana.peak) then ana.empty = true end
    end
    ana.buf  = nil
    ana.done = true
  end
end

-- Follows the selection in REAPER. A new item, or a change to the item,
-- starts a new reading.
local function update_current()
  local n = reaper.CountSelectedMediaItems(0)
  if n ~= 1 then
    cur, cur_msg = nil, (n == 0) and "Select one audio item in REAPER."
                                  or "Select a single item: the chopper works on one at a time."
    return
  end
  local item = reaper.GetSelectedMediaItem(0, 0)
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    cur, cur_msg = nil, "The selected item has no audio take."
    return
  end

  local _, guid = reaper.GetSetMediaItemTakeInfo_String(take, "GUID", "", false)
  local pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  local key  = table.concat({ guid, len, offs, rate }, "|")

  if not cur or cur.key ~= key then
    cur = { item = item, take = take, pos = pos, len = len, key = key }
    ui_name, sel_pad, pts_sig = default_name(take), 1, nil
    view.start, view.len = 0, len
    start_analysis(take, len, key)
  else
    cur.item, cur.take, cur.pos = item, take, pos
  end
end

-------------------------------------------------------------------------------
-- Slice points
-------------------------------------------------------------------------------

-- Markers on the hits. A hit is a moment louder than the floor that rises
-- quickly compared with the moments just before it. The higher the
-- sensitivity, the smaller the rise needed: 18 dB at 0, 3 dB at 100.
local function transient_points(len)
  local db = ana.db
  local rise = 18 - (cfg.sens / 100) * 15
  local hs   = ana.hop_sec
  local gap  = math.max(1, math.floor(cfg.min_gap / 1000 / hs + 0.5))
  local cands, last = {}, -math.huge

  -- A silent head is left out: chop 01 starts at the first sound.
  local head = 0
  for i = 1, #db do
    if db[i] >= cfg.floor_db then
      head = math.max(0, (i - 2) * hs)
      break
    end
  end
  if head < 0.01 then head = 0 end

  for i = 4, #db do
    local d = db[i]
    if d >= cfg.floor_db and i - last >= gap then
      local m = math.min(db[i - 1], db[i - 2], db[i - 3])
      if d - m >= rise then
        -- The hit begins a little earlier: cut just before it.
        local t = math.max(0, (i - 2) * hs)
        if t > head + cfg.min_gap / 1000 and t < len - MIN_SLICE then
          cands[#cands + 1] = { t = t, s = d - m }
        end
        last = i
      end
    end
  end

  -- More hits than allowed: keep the strongest.
  local room = cfg.max_chops - 1
  truncated = (#cands > room)
  if truncated then
    table.sort(cands, function(a, b) return a.s > b.s end)
    for k = #cands, room + 1, -1 do cands[k] = nil end
  end
  table.sort(cands, function(a, b) return a.t < b.t end)

  local pts = { head }
  for _, c in ipairs(cands) do pts[#pts + 1] = c.t end
  return pts
end

-- Markers on the project grid, counted from the start of the item.
local function grid_points(pos, len)
  local div = DIVS[cfg.div] and DIVS[cfg.div][2] or 1
  if div == 0 then
    local num, den = reaper.TimeMap_GetTimeSigAtTime(0, pos)
    div = num * 4 / den
  end
  local qn0 = reaper.TimeMap2_timeToQN(0, pos)
  local pts, k = { 0 }, 1
  truncated = false
  while true do
    local t = reaper.TimeMap2_QNToTime(0, qn0 + k * div) - pos
    if t >= len - MIN_SLICE then break end
    if #pts >= cfg.max_chops then truncated = true break end
    pts[#pts + 1] = t
    k = k + 1
  end
  return pts
end

-- Markers at equal distances.
local function equal_points(len)
  truncated = false
  local pts = {}
  for k = 0, cfg.slices - 1 do pts[#pts + 1] = len * k / cfg.slices end
  return pts
end

-- Everything the markers depend on. When any of it changes, the markers
-- are placed again.
local function points_signature()
  return table.concat({
    cur.key, cur.pos, cfg.mode, cfg.sens, cfg.floor_db, cfg.min_gap,
    cfg.max_chops, cfg.div, cfg.slices,
    (ana and ana.done) and "done" or "pending",
    (cfg.mode == 2) and reaper.Master_GetTempo() or 0,
  }, "|")
end

-- A change of settings places the markers again, replacing any moved by hand.
local function update_points()
  local sig = points_signature()
  if sig == pts_sig then return end
  pts_sig = sig
  if cfg.mode == 1 then
    points = (ana and ana.done) and transient_points(cur.len) or { 0 }
  elseif cfg.mode == 2 then
    points = grid_points(cur.pos, cur.len)
  else
    points = equal_points(cur.len)
  end
  edited = false
  if sel_pad > #points then sel_pad = 1 end
end

-- Start and end of every chop.
local function slices()
  local s = {}
  for k, t in ipairs(points) do
    s[k] = { start = t, stop = points[k + 1] or cur.len }
  end
  return s
end

-- The chop playing at a given time (none before marker 1).
local function slice_at(t)
  if t < points[1] then return nil end
  local k = 1
  for i, p in ipairs(points) do if p <= t then k = i end end
  return k
end

-- Adds a marker by hand, sixteen at most.
local function add_point(t)
  if #points >= PADS then
    set_status("Sixteen slices already: one bank is full.", COL_WARN)
    return
  end
  for _, p in ipairs(points) do
    if math.abs(p - t) < MIN_SLICE then return end
  end
  if t >= cur.len - MIN_SLICE then return end
  points[#points + 1] = t
  table.sort(points)
  edited = true
end

-------------------------------------------------------------------------------
-- Audition
-------------------------------------------------------------------------------

local pv = { handle = nil, stop_at = nil, transport = false, cursor = nil }   -- what is being heard

-- Stops the chop being heard.
local function preview_stop()
  if pv.handle then
    reaper.CF_Preview_Stop(pv.handle)
    pv.handle = nil
  end
  if pv.transport then
    reaper.OnStopButton()
    if pv.cursor then reaper.SetEditCurPos(pv.cursor, false, false) end
    pv.transport, pv.cursor = false, nil
  end
  pv.stop_at, pv.pad, pv.t0, pv.start = nil, nil, nil, nil
end

-- Plays one chop. With SWS it plays on its own through the item's track,
-- otherwise through REAPER's transport.
local function preview_slice(k)
  preview_stop()
  local s = slices()[k]
  if not s or not cur then return end
  local dur = s.stop - s.start

  if reaper.CF_CreatePreview then
    local take = cur.take
    local src  = reaper.GetMediaItemTake_Source(take)
    local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    local offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local vol  = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")
               * reaper.GetMediaItemInfo_Value(cur.item, "D_VOL")
    local h = reaper.CF_CreatePreview(src)
    reaper.CF_Preview_SetValue(h, "D_PLAYRATE", rate)
    reaper.CF_Preview_SetValue(h, "D_POSITION", offs + s.start * rate)
    reaper.CF_Preview_SetValue(h, "D_VOLUME",   vol)
    if reaper.CF_Preview_SetOutputTrack then
      reaper.CF_Preview_SetOutputTrack(h, 0, reaper.GetMediaItem_Track(cur.item))
    end
    reaper.CF_Preview_Play(h)
    pv.handle = h
  else
    pv.cursor = reaper.GetCursorPosition()
    reaper.SetEditCurPos(cur.pos + s.start, false, false)
    reaper.OnPlayButton()
    pv.transport = true
  end
  pv.t0, pv.pad, pv.start = reaper.time_precise(), k, s.start
  pv.stop_at = pv.t0 + dur
end

-- Clicking the chop that is playing stops it; any other one plays.
local function toggle_slice(k)
  if pv.pad == k and pv.stop_at then preview_stop() else preview_slice(k) end
end

-- Stops the chop when its end is reached.
local function preview_watch()
  if pv.stop_at and reaper.time_precise() >= pv.stop_at then preview_stop() end
end

-------------------------------------------------------------------------------
-- Chop
-------------------------------------------------------------------------------

-- Cuts the item at every marker, names the parts 01, 02... and selects them.
local function do_chop()
  if not cur or #points < 2 then return end
  if not reaper.ValidatePtr2(0, cur.item, "MediaItem*") then return end
  preview_stop()
  cancel_analysis()

  local item = cur.item
  local pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local base = ui_name:gsub("^%s+", ""):gsub("%s+$", "")
  if base == "" then base = "Chop" end
  local fade = cfg.fade_ms / 1000

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Cuts are made from the end. If marker 1 was moved in, the part before
  -- it is not a chop: it stays where it is, unnamed and unselected.
  local has_head = points[1] > MIN_SLICE
  local rights = {}
  for k = #points, has_head and 1 or 2, -1 do
    local r = reaper.SplitMediaItem(item, pos + points[k])
    if r then table.insert(rights, 1, r) end
  end
  local parts = has_head and {} or { item }
  for _, r in ipairs(rights) do parts[#parts + 1] = r end

  reaper.SelectAllMediaItems(0, false)
  for k, it in ipairs(parts) do
    local tk = reaper.GetActiveTake(it)
    if tk then
      reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME",
        string.format("%02d %s", k, base), true)
    end
    if fade > 0 then
      reaper.SetMediaItemInfo_Value(it, "D_FADEINLEN",       fade)
      reaper.SetMediaItemInfo_Value(it, "D_FADEOUTLEN",      fade)
      reaper.SetMediaItemInfo_Value(it, "D_FADEINLEN_AUTO",  -1)
      reaper.SetMediaItemInfo_Value(it, "D_FADEOUTLEN_AUTO", -1)
    end
    reaper.SetMediaItemSelected(it, true)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(("SK SP Chopper: chop into %d slices"):format(#parts), -1)

  cur = nil
  set_status(("%d slices created and selected. SK SP Kit Builder can take them in.")
    :format(#parts), COL_OK)
end

-------------------------------------------------------------------------------
-- WAV files
--
--  SAVE AS WAV writes one chop without cutting the item. It uses the
--  processing settings of SK SP Kit Builder, so both scripts write the same
--  kind of file: 48 kHz, 16-bit, as the SP stores its samples.
-------------------------------------------------------------------------------

local KB_SECTION  = "Studio Kozak SP Kit Builder"   -- where SK SP Kit Builder saves its settings
local KIT_SECTION = "SK_SP_KitBuilder"              -- the kit, saved in the project
local SR_OUT      = 48000                           -- sample rate of the files written
local NAME_MAX    = 24                              -- longest name kept
local SEP         = package.config:sub(1, 1)        -- folder separator of the system

-- Processing settings chosen in SK SP Kit Builder, or their defaults.
local function kit_builder_settings()
  local function get(k, d)
    local v = reaper.GetExtState(KB_SECTION, k)
    if v == "" then return d end
    return v
  end
  return {
    channels    = tonumber(get("channels", "1")) or 1,       -- 1 keep, 2 mono, 3 stereo
    norm_mode   = tonumber(get("norm_mode", "1")) or 1,      -- 1 off, otherwise on
    norm_target = tonumber(get("norm_target", "-0.3")) or -0.3,
    trim        = get("trim", "1") == "1",
    trim_db     = tonumber(get("trim_db", "-60")) or -60,
    fade_ms     = tonumber(get("fade_ms", "2")) or 2,
    dither      = get("dither", "0") == "1",
  }
end

-- File names: the SP displays accented letters badly, so they are replaced
-- (é becomes e) and anything other than letters, digits and _ is removed.
local TRANSLIT = {}
local function translit(chars, to)
  for c in chars:gmatch("[\xC0-\xF4][\x80-\xBF]*") do TRANSLIT[c] = to end
end
translit("àáâäãå", "a") translit("ÀÁÂÄÃÅ", "A")
translit("ç", "c")      translit("Ç", "C")
translit("èéêë", "e")   translit("ÈÉÊË", "E")
translit("ìíîï", "i")   translit("ÌÍÎÏ", "I")
translit("ñ", "n")      translit("Ñ", "N")
translit("òóôöõø", "o") translit("ÒÓÔÖÕØ", "O")
translit("ùúûü", "u")   translit("ÙÚÛÜ", "U")
translit("ýÿ", "y")     translit("Ý", "Y")
translit("œ", "oe")     translit("Œ", "OE")
translit("æ", "ae")     translit("Æ", "AE")
translit("ß", "ss")

local function clean_name(str, fallback)
  str = tostring(str or "")
  str = str:gsub("%.%a%a%a%a?$", "")
  str = str:gsub("[\xC0-\xF4][\x80-\xBF]*", function(c) return TRANSLIT[c] or "" end)
  str = str:gsub("[%s%-%.]+", "_")
  str = str:gsub("[^%w_]", "")
  str = str:gsub("_+", "_")
  str = str:gsub("^_+", "")
  str = str:gsub("_+$", "")
  if str == "" then str = fallback or "Chop" end
  return str:sub(1, NAME_MAX)
end

-- True if the file is there.
local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

-- Turns a list of values into 16-bit sound data.
local FMT = {}
local function pack16(t, n)
  local f = FMT[n]
  if not f then f = "<" .. string.rep("i2", n); FMT[n] = f end
  return string.pack(f, table.unpack(t, 1, n))
end

-- Start of a WAV file: format, number of channels and length.
local function wav_header(nch, frames)
  local data = frames * nch * 2
  return string.pack("<c4I4c4c4I4I2I2I4I4I2I2c4I4",
    "RIFF", 36 + data, "WAVE",
    "fmt ", 16, 1, nch, SR_OUT, SR_OUT * nch * 2, nch * 2, 16,
    "data", data)
end

-------------------------------------------------------------------------------
-- Send chops to SK SP Kit Builder
--
--  The kit lives in the project. A chop goes in as a part of the item's audio
--  file, so it stays valid even if the item is cut or moved afterwards.
-------------------------------------------------------------------------------

-- A number written with enough decimals.
local function fnum(v) return string.format("%.9f", v) end

-- Describes a chop for the kit: its audio file, where it starts in it, how
-- long it lasts, its speed and its name.
local function chop_entry(k)
  local sl = slices()[k]
  if not (cur and sl) then return nil end
  local take = cur.take
  local src  = reaper.GetMediaItemTake_Source(take)
  local fn   = reaper.GetMediaSourceFileName(src, "")
  if (not fn or fn == "") and reaper.GetMediaSourceParent then
    local parent = reaper.GetMediaSourceParent(src)
    if parent then fn = reaper.GetMediaSourceFileName(parent, "") end
  end
  if not fn or fn == "" then return nil, "This item has no audio file on disk." end
  local offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if rate <= 0 then rate = 1 end
  local base = ui_name:gsub("^%s+", ""):gsub("%s+$", "")
  if base == "" then base = "Chop" end
  return table.concat({ "file", fn, fnum(offs + sl.start * rate), fnum(sl.stop - sl.start),
                        fnum(rate), ("%s %02d"):format(base, k) }, "\t")
end

-- Puts the chops in the first empty pads of the kit, and says where they went.
local function send_to_kit(ks)
  local free = {}
  for k = 1, PADS do
    local _, v = reaper.GetProjExtState(0, KIT_SECTION, ("pad%02d"):format(k))
    if not v or v == "" then free[#free + 1] = k end
  end
  local placed = {}
  for _, k in ipairs(ks) do
    local slot = free[#placed + 1]
    if not slot then break end
    local entry, err = chop_entry(k)
    if not entry then
      set_status(err or "Nothing to send.", COL_ERR)
      return 0
    end
    reaper.SetProjExtState(0, KIT_SECTION, ("pad%02d"):format(slot), entry)
    placed[#placed + 1] = slot
  end
  if #placed > 0 then
    -- Tells SK SP Kit Builder that the kit has changed.
    local _, rev = reaper.GetProjExtState(0, KIT_SECTION, "rev")
    reaper.SetProjExtState(0, KIT_SECTION, "rev", tostring((tonumber(rev) or 0) + 1))
  end

  if #placed == 0 then
    set_status("The kit is full: clear some pads in SK SP Kit Builder.", COL_ERR)
  elseif #placed < #ks then
    set_status(("%d chop(s) sent to the kit, %d did not fit: the kit is full."):format(
      #placed, #ks - #placed), COL_WARN)
  elseif #placed == 1 then
    set_status(("Chop %02d sent to kit pad %02d."):format(ks[1], placed[1]), COL_OK)
  else
    set_status(("%d chops sent to kit pads %02d to %02d."):format(
      #placed, placed[1], placed[#placed]), COL_OK)
  end
  return #placed
end

local LAST_DIR_KEY = "save_as_dir"   -- remembers the last folder used

-- Writes chop k as a WAV file at the given place, without cutting the item.
local function export_chop(k, path)
  local sl = slices()[k]
  if not (cur and sl) then return end
  if not path or path == "" then return end
  if not reaper.ValidatePtr2(0, cur.take, "MediaItem_Take*") then return end
  preview_stop()

  local ec    = kit_builder_settings()
  local where = path:match("^(.*)[/\\][^/\\]*$") or ""
  if where ~= "" then reaper.SetExtState(EXT_SECTION, LAST_DIR_KEY, where, true) end

  local take = cur.take
  local src  = reaper.GetMediaItemTake_Source(take)
  local nch  = math.max(1, math.min(2, reaper.GetMediaSourceNumChannels(src)))
  local och  = (ec.channels == 2) and 1 or (ec.channels == 3) and 2 or nch

  -- Read the chop, already in mono or stereo as asked.
  local f0  = math.floor(sl.start * SR_OUT + 0.5)
  local f1  = math.floor(sl.stop  * SR_OUT + 0.5)
  local BLK = 4096
  local buf = reaper.new_array(BLK * 2)
  local acc = reaper.CreateTakeAudioAccessor(take)
  local data, got, pos = {}, 0, f0
  while pos < f1 do
    local n = math.min(BLK, f1 - pos)
    buf.clear()
    local rv = reaper.GetAudioAccessorSamples(acc, SR_OUT, nch, pos / SR_OUT, n, buf)
    if rv and rv > 0 then got = got + 1 end
    local t = buf.table(1, n * nch)
    for fr = 0, n - 1 do
      local l = t[fr * nch + 1] or 0
      local r = (nch == 2) and (t[fr * nch + 2] or 0) or l
      if och == 1 then
        data[#data + 1] = (nch == 2) and (l + r) * 0.5 or l
      else
        data[#data + 1] = l
        data[#data + 1] = r
      end
    end
    pos = pos + n
  end
  reaper.DestroyAudioAccessor(acc)

  local frames = #data // och
  local vol = reaper.GetMediaItemInfo_Value(cur.item, "D_VOL")

  -- Find the loudest point, and where the sound starts and ends.
  local thr = 10 ^ (ec.trim_db / 20)
  local first, last, peak = nil, nil, 0
  for fr = 0, frames - 1 do
    local a = math.abs(data[fr * och + 1])
    if och == 2 then
      local b = math.abs(data[fr * och + 2])
      if b > a then a = b end
    end
    if a > peak then peak = a end
    if a > thr then
      if not first then first = fr end
      last = fr
    end
  end
  if got == 0 or peak == 0 then
    set_status(("No audio could be read for chop %02d, nothing written."):format(k), COL_ERR)
    return
  end
  local a0, a1 = 0, frames
  if ec.trim then
    if not first then
      set_status(("Chop %02d is silent below the trim threshold, nothing written."):format(k), COL_WARN)
      return
    end
    a0 = math.max(0, first - math.floor(0.001 * SR_OUT))
    a1 = math.min(frames, last + 1 + math.floor(0.010 * SR_OUT))
  end
  local len = a1 - a0

  local gain = vol
  if ec.norm_mode ~= 1 and peak > 0 then gain = 10 ^ (ec.norm_target / 20) / peak end

  local f, err = io.open(path, "wb")
  if not f then
    set_status("Cannot write the file: " .. tostring(err), COL_ERR)
    return
  end
  f:write(wav_header(och, len))

  -- Volume, fades, optional dither, then 16-bit values.
  local fl   = math.min(math.floor(len / 2), math.floor(ec.fade_ms / 1000 * SR_OUT))
  local out, kq, clipped = {}, 0, 0
  for fr = 0, len - 1 do
    local g = gain
    if fr < fl then g = g * fr / fl end
    local rem = len - 1 - fr
    if rem < fl then g = g * rem / fl end
    for c = 1, och do
      local v = data[(a0 + fr) * och + c] * g * 32767
      if ec.dither then v = v + math.random() - math.random() end
      local q = math.floor(v + 0.5)
      if q > 32767 then q = 32767; clipped = clipped + 1
      elseif q < -32768 then q = -32768; clipped = clipped + 1 end
      kq = kq + 1
      out[kq] = q
      if kq == BLK then f:write(pack16(out, kq)); kq = 0 end
    end
  end
  if kq > 0 then f:write(pack16(out, kq)) end
  f:close()

  local file = path:match("([^/\\]+)$")
  local msg  = ("Chop %02d written to %s / %s  (%s)"):format(k,
    where:match("([^/\\]+)$") or where, file, fmt_len(len / SR_OUT))
  local col  = COL_OK
  if len / SR_OUT < MIN_LEN then msg, col = msg .. "  Under 100 ms, the SP may refuse it.", COL_WARN end
  if clipped > 0 then msg, col = msg .. "  Clipped.", COL_WARN end
  set_status(msg, col)
end

-- SAVE AS WAV: the standard Save window when js_ReaScriptAPI is installed,
-- otherwise a small window of the script asking for the folder and name.
local save_req   = nil   -- chop, folder and file name being asked for
local open_save  = false

-- Name proposed for a chop: "Name_05.wav".
local function default_save_name(k)
  return string.format("%s_%02d.wav", clean_name(ui_name, "Chop"), k)
end

-- Adds ".wav" if missing.
local function with_wav(f)
  if not f:lower():match("%.wav$") then f = f .. ".wav" end
  return f
end

local function request_save(k)
  local last = reaper.GetExtState(EXT_SECTION, LAST_DIR_KEY)
  if reaper.JS_Dialog_BrowseForSaveFile then
    local rv, fn = reaper.JS_Dialog_BrowseForSaveFile("Save chop as WAV", last,
      default_save_name(k), "WAV files (*.wav)\0*.wav\0\0")
    if rv == 1 and fn and fn ~= "" then export_chop(k, with_wav(fn)) end
    return
  end
  save_req  = { k = k, dir = last, file = default_save_name(k) }
  open_save = true
end

-- True if a file can be written in that folder.
local function dir_writable(dir)
  local probe = dir .. SEP .. ".sk_sp_probe"
  local f = io.open(probe, "wb")
  if not f then return false end
  f:close()
  os.remove(probe)
  return true
end

-------------------------------------------------------------------------------
-- Interface
-------------------------------------------------------------------------------

local ctx = reaper.ImGui_CreateContext("Studio Kozak SP Chopper")

-------------------------------------------------------------------------------
-- Look and feel: dark background, amber accent.
-------------------------------------------------------------------------------

local FONT_TITLE = 22
local FONT_BTN   = 17
local fontTitle  = reaper.ImGui_CreateFont('sans-serif', FONT_TITLE)
local fontBtn    = reaper.ImGui_CreateFont('sans-serif', FONT_BTN)
reaper.ImGui_Attach(ctx, fontTitle)
reaper.ImGui_Attach(ctx, fontBtn)

-- Works with both older and newer versions of ReaImGui.
local _pfMode
local function PushFont(f, size)
  if _pfMode == 1 then
    reaper.ImGui_PushFont(ctx, f, size)
  elseif _pfMode == 2 then
    reaper.ImGui_PushFont(ctx, f)
  else
    if pcall(reaper.ImGui_PushFont, ctx, f, size) then _pfMode = 1
    else reaper.ImGui_PushFont(ctx, f); _pfMode = 2 end
  end
end
local function PopFont() reaper.ImGui_PopFont(ctx) end

-- Colours, written as red, green, blue and opacity.
local COL_ACCENT   = 0xD9A441FF   -- amber
local COL_ACCENT_H = 0xE6B75AFF   -- amber, under the mouse
local COL_ACCENT_A = 0xB8863BFF   -- amber, while clicked
local COL_INK      = 0x181A1FFF   -- dark text
local COL_PAPER    = 0xE9E5DAFF   -- light text

local COL_CELL_OFF = 0x212429FF   -- empty pad, waveform background
local COL_PAD      = 0x30343BFF   -- pad
local COL_SHORT    = 0x882222FF   -- chop too short for the SP
local COL_WAVE     = 0x8C8778FF   -- waveform
local COL_SEL      = 0xD9A44126   -- selected chop, light amber

local THEME_COLORS = {
  { reaper.ImGui_Col_WindowBg(),        0x1E2024FF },
  { reaper.ImGui_Col_PopupBg(),         0x24272CFF },
  { reaper.ImGui_Col_Text(),            0xE9E5DAFF },
  { reaper.ImGui_Col_TextDisabled(),    0x8C8778FF },
  { reaper.ImGui_Col_FrameBg(),         0x2A2D33FF },
  { reaper.ImGui_Col_FrameBgHovered(),  0x353942FF },
  { reaper.ImGui_Col_FrameBgActive(),   0x3E434DFF },
  { reaper.ImGui_Col_Button(),          0x30343BFF },
  { reaper.ImGui_Col_ButtonHovered(),   0x3B404AFF },
  { reaper.ImGui_Col_ButtonActive(),    0x474D58FF },
  { reaper.ImGui_Col_CheckMark(),       COL_ACCENT },
  { reaper.ImGui_Col_Header(),          0x33373FFF },
  { reaper.ImGui_Col_HeaderHovered(),   0x3F444EFF },
  { reaper.ImGui_Col_HeaderActive(),    0x4A505BFF },
  { reaper.ImGui_Col_Separator(),       0x3A3E46FF },
  { reaper.ImGui_Col_Border(),          0x35393FFF },
  { reaper.ImGui_Col_TitleBg(),         0x181A1EFF },
  { reaper.ImGui_Col_TitleBgActive(),   0x24272CFF },
  { reaper.ImGui_Col_SliderGrab(),       COL_ACCENT   },
  { reaper.ImGui_Col_SliderGrabActive(), COL_ACCENT_H },
}

local function pushTheme()
  for _, c in ipairs(THEME_COLORS) do reaper.ImGui_PushStyleColor(ctx, c[1], c[2]) end
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(),  8)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),   6)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_GrabRounding(),    6)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_PopupRounding(),   6)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),   18, 12)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),    10, 5)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),     10, 6)
end
local N_VARS = 7   -- number of style settings changed just above
local function popTheme()
  reaper.ImGui_PopStyleVar(ctx, N_VARS)
  reaper.ImGui_PopStyleColor(ctx, #THEME_COLORS)
end

-- The main action button: amber, dark text.
local function accentButton(label, width, height)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        COL_ACCENT)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COL_ACCENT_H)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  COL_ACCENT_A)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          COL_INK)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 12, 5)
  local pressed = reaper.ImGui_Button(ctx, label, width, height)
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleColor(ctx, 4)
  return pressed
end

-- Picks dark or light text, whichever stays readable on the given background.
local function textOn(rgba)
  local r = (rgba >> 24) & 0xFF
  local g = (rgba >> 16) & 0xFF
  local b = (rgba >>  8) & 0xFF
  local brightness = (0.299 * r + 0.587 * g + 0.114 * b) / 255
  return (brightness > 0.55) and COL_INK or COL_PAPER
end

-- Brightens or darkens a colour, keeping its transparency.
local function shade(rgba, f)
  local r = math.min(255, math.floor(((rgba >> 24) & 0xFF) * f))
  local g = math.min(255, math.floor(((rgba >> 16) & 0xFF) * f))
  local b = math.min(255, math.floor(((rgba >>  8) & 0xFF) * f))
  return (r << 24) | (g << 16) | (b << 8) | (rgba & 0xFF)
end

-- A button in the given colour.
local function colouredButton(label, col, w, h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        col)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), shade(col, 1.30))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  shade(col, 0.80))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          textOn(col))
  local pressed = reaper.ImGui_Button(ctx, label, w, h)
  reaper.ImGui_PopStyleColor(ctx, 4)
  return pressed
end

-------------------------------------------------------------------------------
-- Waveform with markers that can be dragged
-------------------------------------------------------------------------------

local drag_m = nil   -- marker being dragged

-- Keeps the view inside the item.
local function clamp_view()
  local len = cur.len
  view.len   = clamp(view.len, math.min(MIN_VIEW, len), len)
  view.start = clamp(view.start, 0, math.max(0, len - view.len))
end

-- Zooms in or out, keeping the given moment at the same place on screen.
local function zoom_at(anchor, factor)
  local new_len = clamp(view.len * factor, math.min(MIN_VIEW, cur.len), cur.len)
  view.start = anchor - (anchor - view.start) * (new_len / view.len)
  view.len   = new_len
  clamp_view()
end

-- Shows the part from a to b, with a small margin.
local function zoom_to(a, b)
  local margin = (b - a) * 0.1
  view.start, view.len = a - margin, (b - a) + 2 * margin
  clamp_view()
end

-- Loudest point of the whole item, so zooming never rescales the display.
local function item_max()
  if ana.maxp and ana.done then return ana.maxp end
  local m = 1e-9
  for i = 1, #ana.peak do if ana.peak[i] > m then m = ana.peak[i] end end
  if ana.done then ana.maxp = m end
  return m
end

-- Waveform of the part shown, one vertical line per pixel. Taken from the
-- overview files REAPER keeps for its own waveforms, which stay detailed at
-- any zoom. The measurements made on the item are used if they are missing.
local disp      = { key = nil, hi = {}, lo = {} }   -- last drawing, kept until the view changes
local disp_buf  = reaper.new_array(WAVE_W * 2 * 2)

local function view_columns()
  local key = table.concat({ cur.key, view.start, view.len, #ana.peak }, "|")
  if disp.key == key then return disp.hi, disp.lo end

  local take = cur.take
  local src  = reaper.GetMediaItemTake_Source(take)
  local nch  = math.max(1, math.min(2, reaper.GetMediaSourceNumChannels(src)))
  local offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if rate <= 0 then rate = 1 end

  local hi, lo = {}, {}
  local pr = WAVE_W / view.len                  -- pixels per second
  disp_buf.clear()
  local rv  = reaper.PCM_Source_GetPeaks(src, pr / rate, offs + view.start * rate,
                                         nch, WAVE_W, 0, disp_buf)
  local got = (rv or 0) & 0xFFFFF

  if got > 0 then
    local t, mins = disp_buf.table(1, WAVE_W * nch * 2), WAVE_W * nch
    for c = 1, WAVE_W do
      local h, l = 0, 0
      for ch = 1, nch do
        local vh = t[(c - 1) * nch + ch] or 0
        local vl = t[mins + (c - 1) * nch + ch] or 0
        if vh > h then h = vh end
        if vl < l then l = vl end
      end
      hi[c], lo[c] = h, l
    end
  else
    local P, hs = ana.peak, ana.hop_sec
    for c = 1, WAVE_W do
      local ta = view.start + (c - 1) / WAVE_W * view.len
      local tb = view.start + c / WAVE_W * view.len
      local ia = math.floor(ta / hs) + 1
      local ib = math.max(ia, math.floor(tb / hs))
      local m = 0
      for i = ia, ib do
        local v = P[i]
        if v and v > m then m = v end
      end
      hi[c], lo[c] = m, -m
    end
  end

  disp.key, disp.hi, disp.lo = key, hi, lo
  return hi, lo
end

-- The whole item at a glance, for the strip below the waveform.
local over = { key = nil, cols = nil }
local function overview_columns()
  local P   = ana.peak
  local key = ana.key .. ":" .. #P
  if over.key == key then return over.cols end
  local nh, cols = ana.nh_total, {}
  for c = 1, WAVE_W do
    local a = math.floor((c - 1) / WAVE_W * nh) + 1
    local b = math.max(a, math.floor(c / WAVE_W * nh))
    local m = 0
    for i = a, b do
      local v = P[i]
      if v and v > m then m = v end
    end
    cols[c] = m
  end
  over.key, over.cols = key, cols
  return cols
end

-- Draws the waveform, the markers and the strip below, and handles the mouse.
local function draw_waveform(sl)
  local len    = cur.len
  clamp_view()
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local x1, y1 = x0 + WAVE_W, y0 + WAVE_H
  reaper.ImGui_InvisibleButton(ctx, "##wave", WAVE_W, WAVE_H)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local dl      = reaper.ImGui_GetWindowDrawList(ctx)
  local function tx(t) return x0 + (t - view.start) / view.len * WAVE_W end

  reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1, COL_CELL_OFF, 6)
  reaper.ImGui_DrawList_PushClipRect(dl, x0, y0, x1, y1, true)

  -- Selected chop
  local s = sl[sel_pad]
  if s then
    reaper.ImGui_DrawList_AddRectFilled(dl, tx(s.start), y0, tx(s.stop), y1, COL_SEL)
  end
  local head_x = tx(points[1])

  -- Waveform
  local cy, amp = y0 + WAVE_H * 0.5, WAVE_H * 0.5 - 8
  reaper.ImGui_DrawList_AddLine(dl, x0, cy, x1, cy, 0x35393FFF, 1)
  if ana then
    local hi, lo = view_columns()
    local k = amp / item_max()
    for c = 1, WAVE_W do
      local top, bot = cy - hi[c] * k, cy - lo[c] * k
      if bot - top > 0.5 then
        local x = x0 + c - 0.5
        reaper.ImGui_DrawList_AddLine(dl, x, top, x, bot, COL_WAVE, 1)
      end
    end
    -- What sits before the first marker is left out of the chops.
    if points[1] > 0 then
      reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, head_x, y1, 0x00000080)
    end
    if not ana.done then
      reaper.ImGui_DrawList_AddText(dl, x0 + 10, y0 + 8, COL_PAPER,
        ("Analysing  %d %%"):format(math.floor(ana.progress * 100)))
    elseif ana.empty then
      reaper.ImGui_DrawList_AddText(dl, x0 + 10, y0 + 8, COL_ERR,
        "No audio could be read from this item.")
    end
  end

  -- Which marker is under the mouse
  local mx   = reaper.ImGui_GetMousePos(ctx)
  local t_at = view.start + clamp((mx - x0) / WAVE_W, 0, 1) * view.len
  local hover_m = nil
  if hovered and not drag_m then
    local best = 6
    for k = 1, #points do
      local d = math.abs(tx(points[k]) - mx)
      if d < best then best, hover_m = d, k end
    end
  end

  -- Playhead while a chop is heard
  if pv.stop_at and pv.start then
    local t = pv.start + (reaper.time_precise() - pv.t0)
    if t >= view.start and t <= view.start + view.len then
      local x = tx(t)
      reaper.ImGui_DrawList_AddLine(dl, x, y0, x, y1, COL_PAPER, 1)
    end
  end

  -- Markers
  for k, t in ipairs(points) do
    if t >= view.start - view.len * 0.05 and t <= view.start + view.len then
      local x   = tx(t)
      local hot = (k == hover_m or k == drag_m)
      local col = hot and COL_ACCENT_H or COL_ACCENT
      reaper.ImGui_DrawList_AddLine(dl, x, y0, x, y1, col, hot and 2 or 1)
      reaper.ImGui_DrawList_AddTriangleFilled(dl, x - 5, y0, x + 5, y0, x, y0 + 8, col)
      reaper.ImGui_DrawList_AddText(dl, x + 4, y1 - 17, col, tostring(k))
    end
  end
  reaper.ImGui_DrawList_PopClipRect(dl)

  -- Wheel: zoom around the mouse. Shift + wheel, or a sideways swipe, scrolls.
  if hovered then
    local wv, wh = reaper.ImGui_GetMouseWheel(ctx)
    wh = wh or 0
    local shift = (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Shift()) ~= 0
    if shift and wv ~= 0 then wh, wv = wv, 0 end
    if wh ~= 0 then
      view.start = view.start - wh * view.len * 0.1
      clamp_view()
    end
    if wv ~= 0 then zoom_at(t_at, 0.8 ^ wv) end
  end

  -- Mouse
  if hover_m or drag_m then
    reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW())
  end
  if reaper.ImGui_IsItemClicked(ctx, reaper.ImGui_MouseButton_Left()) then
    if hover_m then
      drag_m = hover_m
    else
      local k = slice_at(t_at)
      if k then
        sel_pad = k
        toggle_slice(k)
      end
    end
  end
  if drag_m then
    if reaper.ImGui_IsMouseDown(ctx, reaper.ImGui_MouseButton_Left()) and points[drag_m] then
      local lo = (drag_m > 1) and (points[drag_m - 1] + MIN_SLICE) or 0
      local hi = (points[drag_m + 1] or len) - MIN_SLICE
      if hi > lo then
        points[drag_m] = clamp(t_at, lo, hi)
        edited = true
      end
    else
      drag_m = nil
    end
  end
  if hovered and not hover_m
     and reaper.ImGui_IsMouseDoubleClicked(ctx, reaper.ImGui_MouseButton_Left()) then
    add_point(t_at)
  end
  if hover_m and reaper.ImGui_IsItemClicked(ctx, reaper.ImGui_MouseButton_Right()) then
    -- The first marker cannot go; right-clicking it brings it back to 0.
    if hover_m == 1 then
      points[1] = 0
    else
      table.remove(points, hover_m)
      if sel_pad > #points then sel_pad = #points end
    end
    edited = true
  end

  -- Strip: the whole item, with the part shown framed. Click or drag in it
  -- to move there.
  reaper.ImGui_Dummy(ctx, 0, 2)
  local ox, oy = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_InvisibleButton(ctx, "##overview", WAVE_W, OVER_H)
  local o_active = reaper.ImGui_IsItemActive(ctx)
  reaper.ImGui_DrawList_AddRectFilled(dl, ox, oy, ox + WAVE_W, oy + OVER_H, COL_CELL_OFF, 4)
  if ana then
    local cols, k = overview_columns(), (OVER_H * 0.5 - 2) / item_max()
    local ocy = oy + OVER_H * 0.5
    for c = 1, WAVE_W do
      local v = cols[c] * k
      if v > 0.5 then
        reaper.ImGui_DrawList_AddLine(dl, ox + c - 0.5, ocy - v, ox + c - 0.5, ocy + v, 0x5A5850FF, 1)
      end
    end
  end
  for _, t in ipairs(points) do
    local x = ox + t / len * WAVE_W
    reaper.ImGui_DrawList_AddLine(dl, x, oy, x, oy + OVER_H, 0xD9A44188, 1)
  end
  local vx0 = ox + view.start / len * WAVE_W
  local vx1 = ox + (view.start + view.len) / len * WAVE_W
  reaper.ImGui_DrawList_AddRectFilled(dl, vx0, oy, math.max(vx0 + 2, vx1), oy + OVER_H, 0xD9A44122, 3)
  reaper.ImGui_DrawList_AddRect(dl, vx0, oy, math.max(vx0 + 2, vx1), oy + OVER_H, COL_ACCENT, 3, 0, 1)
  if o_active then
    local omx = reaper.ImGui_GetMousePos(ctx)
    view.start = clamp((omx - ox) / WAVE_W, 0, 1) * len - view.len * 0.5
    clamp_view()
  end
end

-------------------------------------------------------------------------------
-- Main loop
-------------------------------------------------------------------------------

local MODES = { "TRANSIENTS", "GRID", "EQUAL" }
local _   -- receives values that are not needed

-- Runs at every refresh of the window.
local function loop()
  update_current()
  run_analysis()
  preview_watch()
  if cur then update_points() end

  if status ~= "" and status_col ~= COL_OK and reaper.time_precise() - status_time > 4 then
    status = ""
  end

  pushTheme()
  reaper.ImGui_SetNextWindowSize(ctx, 700, 700, reaper.ImGui_Cond_FirstUseEver())
  local visible, open = reaper.ImGui_Begin(ctx, "SK SP Chopper", true,
    reaper.ImGui_WindowFlags_AlwaysAutoResize())

  if visible then

    -- Space or Escape stops the chop being heard.
    if pv.stop_at and reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows())
       and not reaper.ImGui_IsAnyItemActive(ctx)
       and (reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Space(), false)
            or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape(), false)) then
      preview_stop()
    end

    -- Title row: item name and length aligned on the bottom of the title, help on the right
    local y0 = reaper.ImGui_GetCursorPosY(ctx)
    PushFont(fontTitle, FONT_TITLE)
    local h_big = reaper.ImGui_GetTextLineHeight(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_ACCENT)
    reaper.ImGui_Text(ctx, "SK SP CHOPPER")
    reaper.ImGui_PopStyleColor(ctx)
    PopFont()
    local h_small = reaper.ImGui_GetTextLineHeight(ctx)
    local y_base  = y0 + (h_big - h_small) * 0.80
    reaper.ImGui_SameLine(ctx, 0, 16)
    reaper.ImGui_SetCursorPosY(ctx, y_base)
    if cur then
      reaper.ImGui_Text(ctx, default_name(cur.take))
      reaper.ImGui_SameLine(ctx, 0, 10)
      reaper.ImGui_SetCursorPosY(ctx, y_base)
      reaper.ImGui_TextDisabled(ctx, fmt_len(cur.len))
    else
      reaper.ImGui_TextDisabled(ctx, "one item, sixteen pads")
    end
    local help_w = reaper.ImGui_CalcTextSize(ctx, "(?)")
    reaper.ImGui_SameLine(ctx, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding()) + WAVE_W - help_w)
    reaper.ImGui_SetCursorPosY(ctx, y_base)
    reaper.ImGui_TextDisabled(ctx, "(?)")
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, table.concat({
        "Wheel: zoom around the mouse",
        "Shift + wheel, or the strip below: scroll",
        "-  +  ALL  SEL: zoom out, in, whole item, selected chop",
        "Drag a marker: move it",
        "Double-click: add a marker",
        "Right-click a marker: remove it (marker 1 goes back to 0)",
        "Click a slice or a pad: hear it",
        "Marker 1 sets where chop 01 starts: anything before it is left out",
        "",
        "SEND TO KIT puts the selected chop in SK SP Kit Builder.",
        "ALL TO KIT sends every chop. Neither cuts the item.",
        "SAVE AS WAV writes the selected chop to a folder you choose.",
        "CHOP cuts the item into its slices in the project.",
      }, "\n"))
    end
    reaper.ImGui_Dummy(ctx, 0, 2)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Dummy(ctx, 0, 2)

    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), GAP, GAP)

    if not cur then
      reaper.ImGui_Dummy(ctx, WAVE_W, 0)
      reaper.ImGui_TextDisabled(ctx, cur_msg)
    else

      -- Row 1: the three modes, then how many chops
      for m, lbl in ipairs(MODES) do
        if m > 1 then reaper.ImGui_SameLine(ctx) end
        if cfg.mode == m then
          accentButton(lbl, COL_W, 0)
        elseif reaper.ImGui_Button(ctx, lbl, COL_W, 0) then
          cfg.mode = m
        end
      end
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, COL_W)
      if cfg.mode == 3 then
        _, cfg.slices = reaper.ImGui_SliderInt(ctx, "##slices", cfg.slices, 2, PADS, "%d slices")
      else
        _, cfg.max_chops = reaper.ImGui_SliderInt(ctx, "##maxchops", cfg.max_chops, 2, PADS, "max %d chops")
      end

      -- Row 2: the mode's settings in three columns, zoom in the fourth
      reaper.ImGui_BeginGroup(ctx)
      if cfg.mode == 1 then
        reaper.ImGui_SetNextItemWidth(ctx, COL_W)
        _, cfg.sens = reaper.ImGui_SliderInt(ctx, "##sens", cfg.sens, 0, 100, "sensitivity %d")
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_SetNextItemWidth(ctx, COL_W)
        _, cfg.floor_db = reaper.ImGui_SliderInt(ctx, "##floor", cfg.floor_db, -80, -10, "floor %d dB")
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_SetNextItemWidth(ctx, COL_W)
        _, cfg.min_gap = reaper.ImGui_SliderInt(ctx, "##gap", cfg.min_gap, 20, 500, "gap %d ms")
      elseif cfg.mode == 2 then
        reaper.ImGui_SetNextItemWidth(ctx, COL_W)
        if reaper.ImGui_BeginCombo(ctx, "##div", DIVS[cfg.div] and DIVS[cfg.div][1] or "") then
          for i, d in ipairs(DIVS) do
            if reaper.ImGui_Selectable(ctx, d[1], i == cfg.div) then cfg.div = i end
          end
          reaper.ImGui_EndCombo(ctx)
        end
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_AlignTextToFramePadding(ctx)
        reaper.ImGui_TextDisabled(ctx, ("from the item start, at %.2f BPM"):format(
          reaper.Master_GetTempo()))
      else
        reaper.ImGui_AlignTextToFramePadding(ctx)
        reaper.ImGui_TextDisabled(ctx, "Equal slices across the whole item.")
      end
      reaper.ImGui_EndGroup(ctx)

      reaper.ImGui_SameLine(ctx, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding())
                                 + 3 * (COL_W + GAP))
      local ZW = (COL_W - 3 * 4) / 4
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 4, GAP)
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 2, 5)
      local zoomed = view.len < cur.len - 1e-9
      if reaper.ImGui_Button(ctx, "-##zout", ZW, 0) then
        zoom_at(view.start + view.len * 0.5, ZOOM_STEP)
      end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "+##zin", ZW, 0) then
        zoom_at(view.start + view.len * 0.5, 1 / ZOOM_STEP)
      end
      reaper.ImGui_SameLine(ctx)
      if not zoomed then reaper.ImGui_BeginDisabled(ctx) end
      if reaper.ImGui_Button(ctx, "ALL##zfit", ZW, 0) then view.start, view.len = 0, cur.len end
      if not zoomed then reaper.ImGui_EndDisabled(ctx) end
      if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
        reaper.ImGui_SetTooltip(ctx, "Show the whole item")
      end
      reaper.ImGui_SameLine(ctx)
      local zs = slices()[sel_pad]
      if reaper.ImGui_Button(ctx, "SEL##zsel", ZW, 0) and zs then zoom_to(zs.start, zs.stop) end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Zoom on the selected chop")
      end
      reaper.ImGui_PopStyleVar(ctx, 2)

      -- Waveform and overview
      local sl = slices()
      draw_waveform(sl)
      sl = slices()   -- markers may have moved

      -- Pads on the left half
      local grid_y = reaper.ImGui_GetCursorPosY(ctx)
      local grid_h = PAD_H * 4 + GAP * 3
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 4, 2)
      reaper.ImGui_BeginGroup(ctx)
      for r = 0, 3 do
        for c = 0, 3 do
          local k = r * 4 + c + 1
          if c > 0 then reaper.ImGui_SameLine(ctx) end
          reaper.ImGui_PushID(ctx, 500 + k)
          local s = sl[k]
          if s then
            local short = (s.stop - s.start) < MIN_LEN
            local col = (k == sel_pad) and COL_ACCENT or (short and COL_SHORT or COL_PAD)
            local playing = (pv.pad == k and pv.stop_at)
            local lbl = ("%02d\n%s"):format(k, playing and "STOP" or fmt_len(s.stop - s.start))
            if colouredButton(lbl .. "##p", col, PAD_W, PAD_H) then
              sel_pad = k
              toggle_slice(k)
            end
          else
            reaper.ImGui_BeginDisabled(ctx)
            colouredButton("##empty", COL_CELL_OFF, PAD_W, PAD_H)
            reaper.ImGui_EndDisabled(ctx)
          end
          reaper.ImGui_PopID(ctx)
        end
      end
      reaper.ImGui_EndGroup(ctx)
      reaper.ImGui_PopStyleVar(ctx)

      -- Right half: the selected chop on top, its actions level with the
      -- bottom row of pads
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_BeginGroup(ctx)
      local s = sl[sel_pad]
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_TextColored(ctx, COL_ACCENT, ("CHOP %02d"):format(sel_pad))
      if s then
        reaper.ImGui_SameLine(ctx, 0, 10)
        reaper.ImGui_Text(ctx, fmt_len(s.stop - s.start))
        reaper.ImGui_SameLine(ctx, 0, 10)
        reaper.ImGui_TextDisabled(ctx, ("at %.3f s"):format(s.start))
      end

      local note, note_col
      if s and s.stop - s.start < MIN_LEN then
        note, note_col = "Under 100 ms: the SP may refuse it.", COL_ERR
      elseif truncated then
        note, note_col = "More hits than pads: the strongest kept.", COL_WARN
      elseif cfg.mode == 1 and not (ana and ana.done) then
        note = "Waiting for the analysis."
      else
        note = ("%d / %d pads"):format(#points, PADS)
        if points[1] > 0 then note = note .. ("  ·  first %s left out"):format(fmt_len(points[1])) end
        if edited then note = note .. "  ·  edited" end
      end
      if note_col then reaper.ImGui_TextColored(ctx, note_col, note)
      else reaper.ImGui_TextDisabled(ctx, note) end

      reaper.ImGui_SetNextItemWidth(ctx, HALF_W)
      _, ui_name = reaper.ImGui_InputTextWithHint(ctx, "##name", "output name", ui_name)
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Name given to the chops: files, kit pads and items.")
      end
      reaper.ImGui_SetNextItemWidth(ctx, HALF_W)
      _, cfg.fade_ms = reaper.ImGui_SliderDouble(ctx, "##fades", cfg.fade_ms, 0, 20, "fades %.1f ms")

      reaper.ImGui_SetCursorPosY(ctx, grid_y + grid_h - BTN_H)
      local can_exp = (s ~= nil)
      if not can_exp then reaper.ImGui_BeginDisabled(ctx) end
      if reaper.ImGui_Button(ctx, ("SEND %02d TO KIT"):format(sel_pad), COL_W, BTN_H) then
        send_to_kit({ sel_pad })
      end
      if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
        reaper.ImGui_SetTooltip(ctx,
          "Puts this chop in the first empty pad of SK SP Kit Builder.\nThe item is not cut.")
      end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, ("SAVE %02d AS WAV..."):format(sel_pad), COL_W, BTN_H) then
        request_save(sel_pad)
      end
      if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
        reaper.ImGui_SetTooltip(ctx,
          "Writes only this chop as a WAV file, in a folder you choose.\n48 kHz / 16-bit, with SK SP Kit Builder's processing settings.")
      end
      if not can_exp then reaper.ImGui_EndDisabled(ctx) end
      reaper.ImGui_EndGroup(ctx)

      -- Bottom row: the two actions on the whole item, one per half
      reaper.ImGui_Dummy(ctx, 0, 2)
      local can_chop = (#points >= 2)
      PushFont(fontBtn, FONT_BTN)
      if not can_chop then reaper.ImGui_BeginDisabled(ctx) end
      if accentButton(("CHOP INTO %d SLICES"):format(#points), HALF_W, ACT_H) then
        do_chop()
      end
      if not can_chop then reaper.ImGui_EndDisabled(ctx) end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, ("ALL %d TO KIT"):format(#points), HALF_W, ACT_H) then
        local ks = {}
        for k = 1, #points do ks[k] = k end
        send_to_kit(ks)
      end
      PopFont()
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
          "Puts every chop in the empty pads of SK SP Kit Builder, in order.\nThe item is not cut.")
      end
      if not reaper.CF_CreatePreview then
        reaper.ImGui_TextDisabled(ctx, "Install SWS to hear the chops on their own.")
      end
    end

    reaper.ImGui_PopStyleVar(ctx)

    if open_save then
      reaper.ImGui_OpenPopup(ctx, "Save chop as WAV")
      open_save = false
    end
    if reaper.ImGui_BeginPopupModal(ctx, "Save chop as WAV", nil,
        reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
      if save_req then
        reaper.ImGui_TextColored(ctx, COL_ACCENT, ("CHOP %02d"):format(save_req.k))
        reaper.ImGui_TextDisabled(ctx,
          "Folder: in the Finder, select it, press Option+Cmd+C, paste here.")
        reaper.ImGui_SetNextItemWidth(ctx, 460)
        _, save_req.dir = reaper.ImGui_InputTextWithHint(ctx, "Folder##sv", "/Users/...", save_req.dir)
        reaper.ImGui_SetNextItemWidth(ctx, 460)
        _, save_req.file = reaper.ImGui_InputText(ctx, "File##sv", save_req.file)

        local dir  = save_req.dir:gsub("^%s+", ""):gsub("%s+$", ""):gsub("[/\\]+$", "")
        local file = save_req.file:gsub("^%s+", ""):gsub("%s+$", ""):gsub("[/\\]", "_")
        local ok   = dir ~= "" and file ~= ""
        local path = ok and (dir .. SEP .. with_wav(file)) or nil
        if path and file_exists(path) then
          reaper.ImGui_TextColored(ctx, COL_WARN, "A file with this name exists: it will be replaced.")
        end

        reaper.ImGui_Spacing(ctx)
        if not ok then reaper.ImGui_BeginDisabled(ctx) end
        if accentButton("SAVE", 140, 0) then
          if dir_writable(dir) then
            export_chop(save_req.k, path)
            save_req = nil
            reaper.ImGui_CloseCurrentPopup(ctx)
          else
            set_status("Cannot write to that folder: check the path.", COL_ERR)
          end
        end
        if not ok then reaper.ImGui_EndDisabled(ctx) end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "CANCEL", 140, 0) then
          save_req = nil
          reaper.ImGui_CloseCurrentPopup(ctx)
        end
        if status ~= "" and status_col == COL_ERR then
          reaper.ImGui_TextColored(ctx, COL_ERR, status)
        end
      else
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      reaper.ImGui_EndPopup(ctx)
    end

    if status ~= "" then
      reaper.ImGui_TextColored(ctx, status_col or COL_ACCENT, status)
    end

    reaper.ImGui_End(ctx)
  end

  popTheme()

  if open then reaper.defer(loop) end
end

-- When the window closes: stop playback, stop reading, save the settings.
reaper.atexit(function()
  preview_stop()
  cancel_analysis()
  save_cfg()
end)

reaper.defer(loop)
