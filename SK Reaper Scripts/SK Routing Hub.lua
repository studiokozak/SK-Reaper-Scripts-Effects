-- =============================================================================
--  SK Routing Hub
--  Studio Kozak — Stéphan Jedrasiak
-- =============================================================================

local SCRIPT_NAME = "SK Routing Hub v1.0.1"
local WIN_W, WIN_H = 960, 720
local COL_LEFT_W   = 290

-- I_SENDMODE : 0=Post-Fader(Post-Pan)  3=Pre-Fader(Post-FX)  1=Pre-Fader(Pre-FX)
local SM_LABELS = { "Post-Fader (Post-Pan)", "Pre-Fader (Post-FX)", "Pre-Fader (Pre-FX)" }
local SM_VALS   = { 0, 3, 1 }
local function sm_to_idx(v)
  v = math.floor(v)
  for i, val in ipairs(SM_VALS) do if val == v then return i end end
  return 1
end

local function enc_srcchan(pair_1based)
  return (pair_1based - 1) * 2
end
local function dec_srcchan(raw)
  raw = math.floor(raw)
  if raw >= 1024 then raw = raw - 1024 end
  local pair = math.floor(raw / 2) + 1
  return pair
end

-- I_DSTCHAN : premier canal destination (0-based)
local function enc_dstchan(pair_1based) return (pair_1based - 1) * 2 end
local function dec_dstchan(raw) return math.floor(math.floor(raw) / 2) + 1 end

local MAX_PAIRS = 64

local function pairs_combo_str()
  local t = {}
  for i = 1, MAX_PAIRS do t[#t+1] = string.format("%d-%d", (i-1)*2+1, (i-1)*2+2) end
  return table.concat(t, "\0") .. "\0"
end

local PAIRS_STR = pairs_combo_str()  -- pré-calculé une fois
local SM_STR    = table.concat(SM_LABELS, "\0") .. "\0"

-- ============================================================
--  CONTEXTE IMGUI
-- ============================================================
local ctx  = reaper.ImGui_CreateContext(SCRIPT_NAME)
local font = reaper.ImGui_CreateFont("sans-serif", 13)
reaper.ImGui_Attach(ctx, font)

-- ============================================================
--  PALETTE
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
  send_col   = 0x3A7A5AFF,
  recv_col   = 0x5A4A8AFF,
  vca_col    = 0x8A6A2AFF,
  folder_col = 0x5A3A2AFF,
  danger     = 0x8A2A2AFF,
  danger_hov = 0xAA3A3AFF,
  mute_on    = 0x9A6A00FF,
  mute_txt   = 0xFFCC44FF,
  phase_on   = 0x7A2A5AFF,
  phase_txt  = 0xFFAADDFF,
  mono_on    = 0x2A5A9AFF,
  sep        = 0x2E2E2EFF,
  new_trk    = 0x2A5A2AFF,
  new_trk_h  = 0x3A7A3AFF,
  chk_dst    = 0x3A6A3AFF,  -- destination cochée
}

-- ============================================================
--  ÉTAT
-- ============================================================
local state = {
  sel_tracks      = {},
  focused_track   = nil,   -- track active dans colonne gauche
  last_sel_count  = -1,
  last_proj_state = -1,
  status_msg      = "",
  status_timer    = 0,
  confirm_delete  = nil,   -- { track_ptr, name } en attente de confirmation
  bulk_edit_sends  = false,  -- edition en masse SENDS
  bulk_edit_recvs  = false,  -- edition en masse RECEIVES
  cp_pastel        = 0.0,    -- slider pastel color picker (0=pur, 1=blanc)
  cp_open          = false,  -- ouvrir color picker pistes
  pending_delete   = nil,   -- suppression à exécuter au prochain début de frame
  pending_deletes  = nil,   -- liste de suppressions multiples
  pre_delete_sel   = {},    -- sélection avant suppression
  new_track_name  = "",     -- masque de nom (ex: "TRACK")
  new_track_color   = 0,     -- couleur des pistes créées
  new_track_cp_pastel = 0.3,
  rename_track_ptr  = nil,   -- pointeur piste en cours de renommage
  rename_just_opened = false,  -- flag pour focus au premier frame
  rename_track_buf  = "",    -- buffer InputText renommage
  folder_name_buf   = "",    -- buffer nom nouveau folder
  folder_color      = 0,     -- couleur du folder
  folder_cp_pastel  = 0.3,
  bus_name_buf      = "",    -- buffer nom nouveau bus
  bus_color         = 0,     -- couleur du bus
  bus_cp_pastel     = 0.3,
  fx_name_buf       = "",    -- buffer nom nouvelle piste FX
  fx_color          = 0,     -- couleur de la piste FX
  fx_cp_pastel      = 0.3,
  vca_name_buf      = "",    -- buffer nom groupe VCA
  vca_color         = 0,     -- couleur choisie pour le VCA (reaper format)
  vca_mute_lead     = false, -- option Mute Lead
  vca_solo_lead     = false, -- option Solo Lead
  vca_cp_pastel     = 0.3,   -- slider pastel du color picker VCA
  nchan_buf         = 2,     -- buffer nombre de canaux
  ctx_menu_track    = nil,   -- piste visée par le menu contextuel
  new_track_count = 1,      -- nombre de pistes à créer
  -- Paramètres persistants de création de send
  np = {
    mode_idx  = 1,
    mono      = false,
    phase     = false,
    mute      = false,
    src_pair  = 1,
    dst_pair  = 1,
    main_send = false,  -- false = master actif (case cochee = master coupe)
  },
  -- Multi-destinations sélectionnées dans popup
  dest_checked = {},  -- [track_ptr] = true/false
}

-- ============================================================
--  UTILITAIRES
-- ============================================================
local function set_status(msg)
  state.status_msg   = msg
  state.status_timer = reaper.time_precise() + 3.5
end

local function tname(t)
  if not t or not reaper.ValidatePtr(t, "MediaTrack*") then return "?" end
  local _, n = reaper.GetTrackName(t) ; return n
end

local function tidx(t)
  return math.floor(reaper.GetMediaTrackInfo_Value(t, "IP_TRACKNUMBER"))
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


local function ensure_chans(t, need)
  local cur = math.max(2, math.floor(reaper.GetMediaTrackInfo_Value(t, "I_NCHAN")))
  if cur < need then reaper.SetMediaTrackInfo_Value(t, "I_NCHAN", need) end
end

local function get_all_tracks()
  local t = {}
  for i = 0, reaper.CountTracks(0)-1 do t[#t+1] = reaper.GetTrack(0,i) end
  return t
end

local function refresh_sel()
  local tracks = {}
  for i = 0, reaper.CountSelectedTracks(0)-1 do
    tracks[#tracks+1] = reaper.GetSelectedTrack(0,i)
  end
  state.sel_tracks = tracks
  if state.focused_track then
    local ok = false
    for _, t in ipairs(tracks) do if t == state.focused_track then ok=true; break end end
    if not ok then state.focused_track = tracks[1] end
  else
    state.focused_track = tracks[1]
  end
end

-- ============================================================
--  LECTURE SENDS / RECEIVES
-- ============================================================
local function read_send(track, cat, idx)
  local raw_src = math.floor(reaper.GetTrackSendInfo_Value(track, cat, idx, "I_SRCCHAN"))
  local raw_dst = math.floor(reaper.GetTrackSendInfo_Value(track, cat, idx, "I_DSTCHAN"))
  local sp = dec_srcchan(raw_src)
  local dp = dec_dstchan(raw_dst)
  local mono = reaper.GetTrackSendInfo_Value(track, cat, idx, "B_MONO") == 1
  -- B_MAINSEND est une propriete de la piste source (pas du send)
  local src_track_ref = cat == 0 and track or reaper.GetTrackSendInfo_Value(track, cat, idx, "P_SRCTRACK")
  local main_send = true
  if src_track_ref and reaper.ValidatePtr(src_track_ref, "MediaTrack*") then
    -- main_send = true signifie "master COUPE" (inverse de B_MAINSEND)
    main_send = reaper.GetMediaTrackInfo_Value(src_track_ref, "B_MAINSEND") == 0
  end
  return {
    idx       = idx,
    dest      = cat == 0  and reaper.GetTrackSendInfo_Value(track, cat, idx, "P_DESTTRACK") or nil,
    src       = cat == -1 and reaper.GetTrackSendInfo_Value(track, cat, idx, "P_SRCTRACK")  or nil,
    vol       = reaper.GetTrackSendInfo_Value(track, cat, idx, "D_VOL"),
    pan       = reaper.GetTrackSendInfo_Value(track, cat, idx, "D_PAN"),
    mute      = reaper.GetTrackSendInfo_Value(track, cat, idx, "B_MUTE") == 1,
    mode      = math.floor(reaper.GetTrackSendInfo_Value(track, cat, idx, "I_SENDMODE")),
    phase     = reaper.GetTrackSendInfo_Value(track, cat, idx, "B_PHASE") == 1,
    mono      = mono,
    src_pair  = sp,
    dst_pair  = dp,
    main_send = main_send,
  }
end

local function get_sends(track)
  local t = {}
  for i = 0, reaper.GetTrackNumSends(track, 0)-1 do t[#t+1] = read_send(track, 0, i) end
  return t
end

local function get_receives(track)
  local t = {}
  for i = 0, reaper.GetTrackNumSends(track, -1)-1 do t[#t+1] = read_send(track, -1, i) end
  return t
end

-- ============================================================
--  ACTIONS
-- ============================================================

-- Applique les paramètres np à un send existant (src_track = piste qui envoie)
local function apply_np(src_track, dst_track, send_idx, np, cat)
  cat = cat or 0

  -- Sauvegarder les I_SRCCHAN de tous les sends existants de src_track
  -- avant d'augmenter I_NCHAN (REAPER peut les décaler)
  local saved_srcchan = {}
  local ns = reaper.GetTrackNumSends(src_track, 0)
  for i = 0, ns - 1 do
    saved_srcchan[i] = reaper.GetTrackSendInfo_Value(src_track, 0, i, "I_SRCCHAN")
  end

  ensure_chans(src_track, np.src_pair * 2)

  -- Restaurer les I_SRCCHAN des sends existants (sauf le nouveau send_idx)
  for i = 0, ns - 1 do
    if i ~= send_idx then
      reaper.SetTrackSendInfo_Value(src_track, 0, i, "I_SRCCHAN", saved_srcchan[i])
    end
  end

  reaper.SetTrackSendInfo_Value(src_track, cat, send_idx, "I_SENDMODE", SM_VALS[np.mode_idx])
  reaper.SetTrackSendInfo_Value(src_track, cat, send_idx, "I_SRCCHAN",  enc_srcchan(np.src_pair))
  reaper.SetTrackSendInfo_Value(src_track, cat, send_idx, "I_DSTCHAN",  enc_dstchan(np.dst_pair))
  reaper.SetTrackSendInfo_Value(src_track, cat, send_idx, "B_MONO",     np.mono  and 1 or 0)
  reaper.SetTrackSendInfo_Value(src_track, cat, send_idx, "B_PHASE",    np.phase and 1 or 0)
  reaper.SetTrackSendInfo_Value(src_track, cat, send_idx, "B_MUTE",     np.mute  and 1 or 0)
  -- Ne couper le master QUE si la case est explicitement cochée
  if np.main_send then
    reaper.SetMediaTrackInfo_Value(src_track, "B_MAINSEND", 0)
  end
end

local function action_create_sends(src_tracks, dst_tracks, np)
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local count = 0

  -- Créer les sends (canaux 1-2 par défaut, modifiables ensuite via Bulk edit)
  for _, src in ipairs(src_tracks) do
    for _, dst in ipairs(dst_tracks) do
      if src ~= dst then
        reaper.CreateTrackSend(src, dst)
        local n = reaper.GetTrackNumSends(src, 0)
        apply_np(src, dst, n-1, np)
        count = count + 1
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK RH : Create send(s)", -1)
  set_status(string.format("✓ %d send(s) created", count))
end

local function action_create_sends_new_track(src_tracks, name, np)
  reaper.Undo_BeginBlock()
  -- Insérer après la dernière piste sélectionnée
  local last = 0
  for _, t in ipairs(state.sel_tracks) do
    local i = tidx(t) ; if i > last then last = i end
  end
  reaper.InsertTrackAtIndex(last, true)
  local new_t = reaper.GetTrack(0, last)
  reaper.GetSetMediaTrackInfo_String(new_t, "P_NAME", name, true)
  local count = 0
  for _, src in ipairs(src_tracks) do
    if src ~= new_t then
      reaper.CreateTrackSend(src, new_t)
      local n = reaper.GetTrackNumSends(src, 0)
      apply_np(src, new_t, n-1, np)
      count = count + 1
    end
  end
  reaper.Undo_EndBlock("SK RH : Send(s) + new track", -1)
  set_status(string.format("✓ \"%s\" created, %d send(s)", name, count))
end

local function action_delete_send(track, idx)
  reaper.Undo_BeginBlock()
  reaper.RemoveTrackSend(track, 0, idx)
  reaper.Undo_EndBlock("SK RH : Supprimer send", -1)
  set_status("✓ Send removed")
end

local function action_delete_receive(track, idx)
  reaper.Undo_BeginBlock()
  reaper.RemoveTrackSend(track, -1, idx)
  reaper.Undo_EndBlock("SK RH : Supprimer receive", -1)
  set_status("✓ Receive removed")
end

-- Ouvre la fenêtre I/O native REAPER pour une track
-- REAPER n'expose pas d'action "ouvrir le send N directement",
-- mais l'action 40293 ouvre le panneau I/O de la track sélectionnée,
-- ce qui est la fenêtre send/receive native.
-- Note API officielle : il n'existe pas d'action publique REAPER permettant
-- d'ouvrir la fenetre "Controls for track" d'un send specifique par index Lua.
-- Cette fenetre ne s'ouvre qu'en double-cliquant dans la routing matrix.
-- La meilleure alternative disponible : action 40293 ouvre la routing matrix
-- de la piste source, qui contient tous ses sends et permet d'y acceder.
local function action_open_io(track)
  reaper.SetOnlyTrackSelected(track)
  reaper.Main_OnCommand(40293, 0)  -- View: Show track routing/send matrix
end

local function action_set_send_field(track, cat, idx, field, val)
  reaper.SetTrackSendInfo_Value(track, cat, idx, field, val)
end

local function action_change_dest(src_track, send_idx, new_dst, s)
  -- Préserve tous les paramètres du send existant
  reaper.Undo_BeginBlock()
  local np = {
    mode_idx = sm_to_idx(s.mode),
    mono     = s.mono,
    phase    = s.phase,
    mute     = s.mute,
    src_pair = s.src_pair,
    dst_pair = s.dst_pair,
  }
  reaper.RemoveTrackSend(src_track, 0, send_idx)
  reaper.CreateTrackSend(src_track, new_dst)
  local n = reaper.GetTrackNumSends(src_track, 0)
  apply_np(src_track, new_dst, n-1, np)
  reaper.SetTrackSendInfo_Value(src_track, 0, n-1, "D_VOL", s.vol)
  reaper.SetTrackSendInfo_Value(src_track, 0, n-1, "D_PAN", s.pan)
  reaper.Undo_EndBlock("SK RH : Changer destination", -1)
  set_status("✓ Dest → " .. tname(new_dst))
end

local function action_dissolve_folder(pt)
  reaper.Undo_BeginBlock()
  reaper.SetMediaTrackInfo_Value(pt, "I_FOLDERDEPTH", 0)
  local ti = tidx(pt) ; local level = 1
  for i = ti, reaper.CountTracks(0)-1 do
    local t = reaper.GetTrack(0,i) ; local d = reaper.GetMediaTrackInfo_Value(t,"I_FOLDERDEPTH")
    reaper.SetMediaTrackInfo_Value(t,"I_FOLDERDEPTH",0)
    level = level + d ; if level <= 0 then break end
  end
  reaper.Undo_EndBlock("SK RH : Dissoudre folder", -1)
  set_status("✓ Folder dissolved")
end

-- ============================================================
--  ACTION : CRÉER FOLDER depuis sélection
--  Logique identique au script de référence Studio Kozak
-- ============================================================
local function action_create_folder(folder_name, reaper_col)
  local n_sel = reaper.CountSelectedTracks(0)
  if n_sel == 0 then set_status("No track selected."); return end

  -- Collecter les pistes sélectionnées avec leur position actuelle
  local sel = {}
  local first_pos = math.huge

  for i = 0, n_sel - 1 do
    local tr  = reaper.GetSelectedTrack(0, i)
    local pos = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
    local is_f = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") > 0
    table.insert(sel, { track = tr, pos = pos, is_folder = is_f })
    if pos < first_pos then first_pos = pos end
  end
  table.sort(sel, function(a, b) return a.pos < b.pos end)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  reaper.Main_OnCommand(40297, 0)

  -- Insérer le folder parent avant la première piste sélectionnée
  local insert_idx = first_pos - 1  -- 0-based
  reaper.InsertTrackAtIndex(insert_idx, true)
  local folder_tr = reaper.GetTrack(0, insert_idx)
  reaper.GetSetMediaTrackInfo_String(folder_tr, "P_NAME", folder_name, true)
  if reaper_col and reaper_col ~= 0 then
    reaper.SetTrackColor(folder_tr, reaper_col)
  end
  reaper.SetMediaTrackInfo_Value(folder_tr, "I_FOLDERDEPTH", 1)

  --
  -- Stratégie :
  --   - Les pistes sélectionnées (simples ou folders) deviennent enfants du nouveau folder.
  --   - Pour les pistes simples : depth = 0 (enfant standard)
  --   - Pour les folders : depth += 1 (sous-folder)
  --   - La dernière piste sélectionnée (ou fin du dernier sous-folder) ferme le nouveau folder.

  local total = reaper.CountTracks(0)

  -- Trouver la "vraie" dernière position occupée par la sélection
  -- (en tenant compte des enfants des folders sélectionnés)
  local last_pos = 0
  for _, s in ipairs(sel) do
    -- Position actuelle (post-insertion = pos+1 pour toutes les pistes >= insert_idx)
    local cur_pos = math.floor(
      reaper.GetMediaTrackInfo_Value(s.track, "IP_TRACKNUMBER")) - 1

    if s.is_folder then
      -- Trouver la fin du sous-folder
      local dc = 1
      for i = cur_pos + 1, total - 1 do
        local d = reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, i), "I_FOLDERDEPTH")
        dc = dc + d
        if dc <= 0 then
          if i > last_pos then last_pos = i end
          break
        end
      end
      -- Ajuster le depth du folder sélectionné
      local d = reaper.GetMediaTrackInfo_Value(s.track, "I_FOLDERDEPTH")
      reaper.SetMediaTrackInfo_Value(s.track, "I_FOLDERDEPTH", d + 1)
    else
      -- Piste simple : depth = 0 (enfant du nouveau folder)
      if cur_pos > last_pos then last_pos = cur_pos end
      reaper.SetMediaTrackInfo_Value(s.track, "I_FOLDERDEPTH", 0)
    end
  end

  -- Fermer le nouveau folder sur la dernière piste de la sélection
  if last_pos > insert_idx then
    local close_tr = reaper.GetTrack(0, last_pos)
    local d = reaper.GetMediaTrackInfo_Value(close_tr, "I_FOLDERDEPTH")
    reaper.SetMediaTrackInfo_Value(close_tr, "I_FOLDERDEPTH", d - 1)
  end

  -- Réactiver l'envoi au master sur les pistes enfants
  -- (elles étaient peut-être coupées avant de rejoindre le folder)
  for _, s in ipairs(sel) do
    if reaper.ValidatePtr(s.track, "MediaTrack*") then
      reaper.SetMediaTrackInfo_Value(s.track, "B_MAINSEND", 1)
    end
  end

  reaper.SetOnlyTrackSelected(folder_tr)
  reaper.TrackList_AdjustWindows(false)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK SM : Creer folder " .. folder_name, -1)
  set_status('Folder "' .. folder_name .. '" created.')
  state.last_proj_state = -1
  state.sel_tracks      = {}
  state.focused_track   = nil
end
local function action_add_child_track(track)
  local sel_index    = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) - 1
  local folder_depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
  local folder_color = reaper.GetTrackColor(track)

  -- Trouver la position d'insertion :
  -- Si folder : chercher la fin du folder (dernière piste enfant)
  -- Sinon : juste après la piste (elle va devenir un folder)
  local insert_index = sel_index + 1

  local closing_track = nil  -- piste qui porte le depth fermant

  if folder_depth == 1 then
    -- Parcourir pour trouver la piste fermante du folder
    local depth_count = 1
    local total = reaper.CountTracks(0)
    for i = sel_index + 1, total - 1 do
      local tr = reaper.GetTrack(0, i)
      local d  = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
      depth_count = depth_count + d
      if depth_count <= 0 then
        -- tr est la piste fermante : on insère APRÈS elle
        closing_track = tr
        insert_index  = i + 1
        break
      end
    end
  end

  reaper.Undo_BeginBlock()
  reaper.InsertTrackAtIndex(insert_index, true)
  local new_track = reaper.GetTrack(0, insert_index)

  if folder_depth == 1 then
    -- La piste fermante cède son rôle à la nouvelle :
    -- ancienne fermante → depth=0, nouvelle → depth=-1
    if closing_track then
      local cd = reaper.GetMediaTrackInfo_Value(closing_track, "I_FOLDERDEPTH")
      reaper.SetMediaTrackInfo_Value(closing_track, "I_FOLDERDEPTH", cd + 1)
    end
    reaper.SetMediaTrackInfo_Value(new_track, "I_FOLDERDEPTH", -1)
  else
    -- Pas encore un folder : transformer la piste en parent, nouvelle = enfant fermant
    reaper.SetMediaTrackInfo_Value(track,     "I_FOLDERDEPTH",  1)
    reaper.SetMediaTrackInfo_Value(new_track, "I_FOLDERDEPTH", -1)
  end

  -- Appliquer la couleur du folder à la piste fille
  if folder_color and folder_color ~= 0 then
    reaper.SetTrackColor(new_track, folder_color)
  end

  reaper.Main_OnCommand(40297, 0)
  reaper.SetTrackSelected(track, true)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK RH : Add child track", -1)
  set_status("Child track added.")
  state.last_proj_state = -1
  state.sel_tracks      = {}
  state.focused_track   = nil
end

local function action_create_bus(bus_name, reaper_col)
  local n_sel = reaper.CountSelectedTracks(0)
  if n_sel == 0 then set_status("No track selected."); return end

  local sel = {}
  local first_pos = math.huge

  for i = 0, n_sel - 1 do
    local tr  = reaper.GetSelectedTrack(0, i)
    local pos = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
    table.insert(sel, tr)
    if pos < first_pos then first_pos = pos end
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Insérer le bus AVANT la première piste sélectionnée
  local insert_idx = first_pos - 1
  reaper.InsertTrackAtIndex(insert_idx, true)
  local bus_tr = reaper.GetTrack(0, insert_idx)
  reaper.GetSetMediaTrackInfo_String(bus_tr, "P_NAME", bus_name, true)
  if reaper_col and reaper_col ~= 0 then
    reaper.SetTrackColor(bus_tr, reaper_col)
  end

  -- Pour chaque piste sélectionnée : couper master + créer send post-fader vers le bus
  for _, tr in ipairs(sel) do
    reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0)
    local si = reaper.CreateTrackSend(tr, bus_tr)
    if si >= 0 then
      reaper.SetTrackSendInfo_Value(tr, 0, si, "I_SENDMODE", 0)  -- Post-fader
      reaper.SetTrackSendInfo_Value(tr, 0, si, "D_VOL",      1.0)
      reaper.SetTrackSendInfo_Value(tr, 0, si, "D_PAN",      0.0)
    end
  end

  reaper.SetOnlyTrackSelected(bus_tr)
  reaper.TrackList_AdjustWindows(false)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK SM : Creer bus " .. bus_name, -1)
  set_status('Bus "' .. bus_name .. '" created.')
  state.last_proj_state = -1
  state.sel_tracks      = {}
  state.focused_track   = nil
end

local function action_add_bus_child(track)
  -- Trouver la dernière piste de la sélection courante
  -- Si aucune sélection, utiliser uniquement track
  local targets = {}
  local last_idx = math.floor(
    reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) - 1

  for _, st in ipairs(state.sel_tracks) do
    if reaper.ValidatePtr(st, "MediaTrack*") then
      table.insert(targets, st)
      local p = math.floor(
        reaper.GetMediaTrackInfo_Value(st, "IP_TRACKNUMBER")) - 1
      if p > last_idx then last_idx = p end
    end
  end
  if #targets == 0 then targets = { track } end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Insérer la piste bus APRÈS la dernière piste sélectionnée
  local insert_idx = last_idx + 1
  reaper.InsertTrackAtIndex(insert_idx, true)
  local bus_tr = reaper.GetTrack(0, insert_idx)

  -- Pas de nom, pas d'envoi au master
  reaper.SetMediaTrackInfo_Value(bus_tr, "B_MAINSEND", 0)

  -- Appliquer la couleur de la piste source à la piste bus
  local src_color = reaper.GetTrackColor(track)
  if src_color and src_color ~= 0 then
    reaper.SetTrackColor(bus_tr, src_color)
  end

  -- Créer un send de la nouvelle piste bus vers chaque piste cible
  for _, tr in ipairs(targets) do
    reaper.CreateTrackSend(bus_tr, tr)
  end

  reaper.SetOnlyTrackSelected(bus_tr)
  reaper.TrackList_AdjustWindows(false)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK RH : Add bus track", -1)
  set_status("Bus track added.")
  state.last_proj_state = -1
  state.sel_tracks      = {}
  state.focused_track   = nil
end

local function action_create_fx(fx_name, reaper_col)
  local n_sel = reaper.CountSelectedTracks(0)
  if n_sel == 0 then set_status("No track selected."); return end

  local sel = {}
  local last_pos = 0

  for i = 0, n_sel - 1 do
    local tr  = reaper.GetSelectedTrack(0, i)
    local pos = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
    table.insert(sel, tr)
    if pos > last_pos then last_pos = pos end
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Insérer la piste FX APRÈS la dernière piste sélectionnée
  reaper.InsertTrackAtIndex(last_pos, true)
  local fx_tr = reaper.GetTrack(0, last_pos)
  reaper.GetSetMediaTrackInfo_String(fx_tr, "P_NAME", fx_name, true)
  if reaper_col and reaper_col ~= 0 then
    reaper.SetTrackColor(fx_tr, reaper_col)
  end

  -- Pour chaque piste sélectionnée : send post-fader vers FX, volume à -inf
  for _, tr in ipairs(sel) do
    local si = reaper.CreateTrackSend(tr, fx_tr)
    if si >= 0 then
      reaper.SetTrackSendInfo_Value(tr, 0, si, "I_SENDMODE", 0)
      reaper.SetTrackSendInfo_Value(tr, 0, si, "D_VOL",      1.0)
      reaper.SetTrackSendInfo_Value(tr, 0, si, "D_PAN",      0.0)
    end
  end

  reaper.SetOnlyTrackSelected(fx_tr)
  reaper.TrackList_AdjustWindows(false)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK RH : Create FX track " .. fx_name, -1)
  set_status('FX track "' .. fx_name .. '" created.')
  state.last_proj_state = -1
  state.sel_tracks      = {}
  state.focused_track   = nil
end

local function action_create_vca(vca_name, reaper_col, mute_lead, solo_lead)
  local n_sel = reaper.CountSelectedTracks(0)

  -- Trouver la position de la première piste sélectionnée
  local first_pos = math.huge
  for i = 0, n_sel - 1 do
    local tr  = reaper.GetSelectedTrack(0, i)
    local pos = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
    if pos < first_pos then first_pos = pos end
  end
  local insert_at = (first_pos < math.huge) and (first_pos - 1) or reaper.CountTracks(0)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Créer la piste VCA juste avant la première piste sélectionnée
  reaper.InsertTrackAtIndex(insert_at, true)
  local vca_tr = reaper.GetTrack(0, insert_at)

  -- Nom
  reaper.GetSetMediaTrackInfo_String(vca_tr, "P_NAME", vca_name, true)

  -- Couleur
  if reaper_col and reaper_col ~= 0 then
    reaper.SetTrackColor(vca_tr, reaper_col)
  end

  -- Trouver un groupe VCA libre (1-8)
  local free_group = nil
  for g = 1, 16 do
    local bit = 2^(g-1)
    -- Vérifier si ce groupe est déjà utilisé dans le projet
    local used = false
    for i = 0, reaper.CountTracks(0)-1 do
      local tr = reaper.GetTrack(0, i)
      if tr ~= vca_tr then
        local m = reaper.GetSetTrackGroupMembership(tr, "VOLUME_VCA_MASTER", 0, 0)
        if m & bit ~= 0 then used = true; break end
      end
    end
    if not used then free_group = g; break end
  end

  if free_group then
    local bit = 2^(free_group-1)
    -- Piste VCA = Master du groupe
    reaper.GetSetTrackGroupMembership(vca_tr, "VOLUME_VCA_MASTER", bit, bit)
    if mute_lead then
      reaper.GetSetTrackGroupMembership(vca_tr, "MUTE_LEAD", bit, bit)
    end
    if solo_lead then
      reaper.GetSetTrackGroupMembership(vca_tr, "SOLO_LEAD", bit, bit)
    end
    -- Pistes sélectionnées = Slaves du groupe
    for i = 0, n_sel - 1 do
      local tr = reaper.GetSelectedTrack(0, i)
      if tr and tr ~= vca_tr then
        reaper.GetSetTrackGroupMembership(tr, "VOLUME_VCA_SLAVE", bit, bit)
        if mute_lead then
          reaper.GetSetTrackGroupMembership(tr, "MUTE_SLAVE", bit, bit)
        end
        if solo_lead then
          reaper.GetSetTrackGroupMembership(tr, "SOLO_SLAVE", bit, bit)
        end
      end
    end
    set_status(string.format('VCA "%s" created (group %d).', vca_name, free_group))
  else
    set_status("All VCA groups (1-16) are already in use.")
  end

  reaper.SetOnlyTrackSelected(vca_tr)
  reaper.TrackList_AdjustWindows(false)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK RH : Creer VCA " .. vca_name, -1)
  state.last_proj_state = -1
  state.sel_tracks      = {}
  state.focused_track   = nil
end

-- Retire tous les slaves d'un groupe VCA quand le master est retiré ou supprimé
local function remove_vca_slaves(bit)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local sb = reaper.GetSetTrackGroupMembership(tr, "VOLUME_VCA_SLAVE", 0, 0)
    if sb & bit ~= 0 then
      reaper.GetSetTrackGroupMembership(tr, "VOLUME_VCA_SLAVE", bit, 0)
      reaper.GetSetTrackGroupMembership(tr, "MUTE_SLAVE",       bit, 0)
      reaper.GetSetTrackGroupMembership(tr, "SOLO_SLAVE",       bit, 0)
    end
  end
end

-- ============================================================
--  STYLE
-- ============================================================
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
--  WIDGETS
-- ============================================================
local function danger_btn(label, w, h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        C.danger)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.danger_hov)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0xCC4444FF)
  local r = reaper.ImGui_Button(ctx, label, w, h)
  reaper.ImGui_PopStyleColor(ctx, 3)
  return r
end

local function col_btn(label, col, hov, w, h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        col)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), hov or col)
  local r = reaper.ImGui_Button(ctx, label, w, h)
  reaper.ImGui_PopStyleColor(ctx, 2)
  return r
end

local function sec_title(label)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.white)
  reaper.ImGui_Text(ctx, label)
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)
end

-- ============================================================
--  POPUP CRÉATION DE SEND
--  Paramètres + sélection multi-destinations avec checkboxes
-- ============================================================
local popup_filter  = ""
local popup_newname = ""

local function draw_create_popup(all_tracks, src_tracks)
  reaper.ImGui_SetNextWindowSize(ctx, 480, 560, reaper.ImGui_Cond_Always())
  if not reaper.ImGui_BeginPopupModal(ctx, "New Send", nil,
      reaper.ImGui_WindowFlags_NoResize()) then return end

  local np = state.np

  -- ── Paramètres ──
  sec_title("Send parameters")

  -- Mode
  reaper.ImGui_Text(ctx, "Type:")
  reaper.ImGui_SameLine(ctx, 90)
  reaper.ImGui_SetNextItemWidth(ctx, 200)
  local cm, nmi = reaper.ImGui_Combo(ctx, "##mode", np.mode_idx-1, SM_STR)
  if cm then np.mode_idx = nmi+1 end

  -- Boutons toggle : M / O / MONO-ST / Master (identiques à send_row)
  reaper.ImGui_Spacing(ctx)
  local BTN_H = 22

  -- Mute
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
    np.mute and C.mute_on or C.bg_item)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
    np.mute and C.mute_txt or C.text_dim)
  if reaper.ImGui_Button(ctx, "M##np_mu", 28, BTN_H) then np.mute = not np.mute end
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_SameLine(ctx, 0, 4)

  -- Phase
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
    np.phase and C.phase_on or C.bg_item)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
    np.phase and C.phase_txt or C.text_dim)
  if reaper.ImGui_Button(ctx, "O##np_ph", 28, BTN_H) then np.phase = not np.phase end
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_SameLine(ctx, 0, 4)

  -- Mono / ST
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
    np.mono and C.mono_on or C.bg_item)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
    np.mono and C.white or C.text_dim)
  if reaper.ImGui_Button(ctx, np.mono and "<>##np_mn" or "><##np_mn", 30, BTN_H) then
    np.mono = not np.mono
  end
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_SameLine(ctx, 0, 12)

  -- Couper envoi au master
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
    np.main_send and C.danger or C.bg_item)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
    np.main_send and 0xFF9999FF or C.text_dim)
  if reaper.ImGui_Button(ctx, "MS##np_ms", 28, BTN_H) then
    np.main_send = not np.main_send
  end
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_SameLine(ctx, 0, 6)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
    np.main_send and 0xFF9999FF or C.text_dim)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, np.main_send and "Master off" or "Master on")
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- ── Destinations ──
  sec_title("Destinations (check to select)")

  -- Filtre
  reaper.ImGui_SetNextItemWidth(ctx, 300)
  local chf, nf = reaper.ImGui_InputText(ctx, "##filter", popup_filter)
  if chf then popup_filter = nf end

  -- Boutons tout/rien
  reaper.ImGui_SameLine(ctx, 0, 8)
  if reaper.ImGui_Button(ctx, "All##all") then
    for _, dt in ipairs(all_tracks) do
      local is_src = false
      for _, st in ipairs(src_tracks) do if dt == st then is_src=true; break end end
      if not is_src then state.dest_checked[tostring(dt)] = true end
    end
  end
  reaper.ImGui_SameLine(ctx, 0, 4)
  if reaper.ImGui_Button(ctx, "None##none") then state.dest_checked = {} end

  -- Liste checkboxes
  reaper.ImGui_BeginChild(ctx, "dlist", 0, 170, 1)
  for _, dt in ipairs(all_tracks) do
    local is_src = false
    for _, st in ipairs(src_tracks) do if dt == st then is_src=true; break end end
    if not is_src then
      local dn = tname(dt)
      local ok = popup_filter == "" or dn:lower():find(popup_filter:lower(), 1, true)
      if ok then
        local ptr = tostring(dt)
        local checked = state.dest_checked[ptr] or false
        -- Badge couleur
        local dc = rcolor(dt)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        dc)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), dc)
        reaper.ImGui_Button(ctx, "##db_"..ptr, 6, 18)
        reaper.ImGui_PopStyleColor(ctx, 2)
        reaper.ImGui_SameLine(ctx, 0, 4)
        -- Checkbox + nom
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),   0xBBBBBBFF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),  0x444444FF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(), 0xDDDDDDFF)
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1)
        local _, nv = reaper.ImGui_Checkbox(ctx, dn.."##chk_"..ptr, checked)
        if nv ~= nil then state.dest_checked[ptr] = nv end
        reaper.ImGui_PopStyleVar(ctx, 1)
        reaper.ImGui_PopStyleColor(ctx, 3)
      end
    end
  end
  reaper.ImGui_EndChild(ctx)

  reaper.ImGui_Spacing(ctx)

  -- Nouvelle piste
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xAAFFAAFF)
  reaper.ImGui_Text(ctx, "+ New destination track:")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SetNextItemWidth(ctx, 270)
  local chn, nn = reaper.ImGui_InputText(ctx, "##ntn", popup_newname)
  if chn then popup_newname = nn end
  reaper.ImGui_SameLine(ctx, 0, 6)
  if col_btn("Create##ntnbtn", C.new_trk, C.new_trk_h) and popup_newname ~= "" then
    action_create_sends_new_track(src_tracks, popup_newname, np)
    popup_newname = "" ; popup_filter = ""
    state.dest_checked = {}
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Boutons OK / Annuler
  -- Compte les destinations cochées
  local dsts = {}
  for _, dt in ipairs(all_tracks) do
    if state.dest_checked[tostring(dt)] then dsts[#dsts+1] = dt end
  end
  local ok_label = #dsts > 0
    and string.format("Creer (%d dst)##ok", #dsts)
    or  "Creer##ok_dis"
  local can_create = #dsts > 0

  if not can_create then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x333333FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x333333FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          C.text_dim)
  end
  if reaper.ImGui_Button(ctx, ok_label, 120) and can_create then
    action_create_sends(src_tracks, dsts, np)
    popup_filter = "" ; state.dest_checked = {}
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  if not can_create then reaper.ImGui_PopStyleColor(ctx, 3) end

  reaper.ImGui_SameLine(ctx, 0, 10)
  if reaper.ImGui_Button(ctx, "Cancel", 80) then
    popup_filter = "" ; popup_newname = ""
    state.dest_checked = {}
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
end

-- ============================================================
--  LIGNE DE SEND/RECEIVE — 1 LIGNE COMPACTE
--  track    : piste de référence
--  s        : données du send (read_send)
--  uid      : ID unique string
--  cat      : 0 = send, -1 = receive
--  all_tracks
--  Retourne true si suppression demandée
-- ============================================================
-- Pour les sends  : orig_dest = piste destination d'origine (filtre par dest)
-- Pour les receives : orig_track = piste destinataire sur laquelle on agit (filtre par dest)
local function bulk_apply(param, value, cat, orig_dest, orig_track)
  local sel_set = {}
  for _, t in ipairs(state.sel_tracks) do sel_set[t] = true end

  if cat == 0 then
    -- Sends : propager aux sends vers la même destination d'origine
    for _, src in ipairs(state.sel_tracks) do
      local sends = get_sends(src)
      for _, s in ipairs(sends) do
        if not sel_set[s.dest] then
          if orig_dest == nil or s.dest == orig_dest then
            if param == "I_SRCCHAN" then
              local pair = math.floor(value / 2) + 1
              ensure_chans(src, pair * 2)
            elseif param == "I_DSTCHAN" then
              local pair = math.floor(value / 2) + 1
              ensure_chans(s.dest, pair * 2)
            end
            reaper.SetTrackSendInfo_Value(src, 0, s.idx, param, value)
          end
        end
      end
    end
  else
    -- Receives : propager à TOUS les receives de la même piste destinataire
    -- (orig_track = la piste FX sur laquelle on agit)
    if orig_track then
      local recvs = get_receives(orig_track)
      for _, r in ipairs(recvs) do
        -- Créer les canaux nécessaires sur la piste source du receive
        if param == "I_SRCCHAN" then
          local pair = math.floor(value / 2) + 1
          ensure_chans(r.src, pair * 2)
        elseif param == "I_DSTCHAN" then
          local pair = math.floor(value / 2) + 1
          ensure_chans(orig_track, pair * 2)
        end
        reaper.SetTrackSendInfo_Value(orig_track, -1, r.idx, param, value)
      end
    else
      for _, dst in ipairs(state.sel_tracks) do
        local recvs = get_receives(dst)
        for _, r in ipairs(recvs) do
          if param == "I_SRCCHAN" then
            local pair = math.floor(value / 2) + 1
            ensure_chans(r.src, pair * 2)
          elseif param == "I_DSTCHAN" then
            local pair = math.floor(value / 2) + 1
            ensure_chans(dst, pair * 2)
          end
          reaper.SetTrackSendInfo_Value(dst, -1, r.idx, param, value)
        end
      end
    end
  end
end

local function send_row(track, s, uid, cat, all_tracks, bulk_edit)
  local is_recv   = (cat == -1)
  local other     = is_recv and s.src or s.dest
  local do_del    = false
  local bulk_delete = false
  local src_ref = is_recv and other or track
  local dst_ref = is_recv and track or other
  local u = uid

  -- Layout identique au SK Routing Hub :
  -- widgets directs avec SameLine, pas de BeginChild ni BeginTable.
  -- PushStyleColor utilisé UNIQUEMENT sur Col_Text (jamais Col_Button dans une boucle).
  local ROW_H = 20

  -- Badge couleur (bouton sans style push/pop pour Col_Button)
  local oc = rcolor(other)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        oc)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), oc)
  reaper.ImGui_Button(ctx, "##bg_"..u, 7, ROW_H)
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_SameLine(ctx, 0, 3)

  -- Nom tronqué (position X fixe après badge)
  local col_name_x = 145  -- X absolu pour le début du combo Mode
  local arrow = is_recv and "<- " or "-> "
  local raw   = tname(other)
  local disp  = #raw > 16 and (raw:sub(1,15).."~") or raw
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
    is_recv and 0xAAAAEEFF or C.white)
  reaper.ImGui_Text(ctx, arrow..disp)
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_SameLine(ctx, col_name_x)

  -- Mode
  reaper.ImGui_SetNextItemWidth(ctx, 152)
  local cmi, nmi = reaper.ImGui_Combo(ctx, "##mode_"..u, sm_to_idx(s.mode)-1, SM_STR)
  if cmi then
    local v = SM_VALS[nmi+1]
    action_set_send_field(track, cat, s.idx, "I_SENDMODE", v)
    if bulk_edit then bulk_apply("I_SENDMODE", v, cat, is_recv and nil or other, is_recv and track or nil) end
  end
  reaper.ImGui_SameLine(ctx, 0, 3)

  -- Mute
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
    s.mute and C.mute_txt or C.text_dim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
    s.mute and C.mute_on or C.bg_item)
  if reaper.ImGui_Button(ctx, "M##mu_"..u, 22, ROW_H) then
    local v = s.mute and 0 or 1
    action_set_send_field(track, cat, s.idx, "B_MUTE", v)
    if bulk_edit then bulk_apply("B_MUTE", v, cat, is_recv and nil or other, is_recv and track or nil) end
  end
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_SameLine(ctx, 0, 3)

  -- Phase
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
    s.phase and C.phase_txt or C.text_dim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
    s.phase and C.phase_on or C.bg_item)
  if reaper.ImGui_Button(ctx, "O##ph_"..u, 22, ROW_H) then
    local v = s.phase and 0 or 1
    action_set_send_field(track, cat, s.idx, "B_PHASE", v)
    if bulk_edit then bulk_apply("B_PHASE", v, cat, is_recv and nil or other, is_recv and track or nil) end
  end
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_SameLine(ctx, 0, 3)

  -- Mono/ST
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
    s.mono and C.white or C.text_dim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
    s.mono and C.mono_on or C.bg_item)
  if reaper.ImGui_Button(ctx, (s.mono and "<>" or "><").."##mn_"..u, 30, ROW_H) then
    local v = s.mono and 0 or 1
    action_set_send_field(track, cat, s.idx, "B_MONO", v)
    if bulk_edit then bulk_apply("B_MONO", v, cat, is_recv and nil or other, is_recv and track or nil) end
  end
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_SameLine(ctx, 0, 3)

  -- Src canaux
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
  reaper.ImGui_Text(ctx, "src")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SameLine(ctx, 0, 2)
  reaper.ImGui_SetNextItemWidth(ctx, 56)
  local csp, nsp = reaper.ImGui_Combo(ctx, "##srcp_"..u, s.src_pair-1, PAIRS_STR)
  if csp then
    local v = enc_srcchan(nsp+1)
    ensure_chans(src_ref, (nsp+1)*2)
    action_set_send_field(track, cat, s.idx, "I_SRCCHAN", v)
    if bulk_edit then bulk_apply("I_SRCCHAN", v, cat, is_recv and nil or other, is_recv and track or nil) end
  end
  reaper.ImGui_SameLine(ctx, 0, 3)

  -- Dst canaux
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
  reaper.ImGui_Text(ctx, "dst")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SameLine(ctx, 0, 2)
  reaper.ImGui_SetNextItemWidth(ctx, 56)
  local cdp, ndp = reaper.ImGui_Combo(ctx, "##dstp_"..u, s.dst_pair-1, PAIRS_STR)
  if cdp then
    local v = enc_dstchan(ndp+1)
    ensure_chans(dst_ref, (ndp+1)*2)
    action_set_send_field(track, cat, s.idx, "I_DSTCHAN", v)
    if bulk_edit then bulk_apply("I_DSTCHAN", v, cat, is_recv and nil or other, is_recv and track or nil) end
  end
  reaper.ImGui_SameLine(ctx, 0, 3)

  -- IO
  -- Changer destination (sends seulement)
  if not is_recv then
    if reaper.ImGui_Button(ctx, "->##chgd_"..u, 24, ROW_H) then
      reaper.ImGui_OpenPopup(ctx, "chgdest_"..u)
    end
    if reaper.ImGui_BeginPopup(ctx, "chgdest_"..u) then
      reaper.ImGui_Text(ctx, "New destination:")
      reaper.ImGui_Separator(ctx)
      for _, dt in ipairs(all_tracks) do
        if dt ~= track then
          local dc = rcolor(dt)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        dc)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), dc)
          reaper.ImGui_Button(ctx, "##dci_"..tostring(dt).."_"..u, 6, 16)
          reaper.ImGui_PopStyleColor(ctx, 2)
          reaper.ImGui_SameLine(ctx, 0, 4)
          if reaper.ImGui_Selectable(ctx, tname(dt).."##cd_"..tostring(dt).."_"..u) then
            if bulk_edit then
              -- Mémorise la destination d'origine du send modifié
              local orig_dest = s.dest
              -- Modifie ce send en premier
              action_change_dest(track, s.idx, dt, s)
              -- Propage uniquement aux sends ayant la même destination d'origine
              local sel_set = {}
              for _, st in ipairs(state.sel_tracks) do sel_set[st] = true end
              for _, src in ipairs(state.sel_tracks) do
                if src ~= track then
                  local sends = get_sends(src)
                  for _, sv in ipairs(sends) do
                    if sv.dest == orig_dest then
                      action_change_dest(src, sv.idx, dt, sv)
                    end
                  end
                end
              end
            else
              action_change_dest(track, s.idx, dt, s)
            end
          end
        end
      end
      reaper.ImGui_EndPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx, 0, 3)
  end

  -- Supprimer
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF8888FF)
  if reaper.ImGui_Button(ctx, "X##del_"..u, 24, ROW_H) then
    do_del = true
    -- En mode bulk : signaler qu'il faut supprimer tous les sends visibles
    if bulk_edit then bulk_delete = true end
  end
  reaper.ImGui_PopStyleColor(ctx, 1)

  return do_del, bulk_delete
end


-- ============================================================
--  PANNEAU SENDS
-- ============================================================

local function panel_sends(all_tracks)
  -- Titre SENDS avec case à cocher alignée sur la même ligne
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.white)
  reaper.ImGui_Text(ctx, "SENDS")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SameLine(ctx, 90)  -- position X fixe pour la checkbox
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),    0xBBBBBBFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),   0x444444FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(), 0xDDDDDDFF)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1)
  local _, bev = reaper.ImGui_Checkbox(ctx, "Bulk edit##bulk_s", state.bulk_edit_sends)
  reaper.ImGui_PopStyleVar(ctx, 1)
  reaper.ImGui_PopStyleColor(ctx, 3)
  if bev ~= nil then state.bulk_edit_sends = bev end
  if state.bulk_edit_sends then
    reaper.ImGui_SameLine(ctx, 0, 6)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFCC44FF)
    reaper.ImGui_Text(ctx, "active")
    reaper.ImGui_PopStyleColor(ctx, 1)
  end
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  local sel_set = {}
  for _, t in ipairs(state.sel_tracks) do sel_set[t] = true end
  local nb = #state.sel_tracks

  local lbl = nb > 1
    and string.format("+ Send from %d tracks##ns", nb)
    or  "+ New send##ns"
  if col_btn(lbl, C.send_col, 0x4A9A6AFF) then
    state.dest_checked = {}
    reaper.ImGui_OpenPopup(ctx, "New Send")
  end
  draw_create_popup(all_tracks, state.sel_tracks)

  reaper.ImGui_Spacing(ctx)

  local any   = false
  local to_del = {}

  for _, src in ipairs(state.sel_tracks) do
    local sends = get_sends(src)
    local vis   = {}
    for _, s in ipairs(sends) do
      if not sel_set[s.dest] then vis[#vis+1] = s end
    end

    if #vis > 0 then
      any = true
      -- Sous-header : simple ligne colorée sans BeginChild
      if nb > 1 then
        local sc = rcolor(src)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        sc)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), sc)
        reaper.ImGui_Button(ctx, "##sh_s"..tostring(src), 5, 14)
        reaper.ImGui_PopStyleColor(ctx, 2)
        reaper.ImGui_SameLine(ctx, 0, 5)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
        reaper.ImGui_Text(ctx, tname(src))
        reaper.ImGui_PopStyleColor(ctx, 1)
      end

      for i, s in ipairs(vis) do
        local uid = "S_"..tostring(src).."_"..i
        local del, bulk_del = send_row(src, s, uid, 0, all_tracks, state.bulk_edit_sends)
        if del then
          if bulk_del then
            -- Supprimer les sends vers la même destination sur toutes les pistes sélectionnées
            local orig = s.dest
            for _, bsrc in ipairs(state.sel_tracks) do
              local bsends = get_sends(bsrc)
              for _, bsv in ipairs(bsends) do
                if not sel_set[bsv.dest] and bsv.dest == orig then
                  to_del[#to_del+1] = { bsrc, bsv.idx }
                end
              end
            end
            break
          else
            to_del[#to_del+1] = { src, s.idx }
          end
        end
      end
    end
  end

  if not any then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
    reaper.ImGui_Text(ctx, "  No outgoing sends.")
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  if #to_del > 0 then
    table.sort(to_del, function(a,b) return a[2]>b[2] end)
    for _, item in ipairs(to_del) do action_delete_send(item[1], item[2]) end
  end

  reaper.ImGui_Spacing(ctx)
end

-- ============================================================
--  PANNEAU RECEIVES
-- ============================================================
local function panel_receives(all_tracks)
  -- Titre RECEIVES avec case à cocher alignée sur la même ligne
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.white)
  reaper.ImGui_Text(ctx, "RECEIVES")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SameLine(ctx, 90)  -- même position X fixe que SENDS
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),    0xBBBBBBFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),   0x444444FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(), 0xDDDDDDFF)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1)
  local _, brv = reaper.ImGui_Checkbox(ctx, "Bulk edit##bulk_r", state.bulk_edit_recvs)
  reaper.ImGui_PopStyleVar(ctx, 1)
  reaper.ImGui_PopStyleColor(ctx, 3)
  if brv ~= nil then state.bulk_edit_recvs = brv end
  if state.bulk_edit_recvs then
    reaper.ImGui_SameLine(ctx, 0, 6)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFCC44FF)
    reaper.ImGui_Text(ctx, "active")
    reaper.ImGui_PopStyleColor(ctx, 1)
  end
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  local nb   = #state.sel_tracks
  local any  = false
  local to_del = {}

  for _, dst in ipairs(state.sel_tracks) do
    local recvs = get_receives(dst)
    if #recvs > 0 then
      any = true
      -- Sous-header : simple ligne sans BeginChild
      if nb > 1 then
        local dc = rcolor(dst)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        dc)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), dc)
        reaper.ImGui_Button(ctx, "##rsh_r"..tostring(dst), 5, 14)
        reaper.ImGui_PopStyleColor(ctx, 2)
        reaper.ImGui_SameLine(ctx, 0, 5)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
        reaper.ImGui_Text(ctx, tname(dst))
        reaper.ImGui_PopStyleColor(ctx, 1)
      end

      for i, r in ipairs(recvs) do
        local uid = "R_"..tostring(dst).."_"..i
        local del, bulk_del = send_row(dst, r, uid, -1, all_tracks, state.bulk_edit_recvs)
        if del then
          if bulk_del then
            -- Supprimer tous les receives de la même piste destinataire (dst)
            local brecvs = get_receives(dst)
            for _, brv in ipairs(brecvs) do
              to_del[#to_del+1] = { dst, brv.idx }
            end
            break
          else
            to_del[#to_del+1] = { dst, r.idx }
          end
        end
      end
    end
  end

  if not any then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
    reaper.ImGui_Text(ctx, "  No receives.")
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  if #to_del > 0 then
    table.sort(to_del, function(a,b) return a[2]>b[2] end)
    for _, item in ipairs(to_del) do action_delete_receive(item[1], item[2]) end
  end

  reaper.ImGui_Spacing(ctx)
end

-- ============================================================
--  PANNEAU VCA
-- ============================================================
local function panel_vca()
  sec_title("VCA")

  local sel = state.sel_tracks
  if #sel == 0 then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
    reaper.ImGui_Text(ctx, "  Select a track on the left.")
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Spacing(ctx) ; return
  end

  -- Fonction helper : nom du Master d'un groupe
  local function grp_master_name(bit)
    for i = 0, reaper.CountTracks(0)-1 do
      local tr = reaper.GetTrack(0, i)
      local m  = reaper.GetSetTrackGroupMembership(tr, "VOLUME_VCA_MASTER", 0, 0)
      if m & bit ~= 0 then
        local _, nm = reaper.GetTrackName(tr)
        return nm, rcolor(tr)
      end
    end
    return nil, 0x888888FF
  end

  -- ── MASTER ───────────────────────────────────────────────────────────────
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
  reaper.ImGui_Text(ctx, "Master:")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SameLine(ctx, 70)

  -- Collecter les bits master de toutes les pistes sélectionnées
  local mb_all = 0
  for _, st in ipairs(sel) do
    mb_all = mb_all | reaper.GetSetTrackGroupMembership(st, "VOLUME_VCA_MASTER", 0, 0)
  end

  if mb_all ~= 0 then
    -- Afficher chaque groupe master avec bouton Retirer
    local first = true
    for g = 1, 16 do
      local bit = 2^(g-1)
      if mb_all & bit ~= 0 then
        local nm, gc = grp_master_name(bit)
        local lbl = (nm or ("Group "..g)) .. "  (G"..g..")"
        if first then first = false
        else reaper.ImGui_SetCursorPosX(ctx, 70) end
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        gc)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), gc)
        reaper.ImGui_Button(ctx, "##vcambg_"..g, 6, 22)
        reaper.ImGui_PopStyleColor(ctx, 2)
        reaper.ImGui_SameLine(ctx, 0, 4)
        reaper.ImGui_AlignTextToFramePadding(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.mute_txt)
        reaper.ImGui_Text(ctx, lbl)
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_SameLine(ctx, 260)
        if danger_btn("Remove##vcarm_"..g) then
          reaper.Undo_BeginBlock()
          for _, st in ipairs(sel) do
            reaper.GetSetTrackGroupMembership(st, "VOLUME_VCA_MASTER", bit, 0)
            reaper.GetSetTrackGroupMembership(st, "MUTE_LEAD",         bit, 0)
            reaper.GetSetTrackGroupMembership(st, "SOLO_LEAD",         bit, 0)
          end
          -- Retirer tous les slaves du groupe
          remove_vca_slaves(bit)
          reaper.Undo_EndBlock("SK RH : Retirer VCA Master G"..g, -1)
          set_status("Master G"..g.." removed.")
        end
      end
    end
  else
    -- Bouton + Master → popup choix groupe + options
    if col_btn("+ Master##vcasm", C.vca_col, 0xAA8A3AFF) then
      reaper.ImGui_OpenPopup(ctx, "vcamst")
    end
    if reaper.ImGui_BeginPopup(ctx, "vcamst") then
      reaper.ImGui_Text(ctx, "VCA Group:") ; reaper.ImGui_Separator(ctx)
      -- Options Mute Lead / Solo Lead EN PREMIER (avant la liste des groupes)
      if state.vca_mst_opts == nil then
        state.vca_mst_opts = { mute_lead = false, solo_lead = false }
      end
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),    0xBBBBBBFF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),   0x444444FF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(), 0xDDDDDDFF)
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1)
      local _, mlv = reaper.ImGui_Checkbox(ctx, "Mute Lead##vcaml",
        state.vca_mst_opts.mute_lead)
      if mlv ~= nil then state.vca_mst_opts.mute_lead = mlv end
      reaper.ImGui_SameLine(ctx, 0, 12)
      local _, slv = reaper.ImGui_Checkbox(ctx, "Solo Lead##vcasl",
        state.vca_mst_opts.solo_lead)
      if slv ~= nil then state.vca_mst_opts.solo_lead = slv end
      reaper.ImGui_PopStyleVar(ctx, 1)
      reaper.ImGui_PopStyleColor(ctx, 3)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Spacing(ctx)
      -- Liste des groupes APRES les options
      for g = 1, 16 do
        local bit = 2^(g-1)
        local nm, gc = grp_master_name(bit)
        local lbl = (nm or ("Group "..g)) .. "##vcamst_"..g
        if reaper.ImGui_Selectable(ctx, lbl) then
          reaper.Undo_BeginBlock()
          for _, st in ipairs(sel) do
            reaper.GetSetTrackGroupMembership(st, "VOLUME_VCA_MASTER", bit, bit)
            if state.vca_mst_opts.mute_lead then
              reaper.GetSetTrackGroupMembership(st, "MUTE_LEAD", bit, bit)
            end
            if state.vca_mst_opts.solo_lead then
              reaper.GetSetTrackGroupMembership(st, "SOLO_LEAD", bit, bit)
            end
          end
          reaper.Undo_EndBlock("SK RH : VCA Master G"..g, -1)
          set_status("Master G"..g.." assigned.")
        end
      end
      reaper.ImGui_EndPopup(ctx)
    end
  end

  reaper.ImGui_Spacing(ctx)

  -- ── SLAVE ────────────────────────────────────────────────────────────────
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
  reaper.ImGui_Text(ctx, "Slave:")
  reaper.ImGui_PopStyleColor(ctx, 1)

  -- Collecter les bits slave de toutes les pistes sélectionnées
  local sb_all = 0
  for _, st in ipairs(sel) do
    sb_all = sb_all | reaper.GetSetTrackGroupMembership(st, "VOLUME_VCA_SLAVE", 0, 0)
  end

  if sb_all ~= 0 then
    local first = true
    for g = 1, 16 do
      local bit = 2^(g-1)
      if sb_all & bit ~= 0 then
        local nm, gc = grp_master_name(bit)
        local lbl = (nm or ("Group "..g)) .. "  (G"..g..")"
        if first then
          reaper.ImGui_SameLine(ctx, 70) ; first = false
        else reaper.ImGui_SetCursorPosX(ctx, 70) end
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        gc)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), gc)
        reaper.ImGui_Button(ctx, "##vcasbg_"..g, 6, 22)
        reaper.ImGui_PopStyleColor(ctx, 2)
        reaper.ImGui_SameLine(ctx, 0, 4)
        reaper.ImGui_AlignTextToFramePadding(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.mute_txt)
        reaper.ImGui_Text(ctx, lbl)
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_SameLine(ctx, 260)
        if danger_btn("Remove##vcars_"..g) then
          reaper.Undo_BeginBlock()
          for _, st in ipairs(sel) do
            reaper.GetSetTrackGroupMembership(st, "VOLUME_VCA_SLAVE",  bit, 0)
            reaper.GetSetTrackGroupMembership(st, "MUTE_SLAVE",        bit, 0)
            reaper.GetSetTrackGroupMembership(st, "SOLO_SLAVE",        bit, 0)
          end
          reaper.Undo_EndBlock("SK RH : Retirer VCA Slave G"..g, -1)
          set_status("Slave G"..g.." removed.")
        end
      end
    end
    -- Bouton + Slave sur nouvelle ligne
    reaper.ImGui_SetCursorPosX(ctx, 70)
    if col_btn("+ Slave##vcass2", C.vca_col, 0xAA8A3AFF) then
      reaper.ImGui_OpenPopup(ctx, "vcaslv")
    end
  else
    reaper.ImGui_SameLine(ctx, 70)
    if col_btn("+ Slave##vcass", C.vca_col, 0xAA8A3AFF) then
      reaper.ImGui_OpenPopup(ctx, "vcaslv")
    end
  end

  if reaper.ImGui_BeginPopup(ctx, "vcaslv") then
    reaper.ImGui_Text(ctx, "VCA Group:") ; reaper.ImGui_Separator(ctx)
    for g = 1, 16 do
      local bit = 2^(g-1)
      local nm, _ = grp_master_name(bit)
      local lbl = (nm or ("Group "..g)) .. "##vcaslv_"..g
      if reaper.ImGui_Selectable(ctx, lbl) then
        -- Vérifier si le Master de ce groupe a Mute Lead / Solo Lead actifs
        local master_mute_lead = false
        local master_solo_lead = false
        for i = 0, reaper.CountTracks(0)-1 do
          local tr = reaper.GetTrack(0, i)
          local m  = reaper.GetSetTrackGroupMembership(tr, "VOLUME_VCA_MASTER", 0, 0)
          if m & bit ~= 0 then
            local ml = reaper.GetSetTrackGroupMembership(tr, "MUTE_LEAD", 0, 0)
            local sl = reaper.GetSetTrackGroupMembership(tr, "SOLO_LEAD", 0, 0)
            if ml & bit ~= 0 then master_mute_lead = true end
            if sl & bit ~= 0 then master_solo_lead = true end
            break
          end
        end
        reaper.Undo_BeginBlock()
        for _, st in ipairs(sel) do
          reaper.GetSetTrackGroupMembership(st, "VOLUME_VCA_SLAVE", bit, bit)
          -- Activer Mute Follow si Master a Mute Lead OU si l'option est cochée
          if master_mute_lead or (state.vca_slv_opts and state.vca_slv_opts.mute_follow) then
            reaper.GetSetTrackGroupMembership(st, "MUTE_SLAVE", bit, bit)
          end
          -- Activer Solo Follow si Master a Solo Lead OU si l'option est cochée
          if master_solo_lead or (state.vca_slv_opts and state.vca_slv_opts.solo_follow) then
            reaper.GetSetTrackGroupMembership(st, "SOLO_SLAVE", bit, bit)
          end
        end
        reaper.Undo_EndBlock("SK RH : VCA Slave G"..g, -1)
        set_status("Slave G"..g.." assigned.")
      end
    end
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    -- Options Mute Follow / Solo Follow
    if state.vca_slv_opts == nil then
      state.vca_slv_opts = { mute_follow = false, solo_follow = false }
    end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),    0xBBBBBBFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),   0x444444FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(), 0xDDDDDDFF)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1)
    local _, mfv = reaper.ImGui_Checkbox(ctx, "Mute Follow##vcamf",
      state.vca_slv_opts.mute_follow)
    if mfv ~= nil then state.vca_slv_opts.mute_follow = mfv end
    reaper.ImGui_SameLine(ctx, 0, 12)
    local _, sfv = reaper.ImGui_Checkbox(ctx, "Solo Follow##vcasf",
      state.vca_slv_opts.solo_follow)
    if sfv ~= nil then state.vca_slv_opts.solo_follow = sfv end
    reaper.ImGui_PopStyleVar(ctx, 1)
    reaper.ImGui_PopStyleColor(ctx, 3)
    reaper.ImGui_EndPopup(ctx)
  end

  reaper.ImGui_Spacing(ctx) ; reaper.ImGui_Spacing(ctx)
end

-- ============================================================
--  COLOR PICKER PISTES
-- ============================================================

local CP_PALETTE = {
  { 0.85, 0.25, 0.25 }, { 0.90, 0.55, 0.20 }, { 0.85, 0.75, 0.15 },
  { 0.25, 0.70, 0.30 }, { 0.20, 0.65, 0.75 }, { 0.30, 0.40, 0.85 },
  { 0.60, 0.25, 0.85 }, { 0.85, 0.25, 0.65 }, { 0.60, 0.60, 0.60 },
  { 0.85, 0.85, 0.85 },
}

local function cp_pastel(r, g, b, t)
  return r + (1-r)*t, g + (1-g)*t, b + (1-b)*t
end

local function rgb_to_reaper_col(r, g, b)
  return (math.floor(r*255+0.5) << 16)
       | (math.floor(g*255+0.5) <<  8)
       |  math.floor(b*255+0.5)
end

local function apply_color_to_sel(r, g, b)
  local rc = rgb_to_reaper_col(r, g, b)
  reaper.Undo_BeginBlock()
  for _, t in ipairs(state.sel_tracks) do
    if reaper.ValidatePtr(t, "MediaTrack*") then
      reaper.SetTrackColor(t, rc)
    end
  end
  reaper.Undo_EndBlock("SK RH : Color tracks", -1)
  set_status(string.format("%d track(s) colored.", #state.sel_tracks))
  state.last_proj_state = -1
end

local function remove_color_from_sel()
  reaper.Undo_BeginBlock()
  for _, t in ipairs(state.sel_tracks) do
    if reaper.ValidatePtr(t, "MediaTrack*") then
      reaper.SetMediaTrackInfo_Value(t, "I_CUSTOMCOLOR", 0)
    end
  end
  reaper.Undo_EndBlock("SK RH : Clear track colors", -1)
  set_status("Color cleared.")
  state.last_proj_state = -1
end

local function draw_color_picker_popup()
  if state.cp_open then
    reaper.ImGui_OpenPopup(ctx, "sk_cp_tracks")
    state.cp_open = false
  end

  reaper.ImGui_SetNextWindowSize(ctx, 340, 0, reaper.ImGui_Cond_Always())
  if not reaper.ImGui_BeginPopup(ctx, "sk_cp_tracks") then return end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.white)
  reaper.ImGui_Text(ctx, "Color")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  reaper.ImGui_SetNextItemWidth(ctx, 200)
  local pc, pv = reaper.ImGui_SliderDouble(ctx, "##pastel",
    state.cp_pastel, 0.0, 1.0,
    "Pastel: " .. math.floor(state.cp_pastel * 100 + 0.5) .. "%%")
  if pc then state.cp_pastel = pv end
  reaper.ImGui_Spacing(ctx)

  local draw = reaper.ImGui_GetWindowDrawList(ctx)
  local pt   = state.cp_pastel
  for i, c in ipairs(CP_PALETTE) do
    local r, g, b = cp_pastel(c[1], c[2], c[3], pt)
    local col32 = (math.floor(r*255+0.5) << 24)
                | (math.floor(g*255+0.5) << 16)
                | (math.floor(b*255+0.5) <<  8)
                | 0xFF
    local clicked = reaper.ImGui_InvisibleButton(ctx, "##cp_"..i, 24, 24)
    local hovered = reaper.ImGui_IsItemHovered(ctx)
    local rx, ry  = reaper.ImGui_GetItemRectMin(ctx)
    reaper.ImGui_DrawList_AddRectFilled(draw, rx, ry, rx+24, ry+24, col32)
    if hovered then
      reaper.ImGui_DrawList_AddRect(draw, rx-1, ry-1, rx+25, ry+25, 0xFFFFFFFF)
    end
    if clicked then
      apply_color_to_sel(r, g, b)
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    if i < #CP_PALETTE then reaper.ImGui_SameLine(ctx, 0, 4) end
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  if reaper.ImGui_Button(ctx, "Clear color##cp_clr") then
    remove_color_from_sel()
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
end

-- Pistes cibles : sel_tracks si t en fait partie, sinon t seul
local function targets_for(tr)
  for _, st in ipairs(state.sel_tracks) do
    if st == tr then return state.sel_tracks end
  end
  return { tr }
end

-- ============================================================
--  COLONNE GAUCHE
-- ============================================================
local function draw_left(all_tracks_unused)
  -- Header fixe HORS du BeginChild (ne scrolle pas)
  if col_btn("+ Track##new_tr", C.send_col, 0x4A9A6AFF) then
    state.new_track_color = 0
      state.new_track_cp_pastel = 0.3
      reaper.ImGui_OpenPopup(ctx, "new_track_popup")
  end
  if #state.sel_tracks > 0 then
    reaper.ImGui_SameLine(ctx, 0, 6)
    if col_btn("+Folder##folder_btn", 0xAA5500FF, 0xCC6600FF) then
      state.folder_name_buf = ""
      state.folder_color    = 0
      state.folder_cp_pastel = 0.3
      reaper.ImGui_OpenPopup(ctx, "new_folder_popup")
    end
    reaper.ImGui_SameLine(ctx, 0, 6)
    if col_btn("+ Bus##bus_btn", 0x7A2A9AFF, 0x9A3ACCFF) then
      state.bus_name_buf = ""
      state.bus_color    = 0
      state.bus_cp_pastel = 0.3
      reaper.ImGui_OpenPopup(ctx, "new_bus_popup")
    end
    reaper.ImGui_SameLine(ctx, 0, 6)
    if col_btn("+ VCA##vca_btn", 0x8A6A2AFF, 0xAA8A3AFF) then
      state.vca_name_buf  = ""
      state.vca_color     = 0
      state.vca_mute_lead = false
      state.vca_solo_lead = false
      state.vca_cp_pastel = 0.3
      reaper.ImGui_OpenPopup(ctx, "new_vca_popup")
    end
    reaper.ImGui_SameLine(ctx, 0, 6)
    if col_btn("+ FX##fx_btn", 0x1A7AAAFF, 0x2A9ACCFF) then
      state.fx_name_buf = ""
      state.fx_color    = 0
      state.fx_cp_pastel = 0.3
      reaper.ImGui_OpenPopup(ctx, "new_fx_popup")
    end
    reaper.ImGui_SameLine(ctx, 0, 6)
    if col_btn("Color##cp_btn", 0x2A4A6AFF, 0x3A6A9AFF) then
      state.cp_open   = true
      state.cp_pastel = 0.3
    end
  end
  draw_color_picker_popup()

  -- Popup création piste FX
  if reaper.ImGui_BeginPopupModal(ctx, "new_fx_popup", nil,
      reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    reaper.ImGui_Text(ctx, "FX track name:")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 260)
    local fxch, fxnv = reaper.ImGui_InputText(ctx, "##fx_name",
      state.fx_name_buf, reaper.ImGui_InputTextFlags_AutoSelectAll())
    if fxch then state.fx_name_buf = fxnv end
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    -- Color picker
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, "Color:")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 200)
    local fxpp, fxpv = reaper.ImGui_SliderDouble(ctx, "##fx_pastel",
      state.fx_cp_pastel, 0.0, 1.0,
      "Pastel: " .. math.floor(state.fx_cp_pastel * 100 + 0.5) .. "%%")
    if fxpp then state.fx_cp_pastel = fxpv end
    reaper.ImGui_Spacing(ctx)
    local fxdraw = reaper.ImGui_GetWindowDrawList(ctx)
    for i, c in ipairs(CP_PALETTE) do
      local r, g, b = cp_pastel(c[1], c[2], c[3], state.fx_cp_pastel)
      local col32 = (math.floor(r*255+0.5) << 24)
                  | (math.floor(g*255+0.5) << 16)
                  | (math.floor(b*255+0.5) <<  8)
                  | 0xFF
      local clicked = reaper.ImGui_InvisibleButton(ctx, "##fxp_"..i, 24, 24)
      local hovered = reaper.ImGui_IsItemHovered(ctx)
      local rx, ry  = reaper.ImGui_GetItemRectMin(ctx)
      reaper.ImGui_DrawList_AddRectFilled(fxdraw, rx, ry, rx+24, ry+24, col32)
      local sel_col = state.fx_color
      local sr = (sel_col >> 16) & 0xFF
      local sg = (sel_col >>  8) & 0xFF
      local sb_c= sel_col        & 0xFF
      local cr = math.floor(r*255+0.5)
      local cg = math.floor(g*255+0.5)
      local cb = math.floor(b*255+0.5)
      if sr == cr and sg == cg and sb_c == cb then
        reaper.ImGui_DrawList_AddRect(fxdraw, rx-2, ry-2, rx+26, ry+26, 0xFFFFFFFF)
      elseif hovered then
        reaper.ImGui_DrawList_AddRect(fxdraw, rx-1, ry-1, rx+25, ry+25, 0xAAAAAAFF)
      end
      if clicked then
        state.fx_color = rgb_to_reaper_col(r, g, b)
      end
      if i < #CP_PALETTE then reaper.ImGui_SameLine(ctx, 0, 4) end
    end
    if state.fx_color ~= 0 then
      reaper.ImGui_Spacing(ctx)
      local pr = ((state.fx_color >> 16) & 0xFF) / 255.0
      local pg = ((state.fx_color >>  8) & 0xFF) / 255.0
      local pb = ( state.fx_color        & 0xFF) / 255.0
      local pc32 = (math.floor(pr*255+0.5) << 24)
                 | (math.floor(pg*255+0.5) << 16)
                 | (math.floor(pb*255+0.5) <<  8)
                 | 0xFF
      local px, py = reaper.ImGui_GetCursorScreenPos(ctx)
      reaper.ImGui_DrawList_AddRectFilled(fxdraw, px, py, px+260, py+16, pc32)
      reaper.ImGui_Dummy(ctx, 260, 16)
    end
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    if col_btn("Create##fx_ok", C.send_col, 0x4A9A6AFF) then
      local nm = state.fx_name_buf ~= "" and state.fx_name_buf or "FX"
      action_create_fx(nm, state.fx_color)
      state.fx_name_buf = ""
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx, 0, 8)
    if reaper.ImGui_Button(ctx, "Cancel##fx_no") then
      state.fx_name_buf = ""
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end

  -- Popup création VCA
  if reaper.ImGui_BeginPopupModal(ctx, "new_vca_popup", nil,
      reaper.ImGui_WindowFlags_AlwaysAutoResize()) then

    reaper.ImGui_Text(ctx, "VCA group name:")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 260)
    local vch, vnv = reaper.ImGui_InputText(ctx, "##vca_name",
      state.vca_name_buf, reaper.ImGui_InputTextFlags_AutoSelectAll())
    if vch then state.vca_name_buf = vnv end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    -- Options Mute Lead / Solo Lead
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),    0xBBBBBBFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),   0x444444FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(), 0xDDDDDDFF)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1)
    local _, mlv = reaper.ImGui_Checkbox(ctx, "Mute Lead##vca_ml", state.vca_mute_lead)
    if mlv ~= nil then state.vca_mute_lead = mlv end
    reaper.ImGui_SameLine(ctx, 0, 16)
    local _, slv = reaper.ImGui_Checkbox(ctx, "Solo Lead##vca_sl", state.vca_solo_lead)
    if slv ~= nil then state.vca_solo_lead = slv end
    reaper.ImGui_PopStyleVar(ctx, 1)
    reaper.ImGui_PopStyleColor(ctx, 3)

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    -- Couleur
    reaper.ImGui_Text(ctx, "Color:")
    reaper.ImGui_Spacing(ctx)

    -- Slider pastel
    reaper.ImGui_SetNextItemWidth(ctx, 200)
    local vpp, vpv = reaper.ImGui_SliderDouble(ctx, "##vca_pastel",
      state.vca_cp_pastel, 0.0, 1.0,
      "Pastel: " .. math.floor(state.vca_cp_pastel * 100 + 0.5) .. "%%")
    if vpp then state.vca_cp_pastel = vpv end
    reaper.ImGui_Spacing(ctx)

    -- Palette
    local draw = reaper.ImGui_GetWindowDrawList(ctx)
    local pt   = state.vca_cp_pastel
    for i, c in ipairs(CP_PALETTE) do
      local r, g, b = cp_pastel(c[1], c[2], c[3], pt)
      local col32 = (math.floor(r*255+0.5) << 24)
                  | (math.floor(g*255+0.5) << 16)
                  | (math.floor(b*255+0.5) <<  8)
                  | 0xFF
      local clicked = reaper.ImGui_InvisibleButton(ctx, "##vcap_"..i, 24, 24)
      local hovered = reaper.ImGui_IsItemHovered(ctx)
      local rx, ry  = reaper.ImGui_GetItemRectMin(ctx)
      reaper.ImGui_DrawList_AddRectFilled(draw, rx, ry, rx+24, ry+24, col32)
      -- Liseré si couleur sélectionnée
      local sel_col = state.vca_color
      local sr = (sel_col >> 16) & 0xFF
      local sg = (sel_col >>  8) & 0xFF
      local sb_c= sel_col        & 0xFF
      local cr = math.floor(r*255+0.5)
      local cg = math.floor(g*255+0.5)
      local cb = math.floor(b*255+0.5)
      if sr == cr and sg == cg and sb_c == cb then
        reaper.ImGui_DrawList_AddRect(draw, rx-2, ry-2, rx+26, ry+26, 0xFFFFFFFF)
      elseif hovered then
        reaper.ImGui_DrawList_AddRect(draw, rx-1, ry-1, rx+25, ry+25, 0xAAAAAAFF)
      end
      if clicked then
        state.vca_color = rgb_to_reaper_col(r, g, b)
      end
      if i < #CP_PALETTE then reaper.ImGui_SameLine(ctx, 0, 4) end
    end

    -- Aperçu couleur sélectionnée
    if state.vca_color ~= 0 then
      reaper.ImGui_Spacing(ctx)
      local pr = ((state.vca_color >> 16) & 0xFF) / 255.0
      local pg = ((state.vca_color >>  8) & 0xFF) / 255.0
      local pb = ( state.vca_color        & 0xFF) / 255.0
      local pc32 = (math.floor(pr*255+0.5) << 24)
                 | (math.floor(pg*255+0.5) << 16)
                 | (math.floor(pb*255+0.5) <<  8)
                 | 0xFF
      local px, py = reaper.ImGui_GetCursorScreenPos(ctx)
      reaper.ImGui_DrawList_AddRectFilled(draw, px, py, px+260, py+16, pc32)
      reaper.ImGui_Dummy(ctx, 260, 16)
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    if col_btn("Create##vca_ok", C.send_col, 0x4A9A6AFF) then
      local nm = state.vca_name_buf ~= "" and state.vca_name_buf or "VCA"
      action_create_vca(nm, state.vca_color, state.vca_mute_lead, state.vca_solo_lead)
      state.vca_name_buf = ""
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx, 0, 8)
    if reaper.ImGui_Button(ctx, "Cancel##vca_no") then
      state.vca_name_buf = ""
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end

  -- Popup création bus
  if reaper.ImGui_BeginPopupModal(ctx, "new_bus_popup", nil,
      reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    reaper.ImGui_Text(ctx, "Summing bus name:")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 260)
    local bch, bnv = reaper.ImGui_InputText(ctx, "##bus_name",
      state.bus_name_buf, reaper.ImGui_InputTextFlags_AutoSelectAll())
    if bch then state.bus_name_buf = bnv end
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    -- Color picker
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, "Color:")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 200)
    local buspp, buspv = reaper.ImGui_SliderDouble(ctx, "##bus_pastel",
      state.bus_cp_pastel, 0.0, 1.0,
      "Pastel: " .. math.floor(state.bus_cp_pastel * 100 + 0.5) .. "%%")
    if buspp then state.bus_cp_pastel = buspv end
    reaper.ImGui_Spacing(ctx)
    local busdraw = reaper.ImGui_GetWindowDrawList(ctx)
    local buspt   = state.bus_cp_pastel
    for i, c in ipairs(CP_PALETTE) do
      local r, g, b = cp_pastel(c[1], c[2], c[3], buspt)
      local col32 = (math.floor(r*255+0.5) << 24)
                  | (math.floor(g*255+0.5) << 16)
                  | (math.floor(b*255+0.5) <<  8)
                  | 0xFF
      local clicked = reaper.ImGui_InvisibleButton(ctx, "##busp_"..i, 24, 24)
      local hovered = reaper.ImGui_IsItemHovered(ctx)
      local rx, ry  = reaper.ImGui_GetItemRectMin(ctx)
      reaper.ImGui_DrawList_AddRectFilled(busdraw, rx, ry, rx+24, ry+24, col32)
      local sel_col = state.bus_color
      local sr = (sel_col >> 16) & 0xFF
      local sg = (sel_col >>  8) & 0xFF
      local sb_c= sel_col        & 0xFF
      local cr = math.floor(r*255+0.5)
      local cg = math.floor(g*255+0.5)
      local cb = math.floor(b*255+0.5)
      if sr == cr and sg == cg and sb_c == cb then
        reaper.ImGui_DrawList_AddRect(busdraw, rx-2, ry-2, rx+26, ry+26, 0xFFFFFFFF)
      elseif hovered then
        reaper.ImGui_DrawList_AddRect(busdraw, rx-1, ry-1, rx+25, ry+25, 0xAAAAAAFF)
      end
      if clicked then
        state.bus_color = rgb_to_reaper_col(r, g, b)
      end
      if i < #CP_PALETTE then reaper.ImGui_SameLine(ctx, 0, 4) end
    end
    if state.bus_color ~= 0 then
      reaper.ImGui_Spacing(ctx)
      local pr = ((state.bus_color >> 16) & 0xFF) / 255.0
      local pg = ((state.bus_color >>  8) & 0xFF) / 255.0
      local pb = ( state.bus_color        & 0xFF) / 255.0
      local pc32 = (math.floor(pr*255+0.5) << 24)
                 | (math.floor(pg*255+0.5) << 16)
                 | (math.floor(pb*255+0.5) <<  8)
                 | 0xFF
      local px, py = reaper.ImGui_GetCursorScreenPos(ctx)
      reaper.ImGui_DrawList_AddRectFilled(busdraw, px, py, px+260, py+16, pc32)
      reaper.ImGui_Dummy(ctx, 260, 16)
    end
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    if col_btn("Create##bus_ok", C.send_col, 0x4A9A6AFF) then
      local nm = state.bus_name_buf ~= "" and state.bus_name_buf or "BUS"
      action_create_bus(nm, state.bus_color)
      state.bus_name_buf = ""
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx, 0, 8)
    if reaper.ImGui_Button(ctx, "Cancel##bus_no") then
      state.bus_name_buf = ""
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end

  -- Popup création folder
  if reaper.ImGui_BeginPopupModal(ctx, "new_folder_popup", nil,
      reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    reaper.ImGui_Text(ctx, "Folder name:")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 260)
    local fch, fnv = reaper.ImGui_InputText(ctx, "##folder_name",
      state.folder_name_buf, reaper.ImGui_InputTextFlags_AutoSelectAll())
    if fch then state.folder_name_buf = fnv end
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    -- Color picker
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, "Color:")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 200)
    local fldpp, fldpv = reaper.ImGui_SliderDouble(ctx, "##fld_pastel",
      state.folder_cp_pastel, 0.0, 1.0,
      "Pastel: " .. math.floor(state.folder_cp_pastel * 100 + 0.5) .. "%%")
    if fldpp then state.folder_cp_pastel = fldpv end
    reaper.ImGui_Spacing(ctx)
    local flddraw = reaper.ImGui_GetWindowDrawList(ctx)
    local fldpt   = state.folder_cp_pastel
    for i, c in ipairs(CP_PALETTE) do
      local r, g, b = cp_pastel(c[1], c[2], c[3], fldpt)
      local col32 = (math.floor(r*255+0.5) << 24)
                  | (math.floor(g*255+0.5) << 16)
                  | (math.floor(b*255+0.5) <<  8)
                  | 0xFF
      local clicked = reaper.ImGui_InvisibleButton(ctx, "##fldp_"..i, 24, 24)
      local hovered = reaper.ImGui_IsItemHovered(ctx)
      local rx, ry  = reaper.ImGui_GetItemRectMin(ctx)
      reaper.ImGui_DrawList_AddRectFilled(flddraw, rx, ry, rx+24, ry+24, col32)
      local sel_col = state.folder_color
      local sr = (sel_col >> 16) & 0xFF
      local sg = (sel_col >>  8) & 0xFF
      local sb_c= sel_col        & 0xFF
      local cr = math.floor(r*255+0.5)
      local cg = math.floor(g*255+0.5)
      local cb = math.floor(b*255+0.5)
      if sr == cr and sg == cg and sb_c == cb then
        reaper.ImGui_DrawList_AddRect(flddraw, rx-2, ry-2, rx+26, ry+26, 0xFFFFFFFF)
      elseif hovered then
        reaper.ImGui_DrawList_AddRect(flddraw, rx-1, ry-1, rx+25, ry+25, 0xAAAAAAFF)
      end
      if clicked then
        state.folder_color = rgb_to_reaper_col(r, g, b)
      end
      if i < #CP_PALETTE then reaper.ImGui_SameLine(ctx, 0, 4) end
    end
    if state.folder_color ~= 0 then
      reaper.ImGui_Spacing(ctx)
      local pr = ((state.folder_color >> 16) & 0xFF) / 255.0
      local pg = ((state.folder_color >>  8) & 0xFF) / 255.0
      local pb = ( state.folder_color        & 0xFF) / 255.0
      local pc32 = (math.floor(pr*255+0.5) << 24)
                 | (math.floor(pg*255+0.5) << 16)
                 | (math.floor(pb*255+0.5) <<  8)
                 | 0xFF
      local px, py = reaper.ImGui_GetCursorScreenPos(ctx)
      reaper.ImGui_DrawList_AddRectFilled(flddraw, px, py, px+260, py+16, pc32)
      reaper.ImGui_Dummy(ctx, 260, 16)
    end
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    if col_btn("Create##folder_ok", C.send_col, 0x4A9A6AFF) then
      local nm = state.folder_name_buf ~= "" and state.folder_name_buf or "FOLDER"
      action_create_folder(nm, state.folder_color)
      state.folder_name_buf = ""
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx, 0, 8)
    if reaper.ImGui_Button(ctx, "Cancel##folder_no") then
      state.folder_name_buf = ""
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end
  if reaper.ImGui_BeginPopupModal(ctx, "new_track_popup", nil,
      reaper.ImGui_WindowFlags_AlwaysAutoResize()) then

    reaper.ImGui_Text(ctx, "Number of tracks to create:")
    reaper.ImGui_SetNextItemWidth(ctx, 80)
    local cc, cv = reaper.ImGui_InputInt(ctx, "##new_tr_count", state.new_track_count)
    if cc then state.new_track_count = math.max(1, math.min(64, cv)) end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, "Name mask:")
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
    reaper.ImGui_Text(ctx, "  Leave empty for auto name. The REAPER track")
    reaper.ImGui_Text(ctx, "  number will be appended automatically.")
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 260)
    local ch, nv = reaper.ImGui_InputText(ctx, "##new_tr_name", state.new_track_name,
      reaper.ImGui_InputTextFlags_AutoSelectAll())
    if ch then state.new_track_name = nv end

    -- Apercu des noms qui seront créés
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
    -- Color picker
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, "Color:")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 200)
    local ntrpp, ntrpv = reaper.ImGui_SliderDouble(ctx, "##ntr_pastel",
      state.new_track_cp_pastel, 0.0, 1.0,
      "Pastel: " .. math.floor(state.new_track_cp_pastel * 100 + 0.5) .. "%%")
    if ntrpp then state.new_track_cp_pastel = ntrpv end
    reaper.ImGui_Spacing(ctx)
    local ntrdraw = reaper.ImGui_GetWindowDrawList(ctx)
    for i, c in ipairs(CP_PALETTE) do
      local r, g, b = cp_pastel(c[1], c[2], c[3], state.new_track_cp_pastel)
      local col32 = (math.floor(r*255+0.5) << 24)
                  | (math.floor(g*255+0.5) << 16)
                  | (math.floor(b*255+0.5) <<  8)
                  | 0xFF
      local clicked = reaper.ImGui_InvisibleButton(ctx, "##ntrp_"..i, 24, 24)
      local hovered = reaper.ImGui_IsItemHovered(ctx)
      local rx, ry  = reaper.ImGui_GetItemRectMin(ctx)
      reaper.ImGui_DrawList_AddRectFilled(ntrdraw, rx, ry, rx+24, ry+24, col32)
      local sel_col = state.new_track_color
      local sr = (sel_col >> 16) & 0xFF
      local sg = (sel_col >>  8) & 0xFF
      local sb_c= sel_col        & 0xFF
      local cr = math.floor(r*255+0.5)
      local cg = math.floor(g*255+0.5)
      local cb = math.floor(b*255+0.5)
      if sr == cr and sg == cg and sb_c == cb then
        reaper.ImGui_DrawList_AddRect(ntrdraw, rx-2, ry-2, rx+26, ry+26, 0xFFFFFFFF)
      elseif hovered then
        reaper.ImGui_DrawList_AddRect(ntrdraw, rx-1, ry-1, rx+25, ry+25, 0xAAAAAAFF)
      end
      if clicked then
        state.new_track_color = rgb_to_reaper_col(r, g, b)
      end
      if i < #CP_PALETTE then reaper.ImGui_SameLine(ctx, 0, 4) end
    end
    if state.new_track_color ~= 0 then
      reaper.ImGui_Spacing(ctx)
      local pr = ((state.new_track_color >> 16) & 0xFF) / 255.0
      local pg = ((state.new_track_color >>  8) & 0xFF) / 255.0
      local pb = ( state.new_track_color        & 0xFF) / 255.0
      local pc32 = (math.floor(pr*255+0.5) << 24)
                 | (math.floor(pg*255+0.5) << 16)
                 | (math.floor(pb*255+0.5) <<  8)
                 | 0xFF
      local px, py = reaper.ImGui_GetCursorScreenPos(ctx)
      reaper.ImGui_DrawList_AddRectFilled(ntrdraw, px, py, px+260, py+16, pc32)
      reaper.ImGui_Dummy(ctx, 260, 16)
    end
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    local lbl = state.new_track_count > 1
      and string.format("Create %d tracks##new_tr_ok", state.new_track_count)
      or  "Create 1 track##new_tr_ok"
    if col_btn(lbl, C.send_col, 0x4A9A6AFF) then
      reaper.Undo_BeginBlock()
      -- Position d'insertion : après la dernière piste sélectionnée,
      -- ou à la fin du projet si aucune piste n'est sélectionnée
      local base_insert = reaper.CountTracks(0)
      if #state.sel_tracks > 0 then
        local last_pos = 0
        for _, st in ipairs(state.sel_tracks) do
          local p = math.floor(reaper.GetMediaTrackInfo_Value(st, "IP_TRACKNUMBER"))
          if p > last_pos then last_pos = p end
        end
        base_insert = last_pos  -- IP_TRACKNUMBER est 1-based, InsertTrackAtIndex est 0-based
      end
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
        if state.new_track_color ~= 0 then
          reaper.SetTrackColor(new_tr, state.new_track_color)
        end
      end
      reaper.Undo_EndBlock("SK RH : Create tracks", -1)
      set_status(string.format("%d track(s) created.", state.new_track_count))
      state.new_track_name  = ""
      state.new_track_count = 1
      state.new_track_color = 0
      state.last_proj_state = -1
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx, 0, 8)
    if reaper.ImGui_Button(ctx, "Cancel##new_tr_no") then
      state.new_track_name  = ""
      state.new_track_count = 1
      state.new_track_color = 0
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end
  reaper.ImGui_Separator(ctx)

  if reaper.CountTracks(0) == 0 then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
    reaper.ImGui_TextWrapped(ctx, "No tracks in project.")
    reaper.ImGui_PopStyleColor(ctx, 1)
    return
  end

  -- Liste scrollable dans un BeginChild sans PushStyleColor autour
  local child_ok = reaper.ImGui_BeginChild(ctx, "left_list", COL_LEFT_W, 0, 0)
  if not child_ok then
    reaper.ImGui_EndChild(ctx)
    return
  end

  local all_proj = {}
  for i = 0, reaper.CountTracks(0)-1 do all_proj[#all_proj+1] = reaper.GetTrack(0,i) end
  local aw = COL_LEFT_W - 20

  for _, t in ipairs(all_proj) do
    local col    = rcolor(t)
    local is_foc = (t == state.focused_track)
    local in_sel = false
    for _, st in ipairs(state.sel_tracks) do if st == t then in_sel=true; break end end
    local idx_n  = tidx(t)

    -- Badge couleur
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        col)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), col)
    reaper.ImGui_Button(ctx, "##cb_"..idx_n, 5, 22)
    reaper.ImGui_PopStyleColor(ctx, 2)
    reaper.ImGui_SameLine(ctx, 0, 4)

    -- Selectable ou InputText selon mode renommage
    local sel_w = aw - 119  -- badge(9) + D(26) + IO(28) + MS(30) + del(26)
    if state.rename_track_ptr == t then
      -- Mode renommage : InputText inline
      reaper.ImGui_SetNextItemWidth(ctx, sel_w)
      local flags = reaper.ImGui_InputTextFlags_EnterReturnsTrue()
                  | reaper.ImGui_InputTextFlags_AutoSelectAll()
      -- Focus + sélection automatique dès l'apparition du champ
      if reaper.ImGui_IsWindowAppearing(ctx) or state.rename_just_opened then
        reaper.ImGui_SetKeyboardFocusHere(ctx)
        state.rename_just_opened = false
      end
      local confirmed, nv = reaper.ImGui_InputText(ctx,
        "##rename_"..idx_n, state.rename_track_buf, flags)
      if nv ~= nil then state.rename_track_buf = nv end
      -- Confirmer sur Enter ou perte de focus
      if confirmed or (not reaper.ImGui_IsItemActive(ctx)
          and reaper.ImGui_IsItemDeactivated(ctx)) then
        reaper.Undo_BeginBlock()
        reaper.GetSetMediaTrackInfo_String(t, "P_NAME", state.rename_track_buf, true)
        reaper.Undo_EndBlock("SK RH : Rename track", -1)
        set_status("Track renamed.")
        state.rename_track_ptr = nil
        state.rename_track_buf = ""
        state.last_proj_state  = -1
      end
      -- Annuler sur Escape
      if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
        state.rename_track_ptr = nil
        state.rename_track_buf = ""
      end
    else
      local hdr_col = is_foc and C.bg_sel or (in_sel and 0x2A3A2AFF or C.bg_item)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),        hdr_col)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), 0x3A4A3AFF)
      local clicked = reaper.ImGui_Selectable(ctx, tname(t).."##t_"..idx_n,
        is_foc or in_sel, reaper.ImGui_SelectableFlags_AllowDoubleClick(), sel_w, 22)
      if clicked then
        if reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
          -- Double-clic : passer en mode renommage
          state.rename_track_ptr   = t
          state.rename_track_buf   = tname(t)
          state.rename_just_opened = true
        else
          local ctrl  = reaper.ImGui_GetKeyMods(ctx) == reaper.ImGui_Mod_Ctrl()
          local shift = reaper.ImGui_GetKeyMods(ctx) == reaper.ImGui_Mod_Shift()
          if ctrl then
            reaper.SetTrackSelected(t, not reaper.IsTrackSelected(t))
          elseif shift and state.focused_track then
            local fi = tidx(state.focused_track)
            local ti = tidx(t)
            local lo, hi = math.min(fi,ti), math.max(fi,ti)
            reaper.Main_OnCommand(40297, 0)
            for _, pt in ipairs(all_proj) do
              local pi = tidx(pt)
              if pi >= lo and pi <= hi then reaper.SetTrackSelected(pt, true) end
            end
          else
            reaper.Main_OnCommand(40297, 0)
            reaper.SetTrackSelected(t, true)
          end
          state.focused_track  = t
          state.last_sel_count = -1
        end
      end
      reaper.ImGui_PopStyleColor(ctx, 2)
    end

    -- Menu contextuel clic droit (doit être immédiatement après le Selectable)
    if reaper.ImGui_BeginPopupContextItem(ctx, "ctx_tr_"..idx_n) then
      -- Réinitialiser le nombre de canaux à 2 à chaque ouverture
      if reaper.ImGui_IsWindowAppearing(ctx) then
        state.nchan_buf = 2
      end

      -- Nombre de canaux
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_Text(ctx, "Channel pairs:")
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, 160)
      local ncc, ncv = reaper.ImGui_InputInt(ctx, "##nchan_"..idx_n, state.nchan_buf)
      if ncc then state.nchan_buf = math.max(2, math.min(64, ncv)) end
      reaper.ImGui_SameLine(ctx, 0, 8)
      if reaper.ImGui_Button(ctx, "  OK  ##nchan_ok_"..idx_n) then
        local targets = targets_for(t)
        local new_nchan = state.nchan_buf
        -- Vérifier les conflits avec les sends existants
        local conflicts = {}
        for _, st in ipairs(targets) do
          if reaper.ValidatePtr(st, "MediaTrack*") then
            local tname_st = tname(st)
            -- Sends sortants : vérifier I_SRCCHAN
            for i = 0, reaper.GetTrackNumSends(st, 0) - 1 do
              local sc = math.floor(reaper.GetTrackSendInfo_Value(st, 0, i, "I_SRCCHAN")) & ~1024
              local pair = math.floor(sc / 2) + 1
              if sc + 2 > new_nchan then
                local dst_tr = reaper.GetTrackSendInfo_Value(st, 0, i, "P_DESTTRACK")
                local dname = reaper.ValidatePtr(dst_tr, "MediaTrack*") and
                              ({reaper.GetTrackName(dst_tr)})[2] or "?"
                conflicts[#conflicts+1] = string.format(
                  '"%s" → "%s" : src ch %d-%d', tname_st, dname, sc+1, sc+2)
              end
            end
            -- Receives entrants : vérifier I_DSTCHAN
            for i = 0, reaper.GetTrackNumSends(st, -1) - 1 do
              local dc = math.floor(reaper.GetTrackSendInfo_Value(st, -1, i, "I_DSTCHAN"))
              if dc + 2 > new_nchan then
                local src_tr = reaper.GetTrackSendInfo_Value(st, -1, i, "P_SRCTRACK")
                local sname = reaper.ValidatePtr(src_tr, "MediaTrack*") and
                              ({reaper.GetTrackName(src_tr)})[2] or "?"
                conflicts[#conflicts+1] = string.format(
                  '"%s" → "%s" : dst ch %d-%d', sname, tname_st, dc+1, dc+2)
              end
            end
          end
        end
        if #conflicts > 0 then
          -- Afficher le message d'erreur
          local msg = string.format(
            "Warning: reducing to %d channels will break %d send(s):\n\n",
            new_nchan, #conflicts)
          for _, c in ipairs(conflicts) do
            msg = msg .. "  - " .. c .. "\n"
          end
          msg = msg .. "\nPlease fix the affected sends first."
          reaper.MB(msg, "SK Routing Hub — Channel conflict", 0)
        else
          reaper.Undo_BeginBlock()
          for _, st in ipairs(targets) do
            if reaper.ValidatePtr(st, "MediaTrack*") then
              reaper.SetMediaTrackInfo_Value(st, "I_NCHAN", new_nchan)
            end
          end
          reaper.Undo_EndBlock("SK RH : Track channels", -1)
          set_status(string.format("%d channel(s) applied.", new_nchan))
          reaper.ImGui_CloseCurrentPopup(ctx)
        end
      end
      reaper.ImGui_Spacing(ctx)

      reaper.ImGui_Separator(ctx)

      if reaper.ImGui_MenuItem(ctx, "Add child track (Folder)##ctx_child_"..idx_n) then
        action_add_child_track(t)
      end
      reaper.ImGui_Separator(ctx)
      if reaper.ImGui_MenuItem(ctx, "Add child track (Bus)##ctx_bus_"..idx_n) then
        action_add_bus_child(t)
      end
      reaper.ImGui_EndPopup(ctx)
    end

    -- Bouton Dissoudre (folders) ou espace réservé (autres pistes)
    local is_folder_tr = reaper.GetMediaTrackInfo_Value(t, "I_FOLDERDEPTH") == 1
    reaper.ImGui_SameLine(ctx, 0, 4)
    if is_folder_tr then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0xAA5500FF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xCC6600FF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          C.white)
      if reaper.ImGui_Button(ctx, "D##dis_"..idx_n, 22, 22) then
        action_dissolve_folder(t)
        state.sel_tracks      = {}
        state.focused_track   = nil
        state.last_proj_state = -1
      end
      reaper.ImGui_PopStyleColor(ctx, 3)
    else
      reaper.ImGui_Dummy(ctx, 22, 22)
    end

    -- Bouton IO (ouvre le routing REAPER de la piste)
    reaper.ImGui_SameLine(ctx, 0, 4)
    if reaper.ImGui_Button(ctx, "IO##io_l"..idx_n, 24, 22) then
      action_open_io(t)
    end

    -- Bouton MS
    reaper.ImGui_SameLine(ctx, 0, 4)
    local ms_on = reaper.GetMediaTrackInfo_Value(t, "B_MAINSEND") == 1
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
      ms_on and C.bg_item or C.danger)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
      ms_on and C.text_dim or 0xFF9999FF)
    if reaper.ImGui_Button(ctx, "MS##ms_"..idx_n, 26, 22) then
      local new_val = ms_on and 0 or 1
      local targets = targets_for(t)
      for _, st in ipairs(targets) do
        if reaper.ValidatePtr(st, "MediaTrack*") then
          reaper.SetMediaTrackInfo_Value(st, "B_MAINSEND", new_val)
        end
      end
      state.last_proj_state = -1
    end
    reaper.ImGui_PopStyleColor(ctx, 2)

    -- Bouton supprimer piste
    reaper.ImGui_SameLine(ctx, 0, 4)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        C.danger)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.danger_hov)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          C.white)
    if reaper.ImGui_Button(ctx, "X##del_tr_"..idx_n, 22, 22) then
      local targets = targets_for(t)
      state.confirm_delete = {
        ptrs = { table.unpack(targets) },
        name = #targets > 1
          and string.format("%d tracks", #targets)
          or  tname(t)
      }
      reaper.ImGui_OpenPopup(ctx, "confirm_del_track")
    end
    reaper.ImGui_PopStyleColor(ctx, 3)
  end

  -- Popup de confirmation suppression
  if reaper.ImGui_BeginPopupModal(ctx, "confirm_del_track", nil,
      reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    local cd = state.confirm_delete
    local del_name = cd and cd.name or ""
    reaper.ImGui_Text(ctx, 'Delete track "' .. del_name .. '"?')
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, "This action cannot be undone.")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    if col_btn("Delete##conf_del", C.danger, C.danger_hov) then
      if cd and cd.ptrs then
        -- Différer la suppression (de bas en haut pour éviter les décalages)
        state.pending_deletes = {}
        for _, ptr in ipairs(cd.ptrs) do
          if reaper.ValidatePtr(ptr, "MediaTrack*") then
            table.insert(state.pending_deletes, ptr)
          end
        end
      end
      state.sel_tracks     = {}
      state.focused_track  = nil
      state.last_sel_count = -1
      state.confirm_delete = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx, 0, 8)
    if reaper.ImGui_Button(ctx, "Cancel##conf_del_no") then
      state.confirm_delete = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end

  reaper.ImGui_EndChild(ctx)
end

-- ============================================================
--  COLONNE DROITE
-- ============================================================
local function draw_right(all_tracks)
  local child_ok = reaper.ImGui_BeginChild(ctx, "right", 0, 0, 0)
  if not child_ok then
    reaper.ImGui_EndChild(ctx)
    return
  end

  if #state.sel_tracks == 0 then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
    reaper.ImGui_Text(ctx, "  <- Select tracks in REAPER.")
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_EndChild(ctx)
    return
  end

  -- En-tête : toutes les pistes sélectionnées sur une ligne
  local nb = #state.sel_tracks
  if nb == 1 then
    -- Une seule piste : badge couleur + nom
    local ft = state.sel_tracks[1]
    local fc = rcolor(ft)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        fc)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), fc)
    reaper.ImGui_Button(ctx, "##hb0", 7, 20)
    reaper.ImGui_PopStyleColor(ctx, 2)
    reaper.ImGui_SameLine(ctx, 0, 6)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.white)
    reaper.ImGui_Text(ctx, tname(ft))
    reaper.ImGui_PopStyleColor(ctx, 1)
  else
    -- Multi-sélection : badges couleur + compteur
    for i, t in ipairs(state.sel_tracks) do
      local fc = rcolor(t)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        fc)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), fc)
      reaper.ImGui_Button(ctx, "##hb"..i, 7, 20)
      reaper.ImGui_PopStyleColor(ctx, 2)
      if i < nb then reaper.ImGui_SameLine(ctx, 0, 3) end
    end
    reaper.ImGui_SameLine(ctx, 0, 8)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.white)
    reaper.ImGui_Text(ctx, nb .. " tracks selected")
    reaper.ImGui_PopStyleColor(ctx, 1)
  end
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  panel_sends(all_tracks)
  reaper.ImGui_Separator(ctx) ; reaper.ImGui_Spacing(ctx)
  panel_receives(all_tracks)
  reaper.ImGui_Separator(ctx) ; reaper.ImGui_Spacing(ctx)
  panel_vca()

  reaper.ImGui_EndChild(ctx)
end

-- ============================================================
--  STATUT
-- ============================================================
local function draw_status()
  reaper.ImGui_Separator(ctx)
  local msg = reaper.time_precise() < state.status_timer
    and state.status_msg
    or  ((reaper.GetProjectName(0, "") ~= "" and reaper.GetProjectName(0, "") or "(untitled)").. "  |  Total tracks: "..reaper.CountTracks(0))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
  reaper.ImGui_Text(ctx, "  "..msg)
  reaper.ImGui_PopStyleColor(ctx, 1)
end

-- ============================================================
--  BOUCLE
-- ============================================================
local function loop()
  -- Exécute la suppression différée AVANT tout accès aux pointeurs de pistes
  if state.pending_delete then
    local ptr = state.pending_delete
    state.pending_delete = nil
    if reaper.ValidatePtr(ptr, "MediaTrack*") then
      reaper.Undo_BeginBlock()
      -- Dissoudre le folder si nécessaire
      local depth = math.floor(reaper.GetMediaTrackInfo_Value(ptr, "I_FOLDERDEPTH"))
      if depth == 1 then action_dissolve_folder(ptr) end
      -- Si la piste est VCA Master, retirer les slaves avant suppression
      local mb = reaper.GetSetTrackGroupMembership(ptr, "VOLUME_VCA_MASTER", 0, 0)
      if mb ~= 0 then
        for g = 1, 16 do
          local bit = 2^(g-1)
          if mb & bit ~= 0 then remove_vca_slaves(bit) end
        end
      end
      reaper.DeleteTrack(ptr)
      reaper.Undo_EndBlock("SK RH : Delete track", -1)
      set_status("Track deleted.")
    end
    state.last_proj_state = -1
    state.last_sel_count  = -1
    reaper.defer(loop)
    return  -- repart sur un frame propre
  end

  if state.pending_deletes and #state.pending_deletes > 0 then
    local ptrs = state.pending_deletes
    state.pending_deletes = nil
    -- Trier par index décroissant pour éviter les décalages
    table.sort(ptrs, function(a, b)
      local ia = reaper.ValidatePtr(a, "MediaTrack*") and
                 math.floor(reaper.GetMediaTrackInfo_Value(a, "IP_TRACKNUMBER")) or 0
      local ib = reaper.ValidatePtr(b, "MediaTrack*") and
                 math.floor(reaper.GetMediaTrackInfo_Value(b, "IP_TRACKNUMBER")) or 0
      return ia > ib
    end)
    reaper.Undo_BeginBlock()
    local count = 0
    for _, ptr in ipairs(ptrs) do
      if reaper.ValidatePtr(ptr, "MediaTrack*") then
        -- Dissoudre le folder si nécessaire
        local depth = math.floor(reaper.GetMediaTrackInfo_Value(ptr, "I_FOLDERDEPTH"))
        if depth == 1 then action_dissolve_folder(ptr) end
        -- Si la piste est VCA Master, retirer les slaves avant suppression
        local mb = reaper.GetSetTrackGroupMembership(ptr, "VOLUME_VCA_MASTER", 0, 0)
        if mb ~= 0 then
          for g = 1, 16 do
            local bit = 2^(g-1)
            if mb & bit ~= 0 then remove_vca_slaves(bit) end
          end
        end
        reaper.DeleteTrack(ptr)
        count = count + 1
      end
    end
    reaper.Undo_EndBlock("SK RH : Delete tracks", -1)
    set_status(string.format("%d track(s) deleted.", count))
    state.last_proj_state = -1
    state.last_sel_count  = -1
    reaper.defer(loop)
    return
  end

  local sc = reaper.CountSelectedTracks(0)
  local ps = reaper.GetProjectStateChangeCount(0)
  if sc ~= state.last_sel_count or ps ~= state.last_proj_state then
    refresh_sel()
    state.last_sel_count  = sc
    state.last_proj_state = ps
  end

  local all = get_all_tracks()
  local nc, nv = push_style()

  reaper.ImGui_SetNextWindowSize(ctx, WIN_W, WIN_H, reaper.ImGui_Cond_FirstUseEver())
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, 680, 500, 9999, 9999)

  local vis, open = reaper.ImGui_Begin(ctx, SCRIPT_NAME, true,
    reaper.ImGui_WindowFlags_NoCollapse())

  if vis then
    -- Statut en bas : on le rend d'abord pour mesurer sa hauteur,
    -- puis on utilise GetContentRegionAvail pour les colonnes
    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    local status_h = 36  -- separator + text + padding

    -- Colonnes dans un child de hauteur = avail_h - status_h
    local cols_ok = reaper.ImGui_BeginChild(ctx, "cols", 0, avail_h - status_h, 0)
    if cols_ok then
      draw_left()
      reaper.ImGui_SameLine(ctx, 0, 6)
      draw_right(all)
    end
    reaper.ImGui_EndChild(ctx)

    draw_status()
  end

  reaper.ImGui_End(ctx)
  pop_style(nc, nv)
  if open then reaper.defer(loop) end
end

-- ============================================================
--  START
-- ============================================================
refresh_sel()
reaper.defer(loop)
