local _, ns = ...
local L, Util = ns.L, ns.Util

--[[
Target button in the player right-click menu (chat names, friends, guild).

Why it is built this way:
  TargetUnit() is protected. A menu entry created by an addon runs addon
  (insecure) code when clicked, so it can never target. Blizzard's own
  Target entry only exists for menus that carry a unit token, which chat
  menus do not.

  So, out of combat, an invisible SecureActionButton is laid over the
  Target row while the menu is open. Clicking it runs the macro:
      /targetexact <name>
      /click BudgetForeverTargetRelay
  The relay is a secure "click" button that clicks the real menu row, so
  Blizzard's menu runs its normal pick/close path instead of addon code
  closing the menu (which would taint the menu manager).

  Both secure buttons set useOnKeyDown = false so they act on release no
  matter how the player set the ActionButtonUseKeyDown CVar.

  In combat secure frames cannot be moved or reconfigured, so the entry is
  shown greyed out with an explanation instead.
]]

local MENU_TAGS = {
    "MENU_UNIT_FRIEND",                     -- chat names, character friends
    "MENU_UNIT_CHAT_ROSTER",                -- chat channel roster
    "MENU_UNIT_GUILD",                      -- guild roster
    "MENU_UNIT_COMMUNITIES_GUILD_MEMBER",
    "MENU_UNIT_COMMUNITIES_WOW_MEMBER",
}

local RELAY_NAME = "BudgetForeverTargetRelay"
local HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight" -- same as Blizzard menu rows

local registered = false
local overlay, relay
local pendingName

local function TargetMatches(fullName)
    return Util.UnitIs("target", fullName)
end

---------------------------------------------------------------------------
-- Secure overlay
---------------------------------------------------------------------------

local function Detach()
    if not overlay or not overlay.host or InCombatLockdown() then return end
    overlay.host, overlay.targetName = nil, nil
    pendingName = nil
    overlay:Hide()
    overlay:ClearAllPoints()
    overlay:SetParent(UIParent)
    overlay:SetAttribute("macrotext", nil)
    relay:SetAttribute("clickbutton", nil)
end

local function CreateSecureButtons()
    if overlay then return true end
    if InCombatLockdown() then return false end

    relay = CreateFrame("Button", RELAY_NAME, UIParent, "SecureActionButtonTemplate")
    relay:SetAttribute("type", "click")
    relay:SetAttribute("useOnKeyDown", false) -- /click sends down = false
    relay:SetSize(1, 1)
    relay:SetPoint("TOPRIGHT", UIParent, "TOPLEFT", -10, 10) -- off screen
    relay:EnableMouse(false)

    overlay = CreateFrame("Button", "BudgetForeverTargetOverlay", UIParent, "SecureActionButtonTemplate")
    overlay:Hide()
    overlay:SetAttribute("type", "macro")
    overlay:SetAttribute("useOnKeyDown", false)
    overlay:RegisterForClicks("LeftButtonUp")

    local highlight = overlay:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture(HIGHLIGHT)
    highlight:SetBlendMode("ADD")

    overlay:SetScript("PreClick", function(self)
        pendingName = self.targetName
    end)

    -- Runs after the macro: /targetexact has already happened. Feedback is
    -- given here so it works even if the relay could not click the row.
    overlay:SetScript("PostClick", function()
        local name = pendingName
        pendingName = nil
        if name and not TargetMatches(name) then
            ns:Error(L.CHAT_TARGET_NOT_FOUND:format(name))
        end
    end)

    -- The row hides when the menu closes; release the overlay next frame so
    -- it never lingers on a pooled row reused by another menu.
    overlay:SetScript("OnHide", function(self)
        local host = self.host
        if not host then return end
        C_Timer.After(0, function()
            if overlay.host == host and not host:IsVisible() then Detach() end
        end)
    end)

    local events = CreateFrame("Frame")
    -- Fires just before combat lockdown starts: last chance to detach.
    events:RegisterEvent("PLAYER_REGEN_DISABLED")
    events:SetScript("OnEvent", Detach)
    return true
end

local function Attach(row, fullName)
    if InCombatLockdown() or not ns:IsEnabled("chatTarget") then return end
    if not row or row:IsForbidden() or not CreateSecureButtons() then return end

    overlay:SetAttribute("macrotext", ("/targetexact %s\n/click %s"):format(fullName, RELAY_NAME))
    relay:SetAttribute("clickbutton", row)

    overlay.host, overlay.targetName = row, fullName
    overlay:SetParent(row)
    overlay:ClearAllPoints()
    overlay:SetAllPoints(row)
    overlay:SetFrameStrata(row:GetFrameStrata())
    overlay:SetFrameLevel(math.min(row:GetFrameLevel() + 10, 10000))
    overlay:Show()
end

---------------------------------------------------------------------------
-- Menu entry
---------------------------------------------------------------------------

-- Runs when the real row is picked. Through the relay (overlay click in
-- progress) there is nothing to do: PostClick reports the result. A direct
-- pick means the overlay was not attached, e.g. combat started meanwhile.
local function OnPicked(fullName)
    if pendingName == fullName then return end
    if InCombatLockdown() then
        ns:Error(L.CHAT_TARGET_COMBAT)
    else
        ns:Error(L.CHAT_TARGET_FAILED:format(fullName))
    end
end

local function IsUsable()
    return not InCombatLockdown()
end

local function SetupTooltip(tooltip)
    local title = TARGET or "Target"
    if GameTooltip_SetTitle then
        GameTooltip_SetTitle(tooltip, title)
    else
        tooltip:SetText(title)
    end
    local inCombat = InCombatLockdown()
    local line = inCombat and L.CHAT_TARGET_COMBAT or L.CHAT_TARGET_RANGE
    if inCombat and GameTooltip_AddErrorLine then
        GameTooltip_AddErrorLine(tooltip, line)
    elseif GameTooltip_AddNormalLine then
        GameTooltip_AddNormalLine(tooltip, line)
    else
        tooltip:AddLine(line, 1, 1, 1, true)
    end
end

local function AddTargetEntry(_, root, context)
    if not ns:IsEnabled("chatTarget") or not Util.ReadableTable(context) then return end
    if Util.Readable(context.isMobile) and context.isMobile then return end

    local fullName = Util.FullName(context)
    if not fullName or Util.IsSelf(fullName) then return end

    local label = TARGET or "Target"
    if Util.FindMenuElement(root, label) then return end -- Blizzard already offers it

    local function OnClick() OnPicked(fullName) end
    local entry
    local whisperIndex = Util.FindMenuElement(root, WHISPER)
    if whisperIndex and root.Insert and MenuUtil.CreateButton then
        entry = MenuUtil.CreateButton(label, OnClick)
        if not pcall(root.Insert, root, entry, whisperIndex + 1) then entry = nil end
    end
    if not entry then
        Util.MenuSection(root)
        entry = root:CreateButton(label, OnClick)
    end

    entry:SetEnabled(IsUsable)
    if entry.SetTooltip then entry:SetTooltip(SetupTooltip) end
    entry:AddInitializer(function(row)
        Attach(row, fullName)
    end)
end

local function Register()
    if registered or not Menu or not Menu.ModifyMenu then return end
    registered = true
    for _, tag in ipairs(MENU_TAGS) do
        Menu.ModifyMenu(tag, AddTargetEntry)
    end
end

ns:RegisterFeature({
    key = "chatTarget",
    category = "social",
    order = 10,
    title = "CHAT_TARGET_TITLE",
    desc = function() return L.CHAT_TARGET_DESC:format(TARGET or "Target") end,
    tip = "CHAT_TARGET_TIP",
    default = true,
    isNew = true,
    -- The menu hook stays registered and checks the setting each time a
    -- menu opens, so toggling is live.
    OnEnable = Register,
    OnDisable = Detach,
})
