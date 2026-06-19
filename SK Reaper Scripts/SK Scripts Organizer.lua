-- =============================================================================
--  SK Scripts Organizer
--  Studio Kozak
--  A categorized launcher for every ReaScript in your Scripts/ folder.
-- =============================================================================

-- =============================================================================
--  GUARD : ReaImGui
-- =============================================================================
if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "This script requires the ReaImGui extension.\n\nInstall it via ReaPack:\nExtensions > ReaPack > Browse packages > 'ReaImGui'.",
    "SK Scripts Organizer", 0)
  return
end

-- =============================================================================
--  CONSTANTS / PATHS
-- =============================================================================
local WINDOW_TITLE = "SK Scripts Organizer"
local RES          = reaper.GetResourcePath()
local OS_WIN       = reaper.GetOS():find("Win") ~= nil
local SEP          = OS_WIN and "\\" or "/"
local SCRIPTS_ROOT = RES .. SEP .. "Scripts"
local KB_PATH      = RES .. SEP .. "reaper-kb.ini"
local CFG_PATH     = RES .. SEP .. "SK_Scripts_Organizer.cfg"

local VALID_EXT = { lua = true, eel = true, py = true }

-- =============================================================================
--  PALETTE
-- =============================================================================
local C = {
  bg         = 0x1A1A1AFF,
  bg_panel   = 0x222222FF,
  bg_item    = 0x2A2A2AFF,
  bg_sel     = 0x2E3A4AFF,
  bg_header  = 0x181818FF,
  border     = 0x3A3A3AFF,
  text       = 0xF0F0F0FF,
  text_dim   = 0xBBBBBBFF,
  accent     = 0x4A8FCAFF,
  accent_dim = 0x2A5A8AFF,
  sep        = 0x2E2E2EFF,
}

local PALETTE = {
  0xE57D7DFF, -- rouge corail
  0xE3B06FFF, -- orange sable
  0xD9C96AFF, -- jaune doré
  0x8FD18FFF, -- vert pastel
  0x77B8C8FF, -- cyan pastel
  0x8590D6FF, -- bleu pervenche
  0xB07AD6FF, -- violet pastel
  0xD36FB6FF, -- rose magenta
  0xBDBDBDFF, -- gris clair
  0xDDDDDDFF, -- blanc cassé
}

-- =============================================================================
--  STATE
-- =============================================================================
local ctx = reaper.ImGui_CreateContext(WINDOW_TITLE)

local CHILD_BORDER = reaper.ImGui_ChildFlags_Borders()
local SEL_FLAGS    = reaper.ImGui_SelectableFlags_AllowDoubleClick()

local cfg
local master = {}
local by_rel = {}

local FONT_SIZE = 15
local FONT = reaper.ImGui_CreateFont("sans-serif", FONT_SIZE)
reaper.ImGui_Attach(ctx, FONT)

local S = {
  search           = "",
  registered_only  = true,
  edit             = false,
  sel_cat          = "__all__",
  selection        = {},
  rename_id        = nil,
  rename_buf       = "",
  new_cat_buf      = "",
  status           = "",
  dirty            = false,
}

-- =============================================================================
--  SMALL HELPERS
-- =============================================================================
local function strip_ext(s) return (s:gsub("%.[^.]+$", "")) end
local function norm_slashes(s) return (s:gsub("\\", "/")) end
local function set_status(msg) S.status = msg end

local function tokenize(line)
  local t, i, n = {}, 1, #line
  while i <= n do
    while i <= n and line:sub(i, i):match("%s") do i = i + 1 end
    if i > n then break end
    if line:sub(i, i) == '"' then
      i = i + 1
      local s = i
      while i <= n and line:sub(i, i) ~= '"' do i = i + 1 end
      t[#t + 1] = line:sub(s, i - 1)
      i = i + 1
    else
      local s = i
      while i <= n and not line:sub(i, i):match("%s") do i = i + 1 end
      t[#t + 1] = line:sub(s, i - 1)
    end
  end
  return t
end

-- =============================================================================
--  CONFIG
-- =============================================================================
local function serialize(v, indent)
  indent = indent or ""
  local tv = type(v)

  if tv == "string" then
    return string.format("%q", v)
  elseif tv == "number" or tv == "boolean" then
    return tostring(v)
  elseif tv == "table" then
    local out = { "{\n" }
    local maxn = 0

    for k in pairs(v) do
      if type(k) == "number" and k > maxn then maxn = k end
    end

    for k = 1, maxn do
      if v[k] ~= nil then
        out[#out + 1] = indent .. "  " .. serialize(v[k], indent .. "  ") .. ",\n"
      end
    end

    for k, val in pairs(v) do
      if type(k) == "string" then
        out[#out + 1] = indent .. "  [" .. string.format("%q", k) .. "]="
                      .. serialize(val, indent .. "  ") .. ",\n"
      end
    end

    out[#out + 1] = indent .. "}"
    return table.concat(out)
  end

  return "nil"
end

local function default_config()
  return {
    version    = 1,
    next_id    = 1,
    categories = {},
    settings   = { registered_only = true, last_cat = "__all__" },
  }
end

local function load_config()
  local fh = io.open(CFG_PATH, "r")
  if not fh then return default_config() end

  local data = fh:read("*a")
  fh:close()

  local chunk = load("return " .. data)
  if not chunk then return default_config() end

  local ok, res = pcall(chunk)
  if not ok or type(res) ~= "table" then return default_config() end

  res.version    = res.version or 1
  res.next_id    = res.next_id or 1
  res.categories = res.categories or {}
  res.settings   = res.settings or {}

  for _, c in ipairs(res.categories) do
    c.scripts = c.scripts or {}
  end

  return res
end

local function save_config()
  cfg.settings.registered_only = S.registered_only
  cfg.settings.last_cat        = S.sel_cat

  local fh = io.open(CFG_PATH, "w")
  if not fh then return end

  fh:write("-- SK Scripts Organizer config (auto-generated)\n")
  fh:write(serialize(cfg))
  fh:write("\n")
  fh:close()

  S.dirty = false
end

-- =============================================================================
--  SCAN
-- =============================================================================
local function enumerate(dir, relbase)
  local i = 0

  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end

    local ext = f:match("%.([^.]+)$")
    if ext then ext = ext:lower() end

    if ext and VALID_EXT[ext] then
      local rel = (relbase ~= "") and (relbase .. "/" .. f) or f
      master[#master + 1] = {
        full = dir .. SEP .. f,
        rel  = rel,
        name = f,
        ext  = ext
      }
    end

    i = i + 1
  end

  i = 0

  while true do
    local sub = reaper.EnumerateSubdirectories(dir, i)
    if not sub then break end

    local subrel = (relbase ~= "") and (relbase .. "/" .. sub) or sub
    enumerate(dir .. SEP .. sub, subrel)

    i = i + 1
  end
end

local function load_registered()
  local map = {}
  local fh = io.open(KB_PATH, "r")
  if not fh then return map end

  for line in fh:lines() do
    if line:sub(1, 4) == "SCR " then
      local t = tokenize(line)
      local section = tonumber(t[3])
      local path    = t[6]

      if section == 0 and path and path ~= "" then
        local rel = norm_slashes(path):gsub("^[Ss]cripts/", "")
        local desc = (t[5] or ""):gsub("^Custom:%s*", "")
        map[rel:lower()] = { name = desc }
      end
    end
  end

  fh:close()
  return map
end

local function rebuild_master()
  master, by_rel = {}, {}

  enumerate(SCRIPTS_ROOT, "")

  local reg = load_registered()

  for _, it in ipairs(master) do
    local r = reg[it.rel:lower()]

    if r then
      it.registered = true
      it.display    = (r.name and r.name ~= "") and r.name or strip_ext(it.name)
    else
      it.registered = false
      it.display    = strip_ext(it.name)
    end

    by_rel[it.rel] = it
  end

  table.sort(master, function(a, b)
    return a.display:lower() < b.display:lower()
  end)

  set_status(("Scanned %d scripts."):format(#master))
end

-- =============================================================================
--  CATEGORY HELPERS
-- =============================================================================
local function find_cat(id)
  for _, c in ipairs(cfg.categories) do
    if c.id == id then return c end
  end
end

local function cat_index_of(cat, rel)
  for i, v in ipairs(cat.scripts) do
    if v == rel then return i end
  end
end

local function cat_add(cat, rel)
  if not cat_index_of(cat, rel) then
    cat.scripts[#cat.scripts + 1] = rel
    S.dirty = true
  end
end

local function cat_remove(cat, rel)
  local i = cat_index_of(cat, rel)
  if i then
    table.remove(cat.scripts, i)
    S.dirty = true
  end
end

local function move_script_in_cat(cat, rel, dir)
  local i = cat_index_of(cat, rel)
  if not i then return end

  local j = i + dir
  if j < 1 or j > #cat.scripts then return end

  cat.scripts[i], cat.scripts[j] = cat.scripts[j], cat.scripts[i]
  S.dirty = true
end

local function new_category(name)
  name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")

  if name == "" then
    set_status("Type a category name, then press Add.")
    return false
  end

  local id = cfg.next_id
  cfg.next_id = id + 1

  local color = PALETTE[((#cfg.categories) % #PALETTE) + 1]

  cfg.categories[#cfg.categories + 1] = {
    id = id,
    name = name,
    color = color,
    scripts = {}
  }

  S.dirty = true
  S.sel_cat = id

  set_status('Created category: "' .. name .. '"')
  return true
end

local function delete_category(id)
  for i, c in ipairs(cfg.categories) do
    if c.id == id then
      table.remove(cfg.categories, i)
      S.dirty = true
      break
    end
  end

  if S.sel_cat == id then
    S.sel_cat = "__all__"
  end
end

local function move_category(idx, dir)
  local j = idx + dir
  if j < 1 or j > #cfg.categories then return end

  cfg.categories[idx], cfg.categories[j] = cfg.categories[j], cfg.categories[idx]
  S.dirty = true
end

local function assigned_set()
  local s = {}

  for _, c in ipairs(cfg.categories) do
    for _, rel in ipairs(c.scripts) do
      s[rel] = true
    end
  end

  return s
end

-- =============================================================================
--  EXECUTION
-- =============================================================================
local function run_script(it)
  if not it or it.missing or not it.full then
    set_status("Cannot run: file not found on disk.")
    return
  end

  local cmd = reaper.AddRemoveReaScript(true, 0, it.full, true)

  if cmd and cmd ~= 0 then
    reaper.Main_OnCommand(cmd, 0)
    set_status("Ran: " .. it.display)
  else
    set_status("Failed to register: " .. it.rel)
  end
end

-- =============================================================================
--  VIEW BUILDING / FILTER
-- =============================================================================
local function passes_filter(it)
  if S.search == "" then return true end

  local q = S.search:lower()

  return it.display:lower():find(q, 1, true) ~= nil
      or it.rel:lower():find(q, 1, true) ~= nil
end

local function build_view()
  local items = {}

  if S.sel_cat == "__all__" then
    for _, it in ipairs(master) do
      if (not S.registered_only or it.registered) and passes_filter(it) then
        items[#items + 1] = it
      end
    end

  elseif S.sel_cat == "__uncat__" then
    local aset = assigned_set()

    for _, it in ipairs(master) do
      if not aset[it.rel]
         and (not S.registered_only or it.registered)
         and passes_filter(it) then
        items[#items + 1] = it
      end
    end

  else
    local cat = find_cat(S.sel_cat)

    if cat then
      for _, rel in ipairs(cat.scripts) do
        local it = by_rel[rel]

        if not it then
          it = {
            rel = rel,
            display = "(missing) " .. rel,
            missing = true,
            ext = "?",
            registered = false
          }
        end

        if passes_filter(it) then
          items[#items + 1] = it
        end
      end
    end
  end

  return items
end

-- =============================================================================
--  INPUT HELPERS
-- =============================================================================
local function ctrl_or_super_down()
  local m    = reaper.ImGui_GetKeyMods(ctx)
  local ctrl = reaper.ImGui_Mod_Ctrl()
  local sup  = reaper.ImGui_Mod_Super()

  return (m & ctrl) ~= 0 or (m & sup) ~= 0
end

local function selection_count()
  local n = 0

  for _ in pairs(S.selection) do
    n = n + 1
  end

  return n
end

-- =============================================================================
--  UI : TOP TOOLBAR
-- =============================================================================
local function draw_toolbar()
  local _

  reaper.ImGui_SetNextItemWidth(ctx, -290)
  _, S.search = reaper.ImGui_InputTextWithHint(
    ctx,
    "##search",
    "Search scripts...",
    S.search
  )

  reaper.ImGui_SameLine(ctx)
  _, S.registered_only = reaper.ImGui_Checkbox(ctx, "Registered only", S.registered_only)

  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(
      ctx,
      "Show only scripts already added to your Action List\n(reads reaper-kb.ini). Hides library/include files."
    )
  end

  reaper.ImGui_SameLine(ctx)
  _, S.edit = reaper.ImGui_Checkbox(ctx, "Edit", S.edit)

  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(
      ctx,
      "Edit OFF: click a script to run it.\nEdit ON: click to select, then assign to categories."
    )
  end

  if not S.edit then
    S.selection = {}
  end

  reaper.ImGui_SameLine(ctx)

  if reaper.ImGui_Button(ctx, "Rescan") then
    rebuild_master()
  end
end

-- =============================================================================
--  UI : LEFT PANE
-- =============================================================================
local function nav_entry(label, count, is_sel, id)
  local cstr  = string.format("(%d)", count)
  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  local tw    = reaper.ImGui_CalcTextSize(ctx, cstr)
  local sel_w = math.max(40, avail - tw - 10)

  local clicked = reaper.ImGui_Selectable(ctx, label .. "##" .. id, is_sel, 0, sel_w, 0)

  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextDisabled(ctx, cstr)

  return clicked
end

local function category_row(cat, idx)
  reaper.ImGui_PushID(ctx, "cat" .. cat.id)

  reaper.ImGui_ColorButton(
    ctx,
    "##sw",
    cat.color,
    reaper.ImGui_ColorEditFlags_NoTooltip(),
    14,
    14
  )

  if S.edit and reaper.ImGui_IsItemClicked(ctx) then
    reaper.ImGui_OpenPopup(ctx, "colorpop")
  end

  if reaper.ImGui_BeginPopup(ctx, "colorpop") then
    reaper.ImGui_Text(ctx, "Category color")
    reaper.ImGui_Separator(ctx)

    for i, col in ipairs(PALETTE) do
      if i > 1 then
        reaper.ImGui_SameLine(ctx)
      end

      if reaper.ImGui_ColorButton(
        ctx,
        "##p" .. i,
        col,
        reaper.ImGui_ColorEditFlags_NoTooltip(),
        20,
        20
      ) then
        cat.color = col
        S.dirty = true
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
    end

    reaper.ImGui_EndPopup(ctx)
  end

  reaper.ImGui_SameLine(ctx)

  if S.rename_id == cat.id then
    reaper.ImGui_SetNextItemWidth(ctx, -1)

    local enter, buf = reaper.ImGui_InputText(
      ctx,
      "##rn",
      S.rename_buf,
      reaper.ImGui_InputTextFlags_EnterReturnsTrue()
        | reaper.ImGui_InputTextFlags_AutoSelectAll()
    )

    S.rename_buf = buf

    if enter then
      local nm = S.rename_buf:gsub("^%s+", ""):gsub("%s+$", "")

      if nm ~= "" then
        cat.name = nm
        S.dirty = true
      end

      S.rename_id = nil
    end

  elseif S.edit then
    -- edit mode: inline count, reorder + delete buttons on the right
    local avail = reaper.ImGui_GetContentRegionAvail(ctx)
    local sel_w = math.max(40, avail - 82)
    local label = string.format("%s  (%d)", cat.name, #cat.scripts)

    if reaper.ImGui_Selectable(ctx, label .. "##cat", S.sel_cat == cat.id, 0, sel_w, 0) then
      S.sel_cat = cat.id
    end

    if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
      S.rename_id  = cat.id
      S.rename_buf = cat.name
    end

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, "^") then S.pending_move = { idx, -1 } end

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, "v") then S.pending_move = { idx, 1 } end

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, "x") then reaper.ImGui_OpenPopup(ctx, "delcat") end

    if reaper.ImGui_BeginPopup(ctx, "delcat") then
      reaper.ImGui_Text(ctx, ("Delete \"%s\"?"):format(cat.name))
      reaper.ImGui_TextDisabled(ctx, "(scripts are not deleted, only the category)")
      reaper.ImGui_Separator(ctx)

      if reaper.ImGui_Button(ctx, "Delete") then
        S.pending_delete = cat.id
        reaper.ImGui_CloseCurrentPopup(ctx)
      end

      reaper.ImGui_SameLine(ctx)

      if reaper.ImGui_Button(ctx, "Cancel") then
        reaper.ImGui_CloseCurrentPopup(ctx)
      end

      reaper.ImGui_EndPopup(ctx)
    end

  else
    -- browse mode: name + right-aligned count
    local cstr  = string.format("(%d)", #cat.scripts)
    local avail = reaper.ImGui_GetContentRegionAvail(ctx)
    local tw    = reaper.ImGui_CalcTextSize(ctx, cstr)
    local sel_w = math.max(40, avail - tw - 10)

    if reaper.ImGui_Selectable(ctx, cat.name .. "##cat", S.sel_cat == cat.id, 0, sel_w, 0) then
      S.sel_cat = cat.id
    end

    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextDisabled(ctx, cstr)
  end

  reaper.ImGui_PopID(ctx)
end

local function draw_left_pane(h)
  if reaper.ImGui_BeginChild(ctx, "left", 230, h, CHILD_BORDER) then
    reaper.ImGui_TextDisabled(ctx, "LIBRARY")

    local n_all = #master

    if nav_entry("All scripts", n_all, S.sel_cat == "__all__", "all") then
      S.sel_cat = "__all__"
    end

    local aset = assigned_set()
    local n_uncat = 0

    for _, it in ipairs(master) do
      if not aset[it.rel] then
        n_uncat = n_uncat + 1
      end
    end

    if nav_entry("Uncategorized", n_uncat, S.sel_cat == "__uncat__", "uncat") then
      S.sel_cat = "__uncat__"
    end

    reaper.ImGui_Separator(ctx)
    reaper.ImGui_TextDisabled(ctx, "CATEGORIES")

    for idx, cat in ipairs(cfg.categories) do
      category_row(cat, idx)
    end

    if S.pending_move then
      move_category(S.pending_move[1], S.pending_move[2])
      S.pending_move = nil
    end

    if S.pending_delete then
      delete_category(S.pending_delete)
      S.pending_delete = nil
    end

    if S.edit then
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, -1)

      local _
      _, S.new_cat_buf = reaper.ImGui_InputTextWithHint(
        ctx,
        "##newcat",
        "New category name",
        S.new_cat_buf
      )

      local input_active = reaper.ImGui_IsItemActive(ctx)

      local enter = input_active and (
        reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter())
        or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter())
      )

      if reaper.ImGui_Button(ctx, "Add category", -1, 0) or enter then
        if new_category(S.new_cat_buf) then
          S.new_cat_buf = ""
        end
      end
    end
  end

  reaper.ImGui_EndChild(ctx)
end

-- =============================================================================
--  UI : ASSIGN POPUP
-- =============================================================================
local function assign_checklist(rels)
  if #cfg.categories == 0 then
    reaper.ImGui_TextDisabled(ctx, "No categories yet.\nEnable Edit to create one.")
    return
  end

  for _, cat in ipairs(cfg.categories) do
    local all_in = true

    for _, rel in ipairs(rels) do
      if not cat_index_of(cat, rel) then
        all_in = false
        break
      end
    end

    -- category color dot
    local dl     = reaper.ImGui_GetWindowDrawList(ctx)
    local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
    local fh     = reaper.ImGui_GetFrameHeight(ctx)
    reaper.ImGui_DrawList_AddCircleFilled(dl, sx + 5, sy + fh * 0.5, 4, cat.color)
    reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + 16)

    local clicked = reaper.ImGui_Checkbox(ctx, cat.name .. "##asg" .. cat.id, all_in)

    if clicked then
      if all_in then
        for _, rel in ipairs(rels) do
          cat_remove(cat, rel)
        end
      else
        for _, rel in ipairs(rels) do
          cat_add(cat, rel)
        end
      end
    end
  end
end

-- =============================================================================
--  UI : RIGHT PANE
-- =============================================================================
local function draw_right_pane(h)
  local cur_cat = (type(S.sel_cat) == "number") and find_cat(S.sel_cat) or nil
  local items   = build_view()

  if reaper.ImGui_BeginChild(ctx, "right", -1, h, CHILD_BORDER,
       reaper.ImGui_WindowFlags_NoScrollbar()) then

    -- FIXED header: edit action bar stays put while the list scrolls
    if S.edit then
      local nsel = selection_count()

      reaper.ImGui_Text(ctx, nsel > 0 and (nsel .. " selected") or "Click scripts to select")

      if nsel > 0 then
        reaper.ImGui_SameLine(ctx)

        if reaper.ImGui_Button(ctx, "Assign to...") then
          reaper.ImGui_OpenPopup(ctx, "bulkassign")
        end

        if cur_cat then
          reaper.ImGui_SameLine(ctx)

          if reaper.ImGui_Button(ctx, "Remove from category") then
            for rel in pairs(S.selection) do
              cat_remove(cur_cat, rel)
            end
          end
        end

        reaper.ImGui_SameLine(ctx)

        if reaper.ImGui_Button(ctx, "Clear") then
          S.selection = {}
        end
      end

      if reaper.ImGui_BeginPopup(ctx, "bulkassign") then
        reaper.ImGui_Text(ctx, "Assign selected to:")
        reaper.ImGui_Separator(ctx)

        local rels = {}

        for rel in pairs(S.selection) do
          rels[#rels + 1] = rel
        end

        assign_checklist(rels)
        reaper.ImGui_EndPopup(ctx)
      end

      reaper.ImGui_Separator(ctx)
    end

    -- SCROLLING list (its own child so the header above never moves).
    -- Zero padding here so rows align with the fixed header above.
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
    if reaper.ImGui_BeginChild(ctx, "right_list", -1, 0, 0) then
      if #items == 0 then
        reaper.ImGui_TextDisabled(ctx, "No scripts to show.")

        if S.registered_only and (S.sel_cat == "__all__" or S.sel_cat == "__uncat__") then
          reaper.ImGui_TextDisabled(ctx, "Uncheck 'Registered only' to see every file on disk.")
        end
      end

      for _, it in ipairs(items) do
        reaper.ImGui_PushID(ctx, it.rel)

        -- category color dot (only when viewing a real category)
        if cur_cat then
          local dl     = reaper.ImGui_GetWindowDrawList(ctx)
          local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
          local lh     = reaper.ImGui_GetTextLineHeight(ctx)
          reaper.ImGui_DrawList_AddCircleFilled(dl, sx + 5, sy + lh * 0.5, 4, cur_cat.color)
          reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + 16)
        end

        local is_sel = S.selection[it.rel] == true

        local sel_w = (S.edit and cur_cat)
          and math.max(40, reaper.ImGui_GetContentRegionAvail(ctx) - 86)
          or 0

        -- unregistered / missing scripts are shown dimmed
        local dim = (not it.registered) or it.missing
        if dim then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
        end

        local clicked = reaper.ImGui_Selectable(
          ctx,
          it.display .. "##row",
          is_sel,
          SEL_FLAGS,
          sel_w,
          0
        )

        if dim then
          reaper.ImGui_PopStyleColor(ctx, 1)
        end

        if clicked then
          if S.edit then
            if reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
              run_script(it)
            elseif ctrl_or_super_down() then
              S.selection[it.rel] = (not is_sel) or nil
            else
              S.selection = { [it.rel] = true }
            end
          else
            run_script(it)
          end
        end

        if reaper.ImGui_BeginPopupContextItem(ctx, "ctx") then
          reaper.ImGui_TextDisabled(ctx, it.display)
          reaper.ImGui_Separator(ctx)

          if not it.missing and reaper.ImGui_MenuItem(ctx, "Run") then
            run_script(it)
          end

          if reaper.ImGui_BeginMenu(ctx, "Assign to category") then
            assign_checklist({ it.rel })
            reaper.ImGui_EndMenu(ctx)
          end

          if cur_cat and cat_index_of(cur_cat, it.rel) then
            if reaper.ImGui_MenuItem(ctx, "Remove from this category") then
              cat_remove(cur_cat, it.rel)
            end
          end

          reaper.ImGui_EndPopup(ctx)
        end

        -- reorder + remove (edit mode, inside a real category)
        if S.edit and cur_cat then
          reaper.ImGui_SameLine(ctx)
          if reaper.ImGui_SmallButton(ctx, "^##up") then move_script_in_cat(cur_cat, it.rel, -1) end

          reaper.ImGui_SameLine(ctx)
          if reaper.ImGui_SmallButton(ctx, "v##dn") then move_script_in_cat(cur_cat, it.rel, 1) end

          reaper.ImGui_SameLine(ctx)
          if reaper.ImGui_SmallButton(ctx, "x##rm") then cat_remove(cur_cat, it.rel) end
        end

        reaper.ImGui_PopID(ctx)
      end
    end
    reaper.ImGui_EndChild(ctx)
    reaper.ImGui_PopStyleVar(ctx)
  end

  reaper.ImGui_EndChild(ctx)
end

-- =============================================================================
--  UI : MAIN FRAME
-- =============================================================================
local function frame()
  draw_toolbar()
  reaper.ImGui_Separator(ctx)

  local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local body_h = math.max(80, avail_h - 24)

  draw_left_pane(body_h)

  reaper.ImGui_SameLine(ctx)

  draw_right_pane(body_h)

  reaper.ImGui_Separator(ctx)
  reaper.ImGui_TextDisabled(ctx, S.status ~= "" and S.status or "Ready.")
end

-- =============================================================================
--  STYLE
-- =============================================================================
local function push_style()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(),       C.bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(),        C.bg_panel)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),        C.bg_item)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0x363636FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),  0x404040FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),         C.accent_dim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),  C.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),   0x5AAFEFFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),         C.bg_sel)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(),  0x3A4A5AFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),   C.accent_dim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),           C.text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TextDisabled(),   C.text_dim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(),        C.bg_panel)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),         C.border)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(),      C.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarBg(),    C.bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrab(),  C.border)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBg(),        C.bg_header)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgActive(),  C.bg_header)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(),      C.sep)

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(),  6)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(),   5)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_PopupRounding(),   5)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),   4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_GrabRounding(),    4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),     6, 5)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),    6, 4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),   10, 10)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarSize(),   12)

  return 21, 9
end

local function pop_style(nc, nv)
  reaper.ImGui_PopStyleColor(ctx, nc)
  reaper.ImGui_PopStyleVar(ctx, nv)
end

-- =============================================================================
--  MAIN LOOP
-- =============================================================================
local function loop()
  reaper.ImGui_SetNextWindowSize(ctx, 760, 520, reaper.ImGui_Cond_FirstUseEver())

  -- font pushed before Begin so the title bar uses it too (size at push: ReaImGui 0.9.3+)
  reaper.ImGui_PushFont(ctx, FONT, FONT_SIZE)

  local nc, nv = push_style()

  local visible, open = reaper.ImGui_Begin(
    ctx,
    WINDOW_TITLE,
    true,
    reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoScrollbar()
  )

  if visible then
    frame()
    reaper.ImGui_End(ctx)
  end

  pop_style(nc, nv)
  reaper.ImGui_PopFont(ctx)

  if S.dirty then
    save_config()
  end

  if open then
    reaper.defer(loop)
  else
    if S.dirty then
      save_config()
    end
  end
end

-- =============================================================================
--  BOOT
-- =============================================================================
cfg = load_config()

S.registered_only = (cfg.settings.registered_only ~= false)
S.sel_cat         = cfg.settings.last_cat or "__all__"

if type(S.sel_cat) == "number" and not find_cat(S.sel_cat) then
  S.sel_cat = "__all__"
end

rebuild_master()

reaper.atexit(function()
  if S.dirty then
    save_config()
  end
end)

reaper.defer(loop)
