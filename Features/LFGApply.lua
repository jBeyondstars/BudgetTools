local _, ns = ...
local L, UI, Util = ns.L, ns.UI, ns.Util

-- One-click application in the Looking For Group browser (LFGBrowseFrame):
-- an "Apply" button whispers a prepared message to the leader of the
-- selected group, and Shift-click on a group does the same in one go.
--
-- The window is Blizzard's: nothing in it is called or written to. The
-- addon only adds its own buttons, reads the search results, and post-hooks
-- (hooksecurefunc / HookScript) so Blizzard's code keeps running untainted.

local KEY = "lfgApply"
local MAX_LETTERS = 200 -- template length in the editor
local MAX_BYTES = 255   -- a chat message
local RESEND_DELAY = 2  -- seconds: a double click sends one whisper
local CHECK = "Interface\\RaidFrame\\ReadyCheck-Ready"
local EDIT_ICON = "Interface\\Buttons\\UI-GuildButton-PublicNote-Up"
local EDITOR_NAME = "BudgetForeverLFGMessage"
local EDITOR_ICON = "Interface\\Icons\\INV_Letter_15"

local LFG = {}
ns.LFGApply = LFG

local attached = false
local applyButton, editButton, editor
local selectedFromHook
local lastSent = 0
local applied = {}                               -- lower-case leader -> time()
local hookedRows = setmetatable({}, { __mode = "k" })
local marks = setmetatable({}, { __mode = "k" }) -- row -> check texture

---------------------------------------------------------------------------
-- Reading the search results (every value can be secret on this client)
---------------------------------------------------------------------------

local function Flag(value)
    return Util.Readable(value) and value == true
end

local function ResultInfo(resultID)
    if not Util.Readable(resultID) or not resultID then return end
    if not C_LFGList or not C_LFGList.GetSearchResultInfo then return end
    local ok, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
    if ok and Util.ReadableTable(info) then return info end
end

local function LeaderName(info)
    local name = info and info.leaderName
    if Util.Readable(name) and type(name) == "string" and name ~= "" then return name end
end

local function CanApply(info)
    return info ~= nil and LeaderName(info) ~= nil
        and not Flag(info.isDelisted) and not Flag(info.hasSelf)
end

local function HasApplied(info)
    local leader = LeaderName(info)
    return leader ~= nil and applied[strlower(leader)] ~= nil
end

-- "Scarlet Monastery" or "SM Library / SM Armory" for a multi-activity listing.
local function ActivityText(info)
    local ids = info and info.activityIDs
    if not Util.ReadableTable(ids) then
        local single = info and info.activityID
        ids = Util.Readable(single) and single and { single } or nil
    end
    if not ids or not C_LFGList or not C_LFGList.GetActivityInfoTable then return end

    local names, total = {}, 0
    for _, id in ipairs(ids) do
        total = total + 1
        if #names < 3 then
            local ok, activity = pcall(C_LFGList.GetActivityInfoTable, id)
            if ok and Util.ReadableTable(activity) then
                local name = activity.fullName
                if #ids > 1 and Util.Readable(activity.shortName) and activity.shortName and activity.shortName ~= "" then
                    name = activity.shortName
                end
                if Util.Readable(name) and type(name) == "string" and name ~= "" then
                    names[#names + 1] = name
                end
            end
        end
    end
    if #names == 0 then return end
    local text = table.concat(names, " / ")
    if total > #names then text = text .. "..." end
    return text
end

-- "tank", "heal/dps"... from the roles ticked in the group finder.
local function MyRoles()
    if not C_LFGListRoles or not C_LFGListRoles.GetRoles then return "" end
    local ok, roles = pcall(C_LFGListRoles.GetRoles)
    if not ok or not Util.ReadableTable(roles) then return "" end
    local words = {}
    if Flag(roles.tank) then words[#words + 1] = "tank" end
    if Flag(roles.healer) then words[#words + 1] = "heal" end
    if Flag(roles.dps) then words[#words + 1] = "dps" end
    return table.concat(words, "/")
end

---------------------------------------------------------------------------
-- The message
---------------------------------------------------------------------------

LFG.TOKENS = { "class", "level", "role", "dungeon", "leader" }
local TOKEN_TIPS = {
    class = "LFG_TOKEN_CLASS", level = "LFG_TOKEN_LEVEL", role = "LFG_TOKEN_ROLE",
    dungeon = "LFG_TOKEN_DUNGEON", leader = "LFG_TOKEN_LEADER",
}
local ALIASES = { classe = "class", niveau = "level", lvl = "level", ["rôle"] = "role", donjon = "dungeon", chef = "leader" }

-- Single line, no "|" (WoW escape codes), no control characters.
local function CleanTemplate(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("[\r\n]+", " "):gsub("|", ""):gsub("%c", "")
    text = strtrim((text:gsub("%s+", " ")))
    return text
end

-- Cuts to `max` bytes without leaving half a UTF-8 character.
local function CapBytes(text, max)
    if #text <= max then return text end
    text = text:sub(1, max)
    local last = #text
    local i = last
    while i > 0 and text:byte(i) >= 128 and text:byte(i) < 192 do i = i - 1 end
    if i > 0 then
        local lead = text:byte(i)
        local need = (lead >= 240 and 4) or (lead >= 224 and 3) or (lead >= 192 and 2) or 1
        if last - i + 1 < need then text = text:sub(1, i - 1) end
    end
    return text
end

function LFG.GetTemplate()
    local saved = ns.db and ns.db.lfg and ns.db.lfg.message
    if type(saved) == "string" and saved ~= "" then return saved end
end

function LFG.SetTemplate(text)
    if not ns.db then return end
    ns.db.lfg = ns.db.lfg or {}
    text = CleanTemplate(text)
    ns.db.lfg.message = text ~= "" and text or nil
    LFG.RefreshAll()
end

-- Values for one group. Without `info` (the editor preview with nothing
-- selected) the group values are examples.
local function TokenValues(info)
    local className = UnitClass("player")
    local level = UnitLevel("player")
    local leader = info and LeaderName(info)
    return {
        class = Util.Readable(className) and className or "",
        level = Util.Readable(level) and tostring(level) or "",
        role = MyRoles(),
        dungeon = (info and ActivityText(info)) or L.LFG_SAMPLE_DUNGEON,
        leader = (leader and (Util.DisplayName(leader) or leader)) or L.LFG_SAMPLE_LEADER,
    }
end

function LFG.Expand(template, info)
    if type(template) ~= "string" or template == "" then return "" end
    local values = TokenValues(info)
    local text = template:gsub("{([^{}]+)}", function(token)
        token = strlower(strtrim(token))
        local value = values[ALIASES[token] or token]
        if value ~= nil then return value end
    end)
    -- An empty {role} must not leave "Priest  lvl 32" or "heal ,".
    text = text:gsub("%s+", " ")
    text = text:gsub(" ([,%.!%?;:])", "%1")
    return CapBytes(strtrim(text), MAX_BYTES)
end

---------------------------------------------------------------------------
-- Applying
---------------------------------------------------------------------------

local function SelectedResult()
    local browse = _G.LFGBrowseFrame
    local behavior = browse and browse.selectionBehavior
    if behavior and behavior.HasSelection and behavior.GetSelectedElementData then
        local ok, resultID = pcall(function()
            if not behavior:HasSelection() then return nil end
            local data = behavior:GetSelectedElementData()
            local first = data and data[1]
            return first and first.resultID
        end)
        if ok then return resultID end
    end
    return selectedFromHook
end

function LFG.Apply(resultID)
    if not ns:IsEnabled(KEY) then return end
    local info = ResultInfo(resultID)
    if not info or Flag(info.isDelisted) then
        ns:Error(L.LFG_ERROR_GONE)
        return
    end
    if Flag(info.hasSelf) then return end
    local leader = LeaderName(info)
    if not leader then
        ns:Error(L.LFG_ERROR_LEADER)
        return
    end

    local template = LFG.GetTemplate()
    if not template then
        LFG.OpenEditor() -- first use: write the message first
        return
    end
    local now = GetTime()
    if now - lastSent < RESEND_DELAY then return end
    local text = LFG.Expand(template, info)
    if text == "" then
        LFG.OpenEditor()
        return
    end

    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    local ok, err = pcall(send, text, "WHISPER", nil, leader)
    if not ok then
        ns:Error(L.LFG_ERROR_SEND)
        geterrorhandler()(err)
        return
    end
    lastSent = now
    applied[strlower(leader)] = time()
    UI.PlayClick()
    LFG.RefreshAll()
end

---------------------------------------------------------------------------
-- Buttons in the browser
---------------------------------------------------------------------------

local function ShowApplyTooltip(button)
    GameTooltip:SetOwner(button, "ANCHOR_TOP")
    GameTooltip:SetText(L.LFG_BUTTON, 1, 0.82, 0)
    local info = ResultInfo(SelectedResult())
    local template = LFG.GetTemplate()
    if CanApply(info) and template then
        GameTooltip:AddLine(L.LFG_TIP_SEND:format(Util.DisplayName(LeaderName(info)) or LeaderName(info)), 1, 1, 1, true)
        GameTooltip:AddLine(LFG.Expand(template, info), 0.6, 0.8, 1, true)
    elseif not template then
        GameTooltip:AddLine(L.LFG_TIP_NO_MESSAGE, 1, 1, 1, true)
    else
        GameTooltip:AddLine(L.LFG_TIP_SELECT, 1, 1, 1, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L.LFG_TIP_EDIT, unpack(UI.MUTED))
    if ns:GetOption(KEY, "shiftClick") then
        GameTooltip:AddLine(L.LFG_TIP_SHIFT, unpack(UI.MUTED))
    end
    GameTooltip:Show()
end

-- Between Blizzard's "Send Message" and "Group Invite" when there is room
-- (105 px on the classic layout), above "Send Message" otherwise.
local function LayoutButtons()
    local browse = _G.LFGBrowseFrame
    if not applyButton or not browse then return end
    local left, right = browse.SendMessageButton, browse.GroupInviteButton
    local gap
    if left and right and left:GetRight() and right:GetLeft() then
        gap = right:GetLeft() - left:GetRight()
    end

    applyButton:ClearAllPoints()
    editButton:ClearAllPoints()
    if left and gap and gap >= 64 then
        local withEdit = gap >= 100
        applyButton:SetWidth(math.min(110, gap - 8 - (withEdit and 24 or 0)))
        applyButton:SetPoint("LEFT", left, "RIGHT", 4, 0)
        editButton:SetPoint("LEFT", applyButton, "RIGHT", 2, 0)
        editButton:SetShown(withEdit and ns:IsEnabled(KEY))
    else
        applyButton:SetWidth(100)
        if left then
            applyButton:SetPoint("BOTTOMLEFT", left, "TOPLEFT", 0, 4)
        else
            applyButton:SetPoint("BOTTOMLEFT", browse, "BOTTOMLEFT", 20, 104)
        end
        editButton:SetPoint("LEFT", applyButton, "RIGHT", 2, 0)
        editButton:SetShown(ns:IsEnabled(KEY))
    end
end

function LFG.RefreshButton()
    if not applyButton then return end
    local on = ns:IsEnabled(KEY)
    applyButton:SetShown(on)
    if not on then
        editButton:Hide()
        return
    end
    local info = ResultInfo(SelectedResult())
    applyButton:SetText(HasApplied(info) and L.LFG_BUTTON_AGAIN or L.LFG_BUTTON)
    applyButton:SetEnabled(CanApply(info))
    if applyButton:IsMouseOver() and GameTooltip:IsOwned(applyButton) then ShowApplyTooltip(applyButton) end
end

local function CreateButtons(browse)
    applyButton = CreateFrame("Button", "BudgetForeverLFGApplyButton", browse, "UIPanelButtonTemplate")
    applyButton:SetSize(100, 22)
    applyButton:SetText(L.LFG_BUTTON)
    applyButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    applyButton:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            LFG.OpenEditor()
        else
            LFG.Apply(SelectedResult())
        end
    end)
    applyButton:SetScript("OnEnter", ShowApplyTooltip)
    applyButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- A disabled button gets no OnEnter: keep the hint about selecting.
    if applyButton.SetMotionScriptsWhileDisabled then applyButton:SetMotionScriptsWhileDisabled(true) end

    editButton = CreateFrame("Button", nil, browse)
    editButton:SetSize(22, 22)
    editButton:SetNormalTexture(EDIT_ICON)
    editButton:SetHighlightTexture(EDIT_ICON, "ADD")
    editButton:SetScript("OnClick", function()
        UI.PlayClick()
        LFG.OpenEditor()
    end)
    editButton:SetScript("OnEnter", function(self)
        UI.ShowTooltip(self, L.LFG_EDITOR_TITLE, L.LFG_EDIT_TIP)
    end)
    editButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    LayoutButtons()
end

---------------------------------------------------------------------------
-- Rows: green check on groups already contacted, Shift-click to apply
---------------------------------------------------------------------------

local function OnRowClick(row, button)
    if button ~= "LeftButton" or not IsShiftKeyDown() then return end
    if not ns:IsEnabled(KEY) or not ns:GetOption(KEY, "shiftClick") then return end
    LFG.Apply(row.resultID)
end

local function DecorateRow(row)
    if not row then return end
    if not hookedRows[row] and row.HookScript then
        hookedRows[row] = true
        row:HookScript("OnClick", OnRowClick)
    end

    local show = ns:IsEnabled(KEY) and ns:GetOption(KEY, "markApplied") and HasApplied(ResultInfo(row.resultID))
    local mark = marks[row]
    if show and not mark then
        mark = row:CreateTexture(nil, "OVERLAY")
        mark:SetSize(14, 14)
        mark:SetTexture(CHECK)
        if row.ActivityName then
            mark:SetPoint("LEFT", row.ActivityName, "RIGHT", 4, 0)
        else
            mark:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 10, 4)
        end
        marks[row] = mark
    end
    if mark then mark:SetShown(show and true or false) end
end

function LFG.RefreshAll()
    LFG.RefreshButton()
    if applyButton then LayoutButtons() end
    local scrollBox = _G.LFGBrowseFrame and LFGBrowseFrame.ScrollBox
    if scrollBox and scrollBox.ForEachFrame then
        pcall(scrollBox.ForEachFrame, scrollBox, DecorateRow)
    end
    if editor and editor:IsShown() and editor.UpdatePreview then editor.UpdatePreview() end
end

local function Attach()
    if attached then return true end
    local browse = _G.LFGBrowseFrame
    if not browse then return false end
    attached = true

    CreateButtons(browse)
    if type(browse.UpdateButtonState) == "function" then
        hooksecurefunc(browse, "UpdateButtonState", LFG.RefreshButton)
    end
    if type(_G.LFGBrowseSearchEntry_Update) == "function" then
        hooksecurefunc("LFGBrowseSearchEntry_Update", DecorateRow)
    end
    if type(_G.LFGBrowseSearchEntry_SetSelection) == "function" then
        hooksecurefunc("LFGBrowseSearchEntry_SetSelection", function(row, selected)
            if selected and row then selectedFromHook = row.resultID end
            LFG.RefreshButton()
        end)
    end
    -- Positions are only known once the window is drawn.
    browse:HookScript("OnShow", function() C_Timer.After(0, LFG.RefreshAll) end)
    LFG.RefreshAll()
    return true
end

---------------------------------------------------------------------------
-- Message editor
---------------------------------------------------------------------------

local function SaveEditor()
    if not editor or not editor:IsShown() then return end
    LFG.SetTemplate(editor.edit:GetText())
    editor:Hide()
end

local function BuildEditor()
    editor = UI.CreateWindow(EDITOR_NAME, 440, 300, EDITOR_ICON)
    editor:SetFrameStrata("DIALOG")
    editor:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    editor:SetScript("OnShow", function() PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN) end)
    editor:SetScript("OnHide", function()
        editor.edit:ClearFocus()
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
    end)

    local hint = editor:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 66, -32)
    hint:SetPoint("TOPRIGHT", -16, -32)
    hint:SetJustifyH("LEFT")
    hint:SetTextColor(unpack(UI.MUTED))
    UI.Localize(hint, "LFG_EDITOR_HINT")

    local inset = UI.CreateInset(editor)
    inset:SetPoint("TOPLEFT", 6, -60)
    inset:SetPoint("BOTTOMRIGHT", -6, 36)

    local label = inset:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", 14, -12)
    UI.Localize(label, "LFG_EDITOR_MESSAGE")

    editor.counter = inset:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    editor.counter:SetPoint("TOPRIGHT", -14, -14)

    local box = CreateFrame("Frame", nil, inset, "BackdropTemplate")
    box:SetPoint("TOPLEFT", 12, -30)
    box:SetPoint("TOPRIGHT", -12, -30)
    box:SetHeight(28)
    UI.ApplyFlat(box, { 0, 0, 0, 0.45 }, { 1, 1, 1, 0.14 })
    box:EnableMouse(true)

    local edit = CreateFrame("EditBox", nil, box)
    edit:SetPoint("TOPLEFT", 8, -4)
    edit:SetPoint("BOTTOMRIGHT", -8, 4)
    edit:SetAutoFocus(false)
    edit:SetFontObject("ChatFontNormal")
    edit:SetTextColor(1, 1, 1)
    edit:SetMaxLetters(MAX_LETTERS)
    editor.edit = edit

    local tokensLabel = inset:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tokensLabel:SetPoint("TOPLEFT", 14, -74)
    UI.Localize(tokensLabel, "LFG_EDITOR_TOKENS")

    local previous
    for _, token in ipairs(LFG.TOKENS) do
        local text = "{" .. token .. "}"
        local button = CreateFrame("Button", nil, inset, "UIPanelButtonTemplate")
        button:SetText(text)
        button:SetSize(math.ceil((button:GetFontString() and button:GetFontString():GetStringWidth() or 60)) + 18, 20)
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
        else
            button:SetPoint("TOPLEFT", 12, -92)
        end
        button:SetScript("OnClick", function()
            UI.PlayClick()
            edit:SetFocus()
            edit:Insert(text)
        end)
        button:SetScript("OnEnter", function(self)
            local example = TokenValues(ResultInfo(SelectedResult()))[token]
            UI.ShowTooltip(self, text, L[TOKEN_TIPS[token]],
                example ~= "" and L.LFG_TOKEN_EXAMPLE:format(example) or nil, UI.GREEN)
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
        previous = button
    end

    local previewLabel = inset:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    previewLabel:SetPoint("TOPLEFT", 14, -126)
    UI.Localize(previewLabel, "LFG_EDITOR_PREVIEW")

    editor.preview = inset:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    editor.preview:SetPoint("TOPLEFT", 14, -146)
    editor.preview:SetPoint("TOPRIGHT", -14, -146)
    editor.preview:SetJustifyH("LEFT")
    editor.preview:SetJustifyV("TOP")
    editor.preview:SetWordWrap(true)

    function editor.UpdatePreview()
        local text = CleanTemplate(edit:GetText())
        local count = edit.GetNumLetters and edit:GetNumLetters() or #edit:GetText()
        editor.counter:SetText(("%d / %d"):format(count, MAX_LETTERS))
        local info = ResultInfo(SelectedResult())
        local leader = CanApply(info) and LeaderName(info) or L.LFG_SAMPLE_LEADER
        if text == "" then
            editor.preview:SetText("|cff808080" .. L.LFG_EDITOR_EMPTY .. "|r")
        else
            editor.preview:SetText(("|cffff80ff%s|r %s"):format(
                L.LFG_PREVIEW_TO:format(Util.DisplayName(leader) or leader),
                LFG.Expand(text, CanApply(info) and info or nil)))
        end
    end

    box:SetScript("OnMouseDown", function() edit:SetFocus() end)
    edit:SetScript("OnEscapePressed", function() editor:Hide() end)
    edit:SetScript("OnEnterPressed", SaveEditor)
    edit:SetScript("OnTextChanged", function() editor.UpdatePreview() end)
    edit:SetScript("OnEditFocusGained", function() box:SetBackdropBorderColor(1, 0.82, 0, 0.6) end)
    edit:SetScript("OnEditFocusLost", function() box:SetBackdropBorderColor(1, 1, 1, 0.14) end)

    -- After SetScript: SetScript drops hooks added before it.
    local placeholder = edit:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    placeholder:SetPoint("LEFT", 0, 0)
    placeholder:SetPoint("RIGHT", 0, 0)
    placeholder:SetJustifyH("LEFT")
    placeholder:SetWordWrap(false)
    UI.Localize(placeholder, "LFG_EDITOR_PLACEHOLDER")
    local function UpdatePlaceholder() placeholder:SetShown(edit:GetText() == "") end
    edit:HookScript("OnTextChanged", UpdatePlaceholder)
    edit:HookScript("OnShow", UpdatePlaceholder)

    editor.save = UI.CreateButton(editor, "BUTTON_SAVE", 110)
    editor.save:SetPoint("BOTTOMRIGHT", -8, 7)
    editor.save:SetScript("OnClick", SaveEditor)

    editor.cancel = UI.CreateButton(editor, "BUTTON_CANCEL", 110)
    editor.cancel:SetPoint("RIGHT", editor.save, "LEFT", -6, 0)
    editor.cancel:SetScript("OnClick", function() editor:Hide() end)
end

function LFG.OpenEditor()
    if not editor then BuildEditor() end
    editor:SetWindowTitle(L.LFG_EDITOR_TITLE)
    local template = LFG.GetTemplate()
    editor.edit:SetText(template or L.LFG_DEFAULT_MESSAGE)
    editor.UpdatePreview()
    editor:Show()
    editor:Raise()
    editor.edit:SetFocus()
    if not template then
        editor.edit:HighlightText() -- typing replaces the suggestion
    else
        editor.edit:SetCursorPosition(#editor.edit:GetText())
    end
end

function LFG.CloseEditor()
    if editor then editor:Hide() end
end

---------------------------------------------------------------------------
-- Enable / disable
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(self)
    -- The browser is a load-on-demand Blizzard addon: wait for it.
    if Attach() then self:UnregisterEvent("ADDON_LOADED") end
end)

local function Enable()
    if not Attach() then events:RegisterEvent("ADDON_LOADED") end
    LFG.RefreshAll()
end

local function Disable()
    LFG.CloseEditor()
    LFG.RefreshAll()
end

ns:On("OPTION_CHANGED", function(key)
    if key == KEY then LFG.RefreshAll() end
end)

ns:On("LANGUAGE_CHANGED", function()
    if editor then editor:SetWindowTitle(L.LFG_EDITOR_TITLE) end
    LFG.RefreshAll()
end)

ns:RegisterFeature({
    key = KEY,
    category = "social",
    order = 30,
    title = "LFG_TITLE",
    desc = "LFG_DESC",
    tip = "LFG_TIP",
    default = true,
    isNew = true,
    options = {
        { key = "shiftClick", title = "LFG_OPT_SHIFT", tip = "LFG_OPT_SHIFT_TIP", default = true },
        { key = "markApplied", title = "LFG_OPT_MARK", tip = "LFG_OPT_MARK_TIP", default = true },
        { key = "editMessage", title = "LFG_OPT_EDIT", tip = "LFG_OPT_EDIT_TIP", action = function() LFG.OpenEditor() end },
    },
    OnEnable = Enable,
    OnDisable = Disable,
})
