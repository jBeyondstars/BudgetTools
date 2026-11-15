local _, ns = ...
local L, UI = ns.L, ns.UI
local Chain = ns.QuestChain

--[[
The quest chain window (Features\QuestChain.lua opens it).

Top: the chain, one line per quest, in order. A check marks a quest you
did, an arrow one in your log, a dot one to come; the quest the window was
opened from is in white.
Bottom: the quest clicked in the list. Its objective, who gives it and who
takes it, each with a button that shows them on the map through the NPC
finder (Shift: a TomTom arrow too).

It is a window of its own, so it stays up when the map moves to another
zone, which closes Blizzard's quest details. While it is open it follows
the quest whose details you open, and quests done or taken update it.
]]

local Panel = {}
ns.QuestChainUI = Panel

local WINDOW_NAME = "BudgetForeverQuestChain"
local ICON = "Interface\\Icons\\INV_Misc_Book_09"
local WIDTH, HEIGHT = 360, 520
local LIST_HEIGHT = 196
local ROW_HEIGHT = 20
local LIST_WIDTH = WIDTH - 12 - 38   -- insets on both sides, the scroll bar
local INFO_WIDTH = WIDTH - 12 - 42
local HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"

local MARKS = {
    done = "Interface\\RaidFrame\\ReadyCheck-Ready",
    ready = "Interface\\ChatFrame\\ChatFrameExpandArrow",
    log = "Interface\\ChatFrame\\ChatFrameExpandArrow",
    todo = "Interface\\QuestFrame\\UI-Quest-BulletPoint",
}
local STATE_TEXT = {
    done = "QUESTCHAIN_STATE_DONE",
    ready = "QUESTCHAIN_STATE_READY",
    log = "QUESTCHAIN_STATE_LOG",
    todo = "QUESTCHAIN_STATE_TODO",
}
local WHITE = { 1, 1, 1 }
local STATE_COLOR = {
    done = { 0.55, 0.55, 0.55 },
    ready = { 1, 0.82, 0 },
    log = { 1, 0.82, 0 },
    todo = { 0.85, 0.85, 0.85 },
}

local window
local rootID       -- the quest the window was opened from
local selectedID   -- the quest clicked in the list
local Render

---------------------------------------------------------------------------
-- List
---------------------------------------------------------------------------

local function Select(self)
    UI.PlayClick()
    selectedID = self.questID
    Render()
end

local function Row(index)
    local row = window.rows[index]
    if row then return row end
    row = CreateFrame("Button", nil, window.child)
    row:SetSize(LIST_WIDTH, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetHighlightTexture(HIGHLIGHT, "ADD")
    row.selected = row:CreateTexture(nil, "BACKGROUND")
    row.selected:SetAllPoints()
    row.selected:SetColorTexture(1, 0.82, 0, 0.18)
    row.mark = row:CreateTexture(nil, "ARTWORK")
    row.mark:SetSize(14, 14)
    row.mark:SetPoint("LEFT", 4, 0)
    row.level = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    row.level:SetPoint("RIGHT", -6, 0)
    row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.text:SetPoint("LEFT", row.mark, "RIGHT", 5, 0)
    row.text:SetPoint("RIGHT", row.level, "LEFT", -6, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    row:SetScript("OnClick", Select)
    window.rows[index] = row
    return row
end

local function FillRow(row, line)
    row.questID = line.id
    row.mark:SetTexture(MARKS[line.state])
    row.text:SetText(line.step .. ". " .. line.name)
    local color = line.current and WHITE or STATE_COLOR[line.state]
    row.text:SetTextColor(color[1], color[2], color[3])
    row.level:SetText(line.level > 0 and tostring(line.level) or "")
    row.selected:SetShown(line.id == selectedID)
    row:Show()
end

---------------------------------------------------------------------------
-- The quest clicked in the list
---------------------------------------------------------------------------

local function ShowGiver(self)
    UI.PlayClick()
    Chain.ShowGiver(self.giver, IsShiftKeyDown())
end

local function GiverTooltip(self)
    if not self.giver or not self.giver.hit then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L.QUESTCHAIN_SHOW_MAP, 1, 0.82, 0)
    GameTooltip:AddLine(L.QUESTCHAIN_SHOW_MAP_TIP, 1, 1, 1, true)
    GameTooltip:Show()
end

-- A "Starts at" / "Turn in" block: a header, "Name, Zone", a button.
local function CreateGiver(parent, header)
    local block = {}
    block.header = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    block.header:SetJustifyH("LEFT")
    UI.Localize(block.header, header)
    block.text = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    block.text:SetWidth(INFO_WIDTH)
    block.text:SetJustifyH("LEFT")
    -- Its label depends on the giver (the map, or the item finder): set when filled.
    block.button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    block.button:SetSize(170, 22)
    block.button:SetScript("OnClick", ShowGiver)
    block.button:SetScript("OnEnter", GiverTooltip)
    block.button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return block
end

-- Places regions one under the other in the info area.
local function Stack(parent)
    local y = 0
    return function(region, gap, height)
        y = y + (gap or 0)
        region:ClearAllPoints()
        region:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -y)
        region:Show()
        y = y + (height or region:GetHeight())
    end, function() return y end
end

local function FillGiver(block, giver, place)
    if not giver then
        block.header:Hide()
        block.text:Hide()
        block.button:Hide()
        return
    end
    place(block.header, 12, block.header:GetStringHeight())
    block.text:SetText(giver.where and (giver.name .. ", " .. giver.where) or giver.name)
    place(block.text, 3, block.text:GetStringHeight())
    block.button.giver = giver
    block.button:SetText(giver.item and L.QUESTCHAIN_FIND_ITEM or L.QUESTCHAIN_SHOW_MAP)
    -- A giver nobody knows the place of: nothing to show.
    if giver.item or giver.hit.map then
        place(block.button, 5)
    else
        block.button:Hide()
    end
end

local function FillInfo(quest)
    local info = window.info
    if not quest then
        window.infoScroll:Hide()
        return
    end
    window.infoScroll:Show()
    local place, used = Stack(info)

    info.name:SetText(quest.name)
    place(info.name, 0, info.name:GetStringHeight())

    local parts = { L[STATE_TEXT[quest.state]] }
    if quest.level > 0 then parts[#parts + 1] = L.QUESTCHAIN_QUEST_LEVEL:format(quest.level) end
    if quest.state == "todo" and quest.minLevel > (UnitLevel("player") or 0) then
        parts[#parts + 1] = "|cffff6060" .. L.QUESTCHAIN_AVAILABLE:format(quest.minLevel) .. "|r"
    end
    info.sub:SetText(table.concat(parts, "  |  "))
    place(info.sub, 4, info.sub:GetStringHeight())

    if quest.objective then
        place(info.objectiveHeader, 12, info.objectiveHeader:GetStringHeight())
        info.objective:SetText(quest.objective)
        place(info.objective, 3, info.objective:GetStringHeight())
    else
        info.objectiveHeader:Hide()
        info.objective:Hide()
    end

    FillGiver(info.start, quest.start, place)
    FillGiver(info.finish, quest.finish, place)
    info:SetHeight(math.max(1, used()))
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function ScrollFrame(parent)
    local template = UI.HasTemplate("ScrollFrameTemplate") and "ScrollFrameTemplate" or "UIPanelScrollFrameTemplate"
    return CreateFrame("ScrollFrame", nil, parent, template)
end

-- Beside the quest log when it is on screen (to its right when the screen
-- has room there, else to its left), else in the middle. Dragging it
-- afterwards is the player's business.
local function PlaceWindow()
    local log = QuestMapFrame
    local visible = log and log:IsVisible()
    local left, right, top = visible and log:GetLeft(), visible and log:GetRight(), visible and log:GetTop()
    if left and right and top then
        local ratio = log:GetEffectiveScale() / UIParent:GetEffectiveScale()
        if right * ratio + 6 + WIDTH <= (UIParent:GetWidth() or 0) then
            window:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", right * ratio + 6, top * ratio - 40)
        else
            window:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", left * ratio - 6, top * ratio - 40)
        end
    else
        window:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    end
end

local refreshQueued = false

local function OnQuestEvent()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0.3, function()
        refreshQueued = false
        Panel.Refresh()
    end)
end

local EVENTS = { "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN" }

local function Build()
    window = UI.CreateWindow(WINDOW_NAME, WIDTH, HEIGHT, ICON)
    window:SetFrameStrata("DIALOG")
    PlaceWindow()
    window:SetScript("OnShow", function(self)
        for _, event in ipairs(EVENTS) do self:RegisterEvent(event) end
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN)
    end)
    window:SetScript("OnHide", function(self)
        self:UnregisterAllEvents()
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
    end)
    window:SetScript("OnEvent", OnQuestEvent)

    window.step = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    window.step:SetPoint("TOPLEFT", 66, -30)
    window.step:SetPoint("TOPRIGHT", -16, -30)
    window.step:SetJustifyH("LEFT")
    window.step:SetWordWrap(false)
    window.step:SetTextColor(UI.MUTED[1], UI.MUTED[2], UI.MUTED[3])

    -- The chain
    local listInset = UI.CreateInset(window)
    listInset:SetPoint("TOPLEFT", 6, -64)
    listInset:SetPoint("TOPRIGHT", -6, -64)
    listInset:SetHeight(LIST_HEIGHT)
    window.scroll = ScrollFrame(listInset)
    window.scroll:SetPoint("TOPLEFT", 6, -6)
    window.scroll:SetPoint("BOTTOMRIGHT", -28, 6)
    window.child = CreateFrame("Frame", nil, window.scroll)
    window.child:SetSize(LIST_WIDTH, 1)
    window.scroll:SetScrollChild(window.child)
    window.rows = {}

    -- The quest clicked in it
    local infoInset = UI.CreateInset(window)
    infoInset:SetPoint("TOPLEFT", listInset, "BOTTOMLEFT", 0, -6)
    infoInset:SetPoint("BOTTOMRIGHT", -6, 8)
    window.infoScroll = ScrollFrame(infoInset)
    window.infoScroll:SetPoint("TOPLEFT", 12, -10)
    window.infoScroll:SetPoint("BOTTOMRIGHT", -28, 8)
    local info = CreateFrame("Frame", nil, window.infoScroll)
    info:SetSize(INFO_WIDTH, 1)
    window.infoScroll:SetScrollChild(info)
    window.info = info

    info.name = info:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    info.name:SetWidth(INFO_WIDTH)
    info.name:SetJustifyH("LEFT")
    info.sub = info:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    info.sub:SetWidth(INFO_WIDTH)
    info.sub:SetJustifyH("LEFT")
    info.sub:SetTextColor(UI.MUTED[1], UI.MUTED[2], UI.MUTED[3])
    info.objectiveHeader = info:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    info.objectiveHeader:SetJustifyH("LEFT")
    UI.Localize(info.objectiveHeader, "QUESTCHAIN_OBJECTIVE")
    info.objective = info:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    info.objective:SetWidth(INFO_WIDTH)
    info.objective:SetJustifyH("LEFT")
    info.start = CreateGiver(info, "QUESTCHAIN_STARTS_AT")
    info.finish = CreateGiver(info, "QUESTCHAIN_TURN_IN")
end

-- Scrolls the list so the line at `index` is in view, a few lines down.
local function ScrollTo(index)
    local scroll = window.scroll
    if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end
    local range = scroll:GetVerticalScrollRange() or 0
    local offset = (index - 4) * ROW_HEIGHT
    if offset > range then offset = range end
    if offset < 0 then offset = 0 end
    scroll:SetVerticalScroll(offset)
end

Render = function(scrollToQuest)
    local chain = rootID and Chain.Get(rootID)
    if not chain then
        -- The links aren't read (or no longer make a chain): nothing to list.
        window:Hide()
        return
    end
    window:SetWindowTitle(L.QUESTCHAIN_WINDOW)
    window.step:SetText(L.QUESTCHAIN_WINDOW_STEP:format(chain.step, chain.steps, chain.count))

    local lines = Chain.Lines(chain)
    local current, picked = 1, nil
    for index, line in ipairs(lines) do
        if line.current then current = index end
        if line.id == selectedID then picked = index end
    end
    if not picked then
        picked = current
        selectedID = lines[current] and lines[current].id
    end
    for index, line in ipairs(lines) do
        FillRow(Row(index), line)
    end
    for index = #lines + 1, #window.rows do window.rows[index]:Hide() end
    window.child:SetHeight(math.max(1, #lines * ROW_HEIGHT))
    if scrollToQuest then ScrollTo(picked) end

    FillInfo(selectedID and Chain.QuestInfo(selectedID))
end

---------------------------------------------------------------------------
-- For Features\QuestChain.lua
---------------------------------------------------------------------------

function Panel.IsOpen()
    return window ~= nil and window:IsShown()
end

-- Opens the window on the chain of a quest, that quest picked.
function Panel.Show(questID)
    if not window then Build() end
    local moved = questID ~= rootID or not window:IsShown()
    if moved then
        rootID, selectedID = questID, questID
    end
    window:Show()
    Render(moved)
end

-- Quests done or taken, or the language, changed.
function Panel.Refresh()
    if not Panel.IsOpen() then return end
    Chain.Reset()
    Render()
end

function Panel.Hide()
    if window then window:Hide() end
end
