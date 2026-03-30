-- =============================================================================
-- SK VCA Manager
-- VCA group manager for REAPER, built on native track grouping.
-- Author : Studio Kozak
--
-- Sections:
--   1. Config & Constants
--   2. REAPER API Wrapper  (R.*)
--   3. Data Model
--   4. Project Scanner     (Scanner.*)
--   5. VCA Mutations       (VCA.*)
--   6. Audit Engine        (Audit.*)
--   7. UI State
--   8. Rendering Helpers
--   9. Panels              (Panels.*)
--  10. Main Loop
-- =============================================================================


-- =============================================================================
-- 1. CONFIG & CONSTANTS
-- =============================================================================

local SCRIPT_NAME    = "SK VCA Manager"
local SCRIPT_VERSION = "1.0"
local EXT_SECTION    = "SK_VCAManager"  -- ProjExtState key namespace
local MAX_GROUPS     = 64               -- REAPER native group limit
local LOW_WORD_GROUPS = 32              -- groups 1-32 use the low bitfield word

-- Check project change count every N frames to detect external edits
local REFRESH_INTERVAL = 30

-- Severity levels used by the audit engine
local SEV = { INFO = 1, WARNING = 2, ERROR = 3 }

-- Window flags: no collapse, no outer scrollbar
local WINDOW_FLAGS = reaper.ImGui_WindowFlags_NoCollapse()
                   | reaper.ImGui_WindowFlags_NoScrollbar()
                   | reaper.ImGui_WindowFlags_NoScrollWithMouse()


-- =============================================================================
-- 2. REAPER API WRAPPER
-- =============================================================================
-- All reaper.* calls are routed through R.* for clarity and consistency.

local R = {}

function R.getTrackCount()
    return reaper.CountTracks(0)
end

function R.getTrack(idx)
    return reaper.GetTrack(0, idx)
end

function R.getTrackGUID(track)
    return reaper.GetTrackGUID(track)
end

function R.getTrackName(track)
    local _, name = reaper.GetTrackName(track)
    return (name and name ~= "") and name or "(Unnamed)"
end

function R.getTrackIndex(track)
    return reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
end

-- Returns low word (groups 1-32) and high word (groups 33-64) of a group membership field.
function R.getGroupMembership(track, groupname)
    local low  = reaper.GetSetTrackGroupMembership(track, groupname, 0, 0)
    local high = reaper.GetSetTrackGroupMembershipHigh(track, groupname, 0, 0)
    return low, high
end

-- Sets or clears the bit for groupNum (1-64) in a group membership field.
function R.setGroupBit(track, groupname, groupNum, value)
    if groupNum <= LOW_WORD_GROUPS then
        local bit = math.floor(2 ^ (groupNum - 1))
        reaper.GetSetTrackGroupMembership(track, groupname, bit, value and bit or 0)
    else
        local bit = math.floor(2 ^ (groupNum - LOW_WORD_GROUPS - 1))
        reaper.GetSetTrackGroupMembershipHigh(track, groupname, bit, value and bit or 0)
    end
end

-- Returns true if the bit for groupNum is set in (low, high).
function R.isGroupBitSet(low, high, groupNum)
    if groupNum <= LOW_WORD_GROUPS then
        return (low & (1 << (groupNum - 1))) ~= 0
    else
        return (high & (1 << (groupNum - LOW_WORD_GROUPS - 1))) ~= 0
    end
end

-- Inserts a new track at the end of the project and names it.
-- Used when creating a new VCA master bus.
function R.createVCAMasterTrack(name)
    local idx = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(idx, true)
    local track = reaper.GetTrack(0, idx)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name, true)
    return track
end

-- Finds a track by GUID; returns nil if not present in the current project.
function R.getTrackByGUID(guid)
    for i = 0, R.getTrackCount() - 1 do
        local t = R.getTrack(i)
        if R.getTrackGUID(t) == guid then return t end
    end
    return nil
end

-- Selects a track in the TCP and scrolls to it.
function R.scrollToTrack(track)
    reaper.SetOnlyTrackSelected(track)
    reaper.Main_OnCommand(40913, 0)
end

function R.beginUndo(label)
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)
end

function R.endUndo(label)
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock(label, -1)
    reaper.UpdateArrange()
    reaper.TrackList_AdjustWindows(false)
end

function R.setProjExt(key, value)
    reaper.SetProjExtState(0, EXT_SECTION, key, tostring(value))
end

function R.getProjExt(key)
    local _, val = reaper.GetProjExtState(0, EXT_SECTION, key)
    return val
end

function R.deleteProjExt(key)
    reaper.SetProjExtState(0, EXT_SECTION, key, "")
end

function R.getProjectStateChangeCount()
    return reaper.GetProjectStateChangeCount(0)
end


-- =============================================================================
-- 3. DATA MODEL
-- =============================================================================
-- Plain Lua tables; no REAPER API calls here.

-- Represents one track's VCA roles within the project.
local function newTrackInfo(guid, index, name)
    return {
        guid     = guid,
        index    = index,
        name     = name,
        masterOf = {},  -- group numbers where this track is VCA master
        slaveOf  = {},  -- group numbers where this track is VCA slave
        issues   = {},  -- AuditIssue list attached during audit
    }
end

-- Represents one VCA group (native group + metadata overlay).
local function newVcaGroup(groupNum)
    return {
        groupNumber = groupNum,
        logicalName = "Group " .. groupNum,  -- overridden by stored metadata
        notes       = "",
        masterGuid  = nil,
        slaveGuids  = {},
        auditState  = "ok",  -- "ok" | "warning" | "error"
    }
end

-- Top-level project state rebuilt on every scan.
local function newProjectVcaState()
    return {
        groups     = {},   -- groupNumber -> VcaGroup
        trackMap   = {},   -- guid -> TrackInfo
        auditIssues = {},
        groupOrder = {},   -- sorted list of active group numbers
    }
end

-- One audit issue record.
local function newAuditIssue(issueType, severity, targetGuid, groupNum, description, fix)
    return {
        type         = issueType,
        severity     = severity,
        targetGuid   = targetGuid,
        groupNumber  = groupNum,
        description  = description,
        suggestedFix = fix or "",
    }
end


-- =============================================================================
-- 4. PROJECT SCANNER
-- =============================================================================
-- Reads native REAPER state and constructs a ProjectVcaState.
-- Pure read - never modifies anything.

local Scanner = {}

-- Returns a set of group numbers that have at least one master or slave in trackList.
local function collectActiveGroups(trackList)
    local active = {}
    for _, track in ipairs(trackList) do
        local mL, mH = R.getGroupMembership(track, "VOLUME_VCA_MASTER")
        local sL, sH = R.getGroupMembership(track, "VOLUME_VCA_SLAVE")
        for g = 1, MAX_GROUPS do
            if R.isGroupBitSet(mL, mH, g) or R.isGroupBitSet(sL, sH, g) then
                active[g] = true
            end
        end
    end
    return active
end

function Scanner.scan()
    local state      = newProjectVcaState()
    local trackCount = R.getTrackCount()
    if trackCount == 0 then return state end

    -- Build TrackInfo for every track in the project
    local allTracks = {}
    for i = 0, trackCount - 1 do
        local t  = R.getTrack(i)
        local g  = R.getTrackGUID(t)
        state.trackMap[g] = newTrackInfo(g, i, R.getTrackName(t))
        allTracks[i + 1]  = t
    end

    -- For each active group, build a VcaGroup from native bits + stored metadata
    for groupNum in pairs(collectActiveGroups(allTracks)) do
        local grp = newVcaGroup(groupNum)

        local storedName = R.getProjExt("group_" .. groupNum .. "_name")
        if storedName and storedName ~= "" then grp.logicalName = storedName end

        local storedNotes = R.getProjExt("group_" .. groupNum .. "_notes")
        if storedNotes and storedNotes ~= "" then grp.notes = storedNotes end

        for i = 0, trackCount - 1 do
            local t  = R.getTrack(i)
            local g  = R.getTrackGUID(t)
            local mL, mH = R.getGroupMembership(t, "VOLUME_VCA_MASTER")
            local sL, sH = R.getGroupMembership(t, "VOLUME_VCA_SLAVE")

            if R.isGroupBitSet(mL, mH, groupNum) then
                -- Flag multiple masters with a pipe separator for audit detection
                grp.masterGuid = grp.masterGuid and (grp.masterGuid .. "|" .. g) or g
                local ti = state.trackMap[g]
                if ti then ti.masterOf[#ti.masterOf + 1] = groupNum end
            end

            if R.isGroupBitSet(sL, sH, groupNum) then
                grp.slaveGuids[#grp.slaveGuids + 1] = g
                local ti = state.trackMap[g]
                if ti then ti.slaveOf[#ti.slaveOf + 1] = groupNum end
            end
        end

        state.groups[groupNum]            = grp
        state.groupOrder[#state.groupOrder + 1] = groupNum
    end

    table.sort(state.groupOrder)
    return state
end


-- =============================================================================
-- 5. VCA MUTATIONS
-- =============================================================================
-- Every function that writes to REAPER is here.
-- All mutations are wrapped in Undo_BeginBlock / Undo_EndBlock.

local VCA = {}

-- Returns the lowest group number (1-64) not currently in use, or nil.
local function findFreeGroupNumber(state)
    for g = 1, MAX_GROUPS do
        if not state.groups[g] then return g end
    end
end

-- Creates a new VCA group with a brand-new dedicated master track.
-- slaveTracks may be empty. Returns groupNum, masterTrack, err.
function VCA.createGroup(state, slaveTracks, logicalName)
    local groupNum = findFreeGroupNumber(state)
    if not groupNum then return nil, nil, "All 64 REAPER groups are in use." end

    local name  = (logicalName and logicalName ~= "") and logicalName or ("VCA " .. groupNum)
    local label = "SK VCA: Create group '" .. name .. "'"
    R.beginUndo(label)

    local master     = R.createVCAMasterTrack(name)
    local masterGuid = R.getTrackGUID(master)
    R.setGroupBit(master, "VOLUME_VCA_MASTER", groupNum, true)

    for _, st in ipairs(slaveTracks or {}) do
        if R.getTrackGUID(st) ~= masterGuid then
            R.setGroupBit(st, "VOLUME_VCA_SLAVE", groupNum, true)
        end
    end

    R.endUndo(label)
    R.setProjExt("group_" .. groupNum .. "_name", name)
    return groupNum, master, nil
end

-- Creates a new VCA group using an existing track as master (no new track created).
-- Returns groupNum, masterTrack, err.
function VCA.createGroupFromExisting(state, masterTrack, slaveTracks, logicalName)
    local groupNum = findFreeGroupNumber(state)
    if not groupNum then return nil, nil, "All 64 REAPER groups are in use." end

    local masterGuid = R.getTrackGUID(masterTrack)
    local name       = (logicalName and logicalName ~= "") and logicalName
                       or R.getTrackName(masterTrack)
    local label      = "SK VCA: Promote '" .. name .. "' as VCA master"
    R.beginUndo(label)

    R.setGroupBit(masterTrack, "VOLUME_VCA_MASTER", groupNum, true)
    for _, st in ipairs(slaveTracks or {}) do
        if R.getTrackGUID(st) ~= masterGuid then
            R.setGroupBit(st, "VOLUME_VCA_SLAVE", groupNum, true)
        end
    end

    R.endUndo(label)
    R.setProjExt("group_" .. groupNum .. "_name", name)
    return groupNum, masterTrack, nil
end

-- Assigns slave tracks to an existing group.
function VCA.addSlaves(groupNum, masterGuid, slaveTracks)
    R.beginUndo("SK VCA: Add slaves to group " .. groupNum)
    for _, st in ipairs(slaveTracks) do
        if R.getTrackGUID(st) ~= masterGuid then
            R.setGroupBit(st, "VOLUME_VCA_SLAVE", groupNum, true)
        end
    end
    R.endUndo("SK VCA: Add slaves to group " .. groupNum)
end

-- Removes slave tracks from an existing group.
function VCA.removeSlaves(groupNum, slaveTracks)
    R.beginUndo("SK VCA: Remove slaves from group " .. groupNum)
    for _, st in ipairs(slaveTracks) do
        R.setGroupBit(st, "VOLUME_VCA_SLAVE", groupNum, false)
    end
    R.endUndo("SK VCA: Remove slaves from group " .. groupNum)
end

-- Removes all VCA assignments for a group and clears its metadata.
function VCA.dissolveGroup(state, groupNum)
    local grp = state.groups[groupNum]
    if not grp then return false, "Group not found." end

    local label = "SK VCA: Dissolve group " .. groupNum
    R.beginUndo(label)

    if grp.masterGuid then
        local mt = R.getTrackByGUID(grp.masterGuid)
        if mt then R.setGroupBit(mt, "VOLUME_VCA_MASTER", groupNum, false) end
    end
    for _, sg in ipairs(grp.slaveGuids) do
        local st = R.getTrackByGUID(sg)
        if st then R.setGroupBit(st, "VOLUME_VCA_SLAVE", groupNum, false) end
    end

    R.endUndo(label)
    R.deleteProjExt("group_" .. groupNum .. "_name")
    R.deleteProjExt("group_" .. groupNum .. "_color")
    R.deleteProjExt("group_" .. groupNum .. "_notes")
    return true, nil
end

-- Moves all slaves of group B into group A, then dissolves group B.
function VCA.mergeGroups(state, groupNumA, groupNumB)
    local groupA = state.groups[groupNumA]
    local groupB = state.groups[groupNumB]
    if not groupA or not groupB then return false, "One or both groups not found." end

    local label = "SK VCA: Merge group " .. groupNumB .. " into " .. groupNumA
    R.beginUndo(label)

    for _, sg in ipairs(groupB.slaveGuids) do
        local st = R.getTrackByGUID(sg)
        if st and sg ~= groupA.masterGuid then
            R.setGroupBit(st, "VOLUME_VCA_SLAVE", groupNumB, false)
            R.setGroupBit(st, "VOLUME_VCA_SLAVE", groupNumA, true)
        end
    end
    if groupB.masterGuid then
        local mt = R.getTrackByGUID(groupB.masterGuid)
        if mt then R.setGroupBit(mt, "VOLUME_VCA_MASTER", groupNumB, false) end
    end

    R.endUndo(label)
    R.deleteProjExt("group_" .. groupNumB .. "_name")
    R.deleteProjExt("group_" .. groupNumB .. "_color")
    R.deleteProjExt("group_" .. groupNumB .. "_notes")
    return true, nil
end

-- Persists a group's display name and notes.
function VCA.setGroupMeta(groupNum, name, notes)
    if name  ~= nil then R.setProjExt("group_" .. groupNum .. "_name",  name)  end
    if notes ~= nil then R.setProjExt("group_" .. groupNum .. "_notes", notes) end
end

-- Selects all tracks belonging to a group in REAPER's TCP.
function VCA.selectGroupTracks(state, groupNum)
    local grp = state.groups[groupNum]
    if not grp then return end
    reaper.Main_OnCommand(40297, 0)  -- unselect all
    if grp.masterGuid then
        local mt = R.getTrackByGUID(grp.masterGuid)
        if mt then reaper.SetTrackSelected(mt, true) end
    end
    for _, sg in ipairs(grp.slaveGuids) do
        local st = R.getTrackByGUID(sg)
        if st then reaper.SetTrackSelected(st, true) end
    end
end


-- =============================================================================
-- 6. AUDIT ENGINE
-- =============================================================================
-- Stateless analysis pass: takes a ProjectVcaState, returns a list of issues.

local Audit = {}

function Audit.run(state)
    local issues = {}

    local function add(t, sev, guid, gNum, desc, fix)
        issues[#issues + 1] = newAuditIssue(t, sev, guid, gNum, desc, fix)
    end

    for _, groupNum in ipairs(state.groupOrder) do
        local g = state.groups[groupNum]

        if not g.masterGuid or g.masterGuid == "" then
            add("NO_MASTER", SEV.ERROR, nil, groupNum,
                "Group " .. groupNum .. " (" .. g.logicalName .. ") has no master.",
                "Assign a master track or dissolve the group.")
        end

        if g.masterGuid and g.masterGuid:find("|") then
            add("MULTIPLE_MASTERS", SEV.ERROR, nil, groupNum,
                "Group " .. groupNum .. " has multiple master tracks.",
                "Remove extra master bits - only one master is allowed.")
        end

        if #g.slaveGuids == 0 then
            add("NO_SLAVES", SEV.WARNING, g.masterGuid, groupNum,
                "Group " .. groupNum .. " (" .. g.logicalName .. ") has no slaves.",
                "Add slave tracks or dissolve the group.")
        end

        if g.masterGuid and not g.masterGuid:find("|") then
            if not R.getTrackByGUID(g.masterGuid) then
                add("MISSING_MASTER", SEV.ERROR, g.masterGuid, groupNum,
                    "Master track for group " .. groupNum .. " was deleted.",
                    "Assign a new master or dissolve the group.")
            end
        end

        for _, sg in ipairs(g.slaveGuids) do
            if not R.getTrackByGUID(sg) then
                add("MISSING_SLAVE", SEV.WARNING, sg, groupNum,
                    "A slave track in group " .. groupNum .. " was deleted.",
                    "Stale reference will clear on next REAPER project save.")
            end
            if g.masterGuid and sg == g.masterGuid then
                add("MASTER_IS_SLAVE", SEV.ERROR, sg, groupNum,
                    "The master track is also a slave in group " .. groupNum .. ".",
                    "Remove the slave bit from the master track.")
            end
        end
    end

    for guid, ti in pairs(state.trackMap) do
        if #ti.masterOf > 1 then
            add("MULTI_MASTER_TRACK", SEV.WARNING, guid, nil,
                "Track '" .. ti.name .. "' is master in " .. #ti.masterOf .. " groups.",
                "Verify this is intentional.")
        end
    end

    -- Orphaned metadata: stored name for a group with no native members
    for g = 1, MAX_GROUPS do
        local stored = R.getProjExt("group_" .. g .. "_name")
        if stored and stored ~= "" and not state.groups[g] then
            add("ORPHAN_METADATA", SEV.INFO, nil, g,
                "Metadata for group " .. g .. " exists but no native members found.",
                "Cleared automatically when the group is dissolved.")
        end
    end

    return issues
end

-- Stamps each VcaGroup's auditState field based on issue severity.
function Audit.annotateState(state, issues)
    for _, g in pairs(state.groups) do g.auditState = "ok" end
    for _, issue in ipairs(issues) do
        if issue.groupNumber then
            local g = state.groups[issue.groupNumber]
            if g then
                if issue.severity == SEV.ERROR then
                    g.auditState = "error"
                elseif issue.severity == SEV.WARNING and g.auditState ~= "error" then
                    g.auditState = "warning"
                end
            end
        end
    end
end


-- =============================================================================
-- 7. UI STATE
-- =============================================================================
-- All transient UI variables in one initialiser - nothing here touches REAPER.

local UI = {}

function UI.init()
    return {
        windowOpen       = true,

        -- Left panel
        selectedGroupNum = nil,   -- group currently open in the detail panel
        searchFilter     = "",    -- text filter for the group list

        -- Centre panel (track list)
        trackListFilter   = "",
        checkedTrackGuids = {},   -- guid -> true, independent of REAPER selection

        -- "New VCA" creation dialog
        showCreateDialog       = false,
        createVcaNameBuf       = "",
        createVcaMode          = 0,    -- 0 = new track, 1 = existing track
        createVcaMasterGuid    = nil,
        _createDialogFocusDone = false,

        -- Right panel (group detail)
        editNameBuf     = "",

        -- Left panel actions
        mergeTargetGroupNum = nil,
        confirmMerge        = false,
        confirmDissolve     = false,

        -- Status bar
        statusMsg   = "",
        statusTimer = 0,
    }
end


-- =============================================================================
-- 8. RENDERING HELPERS
-- =============================================================================

local function ctx() return _G.SK_VCA_CTX end

-- Spacing constants (pixels)
local PAD   = 8   -- internal panel padding
local GAP   = 8   -- gutter between columns
local INLSP = 4   -- compact SameLine gap

-- Colors
local COL_MASTER    = 0xC0392BFF  -- red    - master track highlight
local COL_SLAVE     = 0xD4AC0DFF  -- amber  - slave track highlight
local COL_WARN      = 0xE67E22FF
local COL_ERR       = 0xE74C3CFF
local COL_HDR_BG    = 0x1A2333FF  -- dark blue-grey panel header background
local COL_HDR_TEXT  = 0xFFFFFFFF
local COL_STATUS_OK = 0x2ECC71FF

local SEV_COLOR = { [1] = 0x5DADE2FF, [2] = 0xE67E22FF, [3] = 0xE74C3CFF }

-- Renders text in a given color.
local function colorText(cx, col, text)
    reaper.ImGui_PushStyleColor(cx, reaper.ImGui_Col_Text(), col)
    reaper.ImGui_Text(cx, text)
    reaper.ImGui_PopStyleColor(cx)
end

-- Sets a status bar message with a 5-second display timer.
local function setStatus(uiState, msg)
    uiState.statusMsg   = msg
    uiState.statusTimer = os.time()
end

-- Renders the status bar at the bottom of the window.
local function renderStatusBar(cx, uiState)
    reaper.ImGui_Separator(cx)
    if os.time() - (uiState.statusTimer or 0) < 5 and uiState.statusMsg ~= "" then
        reaper.ImGui_PushStyleColor(cx, reaper.ImGui_Col_Text(), COL_STATUS_OK)
        reaper.ImGui_Text(cx, uiState.statusMsg)
        reaper.ImGui_PopStyleColor(cx)
    else
        reaper.ImGui_TextDisabled(cx, SCRIPT_NAME .. " v" .. SCRIPT_VERSION)
    end
end

-- Renders a colored header bar as the first element inside a BeginChild region.
local function panelHeader(cx, title, w)
    local lineHs = reaper.ImGui_GetFrameHeightWithSpacing(cx)
    reaper.ImGui_PushStyleColor(cx, reaper.ImGui_Col_ChildBg(), COL_HDR_BG)
    reaper.ImGui_BeginChild(cx, "##hdr_" .. title, w, lineHs + PAD, 0,
        reaper.ImGui_WindowFlags_NoScrollbar() |
        reaper.ImGui_WindowFlags_NoScrollWithMouse())
    reaper.ImGui_PopStyleColor(cx)
    reaper.ImGui_SetCursorPosX(cx, PAD)
    reaper.ImGui_SetCursorPosY(cx,
        reaper.ImGui_GetCursorPosY(cx) + reaper.ImGui_GetFrameHeight(cx) * 0.1)
    colorText(cx, COL_HDR_TEXT, title)
    reaper.ImGui_EndChild(cx)
    reaper.ImGui_Separator(cx)
end

-- Renders a colored audit status dot with a tooltip.
local function auditDot(cx, auditState)
    if auditState == "error" then
        reaper.ImGui_PushStyleColor(cx, reaper.ImGui_Col_Text(), COL_ERR)
        reaper.ImGui_Text(cx, "●")
        reaper.ImGui_PopStyleColor(cx)
        if reaper.ImGui_IsItemHovered(cx) then reaper.ImGui_SetTooltip(cx, "Audit error") end
    elseif auditState == "warning" then
        reaper.ImGui_PushStyleColor(cx, reaper.ImGui_Col_Text(), COL_WARN)
        reaper.ImGui_Text(cx, "●")
        reaper.ImGui_PopStyleColor(cx)
        if reaper.ImGui_IsItemHovered(cx) then reaper.ImGui_SetTooltip(cx, "Audit warning") end
    else
        reaper.ImGui_TextDisabled(cx, ".")
    end
end

-- Computes pixel dimensions for all three panels from the current available space.
-- All panels share the same panelH so their top and bottom edges are aligned.
local function computeLayout(cx)
    local aw, ah = reaper.ImGui_GetContentRegionAvail(cx)
    local lineH  = reaper.ImGui_GetFrameHeight(cx)
    local lineHs = reaper.ImGui_GetFrameHeightWithSpacing(cx)
    local hdrH   = lineHs + PAD + 1          -- colored header + separator
    local statusH = lineHs + 4               -- status bar reservation
    local panelH  = ah - statusH

    local leftW   = math.floor(aw * 0.25)
    local rightW  = math.floor(aw * 0.375)   -- Project Tracks (rightmost)
    local centreW = aw - leftW - rightW - GAP * 2  -- Group Detail (centre)

    return {
        lineH = lineH, lineHs = lineHs,
        hdrH  = hdrH,  panelH = panelH,
        leftW = leftW, centreW = centreW, rightW = rightW,
    }
end


-- =============================================================================
-- 9. PANELS
-- =============================================================================

local Panels = {}

-- ── Toolbar ───────────────────────────────────────────────────────────────────

function Panels.toolbar(cx, state, uiState, onRefresh, onCreateVCA)
    if reaper.ImGui_Button(cx, "↺ Refresh") then onRefresh() end
    reaper.ImGui_SameLine(cx, 0, INLSP)

    reaper.ImGui_SetNextItemWidth(cx, 160)
    local fc, fv = reaper.ImGui_InputText(cx, "##gsearch", uiState.searchFilter)
    if fc then uiState.searchFilter = fv end
    if reaper.ImGui_IsItemHovered(cx) then
        reaper.ImGui_SetTooltip(cx, "Filter VCA groups by name")
    end
    reaper.ImGui_SameLine(cx, 0, INLSP)

    if reaper.ImGui_Button(cx, "+ New VCA Group") then
        uiState.showCreateDialog       = true
        uiState.createVcaNameBuf       = ""
        uiState.createVcaMode          = 0
        uiState.createVcaMasterGuid    = nil
        uiState._createDialogFocusDone = false
    end
    reaper.ImGui_SameLine(cx, 0, PAD)

    local n = #state.groupOrder
    reaper.ImGui_TextDisabled(cx,
        n .. " group" .. (n ~= 1 and "s" or "") ..
        "  |  " .. (MAX_GROUPS - n) .. " free")

    -- New VCA creation modal
    if uiState.showCreateDialog then
        reaper.ImGui_OpenPopup(cx, "New VCA Group")
        uiState.showCreateDialog = false
    end
    if reaper.ImGui_BeginPopupModal(cx, "New VCA Group", nil,
            reaper.ImGui_WindowFlags_AlwaysAutoResize()) then

        local _, r0 = reaper.ImGui_RadioButton(cx,
            "Create a new dedicated master track", uiState.createVcaMode == 0)
        if r0 then uiState.createVcaMode = 0 end
        local _, r1 = reaper.ImGui_RadioButton(cx,
            "Use an existing track as master", uiState.createVcaMode == 1)
        if r1 then uiState.createVcaMode = 1 end

        reaper.ImGui_Spacing(cx)
        reaper.ImGui_Separator(cx)
        reaper.ImGui_Spacing(cx)

        if uiState.createVcaMode == 0 then
            reaper.ImGui_Text(cx, "Group name:")
            reaper.ImGui_SetNextItemWidth(cx, 300)
            if not uiState._createDialogFocusDone then
                reaper.ImGui_SetKeyboardFocusHere(cx)
                uiState._createDialogFocusDone = true
            end
            local nc, nn = reaper.ImGui_InputText(cx, "##vcaNewName", uiState.createVcaNameBuf)
            if nc then uiState.createVcaNameBuf = nn end
        else
            reaper.ImGui_Text(cx, "Master track:")
            reaper.ImGui_SetNextItemWidth(cx, 300)
            local label = "(none)"
            if uiState.createVcaMasterGuid then
                local mt = R.getTrackByGUID(uiState.createVcaMasterGuid)
                if mt then label = R.getTrackName(mt) else uiState.createVcaMasterGuid = nil end
            end
            if reaper.ImGui_BeginCombo(cx, "##masterPick", label) then
                for i = 0, R.getTrackCount() - 1 do
                    local t    = R.getTrack(i)
                    local guid = R.getTrackGUID(t)
                    local name = R.getTrackName(t)
                    if reaper.ImGui_Selectable(cx, "#" .. (i + 1) .. "  " .. name .. "##mp" .. guid,
                            uiState.createVcaMasterGuid == guid) then
                        uiState.createVcaMasterGuid = guid
                        if uiState.createVcaNameBuf == "" then
                            uiState.createVcaNameBuf = name
                        end
                    end
                end
                reaper.ImGui_EndCombo(cx)
            end
            reaper.ImGui_Spacing(cx)
            reaper.ImGui_Text(cx, "Group name:")
            reaper.ImGui_SetNextItemWidth(cx, 300)
            if not uiState._createDialogFocusDone then
                reaper.ImGui_SetKeyboardFocusHere(cx)
                uiState._createDialogFocusDone = true
            end
            local nc, nn = reaper.ImGui_InputText(cx, "##vcaNewName", uiState.createVcaNameBuf)
            if nc then uiState.createVcaNameBuf = nn end
        end

        reaper.ImGui_Spacing(cx)
        local cc = 0
        for _ in pairs(uiState.checkedTrackGuids) do cc = cc + 1 end
        reaper.ImGui_TextDisabled(cx, cc > 0
            and cc .. " checked track(s) will become slaves."
            or  "No slaves pre-selected - you can add them later.")
        reaper.ImGui_Spacing(cx)

        local canCreate = uiState.createVcaNameBuf ~= "" and
            (uiState.createVcaMode == 0 or uiState.createVcaMasterGuid ~= nil)
        if not canCreate then reaper.ImGui_BeginDisabled(cx) end
        if reaper.ImGui_Button(cx, "Create") then
            onCreateVCA(uiState.createVcaNameBuf, uiState.createVcaMode,
                        uiState.createVcaMasterGuid)
            reaper.ImGui_CloseCurrentPopup(cx)
        end
        if not canCreate then reaper.ImGui_EndDisabled(cx) end
        reaper.ImGui_SameLine(cx, 0, INLSP)
        if reaper.ImGui_Button(cx, "Cancel##nvcaCancel") then
            reaper.ImGui_CloseCurrentPopup(cx)
        end
        reaper.ImGui_EndPopup(cx)
    end
end

-- ── Left panel: VCA group list ────────────────────────────────────────────────

function Panels.leftPanel(cx, state, uiState, L, onMutate)
    reaper.ImGui_BeginChild(cx, "##left", L.leftW, L.panelH, 1,
        reaper.ImGui_WindowFlags_NoScrollbar() |
        reaper.ImGui_WindowFlags_NoScrollWithMouse())

    panelHeader(cx, "VCA GROUPS", L.leftW)

    -- Group table (leaves room for the two-row action bar below)
    local actionBarH = L.lineHs * 2 + PAD * 2
    local tableH     = L.panelH - L.hdrH - actionBarH - 2

    local filter = uiState.searchFilter:lower()
    if reaper.ImGui_BeginTable(cx, "##grpTbl", 3,
            reaper.ImGui_TableFlags_Borders()  |
            reaper.ImGui_TableFlags_RowBg()    |
            reaper.ImGui_TableFlags_ScrollY()  |
            reaper.ImGui_TableFlags_SizingStretchProp(),
            L.leftW - 2, tableH) then
        reaper.ImGui_TableSetupScrollFreeze(cx, 0, 1)
        reaper.ImGui_TableSetupColumn(cx, "Name", reaper.ImGui_TableColumnFlags_WidthStretch())
        reaper.ImGui_TableSetupColumn(cx, "Slv",  reaper.ImGui_TableColumnFlags_WidthFixed(), 26)
        reaper.ImGui_TableSetupColumn(cx, "  ",   reaper.ImGui_TableColumnFlags_WidthFixed(), 18)
        reaper.ImGui_TableHeadersRow(cx)

        if #state.groupOrder == 0 then
            reaper.ImGui_TableNextRow(cx)
            reaper.ImGui_TableSetColumnIndex(cx, 0)
            reaper.ImGui_TextDisabled(cx, "No groups yet")
        end

        for _, gn in ipairs(state.groupOrder) do
            local g = state.groups[gn]
            if filter == "" or g.logicalName:lower():find(filter, 1, true) then
                reaper.ImGui_TableNextRow(cx)
                reaper.ImGui_TableSetColumnIndex(cx, 0)
                local isSel = uiState.selectedGroupNum == gn
                if reaper.ImGui_Selectable(cx, g.logicalName .. "##grp" .. gn,
                        isSel, reaper.ImGui_SelectableFlags_SpanAllColumns(), 0, 0) then
                    uiState.selectedGroupNum    = gn
                    uiState.editNameBuf         = g.logicalName
                    uiState.mergeTargetGroupNum = nil
                end
                reaper.ImGui_TableSetColumnIndex(cx, 1)
                reaper.ImGui_TextDisabled(cx, tostring(#g.slaveGuids))
                reaper.ImGui_TableSetColumnIndex(cx, 2)
                auditDot(cx, g.auditState)
            end
        end
        reaper.ImGui_EndTable(cx)
    end

    -- Action bar: Dissolve + Merge combo
    reaper.ImGui_Separator(cx)
    local hasSel  = uiState.selectedGroupNum ~= nil and
                    state.groups[uiState.selectedGroupNum] ~= nil
    if not hasSel then reaper.ImGui_BeginDisabled(cx) end

    local bw = math.floor((L.leftW - PAD - INLSP) * 0.40)
    reaper.ImGui_SetCursorPosX(cx, PAD * 0.5)
    reaper.ImGui_PushStyleColor(cx, reaper.ImGui_Col_Button(),        0x7B241CFF)
    reaper.ImGui_PushStyleColor(cx, reaper.ImGui_Col_ButtonHovered(), 0x922B21FF)
    if reaper.ImGui_Button(cx, "Dissolve##diss", bw, 0) then
        uiState.confirmDissolve = true
    end
    reaper.ImGui_PopStyleColor(cx, 2)

    reaper.ImGui_SameLine(cx, 0, INLSP)
    reaper.ImGui_SetNextItemWidth(cx, L.leftW - bw - PAD - INLSP - 2)
    local mergeLabel = uiState.mergeTargetGroupNum and
        "-> " .. (state.groups[uiState.mergeTargetGroupNum] and
            state.groups[uiState.mergeTargetGroupNum].logicalName or "?")
        or "Merge into..."
    if reaper.ImGui_BeginCombo(cx, "##mergeCombo", mergeLabel) then
        for _, gn in ipairs(state.groupOrder) do
            if gn ~= uiState.selectedGroupNum then
                local gg = state.groups[gn]
                if reaper.ImGui_Selectable(cx, gg.logicalName .. "##mc" .. gn,
                        uiState.mergeTargetGroupNum == gn) then
                    uiState.mergeTargetGroupNum = gn
                end
            end
        end
        reaper.ImGui_EndCombo(cx)
    end

    if not hasSel then reaper.ImGui_EndDisabled(cx) end

    -- Confirm Merge button (always rendered, disabled when no target selected)
    local canMerge = hasSel and uiState.mergeTargetGroupNum ~= nil
    if not canMerge then reaper.ImGui_BeginDisabled(cx) end
    reaper.ImGui_SetCursorPosX(cx, PAD * 0.5)
    if reaper.ImGui_Button(cx, "Confirm Merge##cmrg", L.leftW - PAD, 0) then
        uiState.confirmMerge = true
    end
    if not canMerge then reaper.ImGui_EndDisabled(cx) end

    reaper.ImGui_EndChild(cx)

    -- Dissolve confirmation modal
    if uiState.confirmDissolve then
        reaper.ImGui_OpenPopup(cx, "Confirm Dissolve")
        uiState.confirmDissolve = false
    end
    if reaper.ImGui_BeginPopupModal(cx, "Confirm Dissolve", nil,
            reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
        local g = uiState.selectedGroupNum and state.groups[uiState.selectedGroupNum]
        reaper.ImGui_Text(cx, "Dissolve '" .. (g and g.logicalName or "?") .. "'?")
        reaper.ImGui_TextDisabled(cx, "All VCA bits cleared. Undoable via REAPER.")
        reaper.ImGui_Spacing(cx)
        if reaper.ImGui_Button(cx, "Dissolve##doCnf") then
            local ok, err = VCA.dissolveGroup(state, uiState.selectedGroupNum)
            if ok then
                setStatus(uiState, "Group dissolved.")
                uiState.selectedGroupNum    = nil
                uiState.mergeTargetGroupNum = nil
                onMutate()
            else
                setStatus(uiState, "Error: " .. (err or "?"))
            end
            reaper.ImGui_CloseCurrentPopup(cx)
        end
        reaper.ImGui_SameLine(cx, 0, INLSP)
        if reaper.ImGui_Button(cx, "Cancel##dCancel") then
            reaper.ImGui_CloseCurrentPopup(cx)
        end
        reaper.ImGui_EndPopup(cx)
    end

    -- Merge confirmation modal
    if uiState.confirmMerge then
        reaper.ImGui_OpenPopup(cx, "Confirm Merge")
        uiState.confirmMerge = false
    end
    if reaper.ImGui_BeginPopupModal(cx, "Confirm Merge", nil,
            reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
        local tgt  = uiState.mergeTargetGroupNum
        local tgtG = tgt and state.groups[tgt]
        local srcG = uiState.selectedGroupNum and state.groups[uiState.selectedGroupNum]
        reaper.ImGui_Text(cx,
            "Merge '" .. (srcG and srcG.logicalName or "?") ..
            "' INTO '" .. (tgtG and tgtG.logicalName or "?") .. "'?")
        reaper.ImGui_TextDisabled(cx, "Source group will be dissolved.")
        reaper.ImGui_Spacing(cx)
        if reaper.ImGui_Button(cx, "Merge##doMrg") then
            local ok, err = VCA.mergeGroups(state, tgt, uiState.selectedGroupNum)
            if ok then
                setStatus(uiState, "Groups merged.")
                uiState.selectedGroupNum    = tgt
                uiState.mergeTargetGroupNum = nil
                onMutate()
            else
                setStatus(uiState, "Merge error: " .. (err or "?"))
            end
            reaper.ImGui_CloseCurrentPopup(cx)
        end
        reaper.ImGui_SameLine(cx, 0, INLSP)
        if reaper.ImGui_Button(cx, "Cancel##mCancel") then
            reaper.ImGui_CloseCurrentPopup(cx)
        end
        reaper.ImGui_EndPopup(cx)
    end
end

-- ── Centre panel: Group Detail ────────────────────────────────────────────────

function Panels.centrePanel(cx, state, uiState, L, onMutate)
    reaper.ImGui_BeginChild(cx, "##centre", L.centreW, L.panelH, 1,
        reaper.ImGui_WindowFlags_NoScrollbar() |
        reaper.ImGui_WindowFlags_NoScrollWithMouse())

    panelHeader(cx, "GROUP DETAIL", L.centreW)

    if not uiState.selectedGroupNum or not state.groups[uiState.selectedGroupNum] then
        reaper.ImGui_Spacing(cx)
        reaper.ImGui_SetCursorPosX(cx, PAD)
        reaper.ImGui_TextDisabled(cx, "<- Select a VCA group")
        reaper.ImGui_EndChild(cx)
        return
    end

    local gn = uiState.selectedGroupNum
    local g  = state.groups[gn]

    -- Name / Rename row
    reaper.ImGui_SetNextItemWidth(cx, L.centreW - 80 - PAD)
    local nc, nn = reaper.ImGui_InputText(cx, "##rname", uiState.editNameBuf)
    if nc then uiState.editNameBuf = nn end
    reaper.ImGui_SameLine(cx, 0, INLSP)
    if reaper.ImGui_Button(cx, "Rename##rnbtn", 72, 0) then
        if uiState.editNameBuf ~= "" then
            VCA.setGroupMeta(gn, uiState.editNameBuf, nil)
            if g.masterGuid then
                local mt = R.getTrackByGUID(g.masterGuid)
                if mt then
                    reaper.GetSetMediaTrackInfo_String(mt, "P_NAME", uiState.editNameBuf, true)
                end
            end
            setStatus(uiState, "Renamed to: " .. uiState.editNameBuf)
            onMutate()
        end
    end
    reaper.ImGui_Separator(cx)

    -- Master row
    reaper.ImGui_PushStyleColor(cx, reaper.ImGui_Col_Text(), COL_MASTER)
    reaper.ImGui_Text(cx, "MASTER")
    reaper.ImGui_PopStyleColor(cx)
    reaper.ImGui_SameLine(cx, 0, PAD)
    if g.masterGuid then
        local ti = state.trackMap[g.masterGuid]
        if ti then
            reaper.ImGui_Text(cx, "#" .. (ti.index + 1) .. "  " .. ti.name)
            reaper.ImGui_SameLine(cx, 0, INLSP)
            if reaper.ImGui_SmallButton(cx, "Focus##mfoc") then
                local mt = R.getTrackByGUID(g.masterGuid)
                if mt then R.scrollToTrack(mt) end
            end
        else
            reaper.ImGui_PushStyleColor(cx, reaper.ImGui_Col_Text(), COL_ERR)
            reaper.ImGui_Text(cx, "MISSING")
            reaper.ImGui_PopStyleColor(cx)
        end
    else
        reaper.ImGui_TextDisabled(cx, "(none)")
    end
    reaper.ImGui_Separator(cx)

    -- Slaves header
    reaper.ImGui_PushStyleColor(cx, reaper.ImGui_Col_Text(), COL_SLAVE)
    reaper.ImGui_Text(cx, "SLAVES  (" .. #g.slaveGuids .. ")")
    reaper.ImGui_PopStyleColor(cx)
    reaper.ImGui_SameLine(cx, 0, PAD)
    if reaper.ImGui_SmallButton(cx, "Sel all##sela") then
        VCA.selectGroupTracks(state, gn)
        setStatus(uiState, "All group tracks selected.")
    end
    if reaper.ImGui_IsItemHovered(cx) then
        reaper.ImGui_SetTooltip(cx, "Select all group tracks")
    end

    -- Audit issues count (to reserve height below slave table)
    local groupIssues = {}
    for _, issue in ipairs(state.auditIssues or {}) do
        if issue.groupNumber == gn then groupIssues[#groupIssues + 1] = issue end
    end
    local auditH  = #groupIssues > 0
        and math.min(#groupIssues, 3) * L.lineHs * 2 + PAD or 0
    local fixedH  = L.hdrH + L.lineHs * 4 + PAD
    local slaveH  = L.panelH - fixedH - auditH - 2

    if reaper.ImGui_BeginTable(cx, "##slvTbl", 2,
            reaper.ImGui_TableFlags_Borders()  |
            reaper.ImGui_TableFlags_RowBg()    |
            reaper.ImGui_TableFlags_ScrollY()  |
            reaper.ImGui_TableFlags_SizingStretchProp(),
            L.centreW - 2, slaveH) then
        reaper.ImGui_TableSetupScrollFreeze(cx, 0, 1)
        reaper.ImGui_TableSetupColumn(cx, "Track", reaper.ImGui_TableColumnFlags_WidthStretch())
        reaper.ImGui_TableSetupColumn(cx, " ",     reaper.ImGui_TableColumnFlags_WidthFixed(), 38)
        reaper.ImGui_TableHeadersRow(cx)

        for i, sg in ipairs(g.slaveGuids) do
            local ti = state.trackMap[sg]
            reaper.ImGui_TableNextRow(cx)
            reaper.ImGui_TableSetColumnIndex(cx, 0)
            if ti then
                reaper.ImGui_Text(cx, "#" .. (ti.index + 1) .. "  " .. ti.name)
            else
                reaper.ImGui_TextDisabled(cx, "? " .. sg:sub(1, 8) .. "...")
            end
            reaper.ImGui_TableSetColumnIndex(cx, 1)
            if reaper.ImGui_SmallButton(cx, "Focus##sf" .. i) then
                local st = R.getTrackByGUID(sg)
                if st then R.scrollToTrack(st) end
            end
            if reaper.ImGui_IsItemHovered(cx) then
                reaper.ImGui_SetTooltip(cx, "Scroll to track")
            end
            reaper.ImGui_SameLine(cx, 0, 2)
            if reaper.ImGui_SmallButton(cx, "x##sr" .. i) then
                local st = R.getTrackByGUID(sg)
                if st then
                    VCA.removeSlaves(gn, {st})
                    setStatus(uiState, "Slave removed.")
                    onMutate()
                end
            end
            if reaper.ImGui_IsItemHovered(cx) then
                reaper.ImGui_SetTooltip(cx, "Remove from group")
            end
        end
        reaper.ImGui_EndTable(cx)
    end

    -- Inline audit issues
    if #groupIssues > 0 then
        reaper.ImGui_Separator(cx)
        for _, issue in ipairs(groupIssues) do
            local col = SEV_COLOR[issue.severity] or 0xFFFFFFFF
            reaper.ImGui_PushStyleColor(cx, reaper.ImGui_Col_Text(), col)
            reaper.ImGui_TextWrapped(cx, "! " .. issue.description)
            reaper.ImGui_PopStyleColor(cx)
            if issue.suggestedFix ~= "" then
                reaper.ImGui_PushStyleColor(cx, reaper.ImGui_Col_Text(), 0x7DCEA0FF)
                reaper.ImGui_TextWrapped(cx, "  -> " .. issue.suggestedFix)
                reaper.ImGui_PopStyleColor(cx)
            end
        end
    end

    reaper.ImGui_EndChild(cx)
end

-- ── Right panel: Project track list ──────────────────────────────────────────

function Panels.rightPanel(cx, state, uiState, L, onMutate)
    reaper.ImGui_BeginChild(cx, "##right", L.rightW, L.panelH, 1,
        reaper.ImGui_WindowFlags_NoScrollbar() |
        reaper.ImGui_WindowFlags_NoScrollWithMouse())

    panelHeader(cx, "PROJECT TRACKS", L.rightW)

    local hasGroup  = uiState.selectedGroupNum ~= nil and
                      state.groups[uiState.selectedGroupNum] ~= nil
    local cc = 0
    for _ in pairs(uiState.checkedTrackGuids) do cc = cc + 1 end
    local hasChecked = cc > 0
    local selName    = hasGroup and state.groups[uiState.selectedGroupNum].logicalName or "?"

    -- Track name filter
    reaper.ImGui_SetNextItemWidth(cx, L.rightW - PAD - 2)
    local fc, fv = reaper.ImGui_InputText(cx, "##tfilter", uiState.trackListFilter)
    if fc then uiState.trackListFilter = fv end

    -- Add / Remove / Clear buttons
    local canAdd = hasGroup and hasChecked
    if not canAdd then reaper.ImGui_BeginDisabled(cx) end
    if reaper.ImGui_Button(cx, "Add to <<" .. selName .. ">>") then
        local g      = state.groups[uiState.selectedGroupNum]
        local tracks = {}
        for guid in pairs(uiState.checkedTrackGuids) do
            local t = R.getTrackByGUID(guid)
            if t then tracks[#tracks + 1] = t end
        end
        VCA.addSlaves(uiState.selectedGroupNum, g.masterGuid, tracks)
        setStatus(uiState, #tracks .. " track(s) added as slaves.")
        uiState.checkedTrackGuids = {}
        onMutate()
    end
    if not canAdd then
        reaper.ImGui_EndDisabled(cx)
        if reaper.ImGui_IsItemHovered(cx, reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
            reaper.ImGui_SetTooltip(cx,
                not hasGroup and "Select a VCA group first" or "Check tracks below first")
        end
    end

    reaper.ImGui_SameLine(cx, 0, INLSP)
    if not (hasGroup and hasChecked) then reaper.ImGui_BeginDisabled(cx) end
    if reaper.ImGui_Button(cx, "Remove") then
        local tracks = {}
        for guid in pairs(uiState.checkedTrackGuids) do
            local t = R.getTrackByGUID(guid)
            if t then tracks[#tracks + 1] = t end
        end
        VCA.removeSlaves(uiState.selectedGroupNum, tracks)
        setStatus(uiState, #tracks .. " track(s) removed.")
        uiState.checkedTrackGuids = {}
        onMutate()
    end
    if not (hasGroup and hasChecked) then reaper.ImGui_EndDisabled(cx) end

    if hasChecked then
        reaper.ImGui_SameLine(cx, 0, INLSP)
        if reaper.ImGui_SmallButton(cx, "x " .. cc) then
            uiState.checkedTrackGuids = {}
        end
        if reaper.ImGui_IsItemHovered(cx) then reaper.ImGui_SetTooltip(cx, "Clear selection") end
    end

    -- Track table
    local tfilter   = uiState.trackListFilter:lower()
    local overheadH = L.hdrH + L.lineHs * 2 + PAD
    local tableH    = L.panelH - overheadH - 2

    if reaper.ImGui_BeginTable(cx, "##trkTbl", 3,
            reaper.ImGui_TableFlags_Borders()  |
            reaper.ImGui_TableFlags_RowBg()    |
            reaper.ImGui_TableFlags_ScrollY()  |
            reaper.ImGui_TableFlags_SizingStretchProp(),
            L.rightW - 2, tableH) then
        reaper.ImGui_TableSetupScrollFreeze(cx, 0, 1)
        reaper.ImGui_TableSetupColumn(cx, " ",     reaper.ImGui_TableColumnFlags_WidthFixed(), 20)
        reaper.ImGui_TableSetupColumn(cx, "Track", reaper.ImGui_TableColumnFlags_WidthStretch())
        reaper.ImGui_TableSetupColumn(cx, "Role",  reaper.ImGui_TableColumnFlags_WidthFixed(), 60)
        reaper.ImGui_TableHeadersRow(cx)

        for i = 0, R.getTrackCount() - 1 do
            local t    = R.getTrack(i)
            local guid = R.getTrackGUID(t)
            local ti   = state.trackMap[guid]
            local name = ti and ti.name or R.getTrackName(t)

            if tfilter == "" or name:lower():find(tfilter, 1, true) then
                reaper.ImGui_TableNextRow(cx)

                -- Checkbox
                reaper.ImGui_TableSetColumnIndex(cx, 0)
                local isChecked = uiState.checkedTrackGuids[guid] == true
                local chgd, nv = reaper.ImGui_Checkbox(cx, "##ck" .. guid, isChecked)
                if chgd then uiState.checkedTrackGuids[guid] = nv or nil end

                -- Track name, color-coded by role in the selected group
                reaper.ImGui_TableSetColumnIndex(cx, 1)
                local isMaster, isSlave = false, false
                if uiState.selectedGroupNum and ti then
                    for _, gn in ipairs(ti.masterOf) do
                        if gn == uiState.selectedGroupNum then isMaster = true end
                    end
                    for _, gn in ipairs(ti.slaveOf) do
                        if gn == uiState.selectedGroupNum then isSlave = true end
                    end
                end
                local nameCol = isMaster and COL_MASTER or (isSlave and COL_SLAVE or nil)
                if nameCol then
                    reaper.ImGui_PushStyleColor(cx, reaper.ImGui_Col_Text(), nameCol)
                end
                reaper.ImGui_Text(cx, name)
                if nameCol then reaper.ImGui_PopStyleColor(cx) end

                -- Right-click context menu
                if reaper.ImGui_BeginPopupContextItem(cx, "##ctx" .. guid) then
                    reaper.ImGui_TextDisabled(cx, name)
                    reaper.ImGui_Separator(cx)
                    if reaper.ImGui_MenuItem(cx, "Set as VCA Master (new group)") then
                        uiState.createVcaMode          = 1
                        uiState.createVcaMasterGuid    = guid
                        uiState.createVcaNameBuf       = name
                        uiState._createDialogFocusDone = false
                        uiState.showCreateDialog       = true
                    end
                    if hasGroup then
                        local g = state.groups[uiState.selectedGroupNum]
                        reaper.ImGui_Separator(cx)
                        if not isSlave then
                            if reaper.ImGui_MenuItem(cx, "Add to <<" .. g.logicalName .. ">> as slave") then
                                local t2 = R.getTrackByGUID(guid)
                                if t2 then
                                    VCA.addSlaves(uiState.selectedGroupNum, g.masterGuid, {t2})
                                    setStatus(uiState, name .. " added as slave.")
                                    onMutate()
                                end
                            end
                        else
                            if reaper.ImGui_MenuItem(cx, "Remove from <<" .. g.logicalName .. ">>") then
                                local t2 = R.getTrackByGUID(guid)
                                if t2 then
                                    VCA.removeSlaves(uiState.selectedGroupNum, {t2})
                                    setStatus(uiState, name .. " removed.")
                                    onMutate()
                                end
                            end
                        end
                    end
                    reaper.ImGui_EndPopup(cx)
                end

                -- Role summary column
                reaper.ImGui_TableSetColumnIndex(cx, 2)
                if ti then
                    local parts = {}
                    if #ti.masterOf > 0 then
                        local ns = {}
                        for _, gn in ipairs(ti.masterOf) do ns[#ns + 1] = tostring(gn) end
                        parts[#parts + 1] = "M:" .. table.concat(ns, ",")
                    end
                    if #ti.slaveOf > 0 then
                        local ns = {}
                        for _, gn in ipairs(ti.slaveOf) do ns[#ns + 1] = tostring(gn) end
                        parts[#parts + 1] = "S:" .. table.concat(ns, ",")
                    end
                    reaper.ImGui_TextDisabled(cx,
                        #parts > 0 and table.concat(parts, " ") or "-")
                else
                    reaper.ImGui_TextDisabled(cx, "-")
                end
            end
        end
        reaper.ImGui_EndTable(cx)
    end

    reaper.ImGui_EndChild(cx)
end

-- ── Manager: three-column layout ─────────────────────────────────────────────

function Panels.manager(cx, state, uiState, onMutate)
    local L = computeLayout(cx)
    Panels.leftPanel(cx, state, uiState, L, onMutate)
    reaper.ImGui_SameLine(cx, 0, GAP)
    Panels.centrePanel(cx, state, uiState, L, onMutate)
    reaper.ImGui_SameLine(cx, 0, GAP)
    Panels.rightPanel(cx, state, uiState, L, onMutate)
end


-- =============================================================================
-- 10. MAIN LOOP
-- =============================================================================

local AppState = {
    projectState    = nil,
    uiState         = nil,
    lastChangeCount = -1,
    frameCount      = 0,
    ctx             = nil,
    needRefresh     = true,
}

-- Rebuilds the cached project state from scratch.
local function doRefresh()
    AppState.projectState = Scanner.scan()
    local issues = Audit.run(AppState.projectState)
    AppState.projectState.auditIssues = issues
    Audit.annotateState(AppState.projectState, issues)
    -- Attach issues to their TrackInfo records for inline display
    for _, ti in pairs(AppState.projectState.trackMap) do ti.issues = {} end
    for _, issue in ipairs(issues) do
        if issue.targetGuid then
            local ti = AppState.projectState.trackMap[issue.targetGuid]
            if ti then ti.issues[#ti.issues + 1] = issue end
        end
    end
    AppState.lastChangeCount = R.getProjectStateChangeCount()
    AppState.needRefresh     = false
end

-- Creates a VCA group from the dialog inputs and clears checked tracks.
local function handleCreateNewVCA(state, uiState, groupName, mode, masterGuid, onMutate)
    local slaveTracks = {}
    for guid in pairs(uiState.checkedTrackGuids) do
        local t = R.getTrackByGUID(guid)
        if t and guid ~= masterGuid then slaveTracks[#slaveTracks + 1] = t end
    end

    local groupNum, _, err
    if mode == 1 and masterGuid then
        local mt = R.getTrackByGUID(masterGuid)
        if not mt then
            setStatus(uiState, "Error: master track not found.")
            return
        end
        groupNum, _, err = VCA.createGroupFromExisting(state, mt, slaveTracks, groupName)
    else
        groupNum, _, err = VCA.createGroup(state, slaveTracks, groupName)
    end

    if err then
        setStatus(uiState, "Error: " .. err)
        return
    end

    setStatus(uiState, "VCA '" .. groupName .. "' created (" .. #slaveTracks .. " slave(s)).")
    uiState.checkedTrackGuids   = {}
    uiState.selectedGroupNum    = groupNum
    uiState.editNameBuf         = groupName
    uiState.createVcaMasterGuid = nil
    onMutate()
end

local function mainLoop()
    local cx = AppState.ctx
    if not reaper.ValidatePtr(cx, "ImGui_Context*") then return end

    AppState.frameCount = AppState.frameCount + 1
    local ui = AppState.uiState

    -- Detect project changes made outside this script
    if AppState.frameCount % REFRESH_INTERVAL == 0 then
        if R.getProjectStateChangeCount() ~= AppState.lastChangeCount then
            AppState.needRefresh = true
        end
    end

    if AppState.needRefresh then doRefresh() end

    local function onMutate() AppState.needRefresh = true end
    local state = AppState.projectState

    reaper.ImGui_SetNextWindowSize(cx, 960, 680, reaper.ImGui_Cond_FirstUseEver())
    local visible, open = reaper.ImGui_Begin(cx,
        SCRIPT_NAME .. " v" .. SCRIPT_VERSION, true, WINDOW_FLAGS)

    if not open then
        ui.windowOpen = false
        reaper.ImGui_End(cx)
        return
    end

    if visible then
        Panels.toolbar(cx, state, ui,
            function() AppState.needRefresh = true end,
            function(name, mode, masterGuid)
                handleCreateNewVCA(state, ui, name, mode, masterGuid, onMutate)
            end)

        reaper.ImGui_Separator(cx)
        Panels.manager(cx, state, ui, onMutate)
        renderStatusBar(cx, ui)
    end

    reaper.ImGui_End(cx)

    if ui.windowOpen then
        reaper.defer(mainLoop)
    end
end

local function init()
    if not reaper.ImGui_CreateContext then
        reaper.ShowMessageBox(
            "ReaImGui is required.\nInstall via ReaPack.", SCRIPT_NAME, 0)
        return
    end
    local cx = reaper.ImGui_CreateContext(SCRIPT_NAME)
    _G.SK_VCA_CTX    = cx
    AppState.ctx     = cx
    AppState.uiState = UI.init()
    AppState.needRefresh = true
    reaper.defer(mainLoop)
end

init()
