local _, ns = ...
local L = ns.L
local UI = ns.UI
local Util = ns.Util

--[[
Recipes pinned on screen: drag a recipe name out of the professions window
and its reagents stay on screen in a small note, after the big window is
closed.

How the drag is caught:
  Nothing is hooked or changed on Blizzard's recipe rows. A small frame
  parented to ProfessionsFrame (so its OnUpdate only runs while the window is
  shown) watches the left mouse button. A press on a recipe row of the
  crafting page, then a move of a few pixels with the button held, starts our
  own drag: a label with the recipe follows the cursor. Released outside
  ProfessionsFrame, it becomes a note right where the label was. Released
  over the window, nothing happens. Blizzard's row only sees a normal press,
  so a press released on the same row still selects the recipe.
  Leaving the rows alone keeps Blizzard's profession code free of addon
  taint; its Create buttons call crafting functions.

What a note keeps:
  The reagents are read once, when the recipe is pinned, from
  C_TradeSkillUI.GetRecipeSchematic (basic reagent slots, as listed under the
  recipe in the window). They are saved per character in
  BudgetForeverDB.recipes, kept by /bf reset, so notes come back after a
  reload or a relog and need no profession window. The counts in your bags
  and bank are read live. A ×N multiplier (− and + buttons, mouse wheel,
  Shift for 10 at a time) scales them to the number of crafts you want.
]]

local KEY = "recipeNotes"

local Notes = {}
ns.RecipeNotes = Notes

local NOTE_WIDTH = 250
local HEADER_HEIGHT = 46
local MAX_TIMES = 999           -- the ×N multiplier goes from 1 to this
local ROW_HEIGHT = 18
local PADDING = 9
local DRAG_THRESHOLD = 10       -- UI pixels the cursor moves, button held, before a press becomes a drag
local GHOST_X, GHOST_Y = 14, -6 -- where the dragged label sits from the cursor; the note lands there
local QUESTION = 134400         -- INV_Misc_QuestionMark
local HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"
local BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local GetInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
local GetCount = (C_Item and C_Item.GetItemCount) or GetItemCount
local GetQualityColor = (C_Item and C_Item.GetItemQualityColor) or GetItemQualityColor
local RequestItem = C_Item and C_Item.RequestLoadItemDataByID

local active = false
local windows = {} -- recipe ID -> its note frame, while shown
local spare = {}   -- hidden note frames, reused
local wanted = {}  -- item ID -> true: a shown note waits for its name

local function Call(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, a, b, c, d, e = pcall(fn, ...)
    if ok then return a, b, c, d, e end
end

---------------------------------------------------------------------------
-- Saved notes, per character
---------------------------------------------------------------------------

local validated = false

-- This character's notes: { id, name, icon, item, reagents = { { id, count, name } }, times, pos }.
-- times is the ×N multiplier (crafts wanted); count is for one craft.
-- Drops anything a hand-edited SavedVariables file could hold.
local function List()
    if not ns.db then return {} end
    if type(ns.db.recipes) ~= "table" then ns.db.recipes = {} end
    local key = Util.CharacterKey(ns.db.recipes)
    local list = ns.db.recipes[key]
    if type(list) ~= "table" then
        list = {}
        ns.db.recipes[key] = list
    end
    if not validated then
        validated = true
        for index = #list, 1, -1 do
            local note = list[index]
            local ok = type(note) == "table" and type(note.id) == "number" and type(note.reagents) == "table"
            if ok then
                for i = #note.reagents, 1, -1 do
                    local reagent = note.reagents[i]
                    if type(reagent) ~= "table" or type(reagent.id) ~= "number"
                        or type(reagent.count) ~= "number" or reagent.count <= 0 then
                        table.remove(note.reagents, i)
                    end
                end
                if type(note.name) ~= "string" then note.name = "?" end
                ok = #note.reagents > 0
            end
            if not ok then table.remove(list, index) end
        end
    end
    return list
end

local function Times(note)
    local times = tonumber(note.times)
    if not times or times < 1 then return 1 end
    return math.min(math.floor(times), MAX_TIMES)
end

local function Find(recipeID)
    for index, note in ipairs(List()) do
        if note.id == recipeID then return note, index end
    end
end

---------------------------------------------------------------------------
-- Reading a recipe
---------------------------------------------------------------------------

-- Slots the recipe always needs, as opposed to optional or finishing reagents.
local function IsBasicSlot(slot)
    local types = Enum and Enum.CraftingReagentType
    if slot.reagentType ~= nil and types and types.Basic ~= nil and slot.reagentType == types.Basic then return true end
    if slot.required ~= nil then return slot.required == true end
    return slot.reagentType == nil -- nothing tells: Classic data only has basic reagents
end

local function ItemName(id)
    local name = Call(GetInfo, id)
    if type(name) == "string" and name ~= "" then return name end
end

-- A note for the recipe, or nil when no reagent could be read.
local function ReadRecipe(info)
    local api = C_TradeSkillUI
    local schematic = api and Call(api.GetRecipeSchematic, info.recipeID, false)
    if type(schematic) ~= "table" or type(schematic.reagentSlotSchematics) ~= "table" then return end
    local reagents = {}
    for _, slot in ipairs(schematic.reagentSlotSchematics) do
        local first = type(slot) == "table" and type(slot.reagents) == "table" and slot.reagents[1]
        local id = type(first) == "table" and first.itemID
        local count = type(slot) == "table" and slot.quantityRequired
        if type(id) == "number" and type(count) == "number" and count > 0 and IsBasicSlot(slot) then
            local merged = false
            for _, reagent in ipairs(reagents) do
                if reagent.id == id then
                    reagent.count = reagent.count + count
                    merged = true
                    break
                end
            end
            if not merged then
                reagents[#reagents + 1] = { id = id, count = count, name = ItemName(id) }
            end
        end
    end
    if #reagents == 0 then return end
    local name = type(info.name) == "string" and info.name or schematic.name
    local icon = info.icon or schematic.icon
    local item = schematic.outputItemID
    return {
        id = info.recipeID,
        name = type(name) == "string" and name or "?",
        icon = (type(icon) == "number" or type(icon) == "string") and icon or nil,
        item = type(item) == "number" and item or nil,
        reagents = reagents,
    }
end

-- The rank the list shows for a ranked recipe (the highest one learned).
local function ShownRecipe(info)
    local get = Professions and Professions.GetHighestLearnedRecipe
    local shown = get and Call(get, info)
    if type(shown) == "table" and type(shown.recipeID) == "number" then return shown end
    return info
end

---------------------------------------------------------------------------
-- Note windows
---------------------------------------------------------------------------

local function Counts(id)
    local bags = Call(GetCount, id)
    local all = Call(GetCount, id, true)
    if type(bags) ~= "number" then bags = 0 end
    if type(all) ~= "number" or all < bags then all = bags end
    return bags, all - bags
end

local function QualityRGB(quality)
    if type(quality) ~= "number" then return 1, 1, 1 end
    local r, g, b = Call(GetQualityColor, quality)
    if type(r) == "number" then return r, g, b end
    local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if color then return color.r, color.g, color.b end
    return 1, 1, 1
end

local function SetColor(region, color)
    region:SetTextColor(color[1], color[2], color[3])
end

local function SavePosition(frame)
    if not frame.note then return end
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    if point then frame.note.pos = { point, relativePoint, x, y } end
end

local function Place(frame)
    frame:ClearAllPoints()
    local pos = frame.note.pos
    if type(pos) == "table" and type(pos[1]) == "string" and type(pos[3]) == "number" and type(pos[4]) == "number" then
        frame:SetPoint(pos[1], UIParent, type(pos[2]) == "string" and pos[2] or pos[1], pos[3], pos[4])
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    end
end

local function StartMoving(frame)
    frame:StartMoving()
end

local function StopMoving(frame)
    frame:StopMovingOrSizing()
    SavePosition(frame)
end

-- Children pass a drag on to the note, so it moves from anywhere.
local function ChildDragStart(child) StartMoving(child:GetParent()) end
local function ChildDragStop(child) StopMoving(child:GetParent()) end

local function ItemLink(id)
    local _, link = Call(GetInfo, id)
    if type(link) == "string" then return link end
end

-- Shift+click links the item in chat; Alt+click opens the item finder.
local function LinkClick(id)
    if not id or not IsModifierKeyDown() or not HandleModifiedItemClick then return end
    local link = ItemLink(id)
    if link then HandleModifiedItemClick(link) end
end

local function RowEnter(row)
    local reagent = row.reagent
    if not reagent then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    pcall(GameTooltip.SetItemByID, GameTooltip, reagent.id)
    if GameTooltip:NumLines() == 0 then
        GameTooltip:SetText(reagent.name or ("item:" .. reagent.id), 1, 1, 1)
    end
    local bags, bank = Counts(reagent.id)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L.RECIPENOTES_BAGS:format(bags), 1, 1, 1)
    if bank > 0 then GameTooltip:AddLine(L.RECIPENOTES_BANK:format(bank), 1, 0.82, 0) end
    GameTooltip:Show()
end

local function RowClick(row)
    if row.reagent then LinkClick(row.reagent.id) end
end

local function HeaderEnter(header)
    local note = header:GetParent().note
    if not note then return end
    GameTooltip:SetOwner(header, "ANCHOR_RIGHT")
    if note.item then
        pcall(GameTooltip.SetItemByID, GameTooltip, note.item)
    else
        pcall(GameTooltip.SetSpellByID, GameTooltip, note.id)
    end
    if GameTooltip:NumLines() == 0 then GameTooltip:SetText(note.name, 1, 0.82, 0) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L.RECIPENOTES_MOVE, 0.5, 0.8, 1)
    GameTooltip:Show()
end

local function HeaderClick(header)
    local note = header:GetParent().note
    if note then LinkClick(note.item) end
end

local function CloseClick(button)
    local note = button:GetParent().note
    if note then Notes.Unpin(note.id) end
end

local Refresh -- defined below, after the note's parts

-- ×N: how many crafts the counts are for.
local function SetTimes(frame, value)
    local note = frame.note
    if not note then return end
    value = math.max(1, math.min(MAX_TIMES, math.floor(value)))
    if value == Times(note) then return end
    note.times = value
    Refresh(frame)
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
end

local function Step()
    return IsShiftKeyDown() and 10 or 1
end

local function StepperTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(L.RECIPENOTES_TIMES_TITLE, 1, 0.82, 0)
    GameTooltip:AddLine(L.RECIPENOTES_TIMES_HELP, 1, 1, 1, true)
    GameTooltip:Show()
end

local function StepClick(button)
    local frame = button:GetParent().owner
    if frame.note then SetTimes(frame, Times(frame.note) + button.delta * Step()) end
end

local function StepWheel(stepper, delta)
    local frame = stepper.owner
    if frame.note then SetTimes(frame, Times(frame.note) + (delta > 0 and 1 or -1) * Step()) end
end

local function CreateStepButton(stepper, delta, kind, point)
    local button = CreateFrame("Button", nil, stepper)
    button:SetSize(16, 16)
    button:SetPoint(point)
    button.delta = delta
    button:SetNormalTexture("Interface\\Buttons\\UI-" .. kind .. "Button-Up")
    button:SetPushedTexture("Interface\\Buttons\\UI-" .. kind .. "Button-Down")
    button:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
    button:SetMotionScriptsWhileDisabled(true)
    button:SetScript("OnClick", StepClick)
    button:SetScript("OnEnter", StepperTooltip)
    button:SetScript("OnLeave", GameTooltip_Hide)
    return button
end

-- [−] ×N [+] at the right of the header; the mouse wheel works on it too.
local function CreateStepper(frame, header)
    local stepper = CreateFrame("Frame", nil, frame)
    stepper.owner = frame
    stepper:SetSize(60, 16)
    stepper:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -PADDING, -(PADDING + 30))
    stepper:SetFrameLevel(header:GetFrameLevel() + 2)
    stepper:EnableMouse(true)
    stepper:EnableMouseWheel(true)
    stepper:RegisterForDrag("LeftButton")
    stepper:SetScript("OnDragStart", ChildDragStart)
    stepper:SetScript("OnDragStop", ChildDragStop)
    stepper:SetScript("OnMouseWheel", StepWheel)
    stepper:SetScript("OnEnter", StepperTooltip)
    stepper:SetScript("OnLeave", GameTooltip_Hide)

    stepper.minus = CreateStepButton(stepper, -1, "Minus", "LEFT")
    stepper.plus = CreateStepButton(stepper, 1, "Plus", "RIGHT")
    stepper.label = stepper:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stepper.label:SetPoint("LEFT", stepper.minus, "RIGHT", 0, 0)
    stepper.label:SetPoint("RIGHT", stepper.plus, "LEFT", 0, 0)
    stepper.label:SetJustifyH("CENTER")
    stepper.label:SetWordWrap(false)
    return stepper
end

local function CreateRow(frame, index)
    local row = CreateFrame("Button", nil, frame)
    row:SetHeight(ROW_HEIGHT)
    -- Two top anchors: a RIGHT anchor would also pin the vertical center and override the height.
    local top = -(HEADER_HEIGHT + (index - 1) * ROW_HEIGHT)
    row:SetPoint("TOPLEFT", PADDING - 2, top)
    row:SetPoint("TOPRIGHT", -(PADDING - 2), top)
    row:SetHighlightTexture(HIGHLIGHT, "ADD")
    row:RegisterForClicks("LeftButtonUp")
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnDragStart", ChildDragStart)
    row:SetScript("OnDragStop", ChildDragStop)
    row:SetScript("OnEnter", RowEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:SetScript("OnClick", RowClick)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(15, 15)
    row.icon:SetPoint("LEFT", 2, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.count:SetPoint("RIGHT", -2, 0)
    row.count:SetJustifyH("RIGHT")

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetPoint("RIGHT", row.count, "LEFT", -8, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    frame.rows[index] = row
    return row
end

local function CreateNote()
    local frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    frame:Hide()
    frame:SetSize(NOTE_WIDTH, HEADER_HEIGHT + ROW_HEIGHT + PADDING)
    frame:SetFrameStrata("MEDIUM")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    if frame.SetDontSavePosition then frame:SetDontSavePosition(true) end
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", StartMoving)
    frame:SetScript("OnDragStop", StopMoving)
    frame:SetBackdrop(BACKDROP)
    frame:SetBackdropColor(0.03, 0.03, 0.04, 0.9)
    frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

    local closeTemplate = UI.HasTemplate("UIPanelCloseButtonNoScripts") and "UIPanelCloseButtonNoScripts" or "UIPanelCloseButton"
    local close = CreateFrame("Button", nil, frame, closeTemplate)
    close:SetSize(22, 22)
    close:SetPoint("TOPRIGHT", -3, -3)
    close:SetScript("OnClick", CloseClick)

    -- Icon, recipe name and how many you can make; shows the crafted item.
    local header = CreateFrame("Button", nil, frame)
    header:SetPoint("TOPLEFT", PADDING, -PADDING)
    header:SetPoint("TOPRIGHT", -30, -PADDING) -- clear of the close button
    header:SetHeight(30)
    header:RegisterForClicks("LeftButtonUp")
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", ChildDragStart)
    header:SetScript("OnDragStop", ChildDragStop)
    header:SetScript("OnEnter", HeaderEnter)
    header:SetScript("OnLeave", GameTooltip_Hide)
    header:SetScript("OnClick", HeaderClick)

    frame.icon = header:CreateTexture(nil, "ARTWORK")
    frame.icon:SetSize(30, 30)
    frame.icon:SetPoint("LEFT")
    frame.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    frame.title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("TOPLEFT", frame.icon, "TOPRIGHT", 7, -1)
    frame.title:SetPoint("TOPRIGHT", 0, -1)
    frame.title:SetJustifyH("LEFT")
    frame.title:SetWordWrap(false)

    frame.stepper = CreateStepper(frame, header)

    frame.status = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.status:SetPoint("BOTTOMLEFT", frame.icon, "BOTTOMRIGHT", 7, 1)
    frame.status:SetPoint("BOTTOMRIGHT", frame.stepper, "BOTTOMLEFT", -4, 1)
    frame.status:SetJustifyH("LEFT")
    frame.status:SetWordWrap(false)

    local line = frame:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.12)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", PADDING, -(HEADER_HEIGHT - 4))
    line:SetPoint("TOPRIGHT", -PADDING, -(HEADER_HEIGHT - 4))

    frame.rows = {}
    return frame
end

function Refresh(frame)
    local note = frame.note
    if not note then return end
    frame.icon:SetTexture(note.icon or (note.item and Call(GetIcon, note.item)) or QUESTION)
    frame.title:SetText(note.name)

    local times = Times(note)
    local stepper = frame.stepper
    stepper.label:SetText("×" .. times)
    stepper.minus:SetEnabled(times > 1)
    stepper.minus:SetAlpha(times > 1 and 1 or 0.4)
    stepper.plus:SetEnabled(times < MAX_TIMES)
    stepper.plus:SetAlpha(times < MAX_TIMES and 1 or 0.4)

    local makeable
    for index, reagent in ipairs(note.reagents) do
        local row = frame.rows[index] or CreateRow(frame, index)
        row.reagent = reagent
        local name, _, quality = Call(GetInfo, reagent.id)
        if type(name) == "string" and name ~= "" then
            reagent.name = name -- shown next time the item cache is still cold
        else
            name = reagent.name or ("item:" .. reagent.id)
            wanted[reagent.id] = true
            if RequestItem then Call(RequestItem, reagent.id) end
        end
        row.icon:SetTexture(Call(GetIcon, reagent.id) or QUESTION)
        row.name:SetText(name)
        row.name:SetTextColor(QualityRGB(quality))

        -- Green: enough in your bags. Gold: enough counting the bank. Red: missing.
        local bags, bank = Counts(reagent.id)
        local need = reagent.count * times
        row.count:SetText(bags .. "/" .. need)
        if bags >= need then
            SetColor(row.count, UI.GREEN)
        elseif bags + bank >= need then
            SetColor(row.count, UI.GOLD)
        else
            SetColor(row.count, UI.RED)
        end
        local times = math.floor(bags / reagent.count)
        makeable = makeable and math.min(makeable, times) or times
        row:Show()
    end
    for index = #note.reagents + 1, #frame.rows do
        frame.rows[index].reagent = nil
        frame.rows[index]:Hide()
    end

    -- How many your bags allow: green when it reaches ×N, white when it falls short.
    if makeable and makeable > 0 then
        frame.status:SetText(L.RECIPENOTES_CAN_MAKE:format(makeable))
        SetColor(frame.status, makeable >= times and UI.GREEN or { 1, 1, 1 })
    else
        frame.status:SetText(L.RECIPENOTES_MISSING)
        SetColor(frame.status, UI.MUTED)
    end
    frame:SetHeight(HEADER_HEIGHT + #note.reagents * ROW_HEIGHT + PADDING - 2)
end

local function ShowNote(note)
    local frame = windows[note.id]
    if not frame then
        frame = table.remove(spare) or CreateNote()
        windows[note.id] = frame
    end
    frame.note = note
    Refresh(frame)
    Place(frame)
    frame:Show()
    return frame
end

local function HideNote(recipeID)
    local frame = windows[recipeID]
    if not frame then return end
    windows[recipeID] = nil
    frame:StopMovingOrSizing()
    frame:Hide()
    frame.note = nil
    spare[#spare + 1] = frame
end

local function ShowAll()
    for _, note in ipairs(List()) do ShowNote(note) end
end

local function HideAll()
    local ids = {}
    for recipeID in pairs(windows) do ids[#ids + 1] = recipeID end
    for _, recipeID in ipairs(ids) do HideNote(recipeID) end
end

local function RefreshAll()
    for _, frame in pairs(windows) do Refresh(frame) end
end

-- Pins the recipe with the note's top left corner at x, y (UIParent
-- coordinates). A recipe already pinned moves there, with its reagents read again.
function Notes.Pin(info, x, y)
    local fresh = ReadRecipe(info)
    local note, index = Find(info.recipeID)
    if not fresh and not note then
        ns:Error(L.RECIPENOTES_NONE)
        return
    end
    if fresh then
        if note then
            fresh.times = note.times -- keeps its ×N
            List()[index] = fresh
        else
            table.insert(List(), fresh)
        end
        note = fresh
    end
    note.pos = { "TOPLEFT", "BOTTOMLEFT", math.floor(x + 0.5), math.floor(y + 0.5) }
    local frame = ShowNote(note)
    frame:Raise()
    PlaySound(SOUNDKIT.IG_ABILITY_ICON_DROP or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
end

function Notes.Unpin(recipeID)
    local _, index = Find(recipeID)
    if index then table.remove(List(), index) end
    HideNote(recipeID)
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
end

---------------------------------------------------------------------------
-- Dragging a recipe out of the professions window
---------------------------------------------------------------------------

local ghost    -- the label that follows the cursor
local dragging -- recipe info being dragged
local watcher  -- child of ProfessionsFrame: watches presses on recipe rows
local press    -- { info, x, y } of a press on a recipe row, until it moves or ends
local wasDown = false

local function CursorPosition()
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    return x / scale, y / scale
end

local function OverProfessions()
    local frame = ProfessionsFrame
    return frame ~= nil and frame:IsVisible() and frame:IsMouseOver()
end

local function StopDrag()
    local info = dragging
    dragging = nil
    if ghost then ghost:Hide() end
    return info
end

local function FinishDrag()
    local info = StopDrag()
    if not info or not active or OverProfessions() then return end
    local x, y = CursorPosition()
    Notes.Pin(info, x + GHOST_X, y + GHOST_Y)
end

local function GhostUpdate(self)
    local x, y = CursorPosition()
    self:ClearAllPoints()
    self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x + GHOST_X, y + GHOST_Y)
    local inside = OverProfessions() and true or false
    if inside ~= self.inside then
        self.inside = inside
        self.hint:SetText(inside and L.RECIPENOTES_DRAG_OUT or L.RECIPENOTES_DROP)
        SetColor(self.hint, inside and UI.MUTED or UI.GREEN)
        self:SetAlpha(inside and 0.8 or 1)
    end
    if not IsMouseButtonDown("LeftButton") then FinishDrag() end
end

local function CreateGhost()
    ghost = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    ghost:Hide()
    ghost:SetFrameStrata("TOOLTIP")
    ghost:SetClampedToScreen(true)
    ghost:EnableMouse(false)
    ghost:SetHeight(40)
    ghost:SetBackdrop(BACKDROP)
    ghost:SetBackdropColor(0.03, 0.03, 0.04, 0.9)
    ghost:SetBackdropBorderColor(1, 0.82, 0, 1)

    ghost.icon = ghost:CreateTexture(nil, "ARTWORK")
    ghost.icon:SetSize(26, 26)
    ghost.icon:SetPoint("LEFT", 8, 0)
    ghost.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    ghost.text = ghost:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ghost.text:SetPoint("TOPLEFT", ghost.icon, "TOPRIGHT", 7, -1)
    ghost.text:SetJustifyH("LEFT")
    ghost.text:SetWordWrap(false)

    ghost.hint = ghost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ghost.hint:SetPoint("BOTTOMLEFT", ghost.icon, "BOTTOMRIGHT", 7, 1)
    ghost.hint:SetJustifyH("LEFT")
    ghost.hint:SetWordWrap(false)

    ghost:SetScript("OnUpdate", GhostUpdate)
end

local function StartDrag(info)
    if not ghost then CreateGhost() end
    dragging = ShownRecipe(info)
    ghost.icon:SetTexture(dragging.icon or QUESTION)
    ghost.text:SetText(dragging.name or "?")
    ghost.hint:SetText(L.RECIPENOTES_DRAG_OUT)
    ghost.inside = nil
    GameTooltip_Hide() -- the row's tooltip for a cut-off name
    ghost:Show()
    -- Fits the longer of the name and the two hints, cut past 260 pixels
    -- (measured once shown: text of a never-shown frame can measure 0).
    ghost.text:SetWidth(0)
    local width = ghost.text:GetStringWidth()
    for _, hint in ipairs({ L.RECIPENOTES_DROP, L.RECIPENOTES_DRAG_OUT }) do
        ghost.hint:SetText(hint)
        width = math.max(width, ghost.hint:GetStringWidth())
    end
    width = math.min(math.max(width, 120), 260)
    ghost.text:SetWidth(width)
    ghost.hint:SetWidth(width)
    ghost:SetWidth(width + 52)
    GhostUpdate(ghost)
end

local function MouseFocus()
    if GetMouseFoci then
        local foci = GetMouseFoci()
        return type(foci) == "table" and foci[1] or nil
    end
    return GetMouseFocus and GetMouseFocus()
end

-- The recipe of a row of Blizzard's recipe list (rows get GetElementData from the list).
local function RowRecipe(frame)
    local getData = frame.GetElementData
    if type(getData) ~= "function" then return end
    local node = getData(frame)
    if type(node) ~= "table" then return end
    local data
    if type(node.GetData) == "function" then data = node:GetData() else data = node.data end
    local info = type(data) == "table" and data.recipeInfo
    if type(info) == "table" and type(info.recipeID) == "number" then return info end
end

local function FindRecipeUnderMouse()
    local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
    local list = page and page.RecipeList
    if not (list and list:IsVisible() and list:IsMouseOver()) then return end
    local frame = MouseFocus()
    -- The row itself, or the skill-up or lock icon drawn on top of it.
    for _ = 1, 2 do
        if type(frame) ~= "table" or frame:IsForbidden() then return end
        local info = RowRecipe(frame)
        if info then return info end
        frame = frame:GetParent()
    end
end

local function RecipeUnderMouse()
    local ok, info = pcall(FindRecipeUnderMouse)
    if ok then return info end
end

local function Watch()
    if not IsMouseButtonDown("LeftButton") then
        wasDown, press = false, nil
        return
    end
    if not wasDown then
        -- The press itself: remember it when it lands on a recipe.
        wasDown, press = true, nil
        if active and not dragging then
            local info = RecipeUnderMouse()
            if info then
                local x, y = CursorPosition()
                press = { info = info, x = x, y = y }
            end
        end
        return
    end
    if press then
        local x, y = CursorPosition()
        local dx, dy = x - press.x, y - press.y
        if dx * dx + dy * dy >= DRAG_THRESHOLD * DRAG_THRESHOLD then
            local info = press.info
            press = nil
            StartDrag(info)
        end
    end
end

-- False until Blizzard_Professions (load on demand) has created the window.
local function Attach()
    if watcher then return true end
    if not ProfessionsFrame then return false end
    watcher = CreateFrame("Frame", nil, ProfessionsFrame)
    watcher:SetSize(1, 1)
    watcher:SetPoint("TOPLEFT")
    watcher:EnableMouse(false)
    watcher:SetScript("OnUpdate", Watch)
    watcher:SetScript("OnHide", function() wasDown, press = false, nil end)
    return true
end

---------------------------------------------------------------------------
-- Enable / disable
---------------------------------------------------------------------------

local refreshQueued = false

-- Bag updates come in bursts: one refresh for the lot.
local function QueueRefresh()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0.2, function()
        refreshQueued = false
        if active then RefreshAll() end
    end)
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if Attach() then self:UnregisterEvent("ADDON_LOADED") end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if wanted[arg1] then
            wanted[arg1] = nil
            QueueRefresh()
        end
    else
        QueueRefresh()
    end
end)

local function Register(event)
    pcall(events.RegisterEvent, events, event)
end

local function Enable()
    active = true
    if not Attach() then Register("ADDON_LOADED") end
    Register("BAG_UPDATE_DELAYED")
    Register("GET_ITEM_INFO_RECEIVED")
    Register("PLAYERBANKSLOTS_CHANGED")
    Register("BANKFRAME_OPENED")
    ShowAll()
end

local function Disable()
    active = false
    StopDrag()
    press = nil
    events:UnregisterAllEvents()
    HideAll()
end

ns:On("LANGUAGE_CHANGED", function()
    if active then RefreshAll() end
end)

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

ns:RegisterCategory({
    key = "professions",
    order = 32,
    title = "CAT_PROFESSIONS",
    desc = "CAT_PROFESSIONS_DESC",
    icon = "Interface\\Icons\\Trade_BlackSmithing",
})

ns:RegisterFeature({
    key = KEY,
    category = "professions",
    order = 10,
    title = "RECIPENOTES_TITLE",
    desc = "RECIPENOTES_DESC",
    tip = "RECIPENOTES_TIP",
    default = true,
    isNew = true,
    OnEnable = Enable,
    OnDisable = Disable,
})
