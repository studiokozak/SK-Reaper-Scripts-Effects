-- @description SK SP Kit Builder
-- @author Studio Kozak
-- @version 1.0
-- @provides [main] .
-- @about
--   Builds a sixteen-pad kit for the Roland SP-404MKII and exports it as
--   48 kHz / 16-bit WAV files, numbered 01 to 16 by pad, into a folder of
--   your choice (the IMPORT folder of the SD card, typically).
--
--   Pads are filled by dropping audio files from the Finder, from the items
--   selected in REAPER, or straight from SK SP Chopper (SEND TO KIT). Drag a
--   pad onto another to swap them. The kit is saved with the project.
--
--   Optional processing: silence trimming, normalisation per sample or across
--   the whole kit, anti-click fades, mono or stereo conversion, TPDF dither.
--
--   Requirements (all installable with ReaPack):
--     - ReaImGui: required, draws the window.
--     - SWS extension: optional. Plays the pads. Without it, PLAY is greyed.
--     - js_ReaScriptAPI: optional. Adds the BROWSE button to pick the
--       destination folder. Without it, the path is typed or pasted.

local reaper = reaper

if not reaper.ImGui_CreateContext then
  reaper.MB("ReaImGui is required. Please install it via ReaPack.", "Missing dependency", 0)
  return
end

-------------------------------------------------------------------------------
-- Fixed values
-------------------------------------------------------------------------------

local SR        = 48000     -- the SP stores everything at 48 kHz / 16-bit
local PADS      = 16        -- pads in one bank of the SP
local MIN_LEN   = 0.100     -- seconds: the SP may refuse shorter files
local NAME_MAX  = 24        -- longest name kept

local BLOCK     = 4096      -- amount of sound handled at once
local PRE_ROLL  = 0.001     -- seconds kept before the first sound when trimming
local POST_ROLL = 0.010     -- seconds kept after the last one
local BUDGET    = 0.025     -- seconds spent exporting at each refresh of the
                            -- window, so that it stays responsive

-- Layout: four equal columns. The pads take the left half, everything else
-- lines up with the columns, so edges match from top to bottom.
local W      = 840                                 -- width, in pixels
local GAP    = 8
local COL_W  = (W - 3 * GAP) / 4                   -- 204 pixels
local HALF_W = COL_W * 2 + GAP                     -- 416 pixels
local PAD_W, PAD_H = (HALF_W - 3 * GAP) / 4, 66    -- 98 x 66 pixels
local GRID_H = PAD_H * 4 + GAP * 3
local BTN_H  = 30
local ACT_H  = 44

local SEP         = package.config:sub(1, 1)       -- folder separator of the system
local EXT_SECTION = "Studio Kozak SP Kit Builder"  -- name the settings are saved under
local KIT_SECTION = "SK_SP_KitBuilder"             -- the kit, saved in the project and
                                                   -- shared with SK SP Chopper
local TEMP_TRACK  = "SK SP Kit Builder (temp)"     -- hidden track used during an export

-- File types accepted on the pads.
local AUDIO_EXT = { wav = true, aif = true, aiff = true, mp3 = true, flac = true, ogg = true }

-------------------------------------------------------------------------------
-- Settings, remembered between sessions
-------------------------------------------------------------------------------

local cfg = {
  dest_dir    = "",     -- destination folder
  subfolder   = true,   -- write the kit in a folder named after it
  channels    = 1,      -- 1 keep source, 2 mono, 3 stereo
  norm_mode   = 1,      -- 1 off, 2 per sample, 3 whole kit
  norm_target = -0.3,   -- loudest point after normalising, in dBFS
  trim        = true,   -- remove the silence at both ends
  trim_db     = -60,    -- what counts as silence
  fade_ms     = 2.0,    -- short fades against clicks
  dither      = false,  -- light noise that smooths the reduction to 16 bits
}

-- How each setting is saved: s = text, n = number, b = on/off.
local CFG_KINDS = {
  dest_dir = "s", subfolder = "b", channels = "n", norm_mode = "n",
  norm_target = "n", trim = "b", trim_db = "n", fade_ms = "n", dither = "b",
}

local function load_cfg()
  for k, kind in pairs(CFG_KINDS) do
    local raw = reaper.GetExtState(EXT_SECTION, k)
    if raw ~= "" then
      if kind == "s" then cfg[k] = raw
      elseif kind == "n" then cfg[k] = tonumber(raw) or cfg[k]
      else cfg[k] = (raw == "1") end
    end
  end
end

local function save_cfg()
  for k, kind in pairs(CFG_KINDS) do
    local v = cfg[k]
    if kind == "b" then v = v and "1" or "0" end
    reaper.SetExtState(EXT_SECTION, k, tostring(v), true)
  end
end

load_cfg()

-------------------------------------------------------------------------------
-- Names
--
--  The SP displays accented letters badly, so they are replaced (é becomes
--  e) and anything other than letters, digits and _ is removed.
-------------------------------------------------------------------------------

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

local function clean_name(s, fallback)
  s = tostring(s or "")
  s = s:gsub("%.%a%a%a%a?$", "")                     -- drop a file extension
  s = s:gsub("[\xC0-\xF4][\x80-\xBF]*", function(c) return TRANSLIT[c] or "" end)
  s = s:gsub("[%s%-%.]+", "_")
  s = s:gsub("[^%w_]", "")
  s = s:gsub("_+", "_")
  s = s:gsub("^_+", "")
  s = s:gsub("_+$", "")
  if s == "" then s = fallback or "Sample" end
  return s:sub(1, NAME_MAX)
end

-------------------------------------------------------------------------------
-- Small tools
-------------------------------------------------------------------------------

-- A length as "250 ms" or "1.25 s".
local function fmt_len(sec)
  if sec < 1 then return string.format("%d ms", math.floor(sec * 1000 + 0.5)) end
  return string.format("%.2f s", sec)
end

-- Decibels to a plain volume factor.
local function db_to_lin(db) return 10 ^ (db / 20) end

-- True if the file is there.
local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

-- A folder path without spaces or separator at its ends.
local function strip_dir(d) return (d:gsub("^%s+", ""):gsub("%s+$", ""):gsub("[/\\]+$", "")) end
-- The file name at the end of a path.
local function basename(p) return p:match("([^/\\]+)$") or p end

-- True if a file can be written in that folder.
local function dir_writable(dir)
  local probe = dir .. SEP .. ".sk_sp_probe"
  local f = io.open(probe, "wb")
  if not f then return false end
  f:close()
  os.remove(probe)
  return true
end

-- True for the accepted file types.
local function is_audio(path)
  local ext = path:match("%.(%w+)$")
  return ext and AUDIO_EXT[ext:lower()] or false
end

-- "01 Kick.wav" -> "Kick": chops from SK SP Chopper carry their number.
local function pad_name(raw)
  raw = tostring(raw or ""):gsub("%.%w+$", "")
  local num, rest = raw:match("^(%d%d)[%s_%-]+(.+)$")
  if num and tonumber(num) >= 1 and tonumber(num) <= PADS then raw = rest end
  return raw
end

-- Keeps the end of a path, whole folder names only.
local function short_path(p, max)
  if #p <= max then return p end
  local parts = {}
  for x in p:gmatch("[^/\\]+") do parts[#parts + 1] = x end
  local out = parts[#parts] or p
  for i = #parts - 1, 1, -1 do
    local c = parts[i] .. SEP .. out
    if #c + 4 > max then break end
    out = c
  end
  return "..." .. SEP .. out
end

-- Cuts a name that is too long for a pad.
local function shorten(s, n)
  if #s <= n then return s end
  return s:sub(1, n - 1) .. "."
end

-------------------------------------------------------------------------------
-- The kit
--
--  The kit is saved in the project, one line per pad, so it comes back with
--  the project and SK SP Chopper can add to it. A pad holds either an item
--  of the project or an audio file, whole or in part. Each line reads:
--    type, item or file, start in the file, length, speed, name
-------------------------------------------------------------------------------

local pads     = {}    -- the sixteen pads; an empty pad has nothing
local kit_name = ""
local last_rev  = nil  -- change counter: raised at each save, so each script
                       -- notices the other's changes
local last_proj = nil  -- project shown, to notice a change of project tab

-- A number written with enough decimals, or nothing.
local function fnum(v) return v and string.format("%.9f", v) or "" end

-- A pad as one line of text.
local function ser(p)
  if not p then return "" end
  return table.concat({ p.kind, p.ref, fnum(p.s), fnum(p.len), fnum(p.rate), p.name or "" }, "\t")
end

-- One line of text back to a pad.
local function deser(v)
  if not v or v == "" then return nil end
  local f = {}
  for x in (v .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = x end
  if f[1] ~= "item" and f[1] ~= "file" then return nil end
  if not f[2] or f[2] == "" then return nil end
  return {
    kind = f[1], ref = f[2],
    s = tonumber(f[3]), len = tonumber(f[4]), rate = tonumber(f[5]),
    name = f[6] or "",
  }
end

-- Reads a value saved in the project.
local function get_proj(key)
  local _, v = reaper.GetProjExtState(0, KIT_SECTION, key)
  return v or ""
end

-- Reads the kit from the project.
local function load_kit()
  for k = 1, PADS do pads[k] = deser(get_proj(("pad%02d"):format(k))) end
  kit_name = get_proj("kit_name")
  last_rev = get_proj("rev")
end

-- Saves the kit in the project and raises the change counter.
local function save_kit()
  for k = 1, PADS do
    reaper.SetProjExtState(0, KIT_SECTION, ("pad%02d"):format(k), ser(pads[k]))
  end
  reaper.SetProjExtState(0, KIT_SECTION, "kit_name", kit_name)
  local rev = tostring((tonumber(get_proj("rev")) or 0) + 1)
  reaper.SetProjExtState(0, KIT_SECTION, "rev", rev)
  last_rev = rev
end

-- Reloads when the project changes, or when SK SP Chopper has sent chops.
local function poll_kit()
  local proj = reaper.EnumProjects(-1)
  if proj ~= last_proj then
    last_proj = proj
    load_kit()
  elseif get_proj("rev") ~= last_rev then
    load_kit()
  end
end

-------------------------------------------------------------------------------
-- Where each pad's audio is
-------------------------------------------------------------------------------

-- Audio files, opened once and kept open while the script runs.
local src_cache = {}
local function file_source(path)
  local c = src_cache[path]
  if c then return c end
  if not file_exists(path) then return nil end
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil end
  local len = reaper.GetMediaSourceLength(src)
  if not len or len <= 0 then
    reaper.PCM_Source_Destroy(src)
    return nil
  end
  c = { src = src, len = len,
        ch = math.max(1, math.min(2, reaper.GetMediaSourceNumChannels(src))) }
  src_cache[path] = c
  return c
end

-- Finds an item of the project from its identifier. The list is rebuilt
-- whenever the project changes.
local guid_map, guid_sig = {}, nil
local function take_by_guid(guid)
  local sig = tostring(reaper.EnumProjects(-1)) .. "|" .. reaper.GetProjectStateChangeCount(0)
  if sig ~= guid_sig then
    guid_sig, guid_map = sig, {}
    for i = 0, reaper.CountMediaItems(0) - 1 do
      local it = reaper.GetMediaItem(0, i)
      for t = 0, reaper.CountTakes(it) - 1 do
        local tk = reaper.GetTake(it, t)
        if tk then
          local _, g = reaper.GetSetMediaItemTakeInfo_String(tk, "GUID", "", false)
          guid_map[g] = tk
        end
      end
    end
  end
  local tk = guid_map[guid]
  if tk and reaper.ValidatePtr2(0, tk, "MediaItem_Take*") then return tk end
  return nil
end

-- Length, channels and where the audio comes from, or why it is missing.
local function pad_info(p)
  if not p then return nil end
  if p.kind == "item" then
    local tk = take_by_guid(p.ref)
    if not tk then return { missing = "The item is no longer in the project." } end
    local item = reaper.GetMediaItemTake_Item(tk)
    local src  = reaper.GetMediaItemTake_Source(tk)
    return {
      take = tk, item = item,
      len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
      ch   = math.max(1, math.min(2, reaper.GetMediaSourceNumChannels(src))),
      from = "Item in the project",
    }
  end
  local c = file_source(p.ref)
  if not c then return { missing = "File not found: " .. basename(p.ref) } end
  local rate = (p.rate and p.rate > 0) and p.rate or 1
  local s    = p.s or 0
  local len  = p.len or math.max(0, (c.len - s) / rate)
  local from = basename(p.ref)
  if p.s or p.len then from = from .. ("  (part, from %.3f s)"):format(s) end
  return { file = c, len = len, ch = c.ch, s = s, rate = rate, from = from }
end

-------------------------------------------------------------------------------
-- Filling pads
-------------------------------------------------------------------------------

-- Puts files dropped from the Finder on the pads, from pad k on, in
-- alphabetical order.
local function assign_files(k, paths)
  table.sort(paths, function(a, b) return basename(a):lower() < basename(b):lower() end)
  local n, skipped = 0, 0
  for _, path in ipairs(paths) do
    if k > PADS then skipped = skipped + 1
    elseif is_audio(path) and file_source(path) then
      pads[k] = { kind = "file", ref = path, name = pad_name(basename(path)) }
      k, n = k + 1, n + 1
    else
      skipped = skipped + 1
    end
  end
  if n > 0 then save_kit() end
  return n, skipped
end

-- Puts the items selected in REAPER on the pads, from pad k on, in time order.
local function fill_from_selection(k)
  local list = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    local it = reaper.GetSelectedMediaItem(0, i)
    local tk = reaper.GetActiveTake(it)
    if tk and not reaper.TakeIsMIDI(tk) then
      list[#list + 1] = {
        tk  = tk,
        pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION"),
        tn  = reaper.GetMediaTrackInfo_Value(reaper.GetMediaItem_Track(it), "IP_TRACKNUMBER"),
      }
    end
  end
  table.sort(list, function(a, b)
    if math.abs(a.pos - b.pos) > 1e-9 then return a.pos < b.pos end
    return a.tn < b.tn
  end)

  local n = 0
  for _, e in ipairs(list) do
    if k > PADS then break end
    local _, g  = reaper.GetSetMediaItemTakeInfo_String(e.tk, "GUID", "", false)
    local _, nm = reaper.GetSetMediaItemTakeInfo_String(e.tk, "P_NAME", "", false)
    pads[k] = { kind = "item", ref = g, name = pad_name(nm) }
    k, n = k + 1, n + 1
  end
  if n > 0 then save_kit() end
  return n, #list
end

-------------------------------------------------------------------------------
-- Audition
-------------------------------------------------------------------------------

local pv = { h = nil, stop_at = nil }   -- what is being heard

-- Stops the pad being heard.
local function preview_stop()
  if pv.h then
    reaper.CF_Preview_Stop(pv.h)
    pv.h = nil
  end
  pv.stop_at = nil
end

-- Plays a pad (needs SWS).
local function preview_pad(k)
  preview_stop()
  if not reaper.CF_CreatePreview then return end
  local info = pad_info(pads[k])
  if not info or info.missing then return end

  local h
  if info.take then
    local tk   = info.take
    local src  = reaper.GetMediaItemTake_Source(tk)
    local vol  = reaper.GetMediaItemTakeInfo_Value(tk, "D_VOL")
               * reaper.GetMediaItemInfo_Value(info.item, "D_VOL")
    h = reaper.CF_CreatePreview(src)
    reaper.CF_Preview_SetValue(h, "D_PLAYRATE", reaper.GetMediaItemTakeInfo_Value(tk, "D_PLAYRATE"))
    reaper.CF_Preview_SetValue(h, "D_POSITION", reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS"))
    reaper.CF_Preview_SetValue(h, "D_VOLUME",   vol)
    if reaper.CF_Preview_SetOutputTrack then
      reaper.CF_Preview_SetOutputTrack(h, 0, reaper.GetMediaItem_Track(info.item))
    end
  else
    h = reaper.CF_CreatePreview(info.file.src)
    reaper.CF_Preview_SetValue(h, "D_PLAYRATE", info.rate)
    reaper.CF_Preview_SetValue(h, "D_POSITION", info.s)
  end
  reaper.CF_Preview_Play(h)
  pv.h = h
  pv.stop_at = reaper.time_precise() + info.len
end

-- Stops the pad when its end is reached.
local function preview_watch()
  if pv.stop_at and reaper.time_precise() >= pv.stop_at then preview_stop() end
end

-------------------------------------------------------------------------------
-- Temporary track
--
--  Audio files are read through a temporary item, like any other item, so
--  REAPER itself converts them to 48 kHz whatever their sample rate. These
--  items sit on a hidden, muted track that only exists during an export.
-------------------------------------------------------------------------------

local temp = nil   -- the temporary track, while it exists

-- Removes the temporary track.
local function temp_cleanup()
  if temp and reaper.ValidatePtr2(0, temp, "MediaTrack*") then reaper.DeleteTrack(temp) end
  temp = nil
end

-- Removes a temporary track left over if REAPER was closed during an export.
local function purge_temp_tracks()
  for i = reaper.CountTracks(0) - 1, 0, -1 do
    local tr = reaper.GetTrack(0, i)
    local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if nm == TEMP_TRACK then reaper.DeleteTrack(tr) end
  end
end

-- Creates the temporary item for an audio file, or a part of it.
local function temp_take(path, s, rate, len)
  if not temp then
    reaper.PreventUIRefresh(1)
    local idx = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(idx, false)
    temp = reaper.GetTrack(0, idx)
    reaper.GetSetMediaTrackInfo_String(temp, "P_NAME", TEMP_TRACK, true)
    reaper.SetMediaTrackInfo_Value(temp, "B_MUTE", 1)
    reaper.SetMediaTrackInfo_Value(temp, "B_SHOWINTCP", 0)
    reaper.SetMediaTrackInfo_Value(temp, "B_SHOWINMIXER", 0)
    reaper.PreventUIRefresh(-1)
  end
  local item = reaper.AddMediaItemToTrack(temp)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, reaper.PCM_Source_CreateFromFile(path))
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", s)
  reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", rate)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", 0)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", len)
  reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", 0)
  reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", 0)
  reaper.UpdateItemInProject(item)
  return take
end

-------------------------------------------------------------------------------
-- Where every file goes
-------------------------------------------------------------------------------

-- Folder name for the kit: its name, or SP_Kit.
local function kit_folder_name()
  local kit = clean_name(kit_name, "")
  if kit == "" then kit = "SP_Kit" end
  return kit
end

-- Folder the files go to.
local function out_dir()
  local dir = strip_dir(cfg.dest_dir)
  if dir == "" then return "" end
  return cfg.subfolder and (dir .. SEP .. kit_folder_name()) or dir
end

-- Files are numbered by pad, so 05 always means pad 5.
local function plan_export()
  local out = out_dir()
  local jobs, missing = {}, {}
  for k = 1, PADS do
    local p = pads[k]
    if p then
      local info = pad_info(p)
      if info.missing then
        missing[#missing + 1] = ("%02d"):format(k)
      else
        local file = ("%02d_%s.wav"):format(k, clean_name(p.name, "Sample"))
        jobs[#jobs + 1] = { k = k, p = p, info = info, file = file,
                            path = out .. SEP .. file }
      end
    end
  end
  return jobs, missing, out
end

-- Empty pads between filled ones.
local function gaps()
  local last = 0
  for k = 1, PADS do if pads[k] then last = k end end
  local g = {}
  for k = 1, last do if not pads[k] then g[#g + 1] = ("%02d"):format(k) end end
  return g
end

-------------------------------------------------------------------------------
-- WAV writing
-------------------------------------------------------------------------------

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
    "fmt ", 16, 1, nch, SR, SR * nch * 2, nch * 2, 16,
    "data", data)
end

-- Mono or stereo, as chosen in Channels.
local function out_channels(src_ch)
  if cfg.channels == 2 then return 1 end
  if cfg.channels == 3 then return 2 end
  return src_ch
end

-------------------------------------------------------------------------------
-- Export
--
--  The export runs a little at each refresh of the window, so REAPER stays
--  responsive and the progress bar moves. Each pad is read twice: once to
--  measure it, once to write its file.
-------------------------------------------------------------------------------

local COL_OK   = 0x88FF88FF
local COL_WARN = 0xE6B75AFF
local COL_ERR  = 0xE05A4AFF

local job    = nil   -- the export in progress
local report = nil   -- lines shown after an export

-- Where to read a pad's sound, with its volume and fades.
local function job_source(j)
  local info = j.info
  if info.take then
    if not reaper.ValidatePtr2(0, info.take, "MediaItem_Take*") then return nil end
    return {
      take = info.take, ch = info.ch, len = info.len,
      vol      = reaper.GetMediaItemInfo_Value(info.item, "D_VOL"),
      fade_in  = reaper.GetMediaItemInfo_Value(info.item, "D_FADEINLEN"),
      fade_out = reaper.GetMediaItemInfo_Value(info.item, "D_FADEOUTLEN"),
    }
  end
  if not file_exists(j.p.ref) then return nil end
  return {
    take = temp_take(j.p.ref, info.s, info.rate, info.len),
    ch = info.ch, len = info.len, vol = 1, fade_in = 0, fade_out = 0,
  }
end

-- First reading: loudest point, and where the sound starts and stops.
local function scan_begin(j)
  local e = j.src
  return {
    kind  = "scan", j = j,
    nch   = e.ch,
    mix   = (out_channels(e.ch) == 1 and e.ch == 2),
    total = math.max(0, math.floor(e.len * SR + 0.5)),
    thr   = db_to_lin(cfg.trim_db),
    peak  = 0, first = nil, last = nil, got = 0, pos = 0,
    acc   = reaper.CreateTakeAudioAccessor(e.take),
  }
end

-- Measures the next part of the pad, for a short moment. True when done.
local function scan_step(s, buf, deadline)
  local nch, mix, thr = s.nch, s.mix, s.thr
  while s.pos < s.total do
    local n = math.min(BLOCK, s.total - s.pos)
    buf.clear()
    local rv = reaper.GetAudioAccessorSamples(s.acc, SR, nch, s.pos / SR, n, buf)
    if rv and rv > 0 then s.got = s.got + 1 end
    local t = buf.table(1, n * nch)
    local peak, first, last, pos = s.peak, s.first, s.last, s.pos
    for f = 0, n - 1 do
      local i = f * nch + 1
      local x = t[i] or 0
      local a
      if nch == 1 then a = math.abs(x)
      elseif mix  then a = math.abs((x + (t[i + 1] or 0)) * 0.5)
      else
        a = math.abs(x)
        local b = math.abs(t[i + 1] or 0)
        if b > a then a = b end
      end
      if a > peak then peak = a end
      if a > thr then
        if not first then first = pos + f end
        last = pos + f
      end
    end
    s.peak, s.first, s.last = peak, first, last
    s.pos = s.pos + n
    job.done = job.done + n
    if reaper.time_precise() >= deadline then return false end
  end

  reaper.DestroyAudioAccessor(s.acc)
  s.acc = nil

  local j, e = s.j, s.j.src
  -- Never write silence in place of audio that could not be read.
  if s.total > 0 and (s.got == 0 or s.peak == 0) then j.unreadable = true return true end

  j.peak = s.peak * e.vol
  if cfg.trim then
    if not s.first then j.silent = true return true end
    j.start = math.max(0, s.first - math.floor(PRE_ROLL * SR))
    j.stop  = math.min(s.total, s.last + 1 + math.floor(POST_ROLL * SR))
  else
    j.start, j.stop = 0, s.total
  end
  if j.stop <= j.start then j.silent = true end
  return true
end

-- Second reading: volume, fades, mono or stereo, dither, then the 16-bit file.
local function write_begin(j, gain)
  local e      = j.src
  local och    = out_channels(e.ch)
  local frames = j.stop - j.start

  local f, err = io.open(j.path, "wb")
  if not f then return nil, err end
  f:write(wav_header(och, frames))

  -- The longer of the item's own fade and the anti-click fade.
  local half = math.floor(frames / 2)
  return {
    kind = "write", j = j, f = f,
    nch = e.ch, och = och, frames = frames, gain = gain,
    fin  = math.min(half, math.floor(math.max(cfg.fade_ms / 1000, e.fade_in)  * SR)),
    fout = math.min(half, math.floor(math.max(cfg.fade_ms / 1000, e.fade_out) * SR)),
    dither = cfg.dither, out = {}, clipped = 0, pos = j.start,
    acc = reaper.CreateTakeAudioAccessor(e.take),
  }
end

-- Writes the next part of the file, for a short moment. True when done.
local function write_step(s, buf, deadline)
  local j = s.j
  local nch, och, frames, gain = s.nch, s.och, s.frames, s.gain
  local fin, fout, dither = s.fin, s.fout, s.dither
  local rnd, floor, out = math.random, math.floor, s.out

  while s.pos < j.stop do
    local n = math.min(BLOCK, j.stop - s.pos)
    buf.clear()
    reaper.GetAudioAccessorSamples(s.acc, SR, nch, s.pos / SR, n, buf)
    local t = buf.table(1, n * nch)
    local k, clipped = 0, s.clipped
    for fr = 0, n - 1 do
      local idx = s.pos - j.start + fr
      local g   = gain
      if idx < fin then g = g * idx / fin end
      local rem = frames - 1 - idx
      if rem < fout then g = g * rem / fout end

      local i = fr * nch + 1
      local l = t[i] or 0
      local r = (nch == 2) and (t[i + 1] or 0) or l
      local a, b
      if och == 1 then a = (nch == 2) and (l + r) * 0.5 or l
      else a, b = l, r end

      for c = 1, och do
        local v = ((c == 1) and a or b) * g * 32767
        if dither then v = v + rnd() - rnd() end    -- dither: very light noise
        local q = floor(v + 0.5)
        if q > 32767 then q = 32767; clipped = clipped + 1
        elseif q < -32768 then q = -32768; clipped = clipped + 1 end
        k = k + 1
        out[k] = q
      end
    end
    s.clipped = clipped
    s.f:write(pack16(out, k))
    s.pos = s.pos + n
    job.done = job.done + n
    if reaper.time_precise() >= deadline then return false end
  end

  reaper.DestroyAudioAccessor(s.acc)
  s.acc = nil
  s.f:close()
  s.f = nil
  j.clipped = s.clipped
  return true
end

-- Closes what an interrupted export left open.
local function release_op(op)
  if not op then return end
  if op.acc then reaper.DestroyAudioAccessor(op.acc); op.acc = nil end
  if op.f then op.f:close(); op.f = nil end
end

-- The report shown after the export.
local function summarise(jobs, written, out)
  local lines = {}
  local short, silent, clipped, failed, unread = {}, {}, {}, {}, {}
  for _, j in ipairs(jobs) do
    local lbl = ("%02d"):format(j.k)
    if j.missing or j.error then failed[#failed + 1] = lbl
    elseif j.unreadable then unread[#unread + 1] = lbl
    elseif j.silent then silent[#silent + 1] = lbl
    else
      if (j.stop - j.start) / SR < MIN_LEN then short[#short + 1] = lbl end
      if (j.clipped or 0) > 0 then clipped[#clipped + 1] = lbl end
    end
  end

  if #written > 0 then
    lines[#lines + 1] = { ("%d sample%s written to %s"):format(
      #written, #written > 1 and "s" or "", out), COL_OK }
  end
  if #short > 0 then
    lines[#lines + 1] = { "Under 100 ms, the SP may refuse them: pads " .. table.concat(short, " "), COL_WARN }
  end
  if #silent > 0 then
    lines[#lines + 1] = { "Skipped, silent below the trim threshold: pads " .. table.concat(silent, " "), COL_WARN }
  end
  if #clipped > 0 then
    lines[#lines + 1] = { "Clipped, lower the level or normalise: pads " .. table.concat(clipped, " "), COL_WARN }
  end
  if #unread > 0 then
    lines[#lines + 1] = { "No audio could be read, nothing written: pads " .. table.concat(unread, " "), COL_ERR }
  end
  if #failed > 0 then
    lines[#lines + 1] = { "Not written (source gone or file locked): pads " .. table.concat(failed, " "), COL_ERR }
  end
  return { lines = lines, folder = (#written > 0) and out or nil }
end

-- Prepares the export of the planned files.
local function start_export(jobs, out)
  local work = 0
  for _, j in ipairs(jobs) do work = work + 2 * math.floor(j.info.len * SR + 0.5) end
  report = nil
  job = {
    jobs = jobs, out = out, i = 1, phase = "scan", label = "Analysing",
    done = 0, total = math.max(1, work),
    buf = reaper.new_array(BLOCK * 2), written = {}, made = false,
    kit_peak = 0, target = db_to_lin(cfg.norm_target),
  }
end

-- Does a small part of the export: a piece of the current pad, or moving on
-- to the next pad.
local function job_tick(deadline)
  local J = job
  if J.op then
    local op = J.op
    local fin
    if op.kind == "scan" then fin = scan_step(op, J.buf, deadline)
    else fin = write_step(op, J.buf, deadline) end
    if fin then
      if op.kind == "write" then J.written[#J.written + 1] = op.j end
      J.op = nil
      J.i = J.i + 1
    end
    return
  end

  local j = J.jobs[J.i]
  if J.phase == "scan" then
    if not j then
      for _, x in ipairs(J.jobs) do
        if not x.missing and not x.silent and not x.unreadable and x.peak > J.kit_peak then
          J.kit_peak = x.peak
        end
      end
      J.phase, J.label, J.i = "write", "Writing", 1
      return
    end
    j.src = job_source(j)
    if j.src then J.op = scan_begin(j) else j.missing = true; J.i = J.i + 1 end
    return
  end

  if not j then
    J.result   = summarise(J.jobs, J.written, J.out)
    J.finished = true
    return
  end
  if j.missing or j.silent or j.unreadable then J.i = J.i + 1 return end
  if not reaper.ValidatePtr2(0, j.src.take, "MediaItem_Take*") then
    j.missing = true
    J.i = J.i + 1
    return
  end

  if not J.made then
    reaper.RecursiveCreateDirectory(J.out, 0)
    J.made = true
  end
  -- The loudest point already takes the item volume into account.
  local gain = j.src.vol
  if cfg.norm_mode == 2 and j.peak > 0 then
    gain = gain * J.target / j.peak
  elseif cfg.norm_mode == 3 and J.kit_peak > 0 then
    gain = gain * J.target / J.kit_peak
  end
  local op, err = write_begin(j, gain)
  if op then J.op = op else j.error = err or "write failed"; J.i = J.i + 1 end
end

-- Called at each refresh of the window while an export runs.
local function run_job()
  if not job then return end
  local deadline = reaper.time_precise() + BUDGET
  local ok, err = pcall(function()
    repeat job_tick(deadline)
    until job.finished or reaper.time_precise() >= deadline
  end)
  if not ok then
    release_op(job.op)
    temp_cleanup()
    report = { lines = { { "Export failed: " .. tostring(err), COL_ERR } } }
    job = nil
  elseif job.finished then
    temp_cleanup()
    report = job.result
    job = nil
  end
end

-- Stops an export, when the window closes.
local function abort_job()
  if job then
    release_op(job.op)
    job = nil
  end
  temp_cleanup()
end

-- Checks before writing: files that would be replaced, and other WAV files
-- in the folder, which the SP would import along with the kit.
local pending        = nil     -- export waiting for confirmation
local open_overwrite = false   -- asks to show the confirmation window

local function request_export()
  local dir = strip_dir(cfg.dest_dir)
  if dir == "" then
    report = { lines = { { "Choose the destination folder first.", COL_ERR } } }
    return
  end
  if not dir_writable(dir) then
    report = { lines = { { "Cannot write to that folder. Is the SD card mounted?", COL_ERR } } }
    return
  end
  local jobs, missing, out = plan_export()
  if #jobs == 0 then
    report = { lines = { { "No pad can be exported.", COL_ERR } } }
    return
  end
  save_cfg()

  local mine, clash = {}, 0
  for _, j in ipairs(jobs) do
    mine[j.file:lower()] = true
    if file_exists(j.path) then clash = clash + 1 end
  end
  local others = 0
  if cfg.subfolder then
    local i = 0
    while true do
      local fn = reaper.EnumerateFiles(out, i)
      if not fn then break end
      if fn:lower():match("%.wav$") and not mine[fn:lower()] then others = others + 1 end
      i = i + 1
    end
  end

  if clash > 0 or others > 0 or #missing > 0 then
    pending = { jobs = jobs, out = out, clash = clash, others = others, missing = missing }
    open_overwrite = true
  else
    start_export(jobs, out)
  end
end

-------------------------------------------------------------------------------
-- Interface
-------------------------------------------------------------------------------

local ctx = reaper.ImGui_CreateContext("Studio Kozak SP Kit Builder")

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

local COL_CELL_OFF = 0x212429FF   -- empty pad
local COL_PAD      = 0x30343BFF   -- filled pad
local COL_SHORT    = 0x882222FF   -- sample too short for the SP
local COL_MISSING  = 0x5A2A2AFF   -- sample whose source is gone

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
  { reaper.ImGui_Col_PlotHistogram(),    COL_ACCENT   },
  { reaper.ImGui_Col_DragDropTarget(),   COL_ACCENT_H },
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

-- Grey section title.
local function sectionLabel(txt)
  reaper.ImGui_TextDisabled(ctx, txt)
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

-- A drop-down list that shows its own label ("Channels: Mono"), so no text
-- is needed beside it.
local function combo(id, idx, labels, width, prefix)
  reaper.ImGui_SetNextItemWidth(ctx, width)
  if reaper.ImGui_BeginCombo(ctx, id, (prefix or "") .. (labels[idx] or "")) then
    for i, l in ipairs(labels) do
      if reaper.ImGui_Selectable(ctx, l, i == idx) then idx = i end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  return idx
end

local CHANNEL_LABELS = { "Keep source", "Mono", "Stereo" }
local NORM_LABELS    = { "Off", "Per sample", "Whole kit" }

-------------------------------------------------------------------------------
-- Pads
-------------------------------------------------------------------------------

local sel        = 1       -- selected pad
local status, status_col, status_time = "", nil, 0   -- message at the bottom
local open_clear = false   -- asks to show the "Clear the kit?" window
local _                    -- receives values that are not needed

-- Shows a message at the bottom of the window.
local function set_status(msg, col)
  status, status_col, status_time = msg, col, reaper.time_precise()
end

-- Files dropped from the Finder on pad k.
local function drop_files_on(k)
  local ok, count = reaper.ImGui_AcceptDragDropPayloadFiles(ctx)
  if not ok then return end
  local list = {}
  for i = 0, count - 1 do
    local rv, fn = reaper.ImGui_GetDragDropPayloadFile(ctx, i)
    if rv and fn and fn ~= "" then list[#list + 1] = fn end
  end
  local n, skipped = assign_files(k, list)
  sel = k
  if n > 0 then
    local msg = (n == 1) and ("Pad %02d filled."):format(k)
                          or ("Pads %02d to %02d filled."):format(k, k + n - 1)
    if skipped > 0 then msg = msg .. ("  %d file(s) left out: not audio, or no pad left."):format(skipped) end
    set_status(msg, skipped > 0 and COL_WARN or COL_OK)
  else
    set_status("No usable audio file in what was dropped.", COL_ERR)
  end
end

-- Draws pad k and handles clicks, drags and its right-click menu.
local function draw_pad(k)
  local p    = pads[k]
  local info = pad_info(p)
  reaper.ImGui_PushID(ctx, k)

  local col, label
  if not p then
    col   = COL_CELL_OFF
    label = ("%02d"):format(k)
  else
    if k == sel then col = COL_ACCENT
    elseif info.missing then col = COL_MISSING
    elseif info.len < MIN_LEN then col = COL_SHORT
    else col = COL_PAD end
    local len = info.missing and "missing" or fmt_len(info.len)
    label = ("%02d\n%s\n%s"):format(k, shorten(p.name ~= "" and p.name or "(no name)", 12), len)
  end
  if not p and k == sel then col = 0x3A3428FF end

  if colouredButton(label .. "##pad", col, PAD_W, PAD_H) then
    sel = k
    if p then preview_pad(k) end
  end

  -- Drag a pad onto another to swap them.
  if p and reaper.ImGui_BeginDragDropSource(ctx) then
    reaper.ImGui_SetDragDropPayload(ctx, "SK_SP_PAD", tostring(k))
    reaper.ImGui_Text(ctx, ("Pad %02d  %s"):format(k, p.name))
    reaper.ImGui_EndDragDropSource(ctx)
  end
  if reaper.ImGui_BeginDragDropTarget(ctx) then
    local ok, payload = reaper.ImGui_AcceptDragDropPayload(ctx, "SK_SP_PAD")
    if ok then
      local from = tonumber(payload)
      if from and from ~= k then
        pads[from], pads[k] = pads[k], pads[from]
        sel = k
        save_kit()
      end
    end
    drop_files_on(k)
    reaper.ImGui_EndDragDropTarget(ctx)
  end

  if reaper.ImGui_BeginPopupContextItem(ctx, "padmenu") then
    sel = k
    if p and reaper.ImGui_MenuItem(ctx, "Play") then preview_pad(k) end
    if reaper.ImGui_MenuItem(ctx, ("Put selected items from pad %02d"):format(k)) then
      local n, total = fill_from_selection(k)
      if n == 0 then set_status("No audio item selected in REAPER.", COL_ERR) end
      if n < total then set_status(("%d item(s) did not fit."):format(total - n), COL_WARN) end
    end
    if p and reaper.ImGui_MenuItem(ctx, "Clear pad") then
      pads[k] = nil
      save_kit()
    end
    reaper.ImGui_EndPopup(ctx)
  end

  reaper.ImGui_PopID(ctx)
end

-- What the selected pad holds, and what can be done with it. Text on top,
-- buttons level with the bottom row of pads.
local function draw_side()
  local p    = pads[sel]
  local info = pad_info(p)
  local top  = reaper.ImGui_GetCursorPosY(ctx)

  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_TextColored(ctx, COL_ACCENT, ("PAD %02d"):format(sel))
  reaper.ImGui_SameLine(ctx, 0, 10)
  if not p then
    reaper.ImGui_TextDisabled(ctx, "empty")
  elseif info.missing then
    reaper.ImGui_TextColored(ctx, COL_ERR, "source missing")
  else
    reaper.ImGui_Text(ctx, fmt_len(info.len))
    reaper.ImGui_SameLine(ctx, 0, 10)
    reaper.ImGui_TextDisabled(ctx, info.ch == 1 and "mono" or "stereo")
  end

  reaper.ImGui_PushTextWrapPos(ctx, reaper.ImGui_GetCursorPosX(ctx) + HALF_W)
  if p then
    reaper.ImGui_SetNextItemWidth(ctx, HALF_W)
    local chg, v = reaper.ImGui_InputTextWithHint(ctx, "##padname", "pad name", p.name)
    if chg then p.name = v end
    if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then save_kit() end
    reaper.ImGui_TextDisabled(ctx, ("File   %02d_%s.wav"):format(sel, clean_name(p.name, "Sample")))
    if info.missing then
      reaper.ImGui_TextColored(ctx, COL_ERR, info.missing)
    else
      reaper.ImGui_TextDisabled(ctx, "From   " .. info.from)
      if info.len < MIN_LEN then
        reaper.ImGui_TextColored(ctx, COL_ERR, "Under 100 ms: the SP may refuse it.")
      end
    end
  else
    reaper.ImGui_TextDisabled(ctx,
      "Drop audio files on a pad from the Finder, send chops from SK SP Chopper, " ..
      "or add the items selected in REAPER.")
  end
  reaper.ImGui_PopTextWrapPos(ctx)

  -- Buttons
  reaper.ImGui_SetCursorPosY(ctx, top + GRID_H - 2 * BTN_H - GAP)

  local can_play = p and not info.missing and reaper.CF_CreatePreview
  if not can_play then reaper.ImGui_BeginDisabled(ctx) end
  if reaper.ImGui_Button(ctx, "PLAY", COL_W, BTN_H) then preview_pad(sel) end
  if not can_play then reaper.ImGui_EndDisabled(ctx) end
  if not reaper.CF_CreatePreview and reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
    reaper.ImGui_SetTooltip(ctx, "Install SWS to hear the pads.")
  end
  reaper.ImGui_SameLine(ctx)
  if not p then reaper.ImGui_BeginDisabled(ctx) end
  if reaper.ImGui_Button(ctx, "CLEAR PAD", COL_W, BTN_H) then
    preview_stop()
    pads[sel] = nil
    save_kit()
  end
  if not p then reaper.ImGui_EndDisabled(ctx) end

  local nsel = reaper.CountSelectedMediaItems(0)
  if nsel == 0 then reaper.ImGui_BeginDisabled(ctx) end
  if reaper.ImGui_Button(ctx, ("ADD %d SELECTED ITEM%s"):format(nsel, nsel == 1 and "" or "S"),
      COL_W, BTN_H) then
    local n, total = fill_from_selection(sel)
    if n < total then
      set_status(("%d item(s) did not fit after pad 16."):format(total - n), COL_WARN)
    else
      set_status(("%d pad(s) filled from the selected items."):format(n), COL_OK)
    end
  end
  if nsel == 0 then reaper.ImGui_EndDisabled(ctx) end
  if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
    reaper.ImGui_SetTooltip(ctx, ("Fills the pads in time order, from pad %02d on.\n" ..
      "Pads already filled are replaced."):format(sel))
  end
  reaper.ImGui_SameLine(ctx)
  local used = 0
  for k = 1, PADS do if pads[k] then used = used + 1 end end
  if used == 0 then reaper.ImGui_BeginDisabled(ctx) end
  if reaper.ImGui_Button(ctx, "CLEAR KIT", COL_W, BTN_H) then open_clear = true end
  if used == 0 then reaper.ImGui_EndDisabled(ctx) end
end

-------------------------------------------------------------------------------
-- Main loop
-------------------------------------------------------------------------------

-- Runs at every refresh of the window.
local function loop()
  poll_kit()
  run_job()
  preview_watch()

  if status ~= "" and status_col ~= COL_OK and reaper.time_precise() - status_time > 6 then
    status = ""
  end

  pushTheme()
  reaper.ImGui_SetNextWindowSize(ctx, 800, 640, reaper.ImGui_Cond_FirstUseEver())
  local visible, open = reaper.ImGui_Begin(ctx, "SK SP Kit Builder", true,
    reaper.ImGui_WindowFlags_AlwaysAutoResize())

  if visible then

    -- Title, with the subtitle aligned on its bottom
    local y0 = reaper.ImGui_GetCursorPosY(ctx)
    PushFont(fontTitle, FONT_TITLE)
    local h_big = reaper.ImGui_GetTextLineHeight(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_ACCENT)
    reaper.ImGui_Text(ctx, "SK SP KIT BUILDER")
    reaper.ImGui_PopStyleColor(ctx)
    PopFont()
    local h_small = reaper.ImGui_GetTextLineHeight(ctx)
    reaper.ImGui_SameLine(ctx, 0, 16)
    reaper.ImGui_SetCursorPosY(ctx, y0 + (h_big - h_small) * 0.80)
    reaper.ImGui_TextDisabled(ctx, "for Roland SP-404MKII  ·  48 kHz / 16-bit WAV")
    reaper.ImGui_Dummy(ctx, 0, 2)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Dummy(ctx, 0, 2)

    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), GAP, GAP)

    local busy = (job ~= nil)
    if busy then reaper.ImGui_BeginDisabled(ctx) end

    -- Kit name on the left half, pad count on the right
    reaper.ImGui_SetNextItemWidth(ctx, HALF_W)
    local kchg, kval = reaper.ImGui_InputTextWithHint(ctx, "##kit", "kit name", kit_name)
    if kchg then kit_name = kval end
    if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then save_kit() end
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    local used = 0
    for k = 1, PADS do if pads[k] then used = used + 1 end end
    reaper.ImGui_TextDisabled(ctx, ("%d / %d pads"):format(used, PADS))
    local g = gaps()
    if #g > 0 then
      reaper.ImGui_SameLine(ctx, 0, 14)
      reaper.ImGui_TextColored(ctx, COL_WARN, "empty between: " .. table.concat(g, " "))
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
          "Empty pads between filled ones. A multi-select import on the SP\n" ..
          "fills pads one after another, so the samples after a gap would\n" ..
          "land one pad earlier than here.")
      end
    end

    -- Pads on the left half, the selected pad on the right
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 4, 2)
    reaper.ImGui_BeginGroup(ctx)
    for r = 0, 3 do
      for c = 0, 3 do
        if c > 0 then reaper.ImGui_SameLine(ctx) end
        draw_pad(r * 4 + c + 1)
      end
    end
    reaper.ImGui_EndGroup(ctx)
    reaper.ImGui_PopStyleVar(ctx)

    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_BeginGroup(ctx)
    draw_side()
    reaper.ImGui_EndGroup(ctx)

    reaper.ImGui_Dummy(ctx, 0, 2)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Dummy(ctx, 0, 2)

    -- Section titles on one line, so both blocks below start level
    local pad_x = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding())
    sectionLabel("PROCESSING")
    reaper.ImGui_SameLine(ctx, pad_x + HALF_W + GAP)
    sectionLabel("DESTINATION")

    -- Processing on the left half: two columns, three rows
    reaper.ImGui_BeginGroup(ctx)
    cfg.channels = combo("##channels", cfg.channels, CHANNEL_LABELS, COL_W, "Channels: ")
    reaper.ImGui_SameLine(ctx)
    cfg.norm_mode = combo("##norm", cfg.norm_mode, NORM_LABELS, COL_W, "Normalise: ")

    local fh = reaper.ImGui_GetFrameHeight(ctx)
    _, cfg.trim = reaper.ImGui_Checkbox(ctx, "##trim", cfg.trim)
    if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, "Trim the silence at both ends") end
    reaper.ImGui_SameLine(ctx)
    if not cfg.trim then reaper.ImGui_BeginDisabled(ctx) end
    reaper.ImGui_SetNextItemWidth(ctx, COL_W - fh - GAP)
    _, cfg.trim_db = reaper.ImGui_SliderInt(ctx, "##trimdb", cfg.trim_db, -90, -20, "trim below %d dB")
    if not cfg.trim then reaper.ImGui_EndDisabled(ctx) end
    reaper.ImGui_SameLine(ctx)
    if cfg.norm_mode == 1 then reaper.ImGui_BeginDisabled(ctx) end
    reaper.ImGui_SetNextItemWidth(ctx, COL_W)
    _, cfg.norm_target = reaper.ImGui_SliderDouble(ctx, "##target", cfg.norm_target,
      -12, 0, "peak %.1f dBFS")
    if cfg.norm_mode == 1 then reaper.ImGui_EndDisabled(ctx) end

    reaper.ImGui_SetNextItemWidth(ctx, COL_W)
    _, cfg.fade_ms = reaper.ImGui_SliderDouble(ctx, "##fade", cfg.fade_ms, 0, 20, "fades %.1f ms")
    reaper.ImGui_SameLine(ctx)
    _, cfg.dither = reaper.ImGui_Checkbox(ctx, "TPDF dither", cfg.dither)
    reaper.ImGui_EndGroup(ctx)

    -- Destination on the right half, same three rows
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_BeginGroup(ctx)
    local BROWSE_W = 100
    local has_browse = reaper.JS_Dialog_BrowseForFolder ~= nil
    reaper.ImGui_SetNextItemWidth(ctx, has_browse and (HALF_W - BROWSE_W - GAP) or HALF_W)
    local dchg, dval = reaper.ImGui_InputTextWithHint(ctx, "##dest",
      "folder, e.g. IMPORT on the SD card", cfg.dest_dir)
    if dchg then cfg.dest_dir = dval end
    if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then save_cfg() end
    if has_browse then
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "BROWSE", BROWSE_W, 0) then
        local rv, folder = reaper.JS_Dialog_BrowseForFolder("Choose where to export the kit", cfg.dest_dir)
        if rv == 1 and folder and folder ~= "" then
          cfg.dest_dir = folder
          save_cfg()
        end
      end
    end
    _, cfg.subfolder = reaper.ImGui_Checkbox(ctx, "Kit in its own folder", cfg.subfolder)
    local out = out_dir()
    reaper.ImGui_AlignTextToFramePadding(ctx)
    if out == "" then
      reaper.ImGui_TextDisabled(ctx, has_browse
        and "For the SP, pick the IMPORT folder of the card."
        or  "Finder: select the folder, Option+Cmd+C, paste.")
    else
      reaper.ImGui_TextDisabled(ctx, "To   " .. short_path(out, 52))
      if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, out) end
    end
    reaper.ImGui_EndGroup(ctx)

    if busy then reaper.ImGui_EndDisabled(ctx) end

    reaper.ImGui_Dummy(ctx, 0, 2)

    -- Export, full width
    if job then
      local frac = math.min(1, job.done / job.total)
      reaper.ImGui_ProgressBar(ctx, frac, W, ACT_H,
        ("%s  %d %%"):format(job.label, math.floor(frac * 100)))
    else
      local jobs  = plan_export()
      local ready = (#jobs > 0) and (out ~= "")
      local label
      if #jobs == 0 then label = "EXPORT KIT  ·  FILL AT LEAST ONE PAD"
      elseif out == "" then label = "EXPORT KIT  ·  CHOOSE A DESTINATION"
      else label = ("EXPORT KIT  ·  %d SAMPLE%s"):format(#jobs, #jobs > 1 and "S" or "") end
      if not ready then reaper.ImGui_BeginDisabled(ctx) end
      PushFont(fontBtn, FONT_BTN)
      if accentButton(label, W, ACT_H) then request_export() end
      PopFont()
      if not ready then reaper.ImGui_EndDisabled(ctx) end
    end

    -- Report
    if report then
      for _, l in ipairs(report.lines) do
        reaper.ImGui_TextColored(ctx, l[2], l[1])
      end
      if report.folder and reaper.CF_ShellExecute then
        if reaper.ImGui_Button(ctx, "OPEN FOLDER", COL_W, BTN_H) then reaper.CF_ShellExecute(report.folder) end
      end
    end
    if status ~= "" then
      reaper.ImGui_TextColored(ctx, status_col or COL_ACCENT, status)
    end

    reaper.ImGui_PopStyleVar(ctx)

    -- Export confirmation
    if open_overwrite then
      reaper.ImGui_OpenPopup(ctx, "Export kit?")
      open_overwrite = false
    end
    if reaper.ImGui_BeginPopupModal(ctx, "Export kit?", nil,
        reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
      if pending then
        if pending.clash > 0 then
          reaper.ImGui_Text(ctx, ("%d file%s with the same name will be replaced."):format(
            pending.clash, pending.clash > 1 and "s" or ""))
        end
        if pending.others > 0 then
          reaper.ImGui_TextColored(ctx, COL_WARN, ("%d other WAV file%s already in this folder:"):format(
            pending.others, pending.others > 1 and "s are" or " is"))
          reaper.ImGui_TextColored(ctx, COL_WARN, "the SP would import them along with the kit.")
        end
        if #pending.missing > 0 then
          reaper.ImGui_TextColored(ctx, COL_ERR, "Source missing, skipped: pads " ..
            table.concat(pending.missing, " "))
        end
        reaper.ImGui_Spacing(ctx)
        if accentButton("EXPORT", 140, 0) then
          start_export(pending.jobs, pending.out)
          pending = nil
          reaper.ImGui_CloseCurrentPopup(ctx)
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "CANCEL", 140, 0) then
          pending = nil
          reaper.ImGui_CloseCurrentPopup(ctx)
        end
      else
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      reaper.ImGui_EndPopup(ctx)
    end

    -- Clear confirmation
    if open_clear then
      reaper.ImGui_OpenPopup(ctx, "Clear the kit?")
      open_clear = false
    end
    if reaper.ImGui_BeginPopupModal(ctx, "Clear the kit?", nil,
        reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
      reaper.ImGui_Text(ctx, "Empty all sixteen pads? Items and files are not touched.")
      reaper.ImGui_Spacing(ctx)
      if accentButton("CLEAR", 140, 0) then
        preview_stop()
        for k = 1, PADS do pads[k] = nil end
        save_kit()
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "CANCEL", 140, 0) then reaper.ImGui_CloseCurrentPopup(ctx) end
      reaper.ImGui_EndPopup(ctx)
    end

    reaper.ImGui_End(ctx)
  end

  popTheme()

  if open then reaper.defer(loop) end
end

-- When the window closes: stop playback and any export, close the audio
-- files, save the settings.
reaper.atexit(function()
  preview_stop()
  abort_job()
  for _, c in pairs(src_cache) do reaper.PCM_Source_Destroy(c.src) end
  save_cfg()
end)

purge_temp_tracks()
reaper.defer(loop)
