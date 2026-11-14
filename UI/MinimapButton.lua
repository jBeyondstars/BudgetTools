local _, ns = ...
local L = ns.L

--[[
Round button on the minimap edge that opens the options window.

Self-contained (no LibDBIcon), drawn with the same textures LibDBIcon uses
so it sits next to the other addon buttons. Left-drag moves it around the
minimap; the angle is saved in BudgetForeverDB.general.minimapAngle.
GetMinimapShape (set by Leatrix Plus' square minimap, among others) is
honoured so the button follows square corners.
]]

local MinimapButton = {}
ns.MinimapButton = MinimapButton

local DEFAULT_ANGLE = 225
local button

-- Which quadrants are rounded, per minimap shape (same table as LibDBIcon).
-- Quadrants: 1 = top right, 2 = top left, 3 = bottom left, 4 = bottom right.
local SHAPES = {
    ROUND = { true, true, true, true },
    SQUARE = { false, false, false, false },
    ["CORNER-TOPLEFT"] = { false, false, false, true },
    ["CORNER-TOPRIGHT"] = { false, false, true, false },
    ["CORNER-BOTTOMLEFT"] = { false, true, false, false },
    ["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
    ["SIDE-LEFT"] = { false, true, true, true },
    ["SIDE-RIGHT"] = { true, false, true, true },
    ["SIDE-TOP"] = { false, false, true, true },
    ["SIDE-BOTTOM"] = { true, true, false, false },
    ["TRICORNER-TOPLEFT"] = { false, true, true, true },
    ["TRICORNER-TOPRIGHT"] = { true, false, true, true },
    ["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
    ["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}

local function Place()
    local angle = math.rad(ns.db.general.minimapAngle or DEFAULT_ANGLE)
    local x, y = math.cos(angle), math.sin(angle)
    local quadrant = 1
    if x < 0 then quadrant = quadrant + 1 end
    if y > 0 then quadrant = quadrant + 2 end
    local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
    local rounded = (SHAPES[shape] or SHAPES.ROUND)[quadrant]
    local w = (Minimap:GetWidth() / 2) + 5
    local h = (Minimap:GetHeight() / 2) + 5
    if rounded then
        x, y = x * w, y * h
    else
        local dw = math.sqrt(2 * w * w) - 10
        local dh = math.sqrt(2 * h * h) - 10
        x = math.max(-w, math.min(x * dw, w))
        y = math.max(-h, math.min(y * dh, h))
    end
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function OnDragUpdate()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    px, py = px / scale, py / scale
    ns.db.general.minimapAngle = math.deg(math.atan2(py - my, px - mx)) % 360
    Place()
end

local function ShowTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText(L.ADDON_TITLE, 1, 0.82, 0)
    GameTooltip:AddLine(L.TAGLINE, 1, 1, 1, true)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L.COMPARTMENT_HINT, 1, 1, 1)
    GameTooltip:AddLine(L.MINIMAP_DRAG_HINT, 1, 1, 1)
    GameTooltip:Show()
end

local function Create()
    button = CreateFrame("Button", "BudgetForeverMinimapButton", Minimap)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    button:SetSize(31, 31)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetTexture(ns.ICON_MINI)
    icon:SetPoint("TOPLEFT", 7, -5)
    button.icon = icon

    button:SetScript("OnMouseDown", function() icon:SetPoint("TOPLEFT", 8, -6) end)
    button:SetScript("OnMouseUp", function() icon:SetPoint("TOPLEFT", 7, -5) end)
    button:SetScript("OnClick", function() ns.Panel:Toggle() end)
    button:SetScript("OnEnter", ShowTooltip)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", OnDragUpdate)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        icon:SetPoint("TOPLEFT", 7, -5)
    end)

    -- Minimap resized or reshaped by another addon (Leatrix Plus...).
    Minimap:HookScript("OnSizeChanged", function() if button:IsShown() then Place() end end)
end

function MinimapButton:Refresh()
    if not ns.db then return end
    if ns.db.general.minimapButton then
        if not button then Create() end
        Place()
        button:Show()
    elseif button then
        button:Hide()
    end
end

function MinimapButton:SetShown(value)
    ns.db.general.minimapButton = value and true or false
    self:Refresh()
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    MinimapButton:Refresh()
    -- Addons that make the minimap square set GetMinimapShape a bit later.
    C_Timer.After(1, function() MinimapButton:Refresh() end)
end)
