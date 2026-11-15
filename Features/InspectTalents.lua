local _, ns = ...
local L = ns.L
local Util = ns.Util

--[[
A Talents tab in the inspect window, and a button to come back.

What Forever ships:
  The inspect window (Blizzard_InspectUI, Camelot files) has three side tabs:
  Character, PvP and Guild. Talents are a separate entry of the unit menu,
  "View Talents": it inspects the unit, then calls
  PlayerSpellsUtil.OpenToClassTalentsTab(unit), which opens Blizzard's talent
  window on the other player's build. That window has no way back to the
  inspect window.

What this adds:
  - A fourth side tab under Blizzard's three. Clicking it opens that same
    talent window on the player the inspect window is showing (the user
    asked for the existing window, not a page drawn by the addon).
  - A button at the bottom of the talent window while it shows another
    player (where retail has its "copy loadout" button, which Forever
    hides). It calls InspectUnit(unit), Blizzard's own "Inspect": the talent
    window closes and the inspect window opens again on that player.

Out of combat:
  Both make the same calls as the menu. The talent window is a centered
  panel, so the game closes the inspect window when it opens.

In combat:
  ShowUIPanel and HideUIPanel refuse addon code in combat
  (CheckProtectedFunctionsAllowed). Neither window is a protected frame, so:
  - the tab prepares the talent window the way OpenToClassTalentsTab does,
    then shows it with a plain Show(), placed and scaled like a centered
    panel, and hides the inspect window with Hide();
  - the button hides the talent window with Hide() and calls InspectUnit;
    when the inspect answer comes, Blizzard's ShowUIPanel is refused (the
    unit was set by addon code) and the safety net below shows the window.
  The panel manager doesn't track a frame shown that way: Escape closes it
  through UISpecialFrames instead, and HideUIPanel ends in a plain Hide().

The safety net:
  The menu entries run as Blizzard code; the tab and the button run as addon
  code. What they write in the two windows stays tainted, and Blizzard's own
  code reads it when you open your talents or your spellbook (same window)
  with a key. In combat the game then refuses to show or hide the window.
  Once the tab or the button was used, post-hooks on ShowUIPanel and
  HideUIPanel finish the job for these two windows when the game refused.
  Out of combat nothing is refused.
]]

local KEY = "inspectTalents"
local ICON = "Interface\\Icons\\Ability_Marksmanship"
local WINDOW = "PlayerSpellsFrame"
local INSPECT = "InspectFrame"

local InspectTalents = {}
ns.InspectTalents = InspectTalents

local active = false
local installed = false     -- the tab
local backInstalled = false -- the button
local failed = false
local used = false          -- the tab or the button acted at least once
local netInstalled = false
local tab, back

local function InCombat()
    return InCombatLockdown ~= nil and InCombatLockdown() == true
end

---------------------------------------------------------------------------
-- Showing a window without the panel manager (combat only)
---------------------------------------------------------------------------

-- Escape closes panels the manager tracks, then the frames named here.
local function CloseWithEscape(name)
    if type(UISpecialFrames) ~= "table" then return end
    for _, other in ipairs(UISpecialFrames) do
        if other == name then return end
    end
    table.insert(UISpecialFrames, name)
end

-- Top centre of the screen, scaled down to fit, as the manager does for the
-- talent window (checkFitExtraWidth 200, checkFitExtraHeight 140).
local function PlaceCentered(frame)
    if UIPanelUpdateScaleForFit then pcall(UIPanelUpdateScaleForFit, frame, 200, 140) end
    local scale = frame:GetScale()
    if type(scale) ~= "number" or scale <= 0 then scale = 1 end
    local top = tonumber(UIParent:GetAttribute("TOP_OFFSET")) or -104
    if ClampUIPanelY then
        local ok, clamped = pcall(ClampUIPanelY, frame, top)
        if ok and type(clamped) == "number" then top = clamped end
    end
    frame:ClearAllPoints()
    frame:SetPoint("TOP", UIParent, "TOP", 0, top / scale)
end

-- Where the manager last put it; top left the first time.
local function PlaceLeft(frame)
    if frame:GetNumPoints() > 0 then return end
    local left = tonumber(UIParent:GetAttribute("LEFT_OFFSET")) or 16
    local top = tonumber(UIParent:GetAttribute("TOP_OFFSET")) or -104
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", left, top)
end

local PLACE = { [WINDOW] = PlaceCentered, [INSPECT] = PlaceLeft }

-- The name of the window, when it is one of the two this feature drives.
local function Known(frame)
    if frame == nil then return end
    for name in pairs(PLACE) do
        if frame == _G[name] then return name end
    end
end

local function ShowDirect(frame, name)
    if frame:IsShown() then return true end
    if frame:IsProtected() then return false end
    CloseWithEscape(name)
    frame:Show()
    -- After Show: the talent page sets the window's size when it shows.
    PLACE[name](frame)
    return frame:IsShown()
end

local function InstallSafetyNet()
    if netInstalled then return end
    netInstalled = true
    hooksecurefunc("ShowUIPanel", function(frame)
        local name = used and InCombat() and Known(frame)
        if name and not frame:IsShown() then ShowDirect(frame, name) end
    end)
    hooksecurefunc("HideUIPanel", function(frame)
        local name = used and InCombat() and Known(frame)
        if name and frame:IsShown() and not frame:IsProtected() then frame:Hide() end
    end)
end

---------------------------------------------------------------------------
-- The button on the talent window: back to the inspect window
---------------------------------------------------------------------------

local function UpdateBack()
    if not back then return end
    local frame = _G[WINDOW]
    local unit = active and frame.GetInspectUnit and frame:GetInspectUnit()
    if type(unit) == "string" then
        back:SetText(L.INSPECTTALENTS_BACK)
        back:SetWidth(math.max(160, (back:GetTextWidth() or 0) + 40))
        back:Show()
    else
        back:Hide()
    end
end

local function Back()
    local frame = _G[WINDOW]
    local unit = frame and frame.GetInspectUnit and frame:GetInspectUnit()
    if not active or type(unit) ~= "string" or type(InspectUnit) ~= "function" then return end
    local ok, can = pcall(CanInspect, unit)
    if not ok or not Util.Readable(can) or not can then
        ns:Error(L.INSPECTTALENTS_FAR)
        return
    end
    used = true
    InstallSafetyNet()
    -- In combat HideUIPanel would be refused. Hidden first, the talent window
    -- is no longer inspecting and InspectUnit doesn't try to hide it.
    if InCombat() and frame:IsShown() and not frame:IsProtected() then frame:Hide() end
    InspectUnit(unit)
end

InspectTalents.Back = Back

local function InstallBack()
    if backInstalled then return end
    local frame = _G[WINDOW]
    local talents = frame and frame.TalentsFrame
    if not talents or type(frame.GetInspectUnit) ~= "function" then return end
    backInstalled = true
    back = CreateFrame("Button", "BudgetForeverInspectTalentsBack", talents, "UIPanelButtonTemplate")
    back:SetSize(160, 22)
    back:SetPoint("BOTTOM", talents.Background or talents, "BOTTOM", 0, 3)
    local model = talents.InspectCopyButton or talents.ApplyButton
    if model then back:SetFrameLevel(model:GetFrameLevel()) end
    back:SetScript("OnClick", Back)
    back:Hide()
    if type(frame.SetInspecting) == "function" then
        hooksecurefunc(frame, "SetInspecting", UpdateBack)
    end
    talents:HookScript("OnShow", UpdateBack)
    -- The window shows and hides the action bar grid. Once the tab or the
    -- button was used, that runs as addon code even on the player's own key.
    frame:HookScript("OnShow", Util.CleanBars)
    frame:HookScript("OnHide", Util.CleanBars)
    UpdateBack()
end

---------------------------------------------------------------------------
-- The tab on the inspect window
---------------------------------------------------------------------------

-- What OpenToClassTalentsTab does, with Show() in place of ShowUIPanel.
local function OpenInCombat(unit)
    if not _G[WINDOW] and PlayerSpellsFrame_LoadUI then PlayerSpellsFrame_LoadUI() end
    local frame = _G[WINDOW]
    local talents = PlayerSpellsUtil.FrameTabs and PlayerSpellsUtil.FrameTabs.ClassTalents
    if not frame or not talents or type(frame.SetInspectUnit) ~= "function" or type(frame.TrySetTab) ~= "function" then
        return false
    end
    if frame:IsProtected() then return false end
    frame:SetInspectUnit(unit)
    if not frame:TrySetTab(talents) then return false end
    -- Out of the way, as out of combat. Blizzard's manager repairs its own
    -- state for panels hidden with Hide().
    if InspectFrame:IsShown() and not InspectFrame:IsProtected() then InspectFrame:Hide() end
    return ShowDirect(frame, WINDOW)
end

local function ModeTabs()
    local holder = InspectFrame and InspectFrame.ModeTabs
    return holder and holder.Tabs or {}
end

-- Under the last of Blizzard's tabs that is shown (the Guild tab hides for
-- players without a guild).
local function PlaceTab()
    if not tab then return end
    local last
    for _, other in ipairs(ModeTabs()) do
        if other:IsShown() then last = other end
    end
    tab:ClearAllPoints()
    if last then
        tab:SetPoint("TOPLEFT", last, "BOTTOMLEFT")
    else
        tab:SetPoint("TOPLEFT", InspectFrame.ModeTabs, "TOPLEFT")
    end
    tab:SetShown(active)
end

-- Opens Blizzard's talent window on the inspected player.
local function Open()
    if not active or not InspectFrame then return end
    local unit = InspectFrame.unit
    if type(unit) ~= "string" then return end
    if not PlayerSpellsUtil or type(PlayerSpellsUtil.OpenToClassTalentsTab) ~= "function" then
        ns:Error(L.INSPECTTALENTS_FAILED)
        return
    end
    if C_Traits and C_Traits.HasValidInspectData then
        local ok, valid = pcall(C_Traits.HasValidInspectData)
        if ok and Util.Readable(valid) and valid == false then
            ns:Error(L.INSPECTTALENTS_NODATA)
            return
        end
    end
    used = true
    InstallSafetyNet()
    if InCombat() then
        if not OpenInCombat(unit) then
            ns:Error(L.INSPECTTALENTS_COMBAT:format(INSPECT_TALENTS or "View Talents"))
        end
    else
        PlayerSpellsUtil.OpenToClassTalentsTab(unit)
    end
    -- The talent window may have been loaded just now.
    InstallBack()
    UpdateBack()
end

InspectTalents.Open = Open

local function CreateTab()
    local ok, frame = pcall(CreateFrame, "Frame", "BudgetForeverInspectTalentsTab", InspectFrame.ModeTabs, "LargeSideTabButtonTemplate")
    if not ok or not frame or not frame.Icon or not frame.SetChecked or not frame.SetCustomOnMouseUpHandler then
        if ok and frame then frame:Hide() end
        return false
    end
    tab = frame
    tab:EnableMouse(true)
    tab.fillToInterior = true
    tab.tooltipText = TALENTS or "Talents"
    tab.Icon:SetTexture(ICON)
    tab:SetCustomOnMouseUpHandler(function(_, button, upInside)
        if button == "LeftButton" and upInside then Open() end
    end)
    -- Never shown as selected: the inspect window closes when talents open.
    tab:SetChecked(false)
    return true
end

local function Install()
    if installed or failed then return end
    if not InspectFrame or not InspectFrame.ModeTabs or not CreateTab() then
        failed = true
        ns:Print(L.INSPECTTALENTS_FAILED)
        return
    end
    installed = true
    PlaceTab()
    if type(InspectFrame.UpdateTabs) == "function" then
        hooksecurefunc(InspectFrame, "UpdateTabs", PlaceTab)
    end
    InspectFrame:HookScript("OnShow", PlaceTab)
end

local function InspectLoaded()
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    return InspectFrame ~= nil and (not isLoaded or isLoaded("Blizzard_InspectUI") == true)
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(self, event, arg1)
    if event ~= "ADDON_LOADED" or not active then return end
    if arg1 == "Blizzard_InspectUI" then
        Install()
    elseif arg1 == "Blizzard_PlayerSpells" then
        InstallBack()
    end
    if (installed or failed) and backInstalled then self:UnregisterEvent("ADDON_LOADED") end
end)

ns:RegisterFeature({
    key = KEY,
    category = "frames",
    order = 30,
    title = "INSPECTTALENTS_TITLE",
    desc = "INSPECTTALENTS_DESC",
    tip = "INSPECTTALENTS_TIP",
    default = true,
    isNew = true,
    OnEnable = function()
        active = true
        if InspectLoaded() then Install() end
        InstallBack()
        if not ((installed or failed) and backInstalled) then
            -- Both windows are loaded on demand.
            events:RegisterEvent("ADDON_LOADED")
        end
        PlaceTab()
        UpdateBack()
    end,
    OnDisable = function()
        -- The safety net stays: what was tainted lasts until a reload.
        active = false
        PlaceTab()
        UpdateBack()
    end,
})
