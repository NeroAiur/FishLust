-- MinimapButton.lua: Minimap button for FishLust
-- Ported from AccountPlayed minimap system:
--   - Fade in/out on hover (invisible at edge until mouse-over)
--   - Lock/unlock via right-click (prevents accidental dragging)
--   - Cached drag values (no per-frame recalculation)
--   - Minimap OnEnter/OnLeave hooks for edge reveal
--   - Cleanup on hide
--   - Reset exposed on addon table for slash command use
-- Hybrid snap/free-form positioning:
--   - Snaps to minimap edge when close (round minimap)
--   - Breaks free for arbitrary positioning (ElvUI / square minimap)
-- HUGE shoutout to Amadeus!! - https://github.com/Amadeus-

local addonName, addon = ...

local BUTTON_NAME = "FishLust_MinimapButton"

--------------------------------------------------
-- DB Init
--------------------------------------------------
local function InitDB()
    if not FishLustDB then
        FishLustDB = {}
    end

    if not FishLustDB.minimap then
        FishLustDB.minimap = {}
    end

    -- Migrate: if old angle-based data exists, convert to x,y
    if FishLustDB.minimap.angle and not FishLustDB.minimap.x then
        local angle = math.rad(FishLustDB.minimap.angle)
        local radius = 105
        FishLustDB.minimap.x = math.cos(angle) * radius
        FishLustDB.minimap.y = math.sin(angle) * radius
        FishLustDB.minimap.angle = nil
    end

    -- Default position: bottom-left of minimap (225 degrees)
    if not FishLustDB.minimap.x then
        local angle = math.rad(225)
        local radius = 105
        FishLustDB.minimap.x = math.cos(angle) * radius
        FishLustDB.minimap.y = math.sin(angle) * radius
    end

    if FishLustDB.minimap.hide == nil then
        FishLustDB.minimap.hide = false
    end

    if FishLustDB.minimap.locked == nil then
        FishLustDB.minimap.locked = false
    end
end

--------------------------------------------------
-- Positioning
--------------------------------------------------
local function UpdateButtonPosition(button)
    local x = FishLustDB.minimap.x or 0
    local y = FishLustDB.minimap.y or 0
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

--------------------------------------------------
-- Fade (Blizzard built-in, 0 CPU when idle)
--------------------------------------------------
local function FadeButton(btn, targetAlpha, duration)
    duration = duration or 0.15
    UIFrameFadeRemoveFrame(btn)

    local currentAlpha = btn:GetAlpha()
    if math.abs(targetAlpha - currentAlpha) < 0.01 then return end

    if targetAlpha > currentAlpha then
        UIFrameFadeIn(btn, duration, currentAlpha, targetAlpha)
    else
        UIFrameFadeOut(btn, duration, currentAlpha, targetAlpha)
    end
end

--------------------------------------------------
-- Creation
--------------------------------------------------
local function CreateMinimapButton()
    if FishLustDB.minimap.hide then return end

    if _G[BUTTON_NAME] then
        UpdateButtonPosition(_G[BUTTON_NAME])
        return _G[BUTTON_NAME]
    end

    local btn = CreateFrame("Button", BUTTON_NAME, Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetMovable(true)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetClampedToScreen(true)
    btn:SetAlpha(0.01)  -- Start invisible; reveals on hover when snapped

    --------------------------------------------------
    -- Border
    --------------------------------------------------
    btn.border = btn:CreateTexture(nil, "OVERLAY")
    btn.border:SetSize(53, 53)
    btn.border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    btn.border:SetPoint("TOPLEFT")

    --------------------------------------------------
    -- Icon
    --------------------------------------------------
    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetSize(17, 17)
    btn.icon:SetTexture("Interface\\Icons\\Spell_Nature_BloodLust")
    btn.icon:SetPoint("CENTER")
    btn.icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)

    --------------------------------------------------
    -- Highlight
    --------------------------------------------------
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")

    --------------------------------------------------
    -- Tooltip + Hover Fade
    --------------------------------------------------
    btn:SetScript("OnEnter", function(self)
        if FishLustDB.minimap.hide then return end

        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cff00bfffFishLust|r", 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("|cffff8800Left Click:|r",  "|cff00ff00Open Settings|r")
        if not FishLustDB.minimap.locked then
            GameTooltip:AddDoubleLine("|cffff8800Drag:|r", "|cffffff00Move Icon|r")
        end
        GameTooltip:AddDoubleLine("|cffff8800Right Click:|r", "|cffff8800Lock / Unlock|r")
        GameTooltip:AddLine(" ")
        local lockStatus = FishLustDB.minimap.locked
            and "|cffff0000[Locked]|r"
            or  "|cff00ff00[Unlocked]|r"
        GameTooltip:AddLine(lockStatus, 1, 1, 1)
        GameTooltip:Show()

        if self.snapped and not FishLustDB.minimap.hide then
            FadeButton(self, 1, 0.15)
        end
    end)

    btn:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        if self.snapped and not Minimap:IsMouseOver() then
            FadeButton(self, 0.01, 0.15)
        end
    end)

    --------------------------------------------------
    -- Minimap edge hover (reveal button on approach)
    --------------------------------------------------
    Minimap:HookScript("OnEnter", function()
        if not btn.isDragging and btn.snapped and not FishLustDB.minimap.hide then
            FadeButton(btn, 1, 0.15)
        end
    end)

    Minimap:HookScript("OnLeave", function()
        if not btn.isDragging and btn.snapped and not btn:IsMouseOver() then
            FadeButton(btn, 0.01, 0.15)
        end
    end)

    --------------------------------------------------
    -- Click
    --------------------------------------------------
    btn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            if addon and addon.ToggleSettings then
                addon:ToggleSettings()
            elseif SlashCmdList["FishLust"] then
                SlashCmdList["FishLust"]("settings")
            end

        elseif button == "RightButton" then
            FishLustDB.minimap.locked = not FishLustDB.minimap.locked
            local state = FishLustDB.minimap.locked
            PlaySound(state and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
                              or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
            print(string.format(
                "|cff00bfff[FishLust]|r Minimap button %s",
                state and "|cffff0000locked|r" or "|cff00ff00unlocked|r"
            ))
            -- Refresh tooltip
            if GameTooltip:GetOwner() == self then
                self:GetScript("OnEnter")(self)
            end
        end
    end)

    --------------------------------------------------
    -- Drag (cached values, respects lock)
    --------------------------------------------------
    btn:SetScript("OnDragStart", function(self)
        if FishLustDB.minimap.locked then
            print("|cff00bfff[FishLust]|r Minimap button is locked. Right-click to unlock.")
            return
        end

        self.isDragging = true

        -- Cache everything that won't change during the drag
        local minimap        = Minimap
        local minimapScale   = minimap:GetEffectiveScale()
        local mmCX, mmCY     = minimap:GetCenter()
        local edgeRadius     = (minimap:GetWidth() + self:GetWidth()) / 2
        local RADIUS_ADJUST  = -5
        local radSnap        = edgeRadius + RADIUS_ADJUST
        local radPull        = edgeRadius + self:GetWidth() * 0.2
        local radFree        = edgeRadius + self:GetWidth() * 0.7

        self:SetScript("OnUpdate", function(self)
            local cx, cy = GetCursorPosition()
            cx, cy = cx / minimapScale, cy / minimapScale
            local dx, dy = cx - mmCX, cy - mmCY
            local dist = (dx * dx + dy * dy) ^ 0.5

            local radClamp
            if dist <= radSnap then
                self.snapped = true
                radClamp = radSnap
            elseif dist < radPull and self.snapped then
                radClamp = radSnap
            elseif dist < radFree and self.snapped then
                radClamp = radSnap + (dist - radPull) / 2
            else
                self.snapped = false
            end

            if radClamp and dist > 0 then
                local factor = radClamp / dist
                dx = dx * factor
                dy = dy * factor
            end

            FishLustDB.minimap.x = dx
            FishLustDB.minimap.y = dy
            self:ClearAllPoints()
            self:SetPoint("CENTER", minimap, "CENTER", dx, dy)
        end)
    end)

    btn:SetScript("OnDragStop", function(self)
        self.isDragging = false
        self:SetScript("OnUpdate", nil)

        -- Restore correct fade state after drop
        if self.snapped and Minimap:IsMouseOver() then
            FadeButton(self, 1, 0.15)
        elseif self.snapped then
            FadeButton(self, 0.01, 0.15)
        else
            FadeButton(self, 1, 0.15)  -- free-floating: always visible
        end
    end)

    --------------------------------------------------
    -- Cleanup on hide
    --------------------------------------------------
    btn:HookScript("OnHide", function(self)
        UIFrameFadeRemoveFrame(self)
        self:SetScript("OnUpdate", nil)
        self.isDragging = false
    end)

    --------------------------------------------------
    -- Initial state
    --------------------------------------------------
    local edgeRadius = (Minimap:GetWidth() + btn:GetWidth()) / 2
    local savedDist  = (FishLustDB.minimap.x ^ 2 + FishLustDB.minimap.y ^ 2) ^ 0.5
    btn.snapped = (savedDist <= edgeRadius + btn:GetWidth() * 0.3)

    -- Snapped: invisible until hovered. Free: always visible.
    btn:SetAlpha(btn.snapped and 0.01 or 1)

    UpdateButtonPosition(btn)

    if FishLustDB.minimap.hide then
        btn:Hide()
    end

    return btn
end

--------------------------------------------------
-- Reset (called by /FishLust reset minimap)
--------------------------------------------------
function addon.ResetMinimapButton()
    local angle  = math.rad(225)
    local radius = 105
    FishLustDB.minimap.x      = math.cos(angle) * radius
    FishLustDB.minimap.y      = math.sin(angle) * radius
    FishLustDB.minimap.hide   = false
    FishLustDB.minimap.locked = false

    local btn = _G[BUTTON_NAME]
    if btn then
        btn.snapped = true
        UIFrameFadeRemoveFrame(btn)
        btn:EnableMouse(true)
        btn:Show()
        btn:SetAlpha(0.01)
        UpdateButtonPosition(btn)
        print("|cff00bfff[FishLust]|r Minimap button reset to default position.")
    else
        -- Button was hidden, recreate it
        CreateMinimapButton()
        print("|cff00bfff[FishLust]|r Minimap button restored.")
    end
end

-- Expose so other files can call it
addon.CreateMinimapButton = CreateMinimapButton

--------------------------------------------------
-- Slash Command Hook
--------------------------------------------------
local originalSlashHandler
local function HookSlashCommand()
    if not SlashCmdList["FishLust"] then
        C_Timer.After(0.5, HookSlashCommand)
        return
    end

    originalSlashHandler = SlashCmdList["FishLust"]
    SlashCmdList["FishLust"] = function(msg)
        if msg == "minimap" then
            FishLustDB.minimap.hide = not FishLustDB.minimap.hide
            local btn = _G[BUTTON_NAME]
            if btn then
                if FishLustDB.minimap.hide then
                    btn:Hide()
                    print("|cff00bfff[FishLust]|r Minimap button hidden.")
                else
                    btn:Show()
                    btn:SetAlpha(btn.snapped and 0.01 or 1)
                    print("|cff00bfff[FishLust]|r Minimap button shown.")
                end
            else
                -- Was never created (hidden on load), create it now
                if not FishLustDB.minimap.hide then
                    CreateMinimapButton()
                end
            end
        elseif msg == "minimap reset" then
            addon.ResetMinimapButton()
        elseif msg == "minimap lock" then
            FishLustDB.minimap.locked = true
            print("|cff00bfff[FishLust]|r Minimap button |cffff0000locked|r.")
        elseif msg == "minimap unlock" then
            FishLustDB.minimap.locked = false
            print("|cff00bfff[FishLust]|r Minimap button |cff00ff00unlocked|r.")
        else
            originalSlashHandler(msg)
        end
    end
end

--------------------------------------------------
-- Init
--------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    InitDB()
    CreateMinimapButton()
    HookSlashCommand()
end)
