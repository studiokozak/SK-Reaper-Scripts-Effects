-- =============================================================================
--  SK Routing Hub
--  Studio Kozak — Stéphan JEDRASIAK
-- =============================================================================
--  Fenêtre de travail pour le routage des pistes REAPER :
--   - colonne de gauche : liste des pistes du projet (sélection, renommage,
--     folders, création de pistes, de folders, de bus, de retours FX et de VCA) ;
--   - colonne de droite : sends et receives des pistes sélectionnées, ou leurs
--     groupes VCA, selon la vue choisie en haut de la fenêtre.
--  Toutes les modifications peuvent être annulées avec Ctrl+Z dans REAPER.
-- =============================================================================

-- Le script a besoin de l'extension ReaImGui pour afficher sa fenêtre.
if not reaper.ImGui_CreateContext then
  reaper.MB("SK Routing Hub requires the ReaImGui extension (ReaPack).", "SK Routing Hub", 0)
  return
end

local SCRIPT_NAME = "SK Routing Hub"
local WIN_W, WIN_H         = 1040, 720  -- taille de la fenêtre au premier lancement
local WIN_MIN_W, WIN_MIN_H = 980, 520   -- taille minimale
local LEFT_W = 310                      -- largeur de la colonne des pistes

-- Les trois modes d'envoi proposés, dans l'ordre des menus déroulants.
-- Libellés courts dans les lignes, libellés complets dans les fenêtres.
-- SM_VALS donne le code REAPER correspondant à chaque mode.
local SM_LABELS = { "Post-Fader", "Pre-Fader", "Pre-FX" }
local SM_LONG   = { "Post-Fader (Post-Pan)", "Pre-Fader (Post-FX)", "Pre-Fader (Pre-FX)" }
local SM_VALS   = { 0, 3, 1 }
local SM_LONG_STR = table.concat(SM_LONG, "\0") .. "\0"

-- Position d'un mode REAPER dans la liste ci-dessus.
local function sm_to_idx(v)
  v = math.floor(v)
  for i, val in ipairs(SM_VALS) do if val == v then return i end end
  return 1
end

-- Les canaux sont choisis par paires : 1-2, 3-4, 5-6...
-- REAPER les note par le numéro du premier canal, en partant de 0.
local MAX_PAIRS = 64
local PAIR_LABELS = {}
for i = 1, MAX_PAIRS do PAIR_LABELS[i] = string.format("%d-%d", i * 2 - 1, i * 2) end

local function pair_to_chan(pair) return (pair - 1) * 2 end

-- Le repère "mono" que REAPER ajoute aux canaux source est ignoré ici.
local function chan_to_pair(raw)
  raw = math.floor(raw)
  if raw >= 1024 then raw = raw - 1024 end
  return math.floor(raw / 2) + 1
end

-- Options d'affichage de ReaImGui. Une valeur par défaut est utilisée si la
-- version installée ne les propose pas.
local function imgui_flag(name, fallback)
  local f = reaper["ImGui_" .. name]
  if f then return f() end
  return fallback or 0
end

local CF_BORDERS  = imgui_flag("ChildFlags_Borders", imgui_flag("ChildFlags_Border", 1))
local CF_PADDING  = imgui_flag("ChildFlags_AlwaysUseWindowPadding", 2)
local CF_AUTO_Y   = imgui_flag("ChildFlags_AutoResizeY", 0)
local HOVER_DELAY = imgui_flag("HoveredFlags_DelayShort", 0)

-- ============================================================
--  FENÊTRE ET POLICES
-- ============================================================
local ctx  = reaper.ImGui_CreateContext(SCRIPT_NAME)
local font = reaper.ImGui_CreateFont("sans-serif", 14)
reaper.ImGui_Attach(ctx, font)
local font_title = reaper.ImGui_CreateFont("sans-serif", 20)
reaper.ImGui_Attach(ctx, font_title)

-- ============================================================
--  COULEURS DE L'INTERFACE
-- ============================================================
-- Chaque couleur est notée en hexadécimal : rouge, vert, bleu, opacité.
local C = {
  bg          = 0x1B1B1EFF,
  bg_panel    = 0x202024FF,
  bg_card     = 0x232327FF,
  bg_item     = 0x2B2B30FF,
  bg_item_hov = 0x35353BFF,
  bg_item_act = 0x3E3E45FF,
  bg_header   = 0x141416FF,
  bg_popup    = 0x252529FF,
  border      = 0x36363CFF,
  border_soft = 0x2E2E33FF,
  text        = 0xE8E8EAFF,
  text_dim    = 0x9A9AA2FF,
  text_faint  = 0x6A6A72FF,
  white       = 0xFFFFFFFF,
  no_color    = 0x5A5A60FF,
  accent      = 0x4A8FCAFF,
  accent_dim  = 0x3A5F86FF,
  accent_hov  = 0x4A72A0FF,
  send_col    = 0x3A7A5AFF,
  send_hov    = 0x4A9A6AFF,
  recv_col    = 0x5A4A8AFF,
  recv_hov    = 0x6A5A9AFF,
  vca_col     = 0x8A6A2AFF,
  vca_hov     = 0xAA8A3AFF,
  folder_col  = 0xC86A1AFF,
  bus_col     = 0x9A4ACCFF,
  fx_col      = 0x2A9ACCFF,
  danger      = 0x8A2A2AFF,
  danger_hov  = 0xAA3A3AFF,
  danger_txt  = 0xFF8F8FFF,
  mute_on     = 0x7A5600FF,
  mute_txt    = 0xFFCC44FF,
  phase_on    = 0x7A2A5AFF,
  phase_txt   = 0xFFAADDFF,
  mono_on     = 0x2A5A9AFF,
  ms_off_bg   = 0x3E2226FF,
  ghost       = 0x00000000,
  row_hover   = 0x2A2A30FF,
  row_sel     = 0x283444FF,
  row_focus   = 0x2F4258FF,
  row_sep     = 0x2C2C31FF,
  seg_bg      = 0x26262AFF,
  badge_bg    = 0x303036FF,
  tag_on_bg   = 0x3E3420FF,
  tag_off_bg  = 0x2A2A2EFF,
  dot_recv    = 0x3AAA5AFF,
  dot_vca     = 0xCC3A3AFF,
  ok          = 0x3AAA5AFF,
  warn        = 0xE8A23DFF,
  title       = 0xE8A23DFF,
}

-- ============================================================
--  ÉTAT DU SCRIPT
-- ============================================================
-- Tout ce que le script doit retenir d'un affichage à l'autre.
local state = {
  sel_tracks      = {},    -- pistes actuellement sélectionnées
  sel_set         = {},    -- les mêmes, pour savoir vite si une piste en fait partie
  focused_track   = nil,   -- piste active dans la colonne de gauche
  last_sel_count  = -1,    -- repères pour détecter un changement dans REAPER
  last_proj_state = -1,
  status_msg      = "",    -- message affiché dans la barre du bas
  status_kind     = "ok",  -- "ok" ou "warn" (avertissement)
  status_timer    = 0,     -- heure à laquelle le message disparaît
  win_cx          = 0,     -- centre de la fenêtre, pour placer les dialogues
  win_cy          = 0,
  open_dialog     = nil,   -- dialogue à ouvrir à l'affichage en cours
  view_mode       = "sr",  -- "sr" = Sends & receives, "vca" = Groups / VCA
  track_filter    = "",    -- filtre de la liste des pistes
  collapsed       = {},    -- folders repliés dans la liste
  confirm_delete  = nil,   -- suppression de piste en attente de confirmation
  bulk_edit_sends = false, -- édition groupée des sends activée
  bulk_edit_recvs = false, -- édition groupée des receives activée
  -- Réglage "pastel" de chaque sélecteur de couleur (mémorisé entre les sessions)
  cp_pastel        = 0.3,
  folder_cp_pastel = 0.3,
  bus_cp_pastel    = 0.3,
  fx_cp_pastel     = 0.3,
  vca_cp_pastel    = 0.3,
  -- Dialogue de création (piste, folder, bus, FX, VCA) : un seul ouvert à la fois
  dlg_name        = "",
  dlg_color       = 0,
  new_track_count = 1,
  vca_mute_lead   = false,
  vca_solo_lead   = false,
  vca_volume_lead = false,
  -- Renommage dans la liste
  rename_track_ptr   = nil,
  rename_just_opened = false,
  rename_track_buf   = "",
  nchan_buf       = 2,     -- nombre de canaux saisi dans le menu de piste
  new_send_count  = 1,     -- nombre de sends/receives à créer par piste cochée
  -- Réglages du prochain send/receive à créer (conservés d'un dialogue à l'autre)
  np = {
    mode_idx  = 1,
    mono      = false,
    phase     = false,
    mute      = false,
    src_pair  = 1,
    dst_pair  = 1,
    main_send = false,  -- true = l'envoi au master de la source est coupé
  },
  dest_checked  = {},   -- pistes cochées dans le dialogue de création
  send_filter   = "",   -- filtre de la liste du dialogue de création
  send_newname  = "",   -- nom d'une nouvelle piste à créer depuis ce dialogue
  -- Options proposées quand on assigne la sélection à un groupe VCA
  vca_mst_opts  = { mute_lead = false, solo_lead = false, volume_lead = false },
  vca_slv_opts  = { mute_follow = false, solo_follow = false, volume_follow = false },
  -- Groupe VCA en cours de modification (bouton Edit) et ses options
  vca_edit_mst_group = nil,
  vca_edit_mst       = nil,
  vca_edit_slv_group = nil,
  vca_edit_slv       = nil,
  vca_open_edit      = nil,   -- fenêtre d'édition VCA à ouvrir
  cp_open            = false, -- palette des pistes ouverte
  cp_center          = false, -- recentrer la palette à la prochaine ouverture
}

-- ============================================================
--  RÉGLAGES MÉMORISÉS
-- ============================================================
-- Les réglages pastel et la dernière vue utilisée sont conservés par REAPER,
-- même après sa fermeture.
local EXT_SECTION = "SK_RoutingHub"

local function load_pastel(key, default)
  return tonumber(reaper.GetExtState(EXT_SECTION, key)) or default
end

local function save_pastel(key, value)
  reaper.SetExtState(EXT_SECTION, key, tostring(value), true)
end

for _, key in ipairs({ "cp_pastel", "folder_cp_pastel", "bus_cp_pastel", "fx_cp_pastel", "vca_cp_pastel" }) do
  state[key] = load_pastel(key, state[key])
end
if reaper.GetExtState(EXT_SECTION, "view_mode") == "vca" then state.view_mode = "vca" end

-- ============================================================
--  OUTILS GÉNÉRAUX
-- ============================================================
-- Affiche un message dans la barre du bas pendant quelques secondes.
local function set_status(msg, kind)
  state.status_msg   = msg
  state.status_kind  = kind or "ok"
  state.status_timer = reaper.time_precise() + 3.5
end

-- Nom d'une piste ("?" si elle n'existe plus).
local function tname(t)
  if not t or not reaper.ValidatePtr(t, "MediaTrack*") then return "?" end
  local _, n = reaper.GetTrackName(t) ; return n
end

-- Numéro de la piste, tel qu'affiché dans REAPER (1 = première piste).
local function tidx(t)
  return math.floor(reaper.GetMediaTrackInfo_Value(t, "IP_TRACKNUMBER"))
end

-- Couleur d'une piste, convertie pour l'affichage dans la fenêtre.
local function rcolor(t)
  if not t or not reaper.ValidatePtr(t, "MediaTrack*") then return C.no_color end
  local c = reaper.GetTrackColor(t)
  if c == 0 then return C.no_color end
  local r, g, b = reaper.ColorFromNative(c & 0xFFFFFF)
  return (r << 24) | (g << 16) | (b << 8) | 0xFF
end

-- Augmente le nombre de canaux d'une piste si elle en a moins que nécessaire.
local function ensure_chans(t, need)
  local cur = math.max(2, math.floor(reaper.GetMediaTrackInfo_Value(t, "I_NCHAN")))
  if cur < need then reaper.SetMediaTrackInfo_Value(t, "I_NCHAN", need) end
end

local function get_all_tracks()
  local t = {}
  for i = 0, reaper.CountTracks(0)-1 do t[#t+1] = reaper.GetTrack(0,i) end
  return t
end

-- Transforme une liste de pistes en ensemble, pour tester vite l'appartenance.
local function build_track_set(tracks)
  local set = {}
  for _, tr in ipairs(tracks) do set[tr] = true end
  return set
end

-- Relit la sélection de pistes de REAPER.
local function refresh_sel()
  local tracks = {}
  for i = 0, reaper.CountSelectedTracks(0)-1 do
    tracks[#tracks+1] = reaper.GetSelectedTrack(0,i)
  end
  state.sel_tracks = tracks
  state.sel_set    = build_track_set(tracks)
  if not (state.focused_track and state.sel_set[state.focused_track]) then
    state.focused_track = tracks[1]
  end
end

-- Pistes concernées par une action : toute la sélection si la piste en fait
-- partie, sinon la piste seule.
local function targets_for(tr)
  if state.sel_set[tr] then return state.sel_tracks end
  return { tr }
end

-- Oublie la sélection mémorisée après une action qui réorganise les pistes :
-- elle sera relue à l'affichage suivant.
local function reset_sel_cache()
  state.last_proj_state = -1
  state.sel_tracks      = {}
  state.sel_set         = {}
  state.focused_track   = nil
end

-- Les actions qui ajoutent, déplacent ou suppriment des pistes sont mises en
-- attente et exécutées au début de l'affichage suivant, jamais pendant que la
-- liste des pistes est en train d'être dessinée.
local action_queue = {}
local function queue(fn) action_queue[#action_queue+1] = fn end

-- ============================================================
--  LECTURE DES SENDS ET RECEIVES
-- ============================================================
-- Lit tous les réglages d'un send (cat = 0) ou d'un receive (cat = -1).
local function read_send(track, cat, idx)
  local function get(field) return reaper.GetTrackSendInfo_Value(track, cat, idx, field) end
  return {
    idx      = idx,
    dest     = cat == 0  and get("P_DESTTRACK") or nil,
    src      = cat == -1 and get("P_SRCTRACK")  or nil,
    vol      = get("D_VOL"),
    pan      = get("D_PAN"),
    mute     = get("B_MUTE") == 1,
    mode     = math.floor(get("I_SENDMODE")),
    phase    = get("B_PHASE") == 1,
    mono     = get("B_MONO") == 1,
    src_pair = chan_to_pair(get("I_SRCCHAN")),
    dst_pair = chan_to_pair(get("I_DSTCHAN")),
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
--  ACTIONS — SENDS ET RECEIVES
-- ============================================================
-- Un receive n'est que l'autre bout d'un send : créer un receive sur une piste
-- revient à créer un send depuis la piste source.

-- Applique les réglages choisis (np) à un send qui vient d'être créé.
local function apply_np(src_track, send_idx, np)
  -- Ajouter des canaux à la piste peut décaler les sends déjà présents :
  -- on note leurs canaux avant, et on les rétablit après.
  local saved = {}
  local ns = reaper.GetTrackNumSends(src_track, 0)
  for i = 0, ns - 1 do
    saved[i] = reaper.GetTrackSendInfo_Value(src_track, 0, i, "I_SRCCHAN")
  end
  ensure_chans(src_track, np.src_pair * 2)
  for i = 0, ns - 1 do
    if i ~= send_idx then
      reaper.SetTrackSendInfo_Value(src_track, 0, i, "I_SRCCHAN", saved[i])
    end
  end

  local function set(field, v) reaper.SetTrackSendInfo_Value(src_track, 0, send_idx, field, v) end
  set("I_SENDMODE", SM_VALS[np.mode_idx])
  set("I_SRCCHAN",  pair_to_chan(np.src_pair))
  set("I_DSTCHAN",  pair_to_chan(np.dst_pair))
  set("B_MONO",     np.mono  and 1 or 0)
  set("B_PHASE",    np.phase and 1 or 0)
  set("B_MUTE",     np.mute  and 1 or 0)
  -- L'envoi au master de la source n'est coupé que si la case est cochée.
  if np.main_send then
    reaper.SetMediaTrackInfo_Value(src_track, "B_MAINSEND", 0)
  end
end

-- Crée un send de chaque piste source vers chaque piste destination.
local function action_create_sends(src_tracks, dst_tracks, np, noun)
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local count = 0

  for _, src in ipairs(src_tracks) do
    for _, dst in ipairs(dst_tracks) do
      if src ~= dst then
        reaper.CreateTrackSend(src, dst)
        local n = reaper.GetTrackNumSends(src, 0)
        apply_np(src, n-1, np)
        count = count + 1
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK RH : Create send(s)", -1)
  set_status(string.format("%d %s(s) created", count, noun))
end

-- Crée une nouvelle piste juste après la dernière piste sélectionnée, et un
-- send de chaque piste sélectionnée vers elle.
local function action_create_sends_new_track(src_tracks, name, np)
  reaper.Undo_BeginBlock()
  local last = 0
  for _, t in ipairs(src_tracks) do
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
      apply_np(src, n-1, np)
      count = count + 1
    end
  end
  reaper.Undo_EndBlock("SK RH : Send(s) + new track", -1)
  set_status(string.format("\"%s\" created, %d send(s)", name, count))
end

-- Crée une nouvelle piste source juste avant la première piste sélectionnée,
-- qui envoie son signal vers chaque piste sélectionnée (un receive pour elles).
local function action_create_recv_new_track(recv_tracks, name, np)
  reaper.Undo_BeginBlock()
  local first = math.huge
  for _, t in ipairs(recv_tracks) do
    local i = tidx(t) ; if i < first then first = i end
  end
  if first == math.huge then first = reaper.CountTracks(0) + 1 end
  local insert_idx = first - 1
  reaper.InsertTrackAtIndex(insert_idx, true)
  local new_t = reaper.GetTrack(0, insert_idx)
  reaper.GetSetMediaTrackInfo_String(new_t, "P_NAME", name, true)
  local count = 0
  for _, dst in ipairs(recv_tracks) do
    if dst ~= new_t and reaper.ValidatePtr(dst, "MediaTrack*") then
      reaper.CreateTrackSend(new_t, dst)
      local n = reaper.GetTrackNumSends(new_t, 0)
      apply_np(new_t, n-1, np)
      count = count + 1
    end
  end
  reaper.Undo_EndBlock("SK RH : Receive(s) + new track", -1)
  set_status(string.format("\"%s\" created, %d receive(s)", name, count))
end

local function action_delete_send(track, idx)
  reaper.Undo_BeginBlock()
  reaper.RemoveTrackSend(track, 0, idx)
  reaper.Undo_EndBlock("SK RH : Remove send", -1)
  set_status("Send removed")
end

local function action_delete_receive(track, idx)
  reaper.Undo_BeginBlock()
  reaper.RemoveTrackSend(track, -1, idx)
  reaper.Undo_EndBlock("SK RH : Remove receive", -1)
  set_status("Receive removed")
end

-- Ouvre la fenêtre de routing de REAPER pour la piste.
local function action_open_io(track)
  reaper.SetOnlyTrackSelected(track)
  reaper.Main_OnCommand(40293, 0)
end

-- Modifie un réglage d'un send (cat = 0) ou d'un receive (cat = -1).
local function action_set_send_field(track, cat, idx, field, val)
  reaper.SetTrackSendInfo_Value(track, cat, idx, field, val)
end

-- Redirige un send vers une autre piste en gardant tous ses réglages.
local function action_change_dest(src_track, send_idx, new_dst, s)
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
  apply_np(src_track, n-1, np)
  reaper.SetTrackSendInfo_Value(src_track, 0, n-1, "D_VOL", s.vol)
  reaper.SetTrackSendInfo_Value(src_track, 0, n-1, "D_PAN", s.pan)
  reaper.Undo_EndBlock("SK RH : Change destination", -1)
  set_status("Destination changed to " .. tname(new_dst))
end

-- ============================================================
--  ACTIONS — FOLDERS
-- ============================================================
-- Dans REAPER, chaque piste porte une valeur de dossier :
--   1  = la piste ouvre un folder (elle en est le parent) ;
--   0  = piste ordinaire ;
--  -1  = dernière piste d'un folder (-2 si elle ferme deux folders, etc.).
-- Les fonctions ci-dessous ajustent ces valeurs pour déplacer des pistes
-- dans un folder, y compris quand plusieurs folders sont imbriqués.

-- Supprime le folder : le parent et ses pistes deviennent des pistes ordinaires.
local function action_dissolve_folder(pt)
  reaper.Undo_BeginBlock()
  reaper.SetMediaTrackInfo_Value(pt, "I_FOLDERDEPTH", 0)
  local ti = tidx(pt) ; local level = 1
  for i = ti, reaper.CountTracks(0)-1 do
    local t = reaper.GetTrack(0,i) ; local d = reaper.GetMediaTrackInfo_Value(t,"I_FOLDERDEPTH")
    reaper.SetMediaTrackInfo_Value(t,"I_FOLDERDEPTH",0)
    level = level + d ; if level <= 0 then break end
  end
  reaper.Undo_EndBlock("SK RH : Dissolve folder", -1)
  set_status("Folder dissolved")
end

-- Position de la piste en comptant à partir de 0, comme REAPER le demande
-- pour insérer ou déplacer des pistes.
local function track_idx0(t)
  return tidx(t) - 1
end

local function is_folder_track(t)
  return reaper.GetMediaTrackInfo_Value(t, "I_FOLDERDEPTH") == 1
end

-- Toutes les pistes parentes d'un folder.
local function get_folder_tracks_only()
  local folders = {}
  for i = 0, reaper.CountTracks(0)-1 do
    local tr = reaper.GetTrack(0, i)
    if is_folder_track(tr) then folders[#folders+1] = tr end
  end
  return folders
end

-- Pistes sous lesquelles la sélection peut être placée : pistes ordinaires
-- qui ne font pas partie de la sélection.
local function get_convertible_tracks_only(selected_set)
  local list = {}
  for i = 0, reaper.CountTracks(0)-1 do
    local tr = reaper.GetTrack(0, i)
    if not is_folder_track(tr) and not selected_set[tr] then
      list[#list+1] = tr
    end
  end
  return list
end

-- Dernière piste d'un folder : sa position et sa valeur de dossier.
local function get_folder_end_index_and_depth(folder_track)
  local start = track_idx0(folder_track)
  local depth = 1
  local total = reaper.CountTracks(0)
  for i = start + 1, total - 1 do
    local tr = reaper.GetTrack(0, i)
    local d = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
    depth = depth + d
    if depth <= 0 then return i, d end
  end
  local last = total - 1
  local last_tr = reaper.GetTrack(0, last)
  return last, reaper.GetMediaTrackInfo_Value(last_tr, "I_FOLDERDEPTH")
end

-- Niveau d'imbrication de chaque piste (0 = hors de tout folder).
local function compute_depth_before_each_track()
  local total = reaper.CountTracks(0)
  local depth_before = {}
  local depth = 0
  for i = 0, total - 1 do
    depth_before[i] = depth
    local tr = reaper.GetTrack(0, i)
    depth = depth + reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
  end
  return depth_before
end

-- Folder qui contient directement ce folder, s'il y en a un.
local function find_parent_folder(folder_track, depth_before)
  local idx = track_idx0(folder_track)
  local my_depth = depth_before[idx]
  if my_depth <= 0 then return nil end
  local parent_depth = my_depth - 1
  for i = idx - 1, 0, -1 do
    local tr = reaper.GetTrack(0, i)
    if is_folder_track(tr) and depth_before[i] == parent_depth then
      return tr
    end
  end
  return nil
end

-- Quand plusieurs folders se terminent sur la même piste, compte combien
-- d'entre eux la nouvelle dernière piste devra refermer.
local function compute_levels_to_move(folder_track)
  local depth_before = compute_depth_before_each_track()
  local end_idx, end_depth = get_folder_end_index_and_depth(folder_track)
  if end_depth >= 0 then return 1, end_idx, end_depth end
  local levels = 1
  local cur = folder_track
  while true do
    local parent = find_parent_folder(cur, depth_before)
    if not parent then break end
    local p_end_idx = get_folder_end_index_and_depth(parent)
    if p_end_idx == end_idx then
      levels = levels + 1
      cur = parent
    else
      break
    end
  end
  local max_levels = -math.floor(end_depth)
  if levels > max_levels then levels = max_levels end
  return levels, end_idx, end_depth
end

-- Sort une piste de son folder. Si elle refermait un folder, ce rôle passe
-- à la piste non déplacée qui la précède.
local function detach_track_repair(track, selected_set)
  local d = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
  if d < 0 then
    local idx = track_idx0(track)
    local j = idx - 1
    while j >= 0 do
      local prev = reaper.GetTrack(0, j)
      if prev and not selected_set[prev] then
        local prev_d = reaper.GetMediaTrackInfo_Value(prev, "I_FOLDERDEPTH")
        reaper.SetMediaTrackInfo_Value(prev, "I_FOLDERDEPTH", prev_d + d)
        break
      end
      j = j - 1
    end
  end
  reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", 0)
end

-- Déplace provisoirement une piste à la fin du projet, hors de tout folder.
local function move_one_track_to_project_end_root(track)
  reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", 0)
  reaper.Main_OnCommand(40297, 0)
  reaper.SetTrackSelected(track, true)
  reaper.ReorderSelectedTracks(reaper.CountTracks(0), 0)
  reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", 0)
end

-- Place une piste en dernière position d'un folder.
local function insert_as_last_child_nested_safe(folder_track, track)
  local levels, end_idx, end_depth = compute_levels_to_move(folder_track)
  local end_tr = reaper.GetTrack(0, end_idx)
  if not end_tr then return end
  reaper.Main_OnCommand(40297, 0)
  reaper.SetTrackSelected(track, true)
  reaper.ReorderSelectedTracks(end_idx + 1, 0)
  if end_depth < 0 then
    reaper.SetMediaTrackInfo_Value(end_tr, "I_FOLDERDEPTH", end_depth + levels)
  end
  reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", -levels)
  reaper.SetMediaTrackInfo_Value(folder_track, "I_FOLDERDEPTH", 1)
end

-- Place une piste dans un folder, juste après after_track.
local function insert_as_first_child(folder_track, track, after_track)
  local after_idx = track_idx0(after_track)
  reaper.Main_OnCommand(40297, 0)
  reaper.SetTrackSelected(track, true)
  reaper.ReorderSelectedTracks(after_idx + 1, 0)
  reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", 0)
  reaper.SetMediaTrackInfo_Value(folder_track, "I_FOLDERDEPTH", 1)
end

-- Déplace des pistes dans un folder existant, au début (position 0) ou à la
-- fin (position 1). Les pistes gardent leur ordre.
local function action_add_tracks_to_folder(dest_folder, tracks, position)
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local selected_set = build_track_set(tracks)

  if position == 1 then
    for _, tr in ipairs(tracks) do
      detach_track_repair(tr, selected_set)
      move_one_track_to_project_end_root(tr)
      insert_as_last_child_nested_safe(dest_folder, tr)
    end
  else
    local after_track = dest_folder
    for _, tr in ipairs(tracks) do
      detach_track_repair(tr, selected_set)
      move_one_track_to_project_end_root(tr)
      insert_as_first_child(dest_folder, tr, after_track)
      after_track = tr
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK RH : Add to folder", -1)
  set_status(string.format("%d track(s) added to \"%s\"", #tracks, tname(dest_folder)))
  reset_sel_cache()
end

-- "Move under track" : la piste cible devient un folder qui contient les
-- pistes données.
local function action_move_under_track(target_track, tracks)
  if #tracks == 0 or not target_track then return end
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local orig_depth = reaper.GetMediaTrackInfo_Value(target_track, "I_FOLDERDEPTH")
  local selected_set = build_track_set(tracks)
  for _, tr in ipairs(tracks) do
    detach_track_repair(tr, selected_set)
  end

  local target_idx = track_idx0(target_track)
  reaper.SetMediaTrackInfo_Value(target_track, "I_FOLDERDEPTH", 1)

  local first_tr = tracks[1]
  reaper.Main_OnCommand(40297, 0)
  reaper.SetTrackSelected(first_tr, true)
  reaper.ReorderSelectedTracks(target_idx + 1, 0)
  reaper.SetMediaTrackInfo_Value(first_tr, "I_FOLDERDEPTH", orig_depth - 1)

  for i = 2, #tracks do
    local tr = tracks[i]
    move_one_track_to_project_end_root(tr)
    insert_as_last_child_nested_safe(target_track, tr)
  end

  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK RH : Move under track", -1)
  set_status(string.format('%d track(s) moved under "%s"', #tracks, tname(target_track)))
  reset_sel_cache()
end

-- ============================================================
--  ACTIONS — CRÉATION DE PISTES
-- ============================================================
-- Crée une ou plusieurs pistes, après la dernière piste sélectionnée ou à la
-- fin du projet. Avec plusieurs pistes, le nom est suivi d'un numéro.
local function action_create_tracks(count, name, color)
  reaper.Undo_BeginBlock()
  local base_insert = reaper.CountTracks(0)
  if #state.sel_tracks > 0 then
    local last_pos = 0
    for _, st in ipairs(state.sel_tracks) do
      local p = tidx(st)
      if p > last_pos then last_pos = p end
    end
    base_insert = last_pos
  end
  for i = 1, count do
    local insert_at = base_insert + (i - 1)
    reaper.InsertTrackAtIndex(insert_at, true)
    local new_tr = reaper.GetTrack(0, insert_at)
    if name ~= "" then
      local track_name = count == 1 and name or string.format("%s %d", name, i)
      reaper.GetSetMediaTrackInfo_String(new_tr, "P_NAME", track_name, true)
    end
    if color ~= 0 then reaper.SetTrackColor(new_tr, color) end
  end
  reaper.Undo_EndBlock("SK RH : Create tracks", -1)
  set_status(string.format("%d track(s) created", count))
end

-- Crée un folder parent juste avant la première piste sélectionnée et y
-- range toute la sélection.
local function action_create_folder(folder_name, reaper_col)
  local n_sel = reaper.CountSelectedTracks(0)
  if n_sel == 0 then set_status("No track selected", "warn"); return end

  -- Pistes sélectionnées, dans l'ordre du projet.
  local sel = {}
  local first_pos = math.huge

  for i = 0, n_sel - 1 do
    local tr  = reaper.GetSelectedTrack(0, i)
    local pos = tidx(tr)
    local is_f = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") > 0
    table.insert(sel, { track = tr, pos = pos, is_folder = is_f })
    if pos < first_pos then first_pos = pos end
  end
  table.sort(sel, function(a, b) return a.pos < b.pos end)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  reaper.Main_OnCommand(40297, 0)

  local insert_idx = first_pos - 1
  reaper.InsertTrackAtIndex(insert_idx, true)
  local folder_tr = reaper.GetTrack(0, insert_idx)
  reaper.GetSetMediaTrackInfo_String(folder_tr, "P_NAME", folder_name, true)
  if reaper_col and reaper_col ~= 0 then
    reaper.SetTrackColor(folder_tr, reaper_col)
  end
  reaper.SetMediaTrackInfo_Value(folder_tr, "I_FOLDERDEPTH", 1)

  local total = reaper.CountTracks(0)

  -- Cherche la dernière piste couverte par la sélection, en comptant le
  -- contenu des folders sélectionnés.
  local last_pos = 0
  for _, s in ipairs(sel) do
    local cur_pos = tidx(s.track) - 1

    if s.is_folder then
      -- Fin du folder sélectionné.
      local dc = 1
      for i = cur_pos + 1, total - 1 do
        local d = reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, i), "I_FOLDERDEPTH")
        dc = dc + d
        if dc <= 0 then
          if i > last_pos then last_pos = i end
          break
        end
      end
      -- Le folder sélectionné descend d'un niveau, avec son contenu.
      local d = reaper.GetMediaTrackInfo_Value(s.track, "I_FOLDERDEPTH")
      reaper.SetMediaTrackInfo_Value(s.track, "I_FOLDERDEPTH", d + 1)
    else
      -- Une piste ordinaire entre simplement dans le nouveau folder.
      if cur_pos > last_pos then last_pos = cur_pos end
      reaper.SetMediaTrackInfo_Value(s.track, "I_FOLDERDEPTH", 0)
    end
  end

  -- Le nouveau folder se referme sur cette dernière piste.
  if last_pos > insert_idx then
    local close_tr = reaper.GetTrack(0, last_pos)
    local d = reaper.GetMediaTrackInfo_Value(close_tr, "I_FOLDERDEPTH")
    reaper.SetMediaTrackInfo_Value(close_tr, "I_FOLDERDEPTH", d - 1)
  end

  -- Les pistes rangées dans le folder doivent passer par lui : leur envoi
  -- au master est réactivé.
  for _, s in ipairs(sel) do
    if reaper.ValidatePtr(s.track, "MediaTrack*") then
      reaper.SetMediaTrackInfo_Value(s.track, "B_MAINSEND", 1)
    end
  end

  reaper.SetOnlyTrackSelected(folder_tr)
  reaper.TrackList_AdjustWindows(false)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK RH : Create folder " .. folder_name, -1)
  set_status('Folder "' .. folder_name .. '" created')
  reset_sel_cache()
end

-- Ajoute une piste vide à la fin d'un folder. Si la piste n'est pas encore
-- un folder, elle le devient. La nouvelle piste prend la couleur du parent.
local function action_add_child_track(track)
  local sel_index    = tidx(track) - 1
  local folder_depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
  local folder_color = reaper.GetTrackColor(track)

  local insert_index  = sel_index + 1
  local closing_track = nil  -- piste qui referme le folder actuellement

  if folder_depth == 1 then
    local depth_count = 1
    local total = reaper.CountTracks(0)
    for i = sel_index + 1, total - 1 do
      local tr = reaper.GetTrack(0, i)
      local d  = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
      depth_count = depth_count + d
      if depth_count <= 0 then
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
    -- L'ancienne dernière piste cède son rôle à la nouvelle.
    if closing_track then
      local cd = reaper.GetMediaTrackInfo_Value(closing_track, "I_FOLDERDEPTH")
      reaper.SetMediaTrackInfo_Value(closing_track, "I_FOLDERDEPTH", cd + 1)
    end
    reaper.SetMediaTrackInfo_Value(new_track, "I_FOLDERDEPTH", -1)
  else
    reaper.SetMediaTrackInfo_Value(track,     "I_FOLDERDEPTH",  1)
    reaper.SetMediaTrackInfo_Value(new_track, "I_FOLDERDEPTH", -1)
  end

  if folder_color and folder_color ~= 0 then
    reaper.SetTrackColor(new_track, folder_color)
  end

  reaper.Main_OnCommand(40297, 0)
  reaper.SetTrackSelected(track, true)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK RH : Add child track", -1)
  set_status("Child track added")
  reset_sel_cache()
end

-- Crée un bus de sommation avant la première piste sélectionnée. Chaque
-- piste sélectionnée lui envoie son signal (post-fader) et n'envoie plus
-- directement au master.
local function action_create_bus(bus_name, reaper_col)
  local n_sel = reaper.CountSelectedTracks(0)
  if n_sel == 0 then set_status("No track selected", "warn"); return end

  local sel = {}
  local first_pos = math.huge

  for i = 0, n_sel - 1 do
    local tr  = reaper.GetSelectedTrack(0, i)
    local pos = tidx(tr)
    table.insert(sel, tr)
    if pos < first_pos then first_pos = pos end
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local insert_idx = first_pos - 1
  reaper.InsertTrackAtIndex(insert_idx, true)
  local bus_tr = reaper.GetTrack(0, insert_idx)
  reaper.GetSetMediaTrackInfo_String(bus_tr, "P_NAME", bus_name, true)
  if reaper_col and reaper_col ~= 0 then
    reaper.SetTrackColor(bus_tr, reaper_col)
  end

  for _, tr in ipairs(sel) do
    reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0)
    local si = reaper.CreateTrackSend(tr, bus_tr)
    if si >= 0 then
      reaper.SetTrackSendInfo_Value(tr, 0, si, "I_SENDMODE", 0)
      reaper.SetTrackSendInfo_Value(tr, 0, si, "D_VOL",      1.0)
      reaper.SetTrackSendInfo_Value(tr, 0, si, "D_PAN",      0.0)
    end
  end

  reaper.SetOnlyTrackSelected(bus_tr)
  reaper.TrackList_AdjustWindows(false)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK RH : Create bus " .. bus_name, -1)
  set_status('Bus "' .. bus_name .. '" created')
  reset_sel_cache()
end

-- "Add feeding bus track" : crée, après la sélection, une piste sans envoi
-- au master qui alimente la piste (ou chaque piste sélectionnée) par un send.
local function action_add_bus_child(track)
  local targets = {}
  local last_idx = tidx(track) - 1

  for _, st in ipairs(state.sel_tracks) do
    if reaper.ValidatePtr(st, "MediaTrack*") then
      table.insert(targets, st)
      local p = tidx(st) - 1
      if p > last_idx then last_idx = p end
    end
  end
  if #targets == 0 then targets = { track } end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local insert_idx = last_idx + 1
  reaper.InsertTrackAtIndex(insert_idx, true)
  local bus_tr = reaper.GetTrack(0, insert_idx)
  reaper.SetMediaTrackInfo_Value(bus_tr, "B_MAINSEND", 0)

  local src_color = reaper.GetTrackColor(track)
  if src_color and src_color ~= 0 then
    reaper.SetTrackColor(bus_tr, src_color)
  end

  for _, tr in ipairs(targets) do
    reaper.CreateTrackSend(bus_tr, tr)
  end

  reaper.SetOnlyTrackSelected(bus_tr)
  reaper.TrackList_AdjustWindows(false)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK RH : Add bus track", -1)
  set_status("Bus track added")
  reset_sel_cache()
end

-- Crée un retour FX après la dernière piste sélectionnée. Chaque piste
-- sélectionnée lui envoie son signal (post-fader) en gardant son envoi au master.
local function action_create_fx(fx_name, reaper_col)
  local n_sel = reaper.CountSelectedTracks(0)
  if n_sel == 0 then set_status("No track selected", "warn"); return end

  local sel = {}
  local last_pos = 0

  for i = 0, n_sel - 1 do
    local tr  = reaper.GetSelectedTrack(0, i)
    local pos = tidx(tr)
    table.insert(sel, tr)
    if pos > last_pos then last_pos = pos end
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  reaper.InsertTrackAtIndex(last_pos, true)
  local fx_tr = reaper.GetTrack(0, last_pos)
  reaper.GetSetMediaTrackInfo_String(fx_tr, "P_NAME", fx_name, true)
  if reaper_col and reaper_col ~= 0 then
    reaper.SetTrackColor(fx_tr, reaper_col)
  end

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
  set_status('FX track "' .. fx_name .. '" created')
  reset_sel_cache()
end

-- ============================================================
--  ACTIONS — VCA
-- ============================================================
-- Le script gère les groupes 1 à 16. Pour chaque piste, REAPER note à quels
-- groupes elle appartient comme master (elle commande) ou comme slave (elle
-- suit), et quelles options Mute / Solo / Volume sont liées. grp_bit donne
-- le repère d'un groupe dans ces informations.
local function grp_bit(g) return 1 << (g - 1) end

-- Crée une piste VCA master avant la première piste sélectionnée, dans le
-- premier groupe libre, et fait de la sélection ses slaves.

local function action_create_vca(vca_name, reaper_col, mute_lead, solo_lead, volume_lead)
  local n_sel = reaper.CountSelectedTracks(0)

  local first_pos = math.huge
  for i = 0, n_sel - 1 do
    local pos = tidx(reaper.GetSelectedTrack(0, i))
    if pos < first_pos then first_pos = pos end
  end
  local insert_at = (first_pos < math.huge) and (first_pos - 1) or reaper.CountTracks(0)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  reaper.InsertTrackAtIndex(insert_at, true)
  local vca_tr = reaper.GetTrack(0, insert_at)
  reaper.GetSetMediaTrackInfo_String(vca_tr, "P_NAME", vca_name, true)
  if reaper_col and reaper_col ~= 0 then
    reaper.SetTrackColor(vca_tr, reaper_col)
  end

  -- Premier groupe qui n'a pas encore de master.
  local free_group = nil
  for g = 1, 16 do
    local bit = grp_bit(g)
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
    local bit = grp_bit(free_group)
    reaper.GetSetTrackGroupMembership(vca_tr, "VOLUME_VCA_MASTER", bit, bit)
    if mute_lead   then reaper.GetSetTrackGroupMembership(vca_tr, "MUTE_LEAD",   bit, bit) end
    if solo_lead   then reaper.GetSetTrackGroupMembership(vca_tr, "SOLO_LEAD",   bit, bit) end
    if volume_lead then reaper.GetSetTrackGroupMembership(vca_tr, "VOLUME_LEAD", bit, bit) end
    for i = 0, n_sel - 1 do
      local tr = reaper.GetSelectedTrack(0, i)
      if tr and tr ~= vca_tr then
        reaper.GetSetTrackGroupMembership(tr, "VOLUME_VCA_SLAVE", bit, bit)
        if mute_lead   then reaper.GetSetTrackGroupMembership(tr, "MUTE_SLAVE",   bit, bit) end
        if solo_lead   then reaper.GetSetTrackGroupMembership(tr, "SOLO_SLAVE",   bit, bit) end
        if volume_lead then reaper.GetSetTrackGroupMembership(tr, "VOLUME_SLAVE", bit, bit) end
      end
    end
    set_status(string.format('VCA "%s" created (group %d)', vca_name, free_group))
  else
    set_status("All VCA groups (1-16) are already in use", "warn")
  end

  reaper.SetOnlyTrackSelected(vca_tr)
  reaper.TrackList_AdjustWindows(false)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("SK RH : Create VCA " .. vca_name, -1)
  reset_sel_cache()
end

-- Libère toutes les pistes slaves d'un groupe VCA, options comprises.
local function remove_vca_slaves(bit)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local sb = reaper.GetSetTrackGroupMembership(tr, "VOLUME_VCA_SLAVE", 0, 0)
    if sb & bit ~= 0 then
      reaper.GetSetTrackGroupMembership(tr, "VOLUME_VCA_SLAVE", bit, 0)
      reaper.GetSetTrackGroupMembership(tr, "MUTE_SLAVE",       bit, 0)
      reaper.GetSetTrackGroupMembership(tr, "SOLO_SLAVE",       bit, 0)
      reaper.GetSetTrackGroupMembership(tr, "VOLUME_SLAVE",     bit, 0)
    end
  end
end

-- Nom, couleur et piste du master d'un groupe VCA.
local function grp_master(bit)
  for i = 0, reaper.CountTracks(0)-1 do
    local tr = reaper.GetTrack(0, i)
    local m  = reaper.GetSetTrackGroupMembership(tr, "VOLUME_VCA_MASTER", 0, 0)
    if m & bit ~= 0 then
      return tname(tr), rcolor(tr), tr
    end
  end
  return nil, C.no_color, nil
end

-- Vrai si la piste a cette option (key) active dans ce groupe.
local function has_group_flag(tr, key, bit)
  return (reaper.GetSetTrackGroupMembership(tr, key, 0, 0) & bit) ~= 0
end

-- ============================================================
--  ACTIONS — SUPPRESSION / CANAUX
-- ============================================================
-- Supprime des pistes, de la dernière vers la première. Un folder supprimé
-- libère son contenu, un VCA master supprimé libère ses slaves.
local function action_delete_tracks(ptrs)
  table.sort(ptrs, function(a, b)
    local ia = reaper.ValidatePtr(a, "MediaTrack*") and tidx(a) or 0
    local ib = reaper.ValidatePtr(b, "MediaTrack*") and tidx(b) or 0
    return ia > ib
  end)
  reaper.Undo_BeginBlock()
  local count = 0
  for _, ptr in ipairs(ptrs) do
    if reaper.ValidatePtr(ptr, "MediaTrack*") then
      local depth = math.floor(reaper.GetMediaTrackInfo_Value(ptr, "I_FOLDERDEPTH"))
      if depth == 1 then action_dissolve_folder(ptr) end
      local mb = reaper.GetSetTrackGroupMembership(ptr, "VOLUME_VCA_MASTER", 0, 0)
      if mb ~= 0 then
        for g = 1, 16 do
          local bit = grp_bit(g)
          if mb & bit ~= 0 then remove_vca_slaves(bit) end
        end
      end
      reaper.DeleteTrack(ptr)
      count = count + 1
    end
  end
  reaper.Undo_EndBlock("SK RH : Delete tracks", -1)
  set_status(string.format("%d track(s) deleted", count))
  reset_sel_cache()
end

-- Change le nombre de canaux des pistes. Si un send ou un receive utilise un
-- canal qui disparaîtrait, rien n'est modifié et la liste des conflits est
-- affichée. Renvoie true si le changement a été appliqué.
local function action_set_channels(targets, new_nchan)
  local conflicts = {}
  for _, st in ipairs(targets) do
    if reaper.ValidatePtr(st, "MediaTrack*") then
      local tname_st = tname(st)
      for i = 0, reaper.GetTrackNumSends(st, 0) - 1 do
        local sc = math.floor(reaper.GetTrackSendInfo_Value(st, 0, i, "I_SRCCHAN")) & ~1024
        if sc + 2 > new_nchan then
          local dst_tr = reaper.GetTrackSendInfo_Value(st, 0, i, "P_DESTTRACK")
          conflicts[#conflicts+1] = string.format(
            '"%s" -> "%s" : src ch %d-%d', tname_st, tname(dst_tr), sc+1, sc+2)
        end
      end
      for i = 0, reaper.GetTrackNumSends(st, -1) - 1 do
        local dc = math.floor(reaper.GetTrackSendInfo_Value(st, -1, i, "I_DSTCHAN"))
        if dc + 2 > new_nchan then
          local src_tr = reaper.GetTrackSendInfo_Value(st, -1, i, "P_SRCTRACK")
          conflicts[#conflicts+1] = string.format(
            '"%s" -> "%s" : dst ch %d-%d', tname(src_tr), tname_st, dc+1, dc+2)
        end
      end
    end
  end
  if #conflicts > 0 then
    local msg = string.format(
      "Reducing to %d channels would break %d send(s):\n\n", new_nchan, #conflicts)
    for _, c in ipairs(conflicts) do msg = msg .. "  - " .. c .. "\n" end
    msg = msg .. "\nFix the affected sends first."
    reaper.MB(msg, "SK Routing Hub — Channel conflict", 0)
    return false
  end
  reaper.Undo_BeginBlock()
  for _, st in ipairs(targets) do
    if reaper.ValidatePtr(st, "MediaTrack*") then
      reaper.SetMediaTrackInfo_Value(st, "I_NCHAN", new_nchan)
    end
  end
  reaper.Undo_EndBlock("SK RH : Track channels", -1)
  set_status(string.format("%d channels applied", new_nchan))
  return true
end

-- ============================================================
--  COULEURS DES PISTES
-- ============================================================
-- Couleurs proposées dans les palettes (rouge, vert, bleu de 0 à 1).
local CP_PALETTE = {
  { 0.85, 0.25, 0.25 }, { 0.90, 0.55, 0.20 }, { 0.85, 0.75, 0.15 },
  { 0.25, 0.70, 0.30 }, { 0.20, 0.65, 0.75 }, { 0.30, 0.40, 0.85 },
  { 0.60, 0.25, 0.85 }, { 0.85, 0.25, 0.65 },
  { 0.3782, 0.5910, 0.6863 },  -- bleu-gris
  { 0.9160, 0.8319, 0.6807 },  -- crème
}

-- Éclaircit une couleur vers le blanc (t = 0 : intacte, t = 1 : blanc).
local function cp_pastel(r, g, b, t)
  return r + (1-r)*t, g + (1-g)*t, b + (1-b)*t
end

local function to255(v) return math.floor(v * 255 + 0.5) end

-- Conversions vers le format de couleur de REAPER et vers celui de la fenêtre.
local function rgb_to_reaper_col(r, g, b)
  return reaper.ColorToNative(to255(r), to255(g), to255(b))
end

local function rgb_to_u32(r, g, b)
  return (to255(r) << 24) | (to255(g) << 16) | (to255(b) << 8) | 0xFF
end

local function apply_color_to_sel(r, g, b)
  local rc = rgb_to_reaper_col(r, g, b)
  reaper.Undo_BeginBlock()
  for _, t in ipairs(state.sel_tracks) do
    if reaper.ValidatePtr(t, "MediaTrack*") then reaper.SetTrackColor(t, rc) end
  end
  reaper.Undo_EndBlock("SK RH : Color tracks", -1)
  set_status(string.format("%d track(s) colored", #state.sel_tracks))
end

local function remove_color_from_sel()
  reaper.Undo_BeginBlock()
  for _, t in ipairs(state.sel_tracks) do
    if reaper.ValidatePtr(t, "MediaTrack*") then
      reaper.SetMediaTrackInfo_Value(t, "I_CUSTOMCOLOR", 0)
    end
  end
  reaper.Undo_EndBlock("SK RH : Clear track colors", -1)
  set_status("Color cleared")
end

-- Conversion entre le volume tel que REAPER le stocke (1 = 0 dB) et les dB.
local function vol_to_db(v)
  if v <= 0 then return -math.huge end
  return 20 * math.log(v, 10)
end

local function db_to_vol(db)
  if db <= -150 then return 0 end
  return 10 ^ (db / 20)
end

-- ============================================================
--  ÉLÉMENTS D'INTERFACE
-- ============================================================
-- Boutons, cases, interrupteurs et autres petits éléments réutilisés
-- partout dans la fenêtre, pour un aspect homogène.
-- Dans les libellés, ce qui suit "##" sert seulement à distinguer deux
-- éléments de même nom et n'est jamais affiché.

local BTN_PAD_X = 10   -- marge intérieure gauche et droite d'un bouton

-- Écrit un texte centré sur l'élément qui vient d'être dessiné.
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

-- Partie visible d'un libellé (ce qui précède "##").
local function label_vis(label)
  return label:match("^(.-)##") or label
end

-- Largeur d'un bouton adaptée à son texte.
local function btn_w(label)
  return reaper.ImGui_CalcTextSize(ctx, label_vis(label)) + BTN_PAD_X * 2
end

local function auto_btn_size(vis, w, h)
  return w or (reaper.ImGui_CalcTextSize(ctx, vis) + BTN_PAD_X * 2),
         h or reaper.ImGui_GetFrameHeight(ctx)
end

-- Bulle d'aide opaque, bien lisible sur la fenêtre.
local function show_tooltip(text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(), 0x0D0D0FFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),  C.accent_dim)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 1)
  reaper.ImGui_SetTooltip(ctx, text)
  reaper.ImGui_PopStyleVar(ctx, 1)
  reaper.ImGui_PopStyleColor(ctx, 2)
end

-- Bulle d'aide affichée après un court survol de l'élément.
local function tip(text)
  if reaper.ImGui_IsItemHovered(ctx, HOVER_DELAY) then show_tooltip(text) end
end

-- Bouton neutre (secondaire).
local function btn(label, w, h)
  local vis = label_vis(label)
  local bw, bh = auto_btn_size(vis, w, h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        C.bg_item)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.bg_item_hov)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  C.bg_item_act)
  local r = reaper.ImGui_Button(ctx, "##"..label, bw, bh)
  reaper.ImGui_PopStyleColor(ctx, 3)
  draw_centered_label(vis, C.text)
  return r
end

-- Bouton coloré (action principale).
local function col_btn(label, col, hov, w, h)
  local vis = label_vis(label)
  local bw, bh = auto_btn_size(vis, w, h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        col)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), hov or col)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  hov or col)
  local r = reaper.ImGui_Button(ctx, "##"..label, bw, bh)
  reaper.ImGui_PopStyleColor(ctx, 3)
  draw_centered_label(vis, C.white)
  return r
end

-- Bouton rouge (suppression).
local function danger_btn(label, w, h)
  return col_btn(label, C.danger, C.danger_hov, w, h)
end

-- Petit bouton à texte court (symbole), aux couleurs réglables.
local function icon_btn(id, glyph, w, h, txt_col, bg, bg_hov)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        bg or C.bg_item)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), bg_hov or C.bg_item_hov)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  bg_hov or C.bg_item_act)
  local clicked = reaper.ImGui_Button(ctx, "##"..id, w, h)
  reaper.ImGui_PopStyleColor(ctx, 3)
  draw_centered_label(glyph, txt_col or C.text)
  return clicked
end

-- Bouton à bascule (Mute, Polarité, Mono) : allumé = couleur pleine.
local function toggle_btn(id, glyph, on, w, h, on_bg, on_txt)
  local bg  = on and on_bg or C.bg_item
  local hov = on and on_bg or C.bg_item_hov
  return icon_btn(id, glyph, w, h, on and on_txt or C.text_dim, bg, hov)
end

-- Bouton "…" qui ouvre un menu.
local function menu_btn(id, w, h)
  local clicked = icon_btn(id, "", w, h, C.text_dim, C.ghost, C.bg_item_hov)
  local x1, y1 = reaper.ImGui_GetItemRectMin(ctx)
  local x2, y2 = reaper.ImGui_GetItemRectMax(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
  for k = -1, 1 do
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx + k * 4, cy, 1.5, C.text_dim)
  end
  return clicked
end

-- Bouton de création (Folder, Bus...) marqué d'une pastille de couleur.
-- Grisé et inactif quand enabled est faux.
local function kind_btn(label, accent, w, enabled)
  local vis = label_vis(label)
  local h = reaper.ImGui_GetFrameHeight(ctx)
  reaper.ImGui_BeginDisabled(ctx, not enabled)
  local r = btn("##" .. label, w, h)
  reaper.ImGui_EndDisabled(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMin(ctx)
  local x2, y2 = reaper.ImGui_GetItemRectMax(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, vis)
  local sx = math.floor((x1 + x2 - (tw + 11)) / 2)
  local cy = (y1 + y2) / 2
  reaper.ImGui_DrawList_AddCircleFilled(dl, sx + 3, cy, 3, enabled and accent or C.text_faint)
  reaper.ImGui_DrawList_AddText(dl, sx + 11, math.floor(cy - th / 2), enabled and C.text or C.text_faint, vis)
  return r and enabled
end

-- Case à cocher au style commun.
local function styled_checkbox(label, value)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),    C.text_faint)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),   C.bg_item)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(), C.white)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1)
  local _, nv = reaper.ImGui_Checkbox(ctx, label, value)
  reaper.ImGui_PopStyleVar(ctx, 1)
  reaper.ImGui_PopStyleColor(ctx, 3)
  if nv == nil then return value end
  return nv
end

-- Interrupteur on/off avec libellé (comme "Bulk edit").
local SW_W, SW_H = 26, 14
local function switch_w(label)
  return SW_W + 6 + reaper.ImGui_CalcTextSize(ctx, label)
end

-- Renvoie la nouvelle valeur, et vrai si elle vient de changer.
local function toggle_switch(id, value, label)
  local FH = reaper.ImGui_GetFrameHeight(ctx)
  local clicked = reaper.ImGui_InvisibleButton(ctx, "##sw_"..id, switch_w(label), FH)
  local hov = reaper.ImGui_IsItemHovered(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMin(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local cy = y1 + FH / 2
  local bg = value and C.accent or (hov and 0x4A4A52FF or 0x3A3A42FF)
  reaper.ImGui_DrawList_AddRectFilled(dl, x1, cy - SW_H/2, x1 + SW_W, cy + SW_H/2, bg, SW_H/2)
  local kx = value and (x1 + SW_W - SW_H/2) or (x1 + SW_H/2)
  reaper.ImGui_DrawList_AddCircleFilled(dl, kx, cy, SW_H/2 - 2, C.white)
  local _, th = reaper.ImGui_CalcTextSize(ctx, label)
  reaper.ImGui_DrawList_AddText(dl, x1 + SW_W + 6, math.floor(cy - th/2),
    value and C.text or C.text_dim, label)
  if clicked then return not value, true end
  return value, false
end

-- Pastille arrondie affichant un nombre.
local function count_badge(n)
  local s = tostring(n)
  local FH = reaper.ImGui_GetFrameHeight(ctx)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, s)
  local w, h = math.max(tw + 12, 20), th + 2
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local yy = y + (FH - h) / 2
  reaper.ImGui_DrawList_AddRectFilled(dl, x, yy, x + w, yy + h, C.badge_bg, h / 2)
  reaper.ImGui_DrawList_AddText(dl, math.floor(x + (w - tw) / 2), math.floor(yy + 1), C.text_dim, s)
  reaper.ImGui_Dummy(ctx, w, FH)
end

-- Petite étiquette d'option (Mute / Solo / Volume), allumée ou éteinte.
local function flag_tag(label, on)
  local FH = reaper.ImGui_GetFrameHeight(ctx)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, label)
  local w, h = tw + 12, th + 2
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local yy = y + (FH - h) / 2
  reaper.ImGui_DrawList_AddRectFilled(dl, x, yy, x + w, yy + h, on and C.tag_on_bg or C.tag_off_bg, 3)
  reaper.ImGui_DrawList_AddText(dl, x + 6, math.floor(yy + 1), on and C.mute_txt or C.text_faint, label)
  reaper.ImGui_Dummy(ctx, w, FH)
end

-- Petit rectangle vertical à la couleur d'une piste.
local function color_chip(col, w, h)
  local FH = reaper.ImGui_GetFrameHeight(ctx)
  w = w or 4 ; h = h or (FH - 6)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local yy = y + (FH - h) / 2
  reaper.ImGui_DrawList_AddRectFilled(dl, x, yy, x + w, yy + h, col, 1)
  reaper.ImGui_Dummy(ctx, w, FH)
end

-- Texte coloré, aligné sur la hauteur des contrôles.
local function label_text(text, col)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), col or C.text_dim)
  reaper.ImGui_Text(ctx, text)
  reaper.ImGui_PopStyleColor(ctx, 1)
end

-- Trait horizontal sur toute la largeur disponible.
local function hline(pad_top, pad_bottom)
  if pad_top then reaper.ImGui_Dummy(ctx, 0, pad_top) end
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local w = reaper.ImGui_GetContentRegionAvail(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_AddLine(dl, x, y + 0.5, x + w, y + 0.5, C.border_soft, 1)
  reaper.ImGui_Dummy(ctx, w, 1)
  if pad_bottom then reaper.ImGui_Dummy(ctx, 0, pad_bottom) end
end

-- Position du bord droit de la zone en cours, pour aligner à droite.
local function row_right_edge()
  return reaper.ImGui_GetCursorPosX(ctx) + reaper.ImGui_GetContentRegionAvail(ctx)
end

-- Texte centré horizontalement.
local function centered_text(text, col)
  local aw = reaper.ImGui_GetContentRegionAvail(ctx)
  local tw = reaper.ImGui_CalcTextSize(ctx, text)
  reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + math.max(0, (aw - tw) / 2))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), col or C.text_faint)
  reaper.ImGui_Text(ctx, text)
  reaper.ImGui_PopStyleColor(ctx, 1)
end

-- Message d'une section vide : texte gris centré, avec un peu d'air.
local function empty_state(text)
  reaper.ImGui_Dummy(ctx, 0, 6)
  centered_text(text, C.text_faint)
  reaper.ImGui_Dummy(ctx, 0, 6)
end

-- Raccourcit un nom avec "…" pour qu'il tienne dans la largeur donnée.
local function fit_name(raw, max_w)
  if reaper.ImGui_CalcTextSize(ctx, raw) <= max_w then return raw end
  local lo, hi = 0, #raw
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if reaper.ImGui_CalcTextSize(ctx, raw:sub(1, mid) .. "…") <= max_w then lo = mid else hi = mid - 1 end
  end
  return raw:sub(1, lo) .. "…"
end

-- Choix entre plusieurs vues, présenté comme des onglets accolés.
-- Renvoie la vue choisie.
local function segmented(id, items, current, item_w)
  local FH = reaper.ImGui_GetFrameHeight(ctx)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local total = #items * item_w + 4
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + total, y + FH, C.seg_bg, 5)
  local result = current
  for i, it in ipairs(items) do
    reaper.ImGui_SetCursorScreenPos(ctx, x + 2 + (i - 1) * item_w, y + 2)
    local clicked = reaper.ImGui_InvisibleButton(ctx, "##seg_"..id..i, item_w, FH - 4)
    local hov = reaper.ImGui_IsItemHovered(ctx)
    local on = it.key == current
    local x1, y1 = reaper.ImGui_GetItemRectMin(ctx)
    local x2, y2 = reaper.ImGui_GetItemRectMax(ctx)
    if on then
      reaper.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, C.accent_dim, 4)
    elseif hov then
      reaper.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, C.bg_item_hov, 4)
    end
    draw_centered_label(it.label, on and C.white or C.text_dim)
    if clicked then result = it.key end
  end
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_Dummy(ctx, total, FH)
  return result
end

-- Menu déroulant compact, avec une petite flèche grise à droite.
-- Renvoie vrai si le choix a changé, puis la position choisie.
local COMBO_NO_ARROW = imgui_flag("ComboFlags_NoArrowButton", 0)
local COMBO_TALL     = imgui_flag("ComboFlags_HeightLarge", 0)

local function compact_combo(id, idx, items, w, tall)
  local FH = reaper.ImGui_GetFrameHeight(ctx)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local new_idx, changed = idx, false

  reaper.ImGui_SetNextItemWidth(ctx, w)
  local open = reaper.ImGui_BeginCombo(ctx, id, items[idx] or "?", COMBO_NO_ARROW | (tall and COMBO_TALL or 0))
  local hov = not open and reaper.ImGui_IsItemHovered(ctx)
  local ax, ay = x + w - 10, y + FH / 2
  reaper.ImGui_DrawList_AddTriangleFilled(dl, ax - 3.5, ay - 1.5, ax + 3.5, ay - 1.5, ax, ay + 2.5,
    (open or hov) and C.text or C.text_faint)
  if open then
    for i, it in ipairs(items) do
      if reaper.ImGui_Selectable(ctx, it .. "##" .. i, i == idx) then
        new_idx, changed = i, i ~= idx
      end
      if i == idx and reaper.ImGui_IsWindowAppearing(ctx) then reaper.ImGui_SetItemDefaultFocus(ctx) end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  return changed, new_idx
end

-- Champ numérique encadré par des boutons - et +. step fixe le pas des
-- boutons (1 par défaut) ; une valeur saisie est arrondie au multiple de
-- step supérieur. minv et maxv bornent la valeur.
local function int_field(id, value, minv, maxv, width, step)
  step = step or 1
  local FH = reaper.ImGui_GetFrameHeight(ctx)
  local v, changed = value, false

  if icon_btn(id.."_dec", "-", FH, FH, C.text) then
    v = v - step ; changed = true
  end
  reaper.ImGui_SameLine(ctx, 0, 2)

  reaper.ImGui_SetNextItemWidth(ctx, width or 54)
  local ch, nv = reaper.ImGui_InputInt(ctx, "##"..id, v, 0, 0)
  if ch then v = nv ; changed = true end
  -- Hors saisie, le nombre est affiché centré dans le champ.
  if not reaper.ImGui_IsItemActive(ctx) then
    local x1, y1 = reaper.ImGui_GetItemRectMin(ctx)
    local x2, y2 = reaper.ImGui_GetItemRectMax(ctx)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local cover = reaper.ImGui_IsItemHovered(ctx) and C.bg_item_hov or C.bg_item
    reaper.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, cover, 4)
    draw_centered_label(tostring(v), C.text)
  end
  reaper.ImGui_SameLine(ctx, 0, 2)

  if icon_btn(id.."_inc", "+", FH, FH, C.text) then
    v = v + step ; changed = true
  end

  if step > 1 and v % step ~= 0 then
    v = v + (step - v % step)
  end

  if minv then v = math.max(minv, v) end
  if maxv then v = math.min(maxv, v) end
  return v, changed
end

-- Sélecteur de couleur commun à toutes les fenêtres : curseur "pastel" et
-- rangée de couleurs. Renvoie la couleur retenue (0 = aucune) et, si une
-- couleur vient d'être cliquée, ses composantes { r, g, b }.
local SWATCH, SWATCH_GAP = 22, 5
local PALETTE_W = #CP_PALETTE * SWATCH + (#CP_PALETTE - 1) * SWATCH_GAP

local function color_palette_widget(id, color, pastel_key)
  local picked = nil
  local pastel = state[pastel_key]

  reaper.ImGui_SetNextItemWidth(ctx, PALETTE_W)
  local pc, pv = reaper.ImGui_SliderDouble(ctx, "##pastel_"..id, pastel, 0.0, 1.0,
    "Pastel " .. math.floor(pastel * 100 + 0.5) .. "%%")
  if pc then state[pastel_key] = pv ; save_pastel(pastel_key, pv) ; pastel = pv end
  reaper.ImGui_Dummy(ctx, 0, 2)

  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  for i, c in ipairs(CP_PALETTE) do
    local r, g, b = cp_pastel(c[1], c[2], c[3], pastel)
    local rc = rgb_to_reaper_col(r, g, b)
    local clicked = reaper.ImGui_InvisibleButton(ctx, "##sw_"..id..i, SWATCH, SWATCH)
    local hovered = reaper.ImGui_IsItemHovered(ctx)
    local x1, y1 = reaper.ImGui_GetItemRectMin(ctx)
    local x2, y2 = reaper.ImGui_GetItemRectMax(ctx)
    reaper.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, rgb_to_u32(r, g, b), 4)
    if color ~= 0 and color == rc then
      reaper.ImGui_DrawList_AddRect(dl, x1-2, y1-2, x2+2, y2+2, C.white, 5, 0, 2)
    elseif hovered then
      reaper.ImGui_DrawList_AddRect(dl, x1-1, y1-1, x2+1, y2+1, 0xFFFFFF88, 5, 0, 1)
    end
    if clicked then
      picked = { r, g, b }
      -- Un second clic sur la couleur choisie la retire.
      color = (color == rc) and 0 or rc
    end
    if i < #CP_PALETTE then reaper.ImGui_SameLine(ctx, 0, SWATCH_GAP) end
  end
  return color, picked
end

-- ============================================================
--  CARTES DE SECTION
-- ============================================================
-- Une carte est un cadre qui regroupe une section (SENDS, RECEIVES...).
-- Sa hauteur s'adapte à son contenu. card_begin renvoie vrai si la carte
-- est visible ; son contenu n'est alors dessiné que dans ce cas.
-- card_end est toujours appelé ensuite avec cette même valeur.
local function card_begin(id)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), C.bg_card)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),  C.border_soft)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 12, 10)
  local ok = reaper.ImGui_BeginChild(ctx, id, 0, 0, CF_BORDERS | CF_AUTO_Y)
  reaper.ImGui_PopStyleVar(ctx, 1)
  reaper.ImGui_PopStyleColor(ctx, 2)
  if ok then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 6, 4)
  end
  return ok
end

local function card_end(ok)
  if ok then
    reaper.ImGui_PopStyleVar(ctx, 1)
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_Dummy(ctx, 0, 6)
end

-- En-tête de carte : liseré coloré, titre et compteur. Si right_w est donné,
-- les éléments suivants (largeur totale right_w) sont alignés à droite.
local function card_header(title, accent, count, right_w)
  local FH = reaper.ImGui_GetFrameHeight(ctx)
  local right = row_right_edge()
  color_chip(accent, 3, FH - 6)
  reaper.ImGui_SameLine(ctx, 0, 8)
  label_text(title, C.white)
  if count then
    reaper.ImGui_SameLine(ctx, 0, 8)
    count_badge(count)
  end
  if right_w then reaper.ImGui_SameLine(ctx, right - right_w) end
end

-- ============================================================
--  BOUTON ROTATIF DE VOLUME
-- ============================================================
-- Glisser verticalement pour régler, Ctrl pour un réglage fin,
-- double-clic pour revenir à 0 dB, clic droit pour saisir une valeur.
-- Le volume maximal est +12 dB.
local KNOB_STATE = {}   -- glissement en cours et saisie de chaque bouton
local VOL_MAX = db_to_vol(12)

-- Position du volume sur la course du bouton (0 à 1), plus précise autour
-- de 0 dB qu'aux extrêmes.
local function vol_to_norm(v)
  if v <= 0 then return 0 end
  return (math.min(v, VOL_MAX) / VOL_MAX) ^ (1/3)
end

-- Lit une valeur tapée par l'utilisateur ("-6", "-6 dB", "-inf"...).
local function parse_db_input(buf)
  local str = buf:lower():gsub("%s", ""):gsub("db$", "")
  if str == "-inf" or str == "inf-" then return 0 end
  local val = tonumber(str)
  if val then return db_to_vol(math.min(12.0, val)) end
  return nil
end

-- Volume d'un autre send décalé de delta_db (-inf compte comme -60 dB).
local function shifted_vol(vol, delta_db)
  local cur_db = vol_to_db(vol)
  if cur_db < -100 then cur_db = -60 end
  return db_to_vol(math.min(12.0, cur_db + delta_db))
end

-- Dessine le bouton de volume d'un send (cat = 0) ou d'un receive (cat = -1)
-- et applique les changements. En édition groupée, le même écart en dB est
-- appliqué aux sends équivalents, en gardant leurs différences de niveau.
local function draw_vol_knob(uid, bulk_edit, track, cat, s, other)
  local vol = s.vol
  local KS = reaper.ImGui_GetFrameHeight(ctx)
  local db  = vol_to_db(vol)
  local new_vol = nil
  local norm = vol_to_norm(vol)

  -- Course de 270°, de 7 h à 5 h comme sur une console.
  local angle_min = math.pi * 0.75
  local angle_max = angle_min + math.pi * 1.5
  local angle = angle_min + norm * (angle_max - angle_min)

  local draw = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_InvisibleButton(ctx, "##knob_"..uid, KS, KS)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local active  = reaper.ImGui_IsItemActive(ctx)
  local cx, cy  = reaper.ImGui_GetItemRectMin(ctx)
  cx = cx + KS/2 ; cy = cy + KS/2
  local R = KS/2 - 2

  reaper.ImGui_DrawList_AddCircleFilled(draw, cx, cy, R, hovered and 0x34343AFF or 0x2A2A2FFF)
  reaper.ImGui_DrawList_AddCircle(draw, cx, cy, R, 0x505058FF)

  -- Arc coloré jusqu'au niveau actuel (orange au-dessus de 0 dB).
  local arc_col = vol > 1.001 and 0xFF8800FF or 0xD4AC2BFF
  local seg = 32
  for i = 0, seg - 1 do
    local t0 = i / seg
    local t1 = (i+1) / seg
    if t0 <= norm then
      local a0 = angle_min + t0 * (angle_max - angle_min)
      local a1 = angle_min + math.min(t1, norm) * (angle_max - angle_min)
      reaper.ImGui_DrawList_AddLine(draw,
        cx + (R-1) * math.cos(a0), cy + (R-1) * math.sin(a0),
        cx + (R-1) * math.cos(a1), cy + (R-1) * math.sin(a1), arc_col, 2)
    end
  end

  -- Aiguille
  reaper.ImGui_DrawList_AddLine(draw, cx, cy,
    cx + (R-2) * math.cos(angle), cy + (R-2) * math.sin(angle), 0xE8E8E8FF, 1.5)

  -- Valeur en dB à droite du bouton
  local db_txt = db < -100 and "-inf" or string.format("%.1f", db)
  local _, th = reaper.ImGui_CalcTextSize(ctx, db_txt)
  reaper.ImGui_DrawList_AddText(draw, cx + KS/2 + 4, math.floor(cy - th/2),
    (active or hovered) and C.white or C.text_dim, db_txt)

  -- Glissement vertical : le volume suit la distance parcourue depuis le
  -- début du geste.
  local ks = KNOB_STATE[uid]
  if not ks then
    ks = { dragging = false, start_y = 0, start_vol = 1.0, popup_buf = "0.0" }
    KNOB_STATE[uid] = ks
  end

  if active and reaper.ImGui_IsMouseDown(ctx, 0) then
    local _, my = reaper.ImGui_GetMousePos(ctx)
    if not ks.dragging then
      ks.dragging  = true
      ks.start_y   = my
      ks.start_vol = vol
    else
      local dy = ks.start_y - my  -- vers le haut = plus fort
      local ctrl = reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Ctrl() ~= 0
      local sens = ctrl and 0.03 or 0.3  -- dB par pixel parcouru
      local start_db = vol_to_db(ks.start_vol)
      if start_db < -100 then start_db = -60 end
      local target_db = math.min(12.0, start_db + dy * sens)
      new_vol = target_db < -100 and 0 or db_to_vol(target_db)
    end
  else
    ks.dragging = false
  end

  -- Double-clic : retour à 0 dB. Le geste en cours repart lui aussi de 0 dB,
  -- pour que le volume ne revienne pas à sa valeur précédente.
  if hovered and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    local _, my = reaper.ImGui_GetMousePos(ctx)
    new_vol      = 1.0
    ks.dragging  = true
    ks.start_y   = my
    ks.start_vol = 1.0
  end

  if hovered and not active then show_tooltip(db < -100 and "-inf dB" or string.format("%.1f dB", db)) end

  -- Clic droit : petite fenêtre de saisie de la valeur.
  if hovered and reaper.ImGui_IsMouseClicked(ctx, 1) then
    ks.popup_buf = db < -100 and "-inf" or string.format("%.1f", db)
    reaper.ImGui_OpenPopup(ctx, "knob_db_"..uid)
  end
  if reaper.ImGui_BeginPopup(ctx, "knob_db_"..uid) then
    label_text("Volume (dB)")
    reaper.ImGui_SetNextItemWidth(ctx, 90)
    if reaper.ImGui_IsWindowAppearing(ctx) then reaper.ImGui_SetKeyboardFocusHere(ctx) end
    local _, nv = reaper.ImGui_InputText(ctx, "##kdb_"..uid, ks.popup_buf,
      reaper.ImGui_InputTextFlags_AutoSelectAll())
    if nv ~= nil then ks.popup_buf = nv end
    local enter = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter())
               or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter())
    reaper.ImGui_SameLine(ctx, 0, 4)
    if col_btn("OK##kdb_ok_"..uid, C.accent_dim, C.accent_hov) or enter then
      local v = parse_db_input(ks.popup_buf)
      if v ~= nil then new_vol = v end
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx, 0, 4)
    if btn("0 dB##kdb_rst_"..uid) then
      new_vol = 1.0
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end

  -- Application du nouveau volume.
  if new_vol ~= nil and math.abs(new_vol - vol) > 1e-9 then
    local old_db = vol_to_db(vol)
    local delta_db = vol_to_db(new_vol) - (old_db < -100 and -60 or old_db)

    action_set_send_field(track, cat, s.idx, "D_VOL", new_vol)

    if bulk_edit and cat == 0 then
      -- Sends des pistes sélectionnées vers la même destination.
      for _, src in ipairs(state.sel_tracks) do
        for _, sv in ipairs(get_sends(src)) do
          if sv.dest == other and not state.sel_set[sv.dest] and (sv.idx ~= s.idx or src ~= track) then
            action_set_send_field(src, 0, sv.idx, "D_VOL", shifted_vol(sv.vol, delta_db))
          end
        end
      end
    elseif bulk_edit then
      -- Autres receives de la même piste.
      for _, rv in ipairs(get_receives(track)) do
        if rv.idx ~= s.idx then
          action_set_send_field(track, -1, rv.idx, "D_VOL", shifted_vol(rv.vol, delta_db))
        end
      end
    end
  end
end

-- ============================================================
--  STYLE GÉNÉRAL
-- ============================================================
-- Couleurs et espacements appliqués à toute la fenêtre. Renvoie le nombre
-- de réglages posés, pour pouvoir les retirer à la fin de l'affichage.
local function push_style()
  local nc, nv = 0, 0
  local function col(id, c) reaper.ImGui_PushStyleColor(ctx, id, c) ; nc = nc + 1 end
  local function var(id, a, b)
    if b then reaper.ImGui_PushStyleVar(ctx, id, a, b) else reaper.ImGui_PushStyleVar(ctx, id, a) end
    nv = nv + 1
  end
  col(reaper.ImGui_Col_WindowBg(),           C.bg)
  col(reaper.ImGui_Col_ChildBg(),            0x00000000)
  col(reaper.ImGui_Col_PopupBg(),            C.bg_popup)
  col(reaper.ImGui_Col_ModalWindowDimBg(),   0x000000A0)
  col(reaper.ImGui_Col_FrameBg(),            C.bg_item)
  col(reaper.ImGui_Col_FrameBgHovered(),     C.bg_item_hov)
  col(reaper.ImGui_Col_FrameBgActive(),      C.bg_item_act)
  col(reaper.ImGui_Col_Button(),             C.bg_item)
  col(reaper.ImGui_Col_ButtonHovered(),      C.bg_item_hov)
  col(reaper.ImGui_Col_ButtonActive(),       C.bg_item_act)
  col(reaper.ImGui_Col_Header(),             C.row_sel)
  col(reaper.ImGui_Col_HeaderHovered(),      C.accent_dim)
  col(reaper.ImGui_Col_HeaderActive(),       C.accent_hov)
  col(reaper.ImGui_Col_Text(),               C.text)
  col(reaper.ImGui_Col_TextDisabled(),       C.text_faint)
  col(reaper.ImGui_Col_Border(),             C.border)
  col(reaper.ImGui_Col_Separator(),          C.border_soft)
  col(reaper.ImGui_Col_SliderGrab(),         C.accent)
  col(reaper.ImGui_Col_SliderGrabActive(),   0x5AAFEFFF)
  col(reaper.ImGui_Col_CheckMark(),          C.white)
  col(reaper.ImGui_Col_ScrollbarBg(),        0x00000000)
  col(reaper.ImGui_Col_ScrollbarGrab(),      C.border)
  col(reaper.ImGui_Col_ScrollbarGrabHovered(), 0x4A4A52FF)
  col(reaper.ImGui_Col_TitleBg(),            C.bg_header)
  col(reaper.ImGui_Col_TitleBgActive(),      C.bg_header)
  col(reaper.ImGui_Col_TextSelectedBg(),     0x4A8FCA66)
  var(reaper.ImGui_StyleVar_WindowRounding(),    6)
  var(reaper.ImGui_StyleVar_ChildRounding(),     6)
  var(reaper.ImGui_StyleVar_PopupRounding(),     6)
  var(reaper.ImGui_StyleVar_FrameRounding(),     4)
  var(reaper.ImGui_StyleVar_GrabRounding(),      4)
  var(reaper.ImGui_StyleVar_ScrollbarRounding(), 6)
  var(reaper.ImGui_StyleVar_ItemSpacing(),       6, 4)
  var(reaper.ImGui_StyleVar_FramePadding(),      6, 3)
  var(reaper.ImGui_StyleVar_WindowPadding(),     10, 10)
  var(reaper.ImGui_StyleVar_ScrollbarSize(),     10)
  var(reaper.ImGui_StyleVar_PopupBorderSize(),   1)
  var(reaper.ImGui_StyleVar_SelectableTextAlign(), 0, 0.5)
  return nc, nv
end

-- ============================================================
--  DIALOGUES
-- ============================================================
-- Fenêtres de création et de confirmation, qui bloquent le reste de
-- l'interface tant qu'elles sont ouvertes.
local DLG = {
  tracks  = "New tracks##dlg_tracks",
  folder  = "New folder##dlg_folder",
  bus     = "New summing bus##dlg_bus",
  fx      = "New FX return##dlg_fx",
  vca     = "New VCA##dlg_vca",
  send    = "New send##dlg_send",
  receive = "New receive##dlg_recv",
  delete  = "Delete tracks##dlg_delete",
}

-- Ouvre un dialogue centré sur la fenêtre principale. Renvoie vrai s'il est
-- affiché, et son contenu est alors dessiné.
local function dialog_begin(name, width)
  reaper.ImGui_SetNextWindowPos(ctx, state.win_cx, state.win_cy, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  reaper.ImGui_SetNextWindowSize(ctx, width, 0, reaper.ImGui_Cond_Always())
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 16, 14)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 8, 6)
  local open = reaper.ImGui_BeginPopupModal(ctx, name, nil,
    reaper.ImGui_WindowFlags_NoResize() | reaper.ImGui_WindowFlags_NoSavedSettings())
  reaper.ImGui_PopStyleVar(ctx, 2)
  return open
end

-- Titre de rubrique dans un dialogue.
local function dialog_section(text, first)
  if not first then reaper.ImGui_Dummy(ctx, 0, 4) end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_faint)
  reaper.ImGui_Text(ctx, text)
  reaper.ImGui_PopStyleColor(ctx, 1)
end

-- Texte d'aide grisé, renvoyé à la ligne.
local function dialog_help(text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
  reaper.ImGui_TextWrapped(ctx, text)
  reaper.ImGui_PopStyleColor(ctx, 1)
end

-- Pied de dialogue : Cancel et bouton principal alignés à droite.
-- left_fn peut dessiner d'autres contrôles à gauche, sur la même ligne.
-- Entrée valide, Échap annule. Renvoie : validé, annulé.
local function dialog_footer(ok_label, ok_col, ok_hov, enabled, left_fn)
  hline(6, 6)
  local right = row_right_edge()
  local w_cancel = 84
  local w_ok = math.max(100, btn_w(ok_label))
  local total = w_cancel + 8 + w_ok
  if left_fn then
    left_fn()
    reaper.ImGui_SameLine(ctx, right - total)
  else
    reaper.ImGui_SetCursorPosX(ctx, right - total)
  end
  local cancel = btn("Cancel##dlg_cancel", w_cancel)
  reaper.ImGui_SameLine(ctx, 0, 8)
  reaper.ImGui_BeginDisabled(ctx, not enabled)
  local ok = col_btn(ok_label, enabled and ok_col or C.bg_item, enabled and ok_hov or C.bg_item, w_ok)
  reaper.ImGui_EndDisabled(ctx)

  if reaper.ImGui_IsWindowFocused(ctx, imgui_flag("FocusedFlags_ChildWindows", 1)) then
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then cancel = true end
    if enabled and (reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter())
        or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter())) then ok = true end
  end
  return ok and enabled, cancel
end

-- Champ de nom sur toute la largeur, prêt à la saisie dès l'ouverture.
local function name_input(id, buf, hint)
  if reaper.ImGui_IsWindowAppearing(ctx) then reaper.ImGui_SetKeyboardFocusHere(ctx) end
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  local _, nv = reaper.ImGui_InputTextWithHint(ctx, "##"..id, hint, buf,
    reaper.ImGui_InputTextFlags_AutoSelectAll())
  return nv or buf
end

-- Dialogues Folder / Bus / FX / VCA : même présentation, seuls les textes,
-- l'action lancée et (pour le VCA) les options changent.
local CREATE_KINDS = {
  folder = {
    label = "Folder name", default = "FOLDER", pastel = "folder_cp_pastel", ok = "Create folder",
    help  = "The selected tracks are moved into a new parent folder.",
    run   = action_create_folder,
  },
  bus = {
    label = "Bus name", default = "BUS", pastel = "bus_cp_pastel", ok = "Create bus",
    help  = "The selected tracks send post-fader to a new summing bus, and their master send is disabled.",
    run   = action_create_bus,
  },
  fx = {
    label = "FX return name", default = "FX", pastel = "fx_cp_pastel", ok = "Create FX return",
    help  = "The selected tracks send post-fader to a new FX return track.",
    run   = action_create_fx,
  },
  vca = {
    label = "VCA name", default = "VCA", pastel = "vca_cp_pastel", ok = "Create VCA",
    help  = "A new VCA master track controls the selected tracks. Leave the options off for a pure VCA.",
    options = true,
    run   = function(name, col)
      action_create_vca(name, col, state.vca_mute_lead, state.vca_solo_lead, state.vca_volume_lead)
    end,
  },
}

-- Remet à zéro les champs puis demande l'ouverture d'un dialogue de création.
local function open_create_dialog(kind)
  state.dlg_name  = ""
  state.dlg_color = 0
  if kind == "vca" then
    state.vca_mute_lead, state.vca_solo_lead, state.vca_volume_lead = false, false, false
  elseif kind == "tracks" then
    state.new_track_count = 1
  end
  state.open_dialog = kind
end

-- Dialogue Folder / Bus / FX / VCA.
local function draw_create_dialog(kind)
  local k = CREATE_KINDS[kind]
  if not dialog_begin(DLG[kind], 340) then return end

  dialog_help(k.help)
  dialog_section(k.label)
  state.dlg_name = name_input("dlg_name_"..kind, state.dlg_name, k.default)

  if k.options then
    dialog_section("Options")
    state.vca_mute_lead = styled_checkbox("Mute lead##dlg_ml", state.vca_mute_lead)
    reaper.ImGui_SameLine(ctx, 0, 14)
    state.vca_solo_lead = styled_checkbox("Solo lead##dlg_sl", state.vca_solo_lead)
    reaper.ImGui_SameLine(ctx, 0, 14)
    state.vca_volume_lead = styled_checkbox("Volume lead##dlg_vl", state.vca_volume_lead)
  end

  dialog_section("Color")
  state.dlg_color = color_palette_widget("dlg_"..kind, state.dlg_color, k.pastel)

  local ok, cancel = dialog_footer(k.ok.."##dlg_ok", C.send_col, C.send_hov, true)
  if ok then
    local nm = state.dlg_name ~= "" and state.dlg_name or k.default
    local col = state.dlg_color
    queue(function() k.run(nm, col) end)
    reaper.ImGui_CloseCurrentPopup(ctx)
  elseif cancel then
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_EndPopup(ctx)
end

-- Dialogue de création de pistes, avec aperçu des noms numérotés.
local function draw_tracks_dialog()
  if not dialog_begin(DLG.tracks, 340) then return end

  local where = #state.sel_tracks > 0 and "after the last selected track" or "at the end of the project"
  dialog_help("New tracks are inserted " .. where .. ".")

  dialog_section("Count")
  local cv, cc = int_field("dlg_tr_count", state.new_track_count, 1, 64, 60)
  if cc then state.new_track_count = cv end

  dialog_section("Name")
  state.dlg_name = name_input("dlg_tr_name", state.dlg_name, "Leave empty for REAPER's default name")
  if state.dlg_name ~= "" and state.new_track_count > 1 then
    local names = {}
    for i = 1, math.min(state.new_track_count, 3) do
      names[#names+1] = string.format("%s %d", state.dlg_name, i)
    end
    local preview = table.concat(names, ", ") .. (state.new_track_count > 3 and ", …" or "")
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_faint)
    reaper.ImGui_TextWrapped(ctx, preview)
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  dialog_section("Color")
  state.dlg_color = color_palette_widget("dlg_tracks", state.dlg_color, "cp_pastel")

  local n = state.new_track_count
  local ok_lbl = n > 1 and string.format("Create %d tracks##dlg_ok", n) or "Create track##dlg_ok"
  local ok, cancel = dialog_footer(ok_lbl, C.send_col, C.send_hov, true)
  if ok then
    local nm, col = state.dlg_name, state.dlg_color
    queue(function() action_create_tracks(n, nm, col) end)
    reaper.ImGui_CloseCurrentPopup(ctx)
  elseif cancel then
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_EndPopup(ctx)
end

-- Confirmation avant suppression de pistes.
local function draw_delete_dialog()
  if not dialog_begin(DLG.delete, 340) then return end
  local cd = state.confirm_delete
  local what = cd and cd.name or ""
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.white)
  reaper.ImGui_TextWrapped(ctx, 'Delete "' .. what .. '"?')
  reaper.ImGui_PopStyleColor(ctx, 1)
  dialog_help("Folders are dissolved and VCA slaves are released first. You can undo this with Ctrl+Z.")

  local ok, cancel = dialog_footer("Delete##dlg_ok", C.danger, C.danger_hov, true)
  if ok then
    local ptrs = {}
    for _, ptr in ipairs(cd and cd.ptrs or {}) do
      if reaper.ValidatePtr(ptr, "MediaTrack*") then ptrs[#ptrs+1] = ptr end
    end
    queue(function() action_delete_tracks(ptrs) end)
    state.confirm_delete = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
  elseif cancel then
    state.confirm_delete = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_EndPopup(ctx)
end

-- Dialogue de création de sends (ou de receives) : réglages, liste des
-- pistes à cocher, ou création d'une nouvelle piste.
local function draw_send_dialog(mode, all_tracks)
  local is_recv = (mode == "receive")
  if not dialog_begin(is_recv and DLG.receive or DLG.send, 520) then return end

  local np  = state.np
  local sel = state.sel_tracks
  local sel_set = state.sel_set
  local FH  = reaper.ImGui_GetFrameHeight(ctx)

  -- Réglages
  dialog_section(is_recv and "Receive parameters" or "Send parameters", true)
  label_text("Mode")
  reaper.ImGui_SameLine(ctx, 0, 8)
  reaper.ImGui_SetNextItemWidth(ctx, 180)
  local cm, nmi = reaper.ImGui_Combo(ctx, "##dlg_mode", np.mode_idx-1, SM_LONG_STR)
  if cm then np.mode_idx = nmi+1 end

  reaper.ImGui_SameLine(ctx, 0, 16)
  if toggle_btn("dlg_mu", "M", np.mute, FH, FH, C.mute_on, C.mute_txt) then np.mute = not np.mute end
  tip("Mute")
  reaper.ImGui_SameLine(ctx, 0, 2)
  if toggle_btn("dlg_ph", "Ø", np.phase, FH, FH, C.phase_on, C.phase_txt) then np.phase = not np.phase end
  tip("Polarity")
  reaper.ImGui_SameLine(ctx, 0, 2)
  if toggle_btn("dlg_mn", np.mono and "MO" or "ST", np.mono, FH + 6, FH, C.mono_on, C.white) then np.mono = not np.mono end
  tip(np.mono and "Mono" or "Stereo")

  np.main_send = styled_checkbox(is_recv
    and "Disable master send on the source tracks##dlg_ms"
    or  "Disable master send on the selected tracks##dlg_ms", np.main_send)

  -- Pistes à cocher (hors sélection), filtrables par nom
  dialog_section(is_recv and "Sources" or "Destinations")
  local w_all, w_none = btn_w("All"), btn_w("None")
  reaper.ImGui_SetNextItemWidth(ctx, reaper.ImGui_GetContentRegionAvail(ctx) - w_all - w_none - 12)
  local _, nf = reaper.ImGui_InputTextWithHint(ctx, "##dlg_filter", "Filter tracks", state.send_filter)
  if nf then state.send_filter = nf end
  local flt = state.send_filter:lower()

  local candidates = {}
  for _, dt in ipairs(all_tracks) do
    if not sel_set[dt] and (flt == "" or tname(dt):lower():find(flt, 1, true)) then
      candidates[#candidates+1] = dt
    end
  end

  reaper.ImGui_SameLine(ctx, 0, 6)
  if btn("All##dlg_all") then
    for _, dt in ipairs(candidates) do state.dest_checked[tostring(dt)] = true end
  end
  reaper.ImGui_SameLine(ctx, 0, 6)
  if btn("None##dlg_none") then state.dest_checked = {} end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), C.bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),  C.border_soft)
  local list_ok = reaper.ImGui_BeginChild(ctx, "dlg_list", 0, 200, CF_BORDERS)
  reaper.ImGui_PopStyleColor(ctx, 2)
  if list_ok then
    if #candidates == 0 then
      empty_state("No matching track.")
    end
    for _, dt in ipairs(candidates) do
      local ptr = tostring(dt)
      color_chip(rcolor(dt), 4, FH - 8)
      reaper.ImGui_SameLine(ctx, 0, 6)
      state.dest_checked[ptr] = styled_checkbox(tname(dt).."##chk_"..ptr, state.dest_checked[ptr] or false)
    end
    reaper.ImGui_EndChild(ctx)
  end

  local picked = {}
  for _, dt in ipairs(all_tracks) do
    if state.dest_checked[tostring(dt)] then picked[#picked+1] = dt end
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_faint)
  reaper.ImGui_Text(ctx, string.format("%d track(s) checked", #picked))
  reaper.ImGui_PopStyleColor(ctx, 1)

  -- Nouvelle piste : destination pour un send, source pour un receive
  dialog_section(is_recv and "Or create a new source track" or "Or create a new destination track")
  local create_lbl = "Create##dlg_newtrk"
  reaper.ImGui_SetNextItemWidth(ctx, reaper.ImGui_GetContentRegionAvail(ctx) - btn_w(create_lbl) - 8)
  local _, nn = reaper.ImGui_InputTextWithHint(ctx, "##dlg_newname", "New track name", state.send_newname)
  if nn then state.send_newname = nn end
  reaper.ImGui_SameLine(ctx, 0, 8)
  local can_new = state.send_newname ~= ""
  reaper.ImGui_BeginDisabled(ctx, not can_new)
  local do_new = col_btn(create_lbl, can_new and C.send_col or C.bg_item, can_new and C.send_hov or C.bg_item)
  reaper.ImGui_EndDisabled(ctx)

  local function close_dialog()
    state.send_filter, state.send_newname = "", ""
    state.dest_checked   = {}
    state.new_send_count = 1
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  if do_new and can_new then
    local nm = state.send_newname
    if is_recv then
      queue(function() action_create_recv_new_track(sel, nm, np) end)
    else
      queue(function() action_create_sends_new_track(sel, nm, np) end)
    end
    close_dialog()
  end

  -- Pied : nombre de sends par piste cochée, puis boutons
  local total = #picked * state.new_send_count
  local noun  = is_recv and "receive" or "send"
  local ok_lbl = total == 0 and "Create##dlg_ok"
    or (total == 1 and string.format("Create 1 %s##dlg_ok", noun)
                   or  string.format("Create %d %ss##dlg_ok", total, noun))
  local ok, cancel = dialog_footer(ok_lbl, is_recv and C.recv_col or C.send_col,
    is_recv and C.recv_hov or C.send_hov, #picked > 0, function()
      label_text(is_recv and "Per source" or "Per destination")
      reaper.ImGui_SameLine(ctx, 0, 6)
      local nsv, nsc = int_field("dlg_send_count", state.new_send_count, 1, 16, 44)
      if nsc then state.new_send_count = nsv end
    end)

  if ok then
    for _ = 1, state.new_send_count do
      if is_recv then
        action_create_sends(picked, sel, np, "receive")
      else
        action_create_sends(sel, picked, np, "send")
      end
    end
    close_dialog()
  elseif cancel then
    close_dialog()
  end

  reaper.ImGui_EndPopup(ctx)
end

-- Ouvre le dialogue demandé et dessine ceux qui sont ouverts. Ils sont tous
-- gérés ici, au niveau de la fenêtre principale, quel que soit le bouton
-- qui les a demandés.
local function draw_dialogs(all_tracks)
  if state.open_dialog then
    reaper.ImGui_OpenPopup(ctx, DLG[state.open_dialog])
    state.open_dialog = nil
  end
  draw_tracks_dialog()
  for kind in pairs(CREATE_KINDS) do draw_create_dialog(kind) end
  draw_send_dialog("send", all_tracks)
  draw_send_dialog("receive", all_tracks)
  draw_delete_dialog()
end

-- ============================================================
--  LIGNE DE SEND / RECEIVE
-- ============================================================
-- Édition groupée : répercute une modification sur les sends équivalents
-- des pistes sélectionnées (même destination), ou sur tous les receives de
-- la même piste. Les pistes reçoivent les canaux nécessaires si besoin.
local function bulk_apply(param, value, cat, orig_dest, orig_track)
  local sel_set = state.sel_set

  local function prepare(src_tr, dst_tr)
    local pair = math.floor(value / 2) + 1
    if param == "I_SRCCHAN" then ensure_chans(src_tr, pair * 2)
    elseif param == "I_DSTCHAN" then ensure_chans(dst_tr, pair * 2) end
  end

  if cat == 0 then
    for _, src in ipairs(state.sel_tracks) do
      for _, s in ipairs(get_sends(src)) do
        if not sel_set[s.dest] and (orig_dest == nil or s.dest == orig_dest) then
          prepare(src, s.dest)
          reaper.SetTrackSendInfo_Value(src, 0, s.idx, param, value)
        end
      end
    end
  else
    local dsts = orig_track and { orig_track } or state.sel_tracks
    for _, dst in ipairs(dsts) do
      for _, r in ipairs(get_receives(dst)) do
        prepare(r.src, dst)
        reaper.SetTrackSendInfo_Value(dst, -1, r.idx, param, value)
      end
    end
  end
end

-- Colonnes d'une ligne send/receive. Le nom prend la place restante ; les
-- autres colonnes ont une largeur fixe, identique sur toutes les lignes et
-- sur l'en-tête, pour que tout reste aligné.
local SR = { VOL_W = 62, MODE_W = 104, CH_W = 56, GAP = 8 }

local function send_cols(avail_w)
  local FH = reaper.ImGui_GetFrameHeight(ctx)
  local c = { sq = FH, mono_w = FH + 6 }
  local btns_w = FH + 2 + FH + 2 + c.mono_w
  local act_w  = FH + 2 + FH
  local fixed  = SR.VOL_W + SR.GAP + SR.MODE_W + SR.GAP + btns_w + SR.GAP
               + SR.CH_W + 4 + SR.CH_W + SR.GAP + act_w
  c.name_w = math.max(90, avail_w - fixed - SR.GAP)
  c.vol  = c.name_w + SR.GAP
  c.mode = c.vol  + SR.VOL_W  + SR.GAP
  c.btns = c.mode + SR.MODE_W + SR.GAP
  c.src  = c.btns + btns_w    + SR.GAP
  c.dst  = c.src  + SR.CH_W   + 4
  c.act  = c.dst  + SR.CH_W   + SR.GAP
  c.total_w = c.act + act_w
  return c
end

-- En-tête des colonnes : chaque titre est aligné sur le texte de sa colonne,
-- ou centré au-dessus de son bouton.
local function column_header(cols, base_x, first_label)
  local FH, fp = cols.sq, 6
  local function at(x, text)
    reaper.ImGui_SameLine(ctx, base_x + x) ; reaper.ImGui_Text(ctx, text)
  end
  local function centered(x, w, text)
    local tw = reaper.ImGui_CalcTextSize(ctx, text)
    at(x + math.floor((w - tw) / 2), text)
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_faint)
  reaper.ImGui_SetCursorPosX(ctx, base_x + 9)
  reaper.ImGui_Text(ctx, first_label)
  at(cols.vol, "Volume")
  at(cols.mode + fp, "Mode")
  centered(cols.btns, FH, "M")
  centered(cols.btns + FH + 2, FH, "Ø")
  centered(cols.btns + FH * 2 + 4, cols.mono_w, "Ch")
  at(cols.src + fp, "Src")
  at(cols.dst + fp, "Dst")
  reaper.ImGui_PopStyleColor(ctx, 1)
end

-- Largeur commune des boutons "+ Send" et "+ Receive", pour que les deux
-- cartes aient leurs contrôles d'en-tête alignés.
local function header_btn_w(nb)
  local a = btn_w(nb > 1 and string.format("+ Send from %d tracks", nb) or "+ Send")
  local b = btn_w(nb > 1 and string.format("+ Receive to %d tracks", nb) or "+ Receive")
  return math.max(a, b, 110)
end

-- Sous-titre "From X" / "To X" quand plusieurs pistes sont sélectionnées.
local function group_subheader(prefix, track)
  reaper.ImGui_Dummy(ctx, 0, 2)
  color_chip(rcolor(track), 3, 10)
  reaper.ImGui_SameLine(ctx, 0, 6)
  label_text(prefix .. " " .. tname(track), C.text_dim)
end

-- Une ligne de send (cat = 0) ou de receive (cat = -1) : nom de l'autre
-- piste, volume, mode, Mute / Polarité / Mono, canaux, changement de
-- destination et suppression. Renvoie : à supprimer, suppression groupée.
local function send_row(track, s, uid, cat, all_tracks, bulk_edit, cols, base_x, first_row)
  local is_recv = (cat == -1)
  local other   = is_recv and s.src or s.dest
  local src_ref = is_recv and other or track
  local dst_ref = is_recv and track or other
  local do_del, bulk_delete = false, false
  local FH = cols.sq

  local function bulk(param, v)
    if bulk_edit then bulk_apply(param, v, cat, is_recv and nil or other, is_recv and track or nil) end
  end

  reaper.ImGui_PushID(ctx, uid)
  reaper.ImGui_SetCursorPosX(ctx, base_x)
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  -- Trait de séparation et surbrillance au survol
  if not first_row then
    reaper.ImGui_DrawList_AddLine(dl, x0, y0 - 2.5, x0 + cols.total_w, y0 - 2.5, C.row_sep, 1)
  end
  if reaper.ImGui_IsWindowHovered(ctx)
     and reaper.ImGui_IsMouseHoveringRect(ctx, x0 - 6, y0 - 2, x0 + cols.total_w + 6, y0 + FH + 2) then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0 - 6, y0 - 2, x0 + cols.total_w + 6, y0 + FH + 2, C.row_hover, 4)
  end

  -- Couleur et nom de l'autre piste ; un clic la sélectionne dans REAPER
  color_chip(rcolor(other), 3, FH - 6)
  reaper.ImGui_SameLine(ctx, 0, 6)
  local name_w = cols.name_w - 9
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),        0x00000000)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), 0x00000000)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),  0x00000000)
  if reaper.ImGui_Selectable(ctx, fit_name(tname(other), name_w) .. "##selname", false, 0, name_w, FH) then
    if reaper.ValidatePtr(other, "MediaTrack*") then
      reaper.SetOnlyTrackSelected(other)
      state.focused_track  = other
      state.last_sel_count = -1
    end
  end
  reaper.ImGui_PopStyleColor(ctx, 3)
  tip("Select " .. tname(other))

  -- Volume
  reaper.ImGui_SameLine(ctx, base_x + cols.vol)
  draw_vol_knob(uid, bulk_edit, track, cat, s, other)

  -- Mode
  reaper.ImGui_SameLine(ctx, base_x + cols.mode)
  local mi = sm_to_idx(s.mode)
  local cmi, nmi = compact_combo("##mode", mi, SM_LABELS, SR.MODE_W)
  tip(SM_LONG[mi])
  if cmi then
    local v = SM_VALS[nmi]
    action_set_send_field(track, cat, s.idx, "I_SENDMODE", v)
    bulk("I_SENDMODE", v)
  end

  -- Mute / Polarité / Mono
  reaper.ImGui_SameLine(ctx, base_x + cols.btns)
  if toggle_btn("mu", "M", s.mute, FH, FH, C.mute_on, C.mute_txt) then
    local v = s.mute and 0 or 1
    action_set_send_field(track, cat, s.idx, "B_MUTE", v) ; bulk("B_MUTE", v)
  end
  tip("Mute")
  reaper.ImGui_SameLine(ctx, 0, 2)
  if toggle_btn("ph", "Ø", s.phase, FH, FH, C.phase_on, C.phase_txt) then
    local v = s.phase and 0 or 1
    action_set_send_field(track, cat, s.idx, "B_PHASE", v) ; bulk("B_PHASE", v)
  end
  tip("Polarity")
  reaper.ImGui_SameLine(ctx, 0, 2)
  if toggle_btn("mn", s.mono and "MO" or "ST", s.mono, cols.mono_w, FH, C.mono_on, C.white) then
    local v = s.mono and 0 or 1
    action_set_send_field(track, cat, s.idx, "B_MONO", v) ; bulk("B_MONO", v)
  end
  tip(s.mono and "Mono (click for stereo)" or "Stereo (click for mono)")

  -- Canaux source
  reaper.ImGui_SameLine(ctx, base_x + cols.src)
  local csp, nsp = compact_combo("##srcp", s.src_pair, PAIR_LABELS, SR.CH_W, true)
  tip("Source channels")
  if csp then
    local v = pair_to_chan(nsp)
    ensure_chans(src_ref, nsp * 2)
    action_set_send_field(track, cat, s.idx, "I_SRCCHAN", v) ; bulk("I_SRCCHAN", v)
  end

  -- Canaux destination
  reaper.ImGui_SameLine(ctx, base_x + cols.dst)
  local cdp, ndp = compact_combo("##dstp", s.dst_pair, PAIR_LABELS, SR.CH_W, true)
  tip("Destination channels")
  if cdp then
    local v = pair_to_chan(ndp)
    ensure_chans(dst_ref, ndp * 2)
    action_set_send_field(track, cat, s.idx, "I_DSTCHAN", v) ; bulk("I_DSTCHAN", v)
  end

  -- Changement de destination (sends uniquement)
  reaper.ImGui_SameLine(ctx, base_x + cols.act)
  if not is_recv then
    if icon_btn("chgd", "->", FH, FH, C.text_dim) then
      reaper.ImGui_OpenPopup(ctx, "chgdest")
    end
    tip("Change destination")
    if reaper.ImGui_BeginPopup(ctx, "chgdest") then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_faint)
      reaper.ImGui_Text(ctx, bulk_edit and "New destination (bulk)" or "New destination")
      reaper.ImGui_PopStyleColor(ctx, 1)
      reaper.ImGui_Separator(ctx)
      local list_h = math.min(#all_tracks * reaper.ImGui_GetFrameHeightWithSpacing(ctx), 320)
      if reaper.ImGui_BeginChild(ctx, "cd_list", 240, list_h, 0) then
        for _, dt in ipairs(all_tracks) do
          if dt ~= track then
            color_chip(rcolor(dt), 3, FH - 8)
            reaper.ImGui_SameLine(ctx, 0, 6)
            if reaper.ImGui_Selectable(ctx, tname(dt).."##cd_"..tostring(dt), dt == s.dest) then
              local orig_dest = s.dest
              action_change_dest(track, s.idx, dt, s)
              if bulk_edit then
                -- Les autres sends vers l'ancienne destination suivent.
                for _, src in ipairs(state.sel_tracks) do
                  if src ~= track then
                    for _, sv in ipairs(get_sends(src)) do
                      if sv.dest == orig_dest then action_change_dest(src, sv.idx, dt, sv) end
                    end
                  end
                end
              end
              reaper.ImGui_CloseCurrentPopup(ctx)
            end
          end
        end
        reaper.ImGui_EndChild(ctx)
      end
      reaper.ImGui_EndPopup(ctx)
    end
  else
    reaper.ImGui_Dummy(ctx, FH, FH)
  end

  -- Suppression
  reaper.ImGui_SameLine(ctx, 0, 2)
  if icon_btn("del", "X", FH, FH, C.danger_txt, C.bg_item, C.danger) then
    do_del = true
    if bulk_edit then bulk_delete = true end
  end
  tip(bulk_edit and "Remove (bulk)" or "Remove")

  reaper.ImGui_PopID(ctx)
  return do_del, bulk_delete
end

-- ============================================================
--  CARTES SENDS ET RECEIVES
-- ============================================================
-- Carte SENDS : envois des pistes sélectionnées vers d'autres pistes. Les
-- sends entre deux pistes de la sélection ne sont pas listés.
local function panel_sends(all_tracks)
  local ok = card_begin("card_sends")
  if ok then
    local nb = #state.sel_tracks
    local sel_set = state.sel_set

    local groups, total = {}, 0
    for _, src in ipairs(state.sel_tracks) do
      local vis = {}
      for _, s in ipairs(get_sends(src)) do
        if not sel_set[s.dest] then vis[#vis+1] = s end
      end
      if #vis > 0 then groups[#groups+1] = { track = src, rows = vis } ; total = total + #vis end
    end

    local add_lbl = (nb > 1 and string.format("+ Send from %d tracks", nb) or "+ Send") .. "##ns"
    local add_w = header_btn_w(nb)
    card_header("SENDS", C.send_col, total, switch_w("Bulk edit") + 14 + add_w)
    local bv, bch = toggle_switch("bulk_s", state.bulk_edit_sends, "Bulk edit")
    if bch then state.bulk_edit_sends = bv end
    tip("Apply each change to the matching sends of every selected track")
    reaper.ImGui_SameLine(ctx, 0, 14)
    if col_btn(add_lbl, C.send_col, C.send_hov, add_w) then
      state.dest_checked = {}
      state.open_dialog  = "send"
    end
    hline(2, 2)

    local to_del = {}
    if total == 0 then
      empty_state("No outgoing sends on the selection.")
    else
      local base_x = reaper.ImGui_GetCursorPosX(ctx)
      local cols = send_cols(reaper.ImGui_GetContentRegionAvail(ctx))
      column_header(cols, base_x, "Destination")
      for _, grp in ipairs(groups) do
        local src = grp.track
        if nb > 1 then group_subheader("From", src) end
        for i, s in ipairs(grp.rows) do
          local uid = "S_"..tostring(src).."_"..i
          local del, bulk_del = send_row(src, s, uid, 0, all_tracks, state.bulk_edit_sends, cols, base_x, i == 1)
          if del then
            if bulk_del then
              -- Supprime les sends vers cette destination sur toutes les pistes sélectionnées.
              for _, bsrc in ipairs(state.sel_tracks) do
                for _, bsv in ipairs(get_sends(bsrc)) do
                  if not sel_set[bsv.dest] and bsv.dest == s.dest then
                    to_del[#to_del+1] = { bsrc, bsv.idx }
                  end
                end
              end
            else
              to_del[#to_del+1] = { src, s.idx }
            end
          end
        end
      end
    end

    -- Suppressions faites après l'affichage, des derniers sends vers les
    -- premiers, pour ne pas décaler la numérotation des suivants.
    if #to_del > 0 then
      table.sort(to_del, function(a,b) return a[2] > b[2] end)
      for _, item in ipairs(to_del) do action_delete_send(item[1], item[2]) end
    end
  end
  card_end(ok)
end

-- Carte RECEIVES : signaux reçus par les pistes sélectionnées.
local function panel_receives(all_tracks)
  local ok = card_begin("card_recvs")
  if ok then
    local nb = #state.sel_tracks

    local groups, total = {}, 0
    for _, dst in ipairs(state.sel_tracks) do
      local recvs = get_receives(dst)
      if #recvs > 0 then groups[#groups+1] = { track = dst, rows = recvs } ; total = total + #recvs end
    end

    local add_lbl = (nb > 1 and string.format("+ Receive to %d tracks", nb) or "+ Receive") .. "##nr"
    local add_w = header_btn_w(nb)
    card_header("RECEIVES", C.recv_col, total, switch_w("Bulk edit") + 14 + add_w)
    local bv, bch = toggle_switch("bulk_r", state.bulk_edit_recvs, "Bulk edit")
    if bch then state.bulk_edit_recvs = bv end
    tip("Apply each change to every receive of the same track")
    reaper.ImGui_SameLine(ctx, 0, 14)
    if col_btn(add_lbl, C.recv_col, C.recv_hov, add_w) then
      state.dest_checked = {}
      state.open_dialog  = "receive"
    end
    hline(2, 2)

    local to_del = {}
    if total == 0 then
      empty_state("No receives on the selection.")
    else
      local base_x = reaper.ImGui_GetCursorPosX(ctx)
      local cols = send_cols(reaper.ImGui_GetContentRegionAvail(ctx))
      column_header(cols, base_x, "Source")
      for _, grp in ipairs(groups) do
        local dst = grp.track
        if nb > 1 then group_subheader("To", dst) end
        for i, r in ipairs(grp.rows) do
          local uid = "R_"..tostring(dst).."_"..i
          local del, bulk_del = send_row(dst, r, uid, -1, all_tracks, state.bulk_edit_recvs, cols, base_x, i == 1)
          if del then
            if bulk_del then
              -- Supprime tous les receives de cette piste.
              for _, brv in ipairs(get_receives(dst)) do to_del[#to_del+1] = { dst, brv.idx } end
            else
              to_del[#to_del+1] = { dst, r.idx }
            end
          end
        end
      end
    end

    if #to_del > 0 then
      table.sort(to_del, function(a,b) return a[2] > b[2] end)
      local seen = {}
      for _, item in ipairs(to_del) do
        local key = tostring(item[1]) .. "_" .. item[2]
        if not seen[key] then seen[key] = true ; action_delete_receive(item[1], item[2]) end
      end
    end
  end
  card_end(ok)
end

-- ============================================================
--  CARTES VCA
-- ============================================================
-- Options liées au groupe : "lead" côté master, "follow" côté slave.
local VCA_LEAD_KEYS   = { { "MUTE_LEAD", "Mute" },  { "SOLO_LEAD", "Solo" },  { "VOLUME_LEAD", "Volume" } }
local VCA_FOLLOW_KEYS = { { "MUTE_SLAVE", "Mute" }, { "SOLO_SLAVE", "Solo" }, { "VOLUME_SLAVE", "Volume" } }

-- Libellé d'un groupe dans les listes : numéro et nom de son master.
local function group_label(g)
  local nm = grp_master(grp_bit(g))
  return string.format("G%d   %s", g, nm or "(free)")
end

-- Liste des 16 groupes, pour faire de la sélection un master ou un slave.
local function draw_group_picker(kind)
  local sel = state.sel_tracks
  local is_master = kind == "master"
  local opts = is_master and state.vca_mst_opts or state.vca_slv_opts

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_faint)
  reaper.ImGui_Text(ctx, is_master and "Assign as VCA master" or "Assign as VCA slave")
  reaper.ImGui_PopStyleColor(ctx, 1)
  if is_master then
    opts.mute_lead   = styled_checkbox("Mute lead##gp_ml", opts.mute_lead)
    reaper.ImGui_SameLine(ctx, 0, 12)
    opts.solo_lead   = styled_checkbox("Solo lead##gp_sl", opts.solo_lead)
    reaper.ImGui_SameLine(ctx, 0, 12)
    opts.volume_lead = styled_checkbox("Volume lead##gp_vl", opts.volume_lead)
  else
    opts.mute_follow   = styled_checkbox("Mute follow##gp_mf", opts.mute_follow)
    reaper.ImGui_SameLine(ctx, 0, 12)
    opts.solo_follow   = styled_checkbox("Solo follow##gp_sf", opts.solo_follow)
    reaper.ImGui_SameLine(ctx, 0, 12)
    opts.volume_follow = styled_checkbox("Volume follow##gp_vf", opts.volume_follow)
  end
  reaper.ImGui_Separator(ctx)

  for g = 1, 16 do
    local bit = grp_bit(g)
    if reaper.ImGui_Selectable(ctx, group_label(g) .. "##gp_" .. kind .. g) then
      reaper.Undo_BeginBlock()
      if is_master then
        for _, st in ipairs(sel) do
          reaper.GetSetTrackGroupMembership(st, "VOLUME_VCA_MASTER", bit, bit)
          if opts.mute_lead   then reaper.GetSetTrackGroupMembership(st, "MUTE_LEAD",   bit, bit) end
          if opts.solo_lead   then reaper.GetSetTrackGroupMembership(st, "SOLO_LEAD",   bit, bit) end
          if opts.volume_lead then reaper.GetSetTrackGroupMembership(st, "VOLUME_LEAD", bit, bit) end
        end
        reaper.Undo_EndBlock("SK RH : VCA Master G"..g, -1)
        set_status("Master G"..g.." assigned")
      else
        -- Un slave suit au minimum les options "lead" actives sur le master.
        local _, _, master_tr = grp_master(bit)
        local m_mute = master_tr and has_group_flag(master_tr, "MUTE_LEAD",   bit)
        local m_solo = master_tr and has_group_flag(master_tr, "SOLO_LEAD",   bit)
        local m_vol  = master_tr and has_group_flag(master_tr, "VOLUME_LEAD", bit)
        for _, st in ipairs(sel) do
          reaper.GetSetTrackGroupMembership(st, "VOLUME_VCA_SLAVE", bit, bit)
          if m_mute or opts.mute_follow   then reaper.GetSetTrackGroupMembership(st, "MUTE_SLAVE",   bit, bit) end
          if m_solo or opts.solo_follow   then reaper.GetSetTrackGroupMembership(st, "SOLO_SLAVE",   bit, bit) end
          if m_vol  or opts.volume_follow then reaper.GetSetTrackGroupMembership(st, "VOLUME_SLAVE", bit, bit) end
        end
        reaper.Undo_EndBlock("SK RH : VCA Slave G"..g, -1)
        set_status("Slave G"..g.." assigned")
      end
    end
  end
end

-- Fenêtre d'édition des options "lead" (master) ou "follow" (slave) d'un
-- groupe, ouverte par le bouton Edit.
local function draw_vca_edit_popup(kind)
  local is_master = kind == "master"
  local pid = is_master and "vca_edit_master" or "vca_edit_slave"
  if state.vca_open_edit == pid then
    reaper.ImGui_OpenPopup(ctx, pid)
    state.vca_open_edit = nil
    reaper.ImGui_SetNextWindowPos(ctx, state.win_cx, state.win_cy, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  end
  if not reaper.ImGui_BeginPopup(ctx, pid) then return end
  local g    = is_master and state.vca_edit_mst_group or state.vca_edit_slv_group
  local opts = is_master and state.vca_edit_mst or state.vca_edit_slv

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_faint)
  reaper.ImGui_Text(ctx, (is_master and "Master options" or "Slave options") .. " — group " .. (g or "?"))
  reaper.ImGui_PopStyleColor(ctx, 1)
  if opts then
    local word = is_master and "lead" or "follow"
    opts[1] = styled_checkbox("Mute "   .. word .. "##ve1", opts[1])
    reaper.ImGui_SameLine(ctx, 0, 12)
    opts[2] = styled_checkbox("Solo "   .. word .. "##ve2", opts[2])
    reaper.ImGui_SameLine(ctx, 0, 12)
    opts[3] = styled_checkbox("Volume " .. word .. "##ve3", opts[3])
  end
  reaper.ImGui_Dummy(ctx, 0, 4)

  local right = row_right_edge()
  local w_ok = btn_w("Apply")
  reaper.ImGui_SetCursorPosX(ctx, right - 70 - 6 - w_ok)
  if btn("Cancel##ve_no", 70) then reaper.ImGui_CloseCurrentPopup(ctx) end
  reaper.ImGui_SameLine(ctx, 0, 6)
  if col_btn("Apply##ve_ok", C.send_col, C.send_hov) and g and opts then
    local bit = grp_bit(g)
    reaper.Undo_BeginBlock()
    if is_master then
      local _, _, master_tr = grp_master(bit)
      if master_tr then
        for i, kv in ipairs(VCA_LEAD_KEYS) do
          reaper.GetSetTrackGroupMembership(master_tr, kv[1], bit, opts[i] and bit or 0)
        end
        -- Toutes les pistes slaves du groupe suivent le nouveau réglage.
        for i = 0, reaper.CountTracks(0) - 1 do
          local tr = reaper.GetTrack(0, i)
          if has_group_flag(tr, "VOLUME_VCA_SLAVE", bit) then
            for k, kv in ipairs(VCA_FOLLOW_KEYS) do
              reaper.GetSetTrackGroupMembership(tr, kv[1], bit, opts[k] and bit or 0)
            end
          end
        end
      end
    else
      for _, st in ipairs(state.sel_tracks) do
        if has_group_flag(st, "VOLUME_VCA_SLAVE", bit) then
          for k, kv in ipairs(VCA_FOLLOW_KEYS) do
            reaper.GetSetTrackGroupMembership(st, kv[1], bit, opts[k] and bit or 0)
          end
        end
      end
    end
    reaper.Undo_EndBlock("SK RH : Edit VCA " .. (is_master and "Master" or "Slave") .. " G"..g, -1)
    set_status((is_master and "Master" or "Slave") .. " G"..g.." options updated")
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_EndPopup(ctx)
end

-- Nom de piste cliquable : un clic la sélectionne dans REAPER.
local function goto_track_row(tr, id, width, text_col)
  color_chip(rcolor(tr), 3)
  reaper.ImGui_SameLine(ctx, 0, 6)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), text_col or C.text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),        0x00000000)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), C.row_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),  C.row_sel)
  local FH = reaper.ImGui_GetFrameHeight(ctx)
  if reaper.ImGui_Selectable(ctx, fit_name(tname(tr), width - 8) .. "##" .. id, false, 0, width, FH) then
    if reaper.ValidatePtr(tr, "MediaTrack*") then
      reaper.SetOnlyTrackSelected(tr)
      state.focused_track  = tr
      state.last_sel_count = -1
    end
  end
  reaper.ImGui_PopStyleColor(ctx, 4)
  tip("Select " .. tname(tr))
end

-- Boutons Edit / Remove alignés à droite de la ligne.
local function edit_remove_btns(right, id)
  local w_edit, w_rm = btn_w("Edit"), btn_w("Remove")
  reaper.ImGui_SameLine(ctx, right - w_edit - 6 - w_rm)
  local edit = btn("Edit##" .. id .. "_ed")
  reaper.ImGui_SameLine(ctx, 0, 6)
  local rm = danger_btn("Remove##" .. id .. "_rm")
  return edit, rm
end

-- Carte VCA MASTER : groupes commandés par la sélection, avec leurs slaves.
local function panel_vca_master()
  local sel = state.sel_tracks
  local ok = card_begin("card_vca_master")
  if ok then
    local mb_all = 0
    for _, st in ipairs(sel) do
      mb_all = mb_all | reaper.GetSetTrackGroupMembership(st, "VOLUME_VCA_MASTER", 0, 0)
    end
    local n_groups = 0
    for g = 1, 16 do if mb_all & grp_bit(g) ~= 0 then n_groups = n_groups + 1 end end

    local add_lbl = "+ Assign as master##vca_am"
    local add_w = math.max(btn_w("+ Assign as master"), btn_w("+ Assign as slave"))
    card_header("VCA MASTER", C.vca_col, n_groups, add_w)
    if col_btn(add_lbl, C.vca_col, C.vca_hov, add_w) then reaper.ImGui_OpenPopup(ctx, "vca_pick_master") end
    if reaper.ImGui_BeginPopup(ctx, "vca_pick_master") then
      draw_group_picker("master")
      reaper.ImGui_EndPopup(ctx)
    end
    hline(2, 2)

    if mb_all == 0 then
      empty_state("The selection doesn't lead any VCA group.")
    end

    for g = 1, 16 do
      local bit = grp_bit(g)
      if mb_all & bit ~= 0 then
        local right = row_right_edge()
        local nm, gc, master_tr = grp_master(bit)
        reaper.ImGui_PushID(ctx, "vm" .. g)

        color_chip(gc, 3)
        reaper.ImGui_SameLine(ctx, 0, 6)
        label_text("G" .. g, C.mute_txt)
        reaper.ImGui_SameLine(ctx, 0, 8)
        label_text(nm or ("Group " .. g), C.white)
        if master_tr then
          for _, kv in ipairs(VCA_LEAD_KEYS) do
            reaper.ImGui_SameLine(ctx, 0, 6)
            flag_tag(kv[2], has_group_flag(master_tr, kv[1], bit))
          end
        end

        local edit, rm = edit_remove_btns(right, "vm" .. g)
        if edit and master_tr then
          state.vca_edit_mst_group = g
          state.vca_edit_mst = {}
          for i, kv in ipairs(VCA_LEAD_KEYS) do
            state.vca_edit_mst[i] = has_group_flag(master_tr, kv[1], bit)
          end
          state.vca_open_edit = "vca_edit_master"
        end
        if rm then
          reaper.Undo_BeginBlock()
          for _, st in ipairs(sel) do
            reaper.GetSetTrackGroupMembership(st, "VOLUME_VCA_MASTER", bit, 0)
            for _, kv in ipairs(VCA_LEAD_KEYS) do
              reaper.GetSetTrackGroupMembership(st, kv[1], bit, 0)
            end
          end
          remove_vca_slaves(bit)
          reaper.Undo_EndBlock("SK RH : Remove VCA Master G"..g, -1)
          set_status("Master G"..g.." removed")
        end

        -- Pistes slaves du groupe.
        local slaves = {}
        for i = 0, reaper.CountTracks(0)-1 do
          local tr = reaper.GetTrack(0, i)
          if has_group_flag(tr, "VOLUME_VCA_SLAVE", bit) then slaves[#slaves+1] = tr end
        end
        reaper.ImGui_Indent(ctx, 22)
        if #slaves == 0 then
          label_text("No slaves yet.", C.text_faint)
        else
          label_text(string.format("Slaves (%d)", #slaves), C.text_faint)
          for si, strk in ipairs(slaves) do
            goto_track_row(strk, "slv" .. si, 240)
          end
        end
        reaper.ImGui_Unindent(ctx, 22)
        reaper.ImGui_Dummy(ctx, 0, 4)

        reaper.ImGui_PopID(ctx)
      end
    end
    draw_vca_edit_popup("master")
  end
  card_end(ok)
end

-- Carte VCA SLAVE : groupes que la sélection suit, avec leur master.
local function panel_vca_slave()
  local sel = state.sel_tracks
  local ok = card_begin("card_vca_slave")
  if ok then
    local sb_all = 0
    for _, st in ipairs(sel) do
      sb_all = sb_all | reaper.GetSetTrackGroupMembership(st, "VOLUME_VCA_SLAVE", 0, 0)
    end
    local n_groups = 0
    for g = 1, 16 do if sb_all & grp_bit(g) ~= 0 then n_groups = n_groups + 1 end end

    local add_lbl = "+ Assign as slave##vca_as"
    local add_w = math.max(btn_w("+ Assign as master"), btn_w("+ Assign as slave"))
    card_header("VCA SLAVE", C.vca_col, n_groups, add_w)
    if col_btn(add_lbl, C.vca_col, C.vca_hov, add_w) then reaper.ImGui_OpenPopup(ctx, "vca_pick_slave") end
    if reaper.ImGui_BeginPopup(ctx, "vca_pick_slave") then
      draw_group_picker("slave")
      reaper.ImGui_EndPopup(ctx)
    end
    hline(2, 2)

    if sb_all == 0 then
      empty_state("The selection doesn't follow any VCA group.")
    end

    for g = 1, 16 do
      local bit = grp_bit(g)
      if sb_all & bit ~= 0 then
        local right = row_right_edge()
        local nm, _, master_tr = grp_master(bit)
        reaper.ImGui_PushID(ctx, "vs" .. g)

        label_text("G" .. g, C.mute_txt)
        reaper.ImGui_SameLine(ctx, 0, 8)
        if master_tr then
          goto_track_row(master_tr, "goto", 180, C.white)
        else
          label_text("(no master)", C.text_faint)
        end

        -- Options affichées : celles de la première piste sélectionnée du groupe.
        local ref = nil
        for _, st in ipairs(sel) do
          if has_group_flag(st, "VOLUME_VCA_SLAVE", bit) then ref = st ; break end
        end
        if ref then
          for _, kv in ipairs(VCA_FOLLOW_KEYS) do
            reaper.ImGui_SameLine(ctx, 0, 6)
            flag_tag(kv[2], has_group_flag(ref, kv[1], bit))
          end
        end

        local edit, rm = edit_remove_btns(right, "vs" .. g)
        if edit and ref then
          state.vca_edit_slv_group = g
          state.vca_edit_slv = {}
          for i, kv in ipairs(VCA_FOLLOW_KEYS) do
            state.vca_edit_slv[i] = has_group_flag(ref, kv[1], bit)
          end
          state.vca_open_edit = "vca_edit_slave"
        end
        if rm then
          reaper.Undo_BeginBlock()
          for _, st in ipairs(sel) do
            reaper.GetSetTrackGroupMembership(st, "VOLUME_VCA_SLAVE", bit, 0)
            for _, kv in ipairs(VCA_FOLLOW_KEYS) do
              reaper.GetSetTrackGroupMembership(st, kv[1], bit, 0)
            end
          end
          reaper.Undo_EndBlock("SK RH : Remove VCA Slave G"..g, -1)
          set_status("Slave G"..g.." removed")
        end
        reaper.ImGui_PopID(ctx)
      end
    end
    draw_vca_edit_popup("slave")
  end
  card_end(ok)
end

-- ============================================================
--  COLONNE GAUCHE — LISTE DES PISTES
-- ============================================================
-- Dimensions d'une ligne de la liste, en pixels.
local ROW_H   = 26     -- hauteur d'une ligne
local BTN_H   = 20     -- hauteur des boutons, centrés dans la ligne
local INDENT  = 14     -- décalage par niveau de folder
local NUM_W   = 20     -- colonne du numéro de piste
local DOTS_W  = 20     -- colonne des points de rôle
local MS_W, IO_W, MENU_W, BTN_GAP = 30, 28, 24, 2   -- boutons MS, IO, "…"
local BTNS_W  = MS_W + BTN_GAP + IO_W + BTN_GAP + MENU_W

-- Pistes du projet, dans l'ordre, avec leur niveau d'imbrication.
local function compute_track_tree()
  local list, depth = {}, 0
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local fd = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
    list[#list+1] = { track = tr, depth = math.max(0, math.floor(depth)), is_folder = fd == 1 }
    depth = depth + fd
  end
  return list
end

-- Menu d'une piste (clic droit ou bouton "…"). Les actions s'appliquent à
-- toute la sélection si la piste en fait partie.
local function draw_track_menu(t)
  if not reaper.ImGui_BeginPopup(ctx, "trk_menu") then return end
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 8, 6)
  local targets = targets_for(t)
  local multi   = #targets > 1
  local is_fold = is_folder_track(t)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_faint)
  reaper.ImGui_Text(ctx, multi and string.format("%d selected tracks", #targets) or tname(t))
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Separator(ctx)

  if not multi and reaper.ImGui_MenuItem(ctx, "Rename") then
    state.rename_track_ptr   = t
    state.rename_track_buf   = tname(t)
    state.rename_just_opened = true
  end
  if reaper.ImGui_MenuItem(ctx, "Open routing window") then action_open_io(t) end
  if is_fold and reaper.ImGui_MenuItem(ctx, "Dissolve folder") then
    queue(function() action_dissolve_folder(t) ; reset_sel_cache() end)
  end

  -- Nombre de canaux, par pas de 2
  reaper.ImGui_Separator(ctx)
  if reaper.ImGui_IsWindowAppearing(ctx) then
    state.nchan_buf = math.max(2, math.floor(reaper.GetMediaTrackInfo_Value(t, "I_NCHAN")))
  end
  label_text("Channels", C.text)
  reaper.ImGui_SameLine(ctx, 0, 10)
  local ncv, ncc = int_field("nchan", state.nchan_buf, 2, 64, 44, 2)
  if ncc then state.nchan_buf = ncv end
  reaper.ImGui_SameLine(ctx, 0, 6)
  if btn("Apply##nchan_ok") then
    if action_set_channels(targets, state.nchan_buf) then reaper.ImGui_CloseCurrentPopup(ctx) end
  end

  reaper.ImGui_Separator(ctx)
  if not multi then
    if reaper.ImGui_MenuItem(ctx, "Add child track") then
      queue(function() action_add_child_track(t) end)
    end
    if reaper.ImGui_MenuItem(ctx, "Add feeding bus track") then
      queue(function() action_add_bus_child(t) end)
    end
  end

  -- Déplacement dans un folder existant
  local tset = build_track_set(targets)
  local folders = {}
  for _, f in ipairs(get_folder_tracks_only()) do
    if not tset[f] then folders[#folders+1] = f end
  end
  if reaper.ImGui_BeginMenu(ctx, "Move into folder", #folders > 0) then
    for fi, f in ipairs(folders) do
      if reaper.ImGui_BeginMenu(ctx, tname(f) .. "##mf" .. fi) then
        if reaper.ImGui_MenuItem(ctx, "At start") then
          queue(function() action_add_tracks_to_folder(f, targets, 0) end)
        end
        if reaper.ImGui_MenuItem(ctx, "At end") then
          queue(function() action_add_tracks_to_folder(f, targets, 1) end)
        end
        reaper.ImGui_EndMenu(ctx)
      end
    end
    reaper.ImGui_EndMenu(ctx)
  end

  -- Placement sous une autre piste, qui devient un folder
  local convertibles = get_convertible_tracks_only(tset)
  if reaper.ImGui_BeginMenu(ctx, "Move under track", #convertibles > 0) then
    for ci, c in ipairs(convertibles) do
      if reaper.ImGui_MenuItem(ctx, tname(c) .. "##cv" .. ci) then
        queue(function() action_move_under_track(c, targets) end)
      end
    end
    reaper.ImGui_EndMenu(ctx)
  end

  reaper.ImGui_Separator(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.danger_txt)
  if reaper.ImGui_MenuItem(ctx, multi and string.format("Delete %d tracks…", #targets) or "Delete track…") then
    state.confirm_delete = {
      ptrs = { table.unpack(targets) },
      name = multi and string.format("%d tracks", #targets) or tname(t),
    }
    state.open_dialog = "delete"
  end
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_PopStyleVar(ctx, 1)
  reaper.ImGui_EndPopup(ctx)
end

-- Clic sur un nom de piste : sélection simple, Ctrl pour ajouter ou retirer
-- une piste, Maj pour sélectionner toute une plage.
local function handle_track_click(t, tree)
  local mods  = reaper.ImGui_GetKeyMods(ctx)
  local ctrl  = mods & reaper.ImGui_Mod_Ctrl()  ~= 0
  local shift = mods & reaper.ImGui_Mod_Shift() ~= 0
  if ctrl then
    reaper.SetTrackSelected(t, not reaper.IsTrackSelected(t))
  elseif shift and state.focused_track and reaper.ValidatePtr(state.focused_track, "MediaTrack*") then
    local fi, ti = tidx(state.focused_track), tidx(t)
    local lo, hi = math.min(fi, ti), math.max(fi, ti)
    reaper.Main_OnCommand(40297, 0)
    for _, info in ipairs(tree) do
      local pi = tidx(info.track)
      if pi >= lo and pi <= hi then reaper.SetTrackSelected(info.track, true) end
    end
  else
    reaper.SetOnlyTrackSelected(t)
  end
  state.focused_track  = t
  state.last_sel_count = -1
end

-- Une ligne de la liste : flèche de folder, couleur, numéro, nom, points de
-- rôle et boutons MS (envoi au master), IO (routing) et "…" (menu).
local function draw_track_row(info, tree)
  local t    = info.track
  local guid = reaper.GetTrackGUID(t)
  reaper.ImGui_PushID(ctx, guid)

  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local lx0    = reaper.ImGui_GetCursorPosX(ctx)
  local ly0    = reaper.ImGui_GetCursorPosY(ctx)
  local aw     = reaper.ImGui_GetContentRegionAvail(ctx)
  local dl     = reaper.ImGui_GetWindowDrawList(ctx)
  local is_foc = t == state.focused_track
  local in_sel = state.sel_set[t]
  local menu_open = reaper.ImGui_IsPopupOpen(ctx, "trk_menu")
  local hovered = reaper.ImGui_IsWindowHovered(ctx)
    and reaper.ImGui_IsMouseHoveringRect(ctx, x0, y0, x0 + aw, y0 + ROW_H)

  -- Fond de ligne : piste active, puis sélection, puis survol
  local bg = is_foc and C.row_focus or (in_sel and C.row_sel or ((hovered or menu_open) and C.row_hover or nil))
  if bg then reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + aw, y0 + ROW_H, bg, 4) end

  -- Décalage selon le niveau, et flèche pour replier un folder
  reaper.ImGui_SetCursorPosX(ctx, lx0 + 4 + math.min(info.depth, 8) * INDENT)
  if info.is_folder then
    if reaper.ImGui_InvisibleButton(ctx, "##chev", 14, ROW_H) then
      state.collapsed[guid] = not state.collapsed[guid] or nil
    end
    tip(state.collapsed[guid] and "Expand folder" or "Collapse folder")
    local cx1, cy1 = reaper.ImGui_GetItemRectMin(ctx)
    local cx, cy = cx1 + 7, cy1 + ROW_H / 2
    local chev_col = reaper.ImGui_IsItemHovered(ctx) and C.white or C.accent
    if state.collapsed[guid] then
      reaper.ImGui_DrawList_AddTriangleFilled(dl, cx - 2, cy - 4, cx - 2, cy + 4, cx + 3, cy, chev_col)
    else
      reaper.ImGui_DrawList_AddTriangleFilled(dl, cx - 4, cy - 2, cx + 4, cy - 2, cx, cy + 3, chev_col)
    end
  else
    reaper.ImGui_Dummy(ctx, 14, ROW_H)
  end
  reaper.ImGui_SameLine(ctx, 0, 2)

  -- Couleur et numéro de la piste
  local sx = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_DrawList_AddRectFilled(dl, sx, y0 + 6, sx + 3, y0 + ROW_H - 6, rcolor(t), 1)
  local num = tostring(tidx(t))
  local tw, th = reaper.ImGui_CalcTextSize(ctx, num)
  reaper.ImGui_DrawList_AddText(dl, sx + 7 + NUM_W - tw, math.floor(y0 + (ROW_H - th) / 2), C.text_faint, num)
  reaper.ImGui_Dummy(ctx, 7 + NUM_W, ROW_H)
  reaper.ImGui_SameLine(ctx, 0, 8)

  -- Nom, ou champ de saisie pendant le renommage (Entrée valide, Échap annule).
  -- Double-clic sur le nom pour renommer.
  local name_x = reaper.ImGui_GetCursorPosX(ctx)
  local name_w = math.max(40, (lx0 + aw) - name_x - DOTS_W - BTNS_W - 8)
  if state.rename_track_ptr == t then
    reaper.ImGui_SetNextItemWidth(ctx, name_w)
    if state.rename_just_opened then
      reaper.ImGui_SetKeyboardFocusHere(ctx)
      state.rename_just_opened = false
    end
    local flags = reaper.ImGui_InputTextFlags_EnterReturnsTrue() | reaper.ImGui_InputTextFlags_AutoSelectAll()
    local confirmed, nv = reaper.ImGui_InputText(ctx, "##rename", state.rename_track_buf, flags)
    if nv ~= nil then state.rename_track_buf = nv end
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
      state.rename_track_ptr = nil
      state.rename_track_buf = ""
    elseif confirmed or reaper.ImGui_IsItemDeactivated(ctx) then
      reaper.Undo_BeginBlock()
      reaper.GetSetMediaTrackInfo_String(t, "P_NAME", state.rename_track_buf, true)
      reaper.Undo_EndBlock("SK RH : Rename track", -1)
      set_status("Track renamed")
      state.rename_track_ptr = nil
      state.rename_track_buf = ""
      state.last_proj_state  = -1
    end
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),        0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), 0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),  0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), (is_foc or in_sel) and C.white or C.text)
    local clicked = reaper.ImGui_Selectable(ctx, fit_name(tname(t), name_w) .. "##name", false,
      reaper.ImGui_SelectableFlags_AllowDoubleClick(), name_w, ROW_H)
    reaper.ImGui_PopStyleColor(ctx, 4)
    if clicked then
      if reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
        state.rename_track_ptr   = t
        state.rename_track_buf   = tname(t)
        state.rename_just_opened = true
      else
        handle_track_click(t, tree)
      end
    end
    if reaper.ImGui_IsItemClicked(ctx, 1) then reaper.ImGui_OpenPopup(ctx, "trk_menu") end
  end

  -- Points de rôle : vert = reçoit des sends, rouge = VCA master. Dans le cas
  -- rare où une piste a les deux rôles, les deux points se partagent la colonne.
  local dots_lx = lx0 + aw - BTNS_W - DOTS_W
  local dsx = x0 + (dots_lx - lx0)
  local cy  = y0 + ROW_H / 2
  local has_recv = reaper.GetTrackNumSends(t, -1) > 0
  local is_vca_m = reaper.GetSetTrackGroupMembership(t, "VOLUME_VCA_MASTER", 0, 0) ~= 0
  local dcx = dsx + DOTS_W / 2
  if has_recv and is_vca_m then
    reaper.ImGui_DrawList_AddCircleFilled(dl, dcx - 4, cy, 3, C.dot_recv)
    reaper.ImGui_DrawList_AddCircleFilled(dl, dcx + 4, cy, 3, C.dot_vca)
  elseif has_recv then
    reaper.ImGui_DrawList_AddCircleFilled(dl, dcx, cy, 3, C.dot_recv)
  elseif is_vca_m then
    reaper.ImGui_DrawList_AddCircleFilled(dl, dcx, cy, 3, C.dot_vca)
  end
  if (has_recv or is_vca_m) and reaper.ImGui_IsWindowHovered(ctx)
     and reaper.ImGui_IsMouseHoveringRect(ctx, dsx, y0, dsx + DOTS_W, y0 + ROW_H) then
    local parts = {}
    if has_recv then parts[#parts+1] = "Receives sends (bus / FX return)" end
    if is_vca_m then parts[#parts+1] = "VCA master" end
    show_tooltip(table.concat(parts, "\n"))
  end

  -- Boutons visibles au survol et sur la sélection. MS reste toujours
  -- affiché, en rouge, quand l'envoi au master est coupé.
  local bx = lx0 + aw - BTNS_W
  local by = ly0 + math.floor((ROW_H - BTN_H) / 2)
  local show_btns = hovered or in_sel or menu_open
  local ms_on = reaper.GetMediaTrackInfo_Value(t, "B_MAINSEND") == 1
  if show_btns or not ms_on then
    reaper.ImGui_SameLine(ctx, bx)
    reaper.ImGui_SetCursorPosY(ctx, by)
    if icon_btn("ms", "MS", MS_W, BTN_H, ms_on and C.text_dim or C.danger_txt,
        ms_on and C.ghost or C.ms_off_bg, ms_on and C.bg_item_hov or C.danger) then
      local new_val = ms_on and 0 or 1
      for _, st in ipairs(targets_for(t)) do
        if reaper.ValidatePtr(st, "MediaTrack*") then
          reaper.SetMediaTrackInfo_Value(st, "B_MAINSEND", new_val)
        end
      end
      state.last_proj_state = -1
    end
    tip(ms_on and "Master send: on" or "Master send: off")
  end
  if show_btns then
    reaper.ImGui_SameLine(ctx, bx + MS_W + BTN_GAP)
    reaper.ImGui_SetCursorPosY(ctx, by)
    if icon_btn("io", "IO", IO_W, BTN_H, C.text_dim, C.ghost, C.bg_item_hov) then action_open_io(t) end
    tip("Routing window")
    reaper.ImGui_SameLine(ctx, bx + MS_W + IO_W + BTN_GAP * 2)
    reaper.ImGui_SetCursorPosY(ctx, by)
    if menu_btn("menu", MENU_W, BTN_H) then reaper.ImGui_OpenPopup(ctx, "trk_menu") end
    tip("More actions")
  end

  draw_track_menu(t)
  reaper.ImGui_PopID(ctx)
end

-- Barre du bas de la colonne : création de folder, bus, retour FX ou VCA
-- à partir de la sélection, et bouton de la palette de couleurs.
local function draw_selection_bar()
  local nb = #state.sel_tracks
  local has = nb > 0
  local FH = reaper.ImGui_GetFrameHeight(ctx)

  hline(0, 4)
  local msg
  if nb == 0 then msg = "No selection"
  elseif nb == 1 then msg = "1 track selected"
  else msg = string.format("%d tracks selected", nb) end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), has and C.text_dim or C.text_faint)
  reaper.ImGui_Text(ctx, msg)
  reaper.ImGui_PopStyleColor(ctx, 1)

  local aw  = reaper.ImGui_GetContentRegionAvail(ctx)
  local gap = 4
  local col_w = FH + 8
  local w = math.floor((aw - col_w - gap * 4) / 4)

  if kind_btn("Folder##sb_folder", C.folder_col, w, has) then open_create_dialog("folder") end
  tip("Group the selection in a new folder")
  reaper.ImGui_SameLine(ctx, 0, gap)
  if kind_btn("Bus##sb_bus", C.bus_col, w, has) then open_create_dialog("bus") end
  tip("Send the selection to a new summing bus")
  reaper.ImGui_SameLine(ctx, 0, gap)
  if kind_btn("FX##sb_fx", C.fx_col, w, has) then open_create_dialog("fx") end
  tip("Send the selection to a new FX return")
  reaper.ImGui_SameLine(ctx, 0, gap)
  if kind_btn("VCA##sb_vca", C.vca_hov, w, has) then open_create_dialog("vca") end
  tip("Control the selection with a new VCA")
  reaper.ImGui_SameLine(ctx, 0, gap)

  -- Bouton de la palette, dessiné comme quatre pastilles de couleur
  reaper.ImGui_BeginDisabled(ctx, not has)
  local cclick = btn("##sb_color", col_w, FH)
  reaper.ImGui_EndDisabled(ctx)
  do
    local x1, y1 = reaper.ImGui_GetItemRectMin(ctx)
    local x2, y2 = reaper.ImGui_GetItemRectMax(ctx)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local cx, cy, r = (x1 + x2) / 2, (y1 + y2) / 2, 5
    local cols = { 0xE24B4AFF, 0xEF9F27FF, 0x639922FF, 0x378ADDFF }
    for i, c in ipairs(cols) do
      local a = (i - 1) * math.pi / 2 - math.pi / 4
      reaper.ImGui_DrawList_AddCircleFilled(dl, cx + math.cos(a) * 3, cy + math.sin(a) * 3, r - 2,
        has and c or C.text_faint)
    end
  end
  tip("Color the selected tracks")
  if cclick and has then
    if not state.cp_open then state.cp_center = true end
    state.cp_open = true
  end
end

-- Palette des pistes : fenêtre flottante, toujours au premier plan. Elle
-- s'ouvre centrée sur la fenêtre principale, reste ouverte quand la
-- sélection change et colore toujours la sélection du moment. On la ferme
-- avec sa croix.
local function draw_color_window()
  if not state.cp_open then return end
  if state.cp_center then
    reaper.ImGui_SetNextWindowPos(ctx, state.win_cx, state.win_cy, reaper.ImGui_Cond_Always(), 0.5, 0.5)
    state.cp_center = false
  end
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 14, 12)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 8, 6)
  local vis, open = reaper.ImGui_Begin(ctx, "Track color##sk_rh_color", true,
    reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_AlwaysAutoResize()
    | reaper.ImGui_WindowFlags_TopMost() | reaper.ImGui_WindowFlags_NoSavedSettings())
  if vis then
    reaper.ImGui_PushFont(ctx, font, 14)
    local nb = #state.sel_tracks
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_faint)
    reaper.ImGui_Text(ctx, nb == 0 and "Select tracks to color them"
      or (nb == 1 and ("Color " .. tname(state.sel_tracks[1])) or string.format("Color %d tracks", nb)))
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_BeginDisabled(ctx, nb == 0)
    local cur = state.focused_track and reaper.ValidatePtr(state.focused_track, "MediaTrack*")
      and (reaper.GetTrackColor(state.focused_track) & 0xFFFFFF) or 0
    local _, picked = color_palette_widget("sel", cur, "cp_pastel")
    if picked and nb > 0 then apply_color_to_sel(picked[1], picked[2], picked[3]) end
    reaper.ImGui_Dummy(ctx, 0, 2)
    if btn("Clear color##sel_clr") and nb > 0 then remove_color_from_sel() end
    reaper.ImGui_EndDisabled(ctx)
    reaper.ImGui_PopFont(ctx)
    reaper.ImGui_End(ctx)
  end
  reaper.ImGui_PopStyleVar(ctx, 2)
  if not open then state.cp_open = false end
end

-- Colonne de gauche : filtre, bouton "+ Track", liste des pistes et barre
-- d'actions.
local function draw_left()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), C.bg_panel)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),  C.border_soft)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 8, 8)
  local ok = reaper.ImGui_BeginChild(ctx, "left_panel", LEFT_W, 0, CF_BORDERS,
    reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse())
  reaper.ImGui_PopStyleVar(ctx, 1)
  reaper.ImGui_PopStyleColor(ctx, 2)
  if not ok then return end

  local add_lbl = "+ Track##new_tr"
  reaper.ImGui_SetNextItemWidth(ctx, reaper.ImGui_GetContentRegionAvail(ctx) - btn_w(add_lbl) - 6)
  local _, nf = reaper.ImGui_InputTextWithHint(ctx, "##track_filter", "Filter tracks", state.track_filter)
  if nf then state.track_filter = nf end
  reaper.ImGui_SameLine(ctx, 0, 6)
  if col_btn(add_lbl, C.send_col, C.send_hov) then open_create_dialog("tracks") end
  tip("Create one or more tracks")
  reaper.ImGui_Dummy(ctx, 0, 2)

  -- Liste défilante. Avec un filtre, seules les pistes dont le nom contient
  -- le texte sont affichées ; sinon, le contenu des folders repliés est masqué.
  local bar_h = reaper.ImGui_GetTextLineHeight(ctx) + reaper.ImGui_GetFrameHeight(ctx) + 22
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 4, 2)
  if reaper.ImGui_BeginChild(ctx, "track_list", 0, -bar_h, 0) then
    local tree = compute_track_tree()
    if #tree == 0 then
      empty_state("No tracks in the project.")
    end
    local filter = state.track_filter:lower()
    local hide_depth, shown = nil, 0
    for _, info in ipairs(tree) do
      local visible = true
      if filter ~= "" then
        visible = tname(info.track):lower():find(filter, 1, true) ~= nil
      else
        if hide_depth and info.depth > hide_depth then
          visible = false
        else
          hide_depth = nil
          if info.is_folder and state.collapsed[reaper.GetTrackGUID(info.track)] then
            hide_depth = info.depth
          end
        end
      end
      if visible then draw_track_row(info, tree) ; shown = shown + 1 end
    end
    if #tree > 0 and shown == 0 then empty_state("No matching track.") end
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleVar(ctx, 1)

  draw_selection_bar()
  reaper.ImGui_EndChild(ctx)
end

-- ============================================================
--  COLONNE DROITE
-- ============================================================
-- Ligne de titre : couleurs et noms des pistes sélectionnées. Pour une seule
-- piste, son type, son nombre de canaux et ses particularités.
local function draw_selection_header()
  local sel = state.sel_tracks
  local nb  = #sel
  for i = 1, math.min(nb, 12) do
    color_chip(rcolor(sel[i]), 5, 14)
    reaper.ImGui_SameLine(ctx, 0, 3)
  end
  reaper.ImGui_SameLine(ctx, 0, 6)
  local text
  if nb <= 4 then
    local names = {}
    for _, t in ipairs(sel) do names[#names+1] = tname(t) end
    text = table.concat(names, ", ")
  else
    text = string.format("%d tracks selected", nb)
  end

  local meta = ""
  if nb == 1 then
    local t = sel[1]
    local parts = { is_folder_track(t) and "Folder" or "Track" }
    parts[#parts+1] = string.format("%d ch", math.floor(reaper.GetMediaTrackInfo_Value(t, "I_NCHAN")))
    if reaper.GetMediaTrackInfo_Value(t, "B_MAINSEND") == 0 then parts[#parts+1] = "master send off" end
    if reaper.GetSetTrackGroupMembership(t, "VOLUME_VCA_MASTER", 0, 0) ~= 0 then parts[#parts+1] = "VCA master" end
    meta = table.concat(parts, "  ·  ")
  end

  local aw = reaper.ImGui_GetContentRegionAvail(ctx)
  local mw = meta ~= "" and (reaper.ImGui_CalcTextSize(ctx, meta) + 12) or 0
  label_text(fit_name(text, aw - mw - 4), C.white)
  if meta ~= "" then
    reaper.ImGui_SameLine(ctx, 0, 12)
    label_text(meta, C.text_faint)
  end
end

-- Colonne de droite : cartes Sends / Receives ou cartes VCA selon la vue.
local function draw_right(all_tracks)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 6, 0)
  local ok = reaper.ImGui_BeginChild(ctx, "right", 0, 0, CF_PADDING)
  reaper.ImGui_PopStyleVar(ctx, 1)
  if not ok then return end

  if #state.sel_tracks == 0 then
    local _, ah = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_Dummy(ctx, 0, ah * 0.35)
    centered_text("No track selected", C.text_dim)
    centered_text("Select one or more tracks in REAPER or in the list.", C.text_faint)
    reaper.ImGui_EndChild(ctx)
    return
  end

  draw_selection_header()
  reaper.ImGui_Dummy(ctx, 0, 4)

  if state.view_mode == "vca" then
    panel_vca_master()
    panel_vca_slave()
  else
    panel_sends(all_tracks)
    panel_receives(all_tracks)
  end

  reaper.ImGui_EndChild(ctx)
end

-- ============================================================
--  EN-TÊTE ET BARRE DU BAS
-- ============================================================
local VIEWS = {
  { key = "sr",  label = "Sends & receives" },
  { key = "vca", label = "Groups / VCA" },
}

-- En-tête : titre, choix de la vue, nom du projet et nombre de pistes.
local function draw_header()
  local lx    = reaper.ImGui_GetCursorPosX(ctx)
  local right = row_right_edge()

  reaper.ImGui_PushFont(ctx, font_title, 20)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.title)
  reaper.ImGui_Text(ctx, "SK ROUTING HUB")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_PopFont(ctx)

  reaper.ImGui_SameLine(ctx, 0, 20)
  local nv = segmented("view", VIEWS, state.view_mode, 130)
  if nv ~= state.view_mode then
    state.view_mode = nv
    reaper.SetExtState(EXT_SECTION, "view_mode", nv, true)
  end

  local pname = reaper.GetProjectName(0, "")
  if pname == "" then pname = "(untitled)" end
  local n = reaper.CountTracks(0)
  local info = string.format("%s  ·  %d track%s", pname:gsub("%.[Rr][Pp][Pp]$", ""), n, n == 1 and "" or "s")
  local tw = reaper.ImGui_CalcTextSize(ctx, info)
  reaper.ImGui_SameLine(ctx, math.max(lx, right - tw))
  label_text(info, C.text_faint)

  reaper.ImGui_Dummy(ctx, 0, 2)
end

-- Rappels d'utilisation affichés en bas à droite, selon la vue.
local HINTS = {
  sr  = "Knob: drag · Ctrl+drag fine · double-click 0 dB · right-click type value",
  vca = "Click a track name to select it in REAPER",
}

-- Barre du bas : dernier message (ou "Ready") et rappel d'utilisation.
local function draw_status()
  local right = row_right_edge()
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local FH = reaper.ImGui_GetFrameHeight(ctx)
  local active = reaper.time_precise() < state.status_timer

  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  if active then
    local col = state.status_kind == "warn" and C.warn or C.ok
    reaper.ImGui_DrawList_AddCircleFilled(dl, x + 4, y + FH / 2, 3, col)
    reaper.ImGui_Dummy(ctx, 10, FH)
    reaper.ImGui_SameLine(ctx, 0, 4)
    label_text(state.status_msg, C.text)
  else
    label_text("Ready", C.text_faint)
  end

  local hint = HINTS[state.view_mode] or ""
  local hw = reaper.ImGui_CalcTextSize(ctx, hint)
  reaper.ImGui_SameLine(ctx, math.max(reaper.ImGui_GetCursorPosX(ctx) + 20, right - hw))
  label_text(hint, C.text_faint)
end

-- ============================================================
--  AFFICHAGE
-- ============================================================
-- La fenêtre est redessinée en continu, plusieurs dizaines de fois par
-- seconde, tant qu'elle est ouverte.
local function loop()
  -- Actions mises en attente à l'affichage précédent.
  if #action_queue > 0 then
    local q = action_queue
    action_queue = {}
    for _, fn in ipairs(q) do fn() end
    state.last_proj_state = -1
    state.last_sel_count  = -1
  end

  -- Relit la sélection seulement si quelque chose a changé dans REAPER.
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
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, WIN_MIN_W, WIN_MIN_H, 9999, 9999)

  local vis, open = reaper.ImGui_Begin(ctx, SCRIPT_NAME, true,
    reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoScrollbar()
    | reaper.ImGui_WindowFlags_NoScrollWithMouse())

  if vis then
    reaper.ImGui_PushFont(ctx, font, 14)

    local wx, wy = reaper.ImGui_GetWindowPos(ctx)
    local ww, wh = reaper.ImGui_GetWindowSize(ctx)
    state.win_cx, state.win_cy = wx + ww / 2, wy + wh / 2

    draw_header()

    -- Deux colonnes, au-dessus de la barre du bas.
    local FH = reaper.ImGui_GetFrameHeight(ctx)
    local status_h = FH + 22
    local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    if reaper.ImGui_BeginChild(ctx, "body", 0, avail_h - status_h, 0) then
      draw_left()
      reaper.ImGui_SameLine(ctx, 0, 8)
      draw_right(all)
      reaper.ImGui_EndChild(ctx)
    end

    hline(2, 2)
    draw_status()

    draw_dialogs(all)

    reaper.ImGui_PopFont(ctx)
    reaper.ImGui_End(ctx)
  end

  -- La palette est une fenêtre à part, fermée avec la fenêtre principale.
  if open then draw_color_window() end

  reaper.ImGui_PopStyleColor(ctx, nc)
  reaper.ImGui_PopStyleVar(ctx, nv)
  if open then reaper.defer(loop) end
end

-- ============================================================
--  LANCEMENT
-- ============================================================
refresh_sel()
reaper.defer(loop)

