local _, ns = ...
local L = ns.L
local Util = ns.Util

--[[
Experience per hour for the current session, in a small movable box.

Session:
  - Starts at login, survives a /reload, and starts over when you clear it
    (right-click menu, the button in /bgt, or /bgt xp clear).
  - Turning the feature on from /bgt starts a new session when the stored one
    was left more than a few minutes ago (XP was not followed meanwhile).
  - Stored per character in BudgetForeverDB.xp.chars["Name-Realm"]; the
    box position, size and the display settings are shared.

Counting:
  Every PLAYER_XP_UPDATE adds the difference with the last reading. When
  the bar went down or the level went up, a level was gained: what was left
  of the old bar plus what is on the new one.

Display (all from the right-click menu, and in /bgt):
  - which lines are shown, the size, the background, locking the position.
]]

local KEY = "xpRate"
local TICK = 1              -- seconds between two refreshes of the box
local GAP = 300             -- a stored session older than this is not resumed
local PADDING = 8
local ROW_HEIGHT = 15
local MAIN_HEIGHT = 18      -- the XP/hour line is a bit larger
local COLUMN_GAP = 14
local MIN_WIDTH = 110
local SCALES = { 75, 90, 100, 110, 125, 150, 175 }
local BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- Lines in display order. `key` is the sub-option that shows the line.
local LINES = {
    { key = "showRate", title = "XPRATE_OPT_RATE", main = true },
    { key = "showGained", title = "XPRATE_OPT_GAINED" },
    { key = "showTime", title = "XPRATE_OPT_TIME" },
    { key = "showLevel", title = "XPRATE_OPT_LEVEL" },
    { key = "showProgress", title = "XPRATE_OPT_PROGRESS" },
    { key = "showRested", title = "XPRATE_OPT_RESTED" },
}

local XP = {}
ns.XPRate = XP

local active = false
local session               -- this character's session table (lives in saved data)
local frame
local ticker
local events = CreateFrame("Frame")

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

local function Call(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
end

local function Number(value)
    if Util.Readable(value) and type(value) == "number" then return value end
end

-- XP on the bar, size of the bar, level. nil when the game hides them.
local function ReadXP()
    local xp = Number(Call(UnitXP, "player"))
    local max = Number(Call(UnitXPMax, "player"))
    local level = Number(Call(UnitLevel, "player"))
    if not xp or not max or not level then return end
    return xp, max, level
end

local function Rested()
    return Number(Call(GetXPExhaustion)) or 0
end

-- nil, or why there is no experience to earn.
local function NoXPReason()
    if Call(IsXPUserDisabled) == true then return L.XPRATE_DISABLED end
    if Call(IsPlayerAtEffectiveMaxLevel) == true then return L.XPRATE_MAX end
    local _, max, level = ReadXP()
    if max == 0 then return L.XPRATE_MAX end
    local cap = Number(Call(GetMaxLevelForPlayerExpansion)) or Number(Call(GetMaxPlayerLevel))
    if level and cap and cap > 0 and level >= cap then return L.XPRATE_MAX end
end

---------------------------------------------------------------------------
-- Session
---------------------------------------------------------------------------

local function Settings()
    local db = ns.db.xp
    if type(db.chars) ~= "table" then db.chars = {} end
    return db
end

local function NewSession()
    local xp, max, level = ReadXP()
    session = {
        start = time(),
        seen = time(),
        gained = 0,
        levels = 0,
        xp = xp or 0,
        max = max or 0,
        level = level or 0,
    }
    Settings().chars[Util.CharacterKey()] = session
end

-- Picks up the stored session after a /reload, or starts a new one.
local function LoadSession()
    local stored = Settings().chars[Util.CharacterKey()]
    local valid = type(stored) == "table" and type(stored.start) == "number"
        and type(stored.gained) == "number" and type(stored.seen) == "number"
    if not valid or time() - stored.seen > GAP then
        NewSession()
        return
    end
    session = stored
    session.levels = type(session.levels) == "number" and session.levels or 0
    -- XP can't move during a reload: take the bar as it is now.
    local xp, max, level = ReadXP()
    if xp then session.xp, session.max, session.level = xp, max, level end
end

local function OnXPUpdate()
    if not session then return end
    local xp, max, level = ReadXP()
    if not xp then return end
    local last = type(session.xp) == "number" and session.xp or xp
    local lastLevel = type(session.level) == "number" and session.level or level
    local gain
    if xp < last or level > lastLevel then
        -- A level was gained. UnitLevel can lag a moment behind the bar,
        -- so the believed level moves up now and is not counted twice.
        gain = math.max(0, (session.max or 0) - last) + xp
        session.level = math.max(level, lastLevel + 1)
        session.levels = (session.levels or 0) + 1
    else
        gain = xp - last
        session.level = level
    end
    session.gained = session.gained + gain
    session.xp, session.max = xp, max
end

local function Elapsed()
    if not session then return 0 end
    return math.max(0, time() - session.start)
end

-- XP per hour, nil while no time has passed.
local function Rate()
    local elapsed = Elapsed()
    if not session or elapsed < 1 then return end
    return session.gained / elapsed * 3600
end

-- Seconds to the next level at the current rate, nil if unknown.
local function TimeToLevel()
    local rate = Rate()
    local xp, max = ReadXP()
    if not rate or rate <= 0 or not xp or max <= 0 then return end
    return math.max(0, max - xp) / rate * 3600
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

local function Big(value)
    value = math.floor(value + 0.5)
    if BreakUpLargeNumbers then
        local ok, text = pcall(BreakUpLargeNumbers, value)
        if ok and type(text) == "string" then return text end
    end
    return tostring(value)
end

local function Duration(seconds)
    if not seconds then return "-" end
    seconds = math.floor(seconds + 0.5)
    if seconds >= 100 * 3600 then return ">99h" end
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor(seconds % 3600 / 60)
    if hours > 0 then return L.XPRATE_HOURS:format(hours, minutes) end
    return L.XPRATE_MINUTES:format(minutes, seconds % 60)
end

-- Label and value of one line.
local function LineText(line)
    local key = line.key
    if key == "showRate" then
        local rate = Rate()
        return L.XPRATE_RATE, rate and Big(rate) or "-"
    elseif key == "showGained" then
        return L.XPRATE_GAINED, Big(session and session.gained or 0)
    elseif key == "showTime" then
        return L.XPRATE_TIME, Duration(Elapsed())
    elseif key == "showLevel" then
        return L.XPRATE_LEVEL, Duration(TimeToLevel())
    elseif key == "showProgress" then
        local xp, max, level = ReadXP()
        if not xp or max <= 0 then return L.XPRATE_PROGRESS:format(level or 0), "-" end
        return L.XPRATE_PROGRESS:format(level), ("%.1f%%"):format(xp / max * 100)
    elseif key == "showRested" then
        local rested = Rested()
        local _, max = ReadXP()
        if rested <= 0 then return L.XPRATE_RESTED, "0" end
        if max and max > 0 then
            return L.XPRATE_RESTED, ("%s (%d%%)"):format(Big(rested), math.floor(rested / max * 100 + 0.5))
        end
        return L.XPRATE_RESTED, Big(rested)
    end
end

---------------------------------------------------------------------------
-- The box
---------------------------------------------------------------------------

local function ScalePercent()
    local value = ns.db.xp.scale
    if type(value) == "number" and value >= 50 and value <= 200 then return value end
    return 100
end

local function SavePosition()
    local left, top = frame:GetLeft(), frame:GetTop()
    if not left or not top then return end
    local scale = frame:GetScale()
    ns.db.xp.pos = { left * scale, top * scale } -- UIParent units, whatever the size
end

local function Place()
    local scale = frame:GetScale()
    local pos = ns.db.xp.pos
    frame:ClearAllPoints()
    if type(pos) == "table" and type(pos[1]) == "number" and type(pos[2]) == "number" then
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos[1] / scale, pos[2] / scale)
    else
        frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -230 / scale, -240 / scale)
    end
end

local function SetScalePercent(percent)
    if frame then
        if ns.db.xp.pos == nil then SavePosition() end
        frame:SetScale(percent / 100)
        ns.db.xp.scale = percent
        Place()
    else
        ns.db.xp.scale = percent
    end
    ns:Fire("OPTION_CHANGED", KEY, "scale", percent)
end

local function VisibleLines()
    local list = {}
    for _, line in ipairs(LINES) do
        if ns:GetOption(KEY, line.key) then table.insert(list, line) end
    end
    -- Every line unticked would leave an empty box: keep the main one.
    if #list == 0 then table.insert(list, LINES[1]) end
    return list
end

-- Writes the values; the box only widens between two layouts, so it does
-- not jitter every second as the numbers change.
local function Update()
    if not frame or not frame:IsShown() then return end
    local labelWidth, valueWidth = 0, 0
    local reason = NoXPReason()
    for index, row in ipairs(frame.rows) do
        if row.line then
            local label, value
            if reason then
                label, value = index == 1 and L.XPRATE_SHORT or "", index == 1 and reason or ""
            else
                label, value = LineText(row.line)
            end
            row.label:SetText(label)
            row.value:SetText(value)
            labelWidth = math.max(labelWidth, row.label:GetStringWidth())
            valueWidth = math.max(valueWidth, row.value:GetStringWidth())
        end
    end
    local width = math.max(MIN_WIDTH, math.ceil(PADDING * 2 + labelWidth + COLUMN_GAP + valueWidth))
    if width > (frame.width or 0) then
        frame.width = width
        frame:SetWidth(width)
    end
end

local function ApplyBackground()
    if ns:GetOption(KEY, "background") then
        frame:SetBackdrop(BACKDROP)
        frame:SetBackdropColor(0.03, 0.03, 0.04, 0.85)
        frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    else
        frame:SetBackdrop(nil)
    end
end

-- Shows the chosen lines; called when a display setting changes.
local function Layout()
    if not frame then return end
    local lines = NoXPReason() and { LINES[1] } or VisibleLines()
    local y = -PADDING
    for index, row in ipairs(frame.rows) do
        local line = lines[index]
        row.line = line
        if line then
            local height = line.main and MAIN_HEIGHT or ROW_HEIGHT
            row.label:SetFontObject(line.main and "GameFontNormal" or "GameFontNormalSmall")
            row.value:SetFontObject(line.main and "GameFontHighlight" or "GameFontHighlightSmall")
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", PADDING, y)
            row:SetPoint("TOPRIGHT", -PADDING, y)
            row:SetHeight(height)
            row:Show()
            y = y - height
        else
            row:Hide()
        end
    end
    frame:SetHeight(-y + PADDING)
    ApplyBackground()
    frame.width = 0
    Update()
end

---------------------------------------------------------------------------
-- Menus
---------------------------------------------------------------------------

local function AddScaleRadios(root)
    local refresh = MenuResponse and MenuResponse.Refresh
    for _, percent in ipairs(SCALES) do
        root:CreateRadio(("%d%%"):format(percent),
            function() return ScalePercent() == percent end,
            function()
                SetScalePercent(percent)
                return refresh
            end)
    end
end

local function AddCheckbox(root, title, option)
    local refresh = MenuResponse and MenuResponse.Refresh
    root:CreateCheckbox(title,
        function() return ns:GetOption(KEY, option) end,
        function()
            ns:SetOption(KEY, option, not ns:GetOption(KEY, option))
            return refresh
        end)
end

local function OpenMenu(owner)
    if not MenuUtil or not MenuUtil.CreateContextMenu then return end
    local close = MenuResponse and MenuResponse.Close
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.XPRATE_TITLE)
        for _, line in ipairs(LINES) do AddCheckbox(root, L[line.title], line.key) end
        root:CreateDivider()
        local size = root:CreateButton(L.XPRATE_MENU_SIZE:format(ScalePercent()))
        AddScaleRadios(size)
        AddCheckbox(root, L.XPRATE_OPT_BACKGROUND, "background")
        AddCheckbox(root, L.XPRATE_OPT_LOCK, "lock")
        root:CreateDivider()
        root:CreateButton(L.XPRATE_OPT_CLEAR, function()
            XP.Clear()
            return close
        end)
        root:CreateButton(L.XPRATE_MENU_HIDE, function()
            ns:SetEnabled(KEY, false)
            ns:Print(L.XPRATE_HIDDEN)
            return close
        end)
    end)
end

local function OpenScaleMenu(owner)
    if not MenuUtil or not MenuUtil.CreateContextMenu then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.XPRATE_MENU_SIZE:format(ScalePercent()))
        AddScaleRadios(root)
    end)
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

local function ShowTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM", 0, -4)
    GameTooltip:SetText(L.XPRATE_TITLE, 1, 0.82, 0)
    local reason = NoXPReason()
    if reason then
        GameTooltip:AddLine(reason, 1, 1, 1)
    else
        for _, line in ipairs(LINES) do
            local label, value = LineText(line)
            GameTooltip:AddDoubleLine(label, value, 1, 0.82, 0, 1, 1, 1)
        end
        if session and session.levels > 0 then
            GameTooltip:AddDoubleLine(L.XPRATE_LEVELS, "+" .. session.levels, 1, 0.82, 0, 1, 1, 1)
        end
    end
    GameTooltip:AddLine(" ")
    if not ns:GetOption(KEY, "lock") then GameTooltip:AddLine(L.XPRATE_HINT_DRAG, 0.5, 0.8, 1) end
    GameTooltip:AddLine(L.XPRATE_HINT_MENU, 0.5, 0.8, 1)
    GameTooltip:Show()
end

local function CreateRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.label:SetPoint("LEFT")
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.value:SetPoint("RIGHT")
    row.value:SetJustifyH("RIGHT")
    row.value:SetWordWrap(false)
    return row
end

local function CreateBox()
    frame = CreateFrame("Frame", "BudgetForeverXPRate", UIParent, "BackdropTemplate")
    frame:Hide()
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    if frame.SetDontSavePosition then frame:SetDontSavePosition(true) end
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetSize(MIN_WIDTH, 40)
    frame:SetScale(ScalePercent() / 100)

    frame.rows = {}
    for index = 1, #LINES do frame.rows[index] = CreateRow(frame) end

    frame:SetScript("OnDragStart", function(self)
        if ns:GetOption(KEY, "lock") then return end
        GameTooltip:Hide()
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
        Place() -- back to a TOPLEFT anchor, so it widens to the right
    end)
    frame:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            GameTooltip:Hide()
            OpenMenu(self)
        end
    end)
    frame:SetScript("OnEnter", ShowTooltip)
    frame:SetScript("OnLeave", GameTooltip_Hide)
    frame:SetScript("OnShow", Update)

    Place()
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

function XP.Clear()
    if not active then ns:Print(L.XPRATE_OFF) return end
    NewSession()
    Layout()
    ns:Print(L.XPRATE_CLEARED)
end

function XP.Command(rest)
    local command = strlower(strtrim(rest or ""))
    if command == "clear" or command == "reset" or command == "raz" or command == "effacer" then
        XP.Clear()
        return
    end
    if not active then ns:Print(L.XPRATE_OFF) return end
    local reason = NoXPReason()
    if reason then ns:Print(reason) return end
    local rate = Rate()
    ns:Print(L.XPRATE_SUMMARY:format(Big(session.gained), Duration(Elapsed()),
        rate and Big(rate) or "-", Duration(TimeToLevel())))
    ns:Print(L.XPRATE_SUMMARY_HELP)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_XP_UPDATE" then
        OnXPUpdate()
        Update()
    elseif event == "PLAYER_LEVEL_UP" or event == "UPDATE_EXHAUSTION" or event == "ENABLE_XP_GAIN"
        or event == "DISABLE_XP_GAIN" then
        -- The level and bar size settle a moment after the event.
        C_Timer.After(0.5, function()
            if not active then return end
            OnXPUpdate()
            Layout()
        end)
    elseif event == "PLAYER_ENTERING_WORLD" then
        if arg1 == true then NewSession() end -- a real login, not a /reload
        Layout()
    elseif event == "PLAYER_LOGOUT" then
        if session then session.seen = time() end
    end
end)

local function Register(event)
    pcall(events.RegisterEvent, events, event)
end

local function Tick()
    if not active then return end
    if session then session.seen = time() end
    Update()
end

local function Enable()
    active = true
    LoadSession()
    if not frame then CreateBox() end
    Register("PLAYER_XP_UPDATE")
    Register("PLAYER_LEVEL_UP")
    Register("UPDATE_EXHAUSTION")
    Register("ENABLE_XP_GAIN")
    Register("DISABLE_XP_GAIN")
    Register("PLAYER_ENTERING_WORLD")
    Register("PLAYER_LOGOUT")
    if not ticker then ticker = C_Timer.NewTicker(TICK, Tick) end
    frame:Show()
    Layout()
end

local function Disable()
    active = false
    events:UnregisterAllEvents()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
    if session then session.seen = time() end
    if frame then frame:Hide() end
end

ns:On("OPTION_CHANGED", function(key)
    if key == KEY and active then Layout() end
end)

ns:On("LANGUAGE_CHANGED", function()
    if active then Layout() end
end)

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

ns:RegisterCategory({
    key = "leveling",
    order = 15,
    title = "CAT_LEVELING",
    desc = "CAT_LEVELING_DESC",
    icon = "Interface\\Icons\\INV_Misc_PocketWatch_01",
})

ns:RegisterFeature({
    key = KEY,
    category = "leveling",
    order = 10,
    title = "XPRATE_TITLE",
    desc = "XPRATE_DESC",
    tip = "XPRATE_TIP",
    default = true,
    isNew = true,
    options = {
        { key = "showRate", title = "XPRATE_OPT_RATE", default = true },
        { key = "showGained", title = "XPRATE_OPT_GAINED", default = true },
        { key = "showTime", title = "XPRATE_OPT_TIME", default = true },
        { key = "showLevel", title = "XPRATE_OPT_LEVEL", default = true },
        { key = "showProgress", title = "XPRATE_OPT_PROGRESS", default = false },
        { key = "showRested", title = "XPRATE_OPT_RESTED", default = false },
        { key = "background", title = "XPRATE_OPT_BACKGROUND", default = true },
        { key = "lock", title = "XPRATE_OPT_LOCK", tip = "XPRATE_OPT_LOCK_TIP", default = false },
        { key = "scale", title = function() return L.XPRATE_MENU_SIZE:format(ScalePercent()) end,
            tip = "XPRATE_OPT_SCALE_TIP", action = function(button) OpenScaleMenu(button) end },
        { key = "clear", title = "XPRATE_OPT_CLEAR", tip = "XPRATE_OPT_CLEAR_TIP", action = function() XP.Clear() end },
    },
    OnEnable = Enable,
    OnDisable = Disable,
})
