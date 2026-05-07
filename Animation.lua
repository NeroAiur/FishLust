-- Animation.lua: Animated sprite display for FishLust

local addonName, addon = ...

-- Animation sprite configs (keyed by animationStyle value)
local THEMES = {
    fish = {
        texture    = "Interface\\AddOns\\FishLust\\fish.tga",
        frameCount = 4,
        columns    = 2,
        rows       = 2,
    },
    pedro = {
        texture    = "Interface\\AddOns\\FishLust\\pedrolust.tga",
        frameCount = 32,
        columns    = 4,
        rows       = 8,
    },
    text = {
        isText     = true,
        frameCount = 1,
        columns    = 1,
        rows       = 1,
    },
    -- "none" is handled by early-exit in StartAnimation; no entry needed
}

-- Animation state
local animState = {
    isPlaying = false,
    currentFrame = 0,
    frameCount = 4,
    fps = 8,
    ticker = nil,
    columns = 2,
    rows = 2,
}

-- MEMORY LEAK FIX: Debouncing
local lastAnimStart = 0
local lastAnimStop = 0
local ANIM_COOLDOWN = 0.3  -- Minimum time between start/stop calls

-- MEMORY LEAK FIX: Track pending timers
local pendingTimers = {}

-- Create animation frame
local animFrame = CreateFrame("Frame", "FishLustAnimFrame", UIParent)
animFrame:SetSize(128, 128)
animFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
animFrame:Hide()

-- Create texture (hidden for text theme)
local animTexture = animFrame:CreateTexture(nil, "ARTWORK")
animTexture:SetAllPoints(animFrame)

-- Create text display (shown only for text theme)
local animText = animFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
animText:SetAllPoints(animFrame)
animText:SetJustifyH("CENTER")
animText:SetJustifyV("MIDDLE")
animText:SetTextColor(1, 1, 0)   -- bright yellow, easy to see
animText:SetFont("Fonts\\FRIZQT__.TTF", 32, "OUTLINE")
animText:Hide()

-- Get current animation style safely
local function GetCurrentTheme()
    if not FishLustDB then return "fish" end
    local style = FishLustDB.animationStyle or "fish"
    if not THEMES[style] then return "fish" end
    return style
end

-- Update texture/text based on theme
local function UpdateTexture()
    local theme       = GetCurrentTheme()
    local themeConfig = THEMES[theme]

    if not themeConfig then
        print("|cff00bfff[FishLust]|r |cffff0000ERROR:|r Invalid theme configuration")
        return false
    end

    if themeConfig.isText then
        -- Text theme: hide sprite texture, show FontString
        animTexture:SetTexture(nil)
        animText:SetText(FishLustDB and FishLustDB.partyText or "PARTY TIME!")
        animState.frameCount = 1
        animState.columns    = 1
        animState.rows       = 1
    else
        -- Sprite theme: hide text, set texture
        animTexture:SetTexture(themeConfig.texture)
        animState.frameCount = themeConfig.frameCount or 4
        animState.columns    = themeConfig.columns    or 2
        animState.rows       = themeConfig.rows       or 2
    end

    return true
end

-- Calculate texture coordinates
local function GetFrameCoords(frameIndex)
    if frameIndex >= animState.frameCount then
        frameIndex = 0
    end
    
    local col = frameIndex % animState.columns
    local row = math.floor(frameIndex / animState.columns)
    
    local frameWidth = 1.0 / animState.columns
    local frameHeight = 1.0 / animState.rows
    
    local left = col * frameWidth
    local right = left + frameWidth
    local top = row * frameHeight
    local bottom = top + frameHeight
    
    return left, right, top, bottom
end

-- Update animation frame
local function UpdateAnimationFrame()
    if not animState.isPlaying then
        return
    end
    
    local left, right, top, bottom = GetFrameCoords(animState.currentFrame)
    animTexture:SetTexCoord(left, right, top, bottom)
    animState.currentFrame = (animState.currentFrame + 1) % animState.frameCount
end

-- MEMORY LEAK FIX: Cancel all pending timers
local function CancelPendingTimers()
    for i = #pendingTimers, 1, -1 do
        local timer = pendingTimers[i]
        if timer then
            timer:Cancel()
        end
        pendingTimers[i] = nil
    end
    wipe(pendingTimers)
end

-- Stop ticker safely
local function StopTicker()
    if animState.ticker then
        animState.ticker:Cancel()
        animState.ticker = nil
    end
end

-- Start ticker
local function StartTicker()
    StopTicker()
    
    local interval = 1.0 / animState.fps
    animState.ticker = C_Timer.NewTicker(interval, function()
        if not animState.isPlaying then
            StopTicker()
            return
        end
        UpdateAnimationFrame()
    end)
end

-- MEMORY LEAK FIX: Remove all animation groups
local function CleanupAnimationGroups()
    -- Stop any fade animations
    UIFrameFadeRemoveFrame(animFrame)
end

-- Apply the current lock state to the frame (mouse interaction)
local function ApplyLockState()
    local locked = FishLustDB and FishLustDB.animationLocked
    -- Disable/enable mouse so the frame can't be grabbed when locked
    animFrame:EnableMouse(not locked)
end

-- Start animation (WITH MEMORY LEAK FIXES)
function addon:StartAnimation()
    -- Respect the enable flag set in settings
    if FishLustDB and FishLustDB.animationStyle == "none" then
        if printDebug then printDebug("|cff00bfff[FishLust]|r Animation set to None, skipping.") end
        return
    end

    -- DEBOUNCE: Prevent rapid restarts
    local now = GetTime()
    if now - lastAnimStart < ANIM_COOLDOWN then
        if FishLustDB and FishLustDB.debugMode then
            print("|cff00bfff[FishLust]|r Animation start blocked - cooldown active")
        end
        return
    end
    lastAnimStart = now
    
    -- If already playing, don't restart
    if animState.isPlaying then
        return
    end
    
    -- Cleanup any existing animations first
    CleanupAnimationGroups()
    CancelPendingTimers()
    
    -- Update texture
    if not UpdateTexture() then
        print("|cff00bfff[FishLust]|r |cffff0000ERROR:|r Failed to load animation texture")
        return
    end
    
    -- Apply saved settings
    if FishLustDB then
        if FishLustDB.animationSize then
            animFrame:SetSize(FishLustDB.animationSize, FishLustDB.animationSize)
        end
        if FishLustDB.animationFPS then
            animState.fps = FishLustDB.animationFPS
        end
        if FishLustDB.animationX and FishLustDB.animationY then
            animFrame:ClearAllPoints()
            animFrame:SetPoint("CENTER", UIParent, "CENTER", FishLustDB.animationX, FishLustDB.animationY)
        end
    end
    
    -- Reapply lock state every time animation shows (covers /reload and session restore)
    ApplyLockState()

    animState.isPlaying = true
    animState.currentFrame = 0

    local isTextTheme = THEMES[GetCurrentTheme()] and THEMES[GetCurrentTheme()].isText
    if isTextTheme then
        -- Text theme: show FontString, hide sprite texture, skip ticker
        animTexture:Hide()
        animText:SetText(FishLustDB and FishLustDB.partyText or "PARTY TIME!")
        animText:Show()
    else
        -- Sprite theme: hide text, show texture, start ticker
        animText:Hide()
        animTexture:Show()
        UpdateAnimationFrame()
        StartTicker()
    end

    animFrame:Show()

    -- Fade in
    animFrame:SetAlpha(0)
    UIFrameFadeIn(animFrame, 0.3, 0, 1)

    if FishLustDB and FishLustDB.debugMode then
        local theme = GetCurrentTheme()
        print("|cff00bfff[FishLust]|r |cffff1493Animation started!|r (Theme: " .. theme .. ")")
    end
end

-- Stop animation (WITH MEMORY LEAK FIXES)
function addon:StopAnimation()
    -- DEBOUNCE: Prevent rapid stops
    local now = GetTime()
    if now - lastAnimStop < ANIM_COOLDOWN then
        return
    end
    lastAnimStop = now
    
    if not animState.isPlaying then
        return
    end
    
    animState.isPlaying = false
    StopTicker()
    animText:Hide()   -- ensure text is cleared regardless of theme

    -- Cleanup animation groups before creating new one
    CleanupAnimationGroups()
    
    -- Fade out
    UIFrameFadeOut(animFrame, 0.3, 1, 0)
    
    -- Store timer reference for cleanup
    local hideTimer = C_Timer.NewTimer(0.3, function()
        animFrame:Hide()
        CleanupAnimationGroups()
    end)
    table.insert(pendingTimers, hideTimer)
    
    if FishLustDB and FishLustDB.debugMode then
        print("|cff00bfff[FishLust]|r |cffff1493Animation stopped!|r")
    end
end

-- Make frame draggable
animFrame:SetMovable(true)
animFrame:EnableMouse(true)
animFrame:RegisterForDrag("LeftButton")
animFrame:SetScript("OnDragStart", function(self)
    -- Respect position lock
    if FishLustDB and FishLustDB.animationLocked then
        print("|cff00bfff[FishLust]|r Animation position is locked. Uncheck |cffff8800Lock Position|r in Settings to move it.")
        return
    end
    self:StartMoving()
end)
animFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    -- GetPoint() after StopMovingOrSizing can return an offset relative to an
    -- arbitrary anchor WoW chose during the drag, not UIParent CENTER.
    -- Calculate the true CENTER-relative offset from raw screen coordinates so
    -- that StartAnimation always restores to exactly the right spot.
    local pWidth  = UIParent:GetWidth()
    local pHeight = UIParent:GetHeight()
    local x = (self:GetLeft() + self:GetWidth()  / 2) - pWidth  / 2
    local y = (self:GetBottom() + self:GetHeight() / 2) - pHeight / 2
    if FishLustDB then
        FishLustDB.animationX = x
        FishLustDB.animationY = y
    end
    -- Re-anchor cleanly so the frame's internal anchor is always consistent
    self:ClearAllPoints()
    self:SetPoint("CENTER", UIParent, "CENTER", x, y)
end)

-- Update FPS
function addon:UpdateAnimationFPS(fps)
    animState.fps = fps
    if animState.isPlaying then
        StartTicker()
    end
end

-- Live-update the party text while the animation is running
function addon:UpdatePartyText(text)
    FishLustDB.partyText = text
    if animState.isPlaying and THEMES[GetCurrentTheme()].isText then
        animText:SetText(text)
    end
end

-- Update texture when theme changes
function addon:UpdateAnimationTexture()
    local wasPlaying = animState.isPlaying
    
    if wasPlaying then
        self:StopAnimation()
    end
    
    UpdateTexture()
    
    if wasPlaying then
        -- Use timer to avoid rapid restart
        local restartTimer = C_Timer.NewTimer(0.2, function()
            self:StartAnimation()
        end)
        table.insert(pendingTimers, restartTimer)
    end
end

-- Lock/unlock animation position
-- Persists via FishLustDB.animationLocked (saved variable)
function addon:SetAnimationLocked(locked)
    FishLustDB.animationLocked = locked
    ApplyLockState()

    if locked then
        print("|cff00bfff[FishLust]|r Animation position |cffff0000locked|r.")
    else
        print("|cff00bfff[FishLust]|r Animation position |cff00ff00unlocked|r.")
    end
end

-- MEMORY LEAK FIX: Comprehensive cleanup
local function CleanupAnimation()
    animState.isPlaying = false
    StopTicker()
    CancelPendingTimers()
    CleanupAnimationGroups()
    animFrame:Hide()
    animFrame:SetAlpha(1)
end

-- Slash commands
SLASH_DJLANIM1 = "/djlanim"
SLASH_DJLANIM2 = "/djla"
SlashCmdList["DJLANIM"] = function(msg)
    if msg == "start" or msg == "play" then
        addon:StartAnimation()
    elseif msg == "stop" then
        addon:StopAnimation()
    elseif msg == "toggle" then
        if animState.isPlaying then
            addon:StopAnimation()
        else
            addon:StartAnimation()
        end
    elseif msg == "lock" then
        addon:SetAnimationLocked(true)
    elseif msg == "unlock" then
        addon:SetAnimationLocked(false)
    elseif msg == "info" then
        print("|cff00bfff[FishLust Animation] Info:|r")
        print("  Theme:", GetCurrentTheme())
        print("  Frame count:", animState.frameCount)
        print("  Grid:", animState.columns .. "x" .. animState.rows)
        print("  Current frame:", animState.currentFrame)
        print("  FPS:", animState.fps)
        print("  Playing:", animState.isPlaying and "Yes" or "No")
        print("  Position locked:", (FishLustDB and FishLustDB.animationLocked) and "|cffff0000Yes|r" or "|cff00ff00No|r")
        local theme = THEMES[GetCurrentTheme()]
        print("  Texture:", theme.texture)
        print("  Ticker active:", animState.ticker and "Yes" or "No")
        print("  Pending timers:", #pendingTimers)
    elseif msg == "reset" then
        -- Reset clears the lock so the position can be set freely
        if FishLustDB and FishLustDB.animationLocked then
            print("|cff00bfff[FishLust]|r Position was locked - unlocking before reset.")
            addon:SetAnimationLocked(false)
        end
        animFrame:ClearAllPoints()
        animFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        if FishLustDB then
            FishLustDB.animationX = 0
            FishLustDB.animationY = 0
        end
        print("|cff00bfff[FishLust]|r Animation position reset to center")
    elseif msg == "cleanup" then
        CleanupAnimation()
        collectgarbage("collect")
        print("|cff00bfff[FishLust]|r Animation cleanup complete")
    elseif msg:match("^size") then
        local size = tonumber(msg:match("^size%s+(%d+)"))
        if size and size >= 32 and size <= 512 then
            animFrame:SetSize(size, size)
            if FishLustDB then
                FishLustDB.animationSize = size
            end
            print("|cff00bfff[FishLust]|r Animation size set to " .. size .. "x" .. size)
        else
            print("|cff00bfff[FishLust]|r Usage: /djlanim size <32-512>")
        end
    elseif msg:match("^fps") then
        local fps = tonumber(msg:match("^fps%s+(%d+)"))
        if fps and fps >= 1 and fps <= 60 then
            addon:UpdateAnimationFPS(fps)
            if FishLustDB then
                FishLustDB.animationFPS = fps
            end
            print("|cff00bfff[FishLust]|r Animation FPS set to " .. fps)
        else
            print("|cff00bfff[FishLust]|r Usage: /djlanim fps <1-60>")
        end
    else
        print("|cff00bfff[FishLust Animation] [HELP]\nAvailable Commands:|r")
        print("  |cffff1493/djlanim start|r - Start animation")
        print("  |cffff1493/djlanim stop|r - Stop animation")
        print("  |cffff1493/djlanim toggle|r - Toggle animation on/off")
        print("  |cffff1493/djlanim lock|r - Lock animation position")
        print("  |cffff1493/djlanim unlock|r - Unlock animation position")
        print("  |cffff1493/djlanim info|r - Show animation info")
        print("  |cffff1493/djlanim reset|r - Reset position to center (also unlocks)")
        print("  |cffff1493/djlanim cleanup|r - Force cleanup")
        print("  |cffff1493/djlanim size <number>|r - Set animation size (32-512)")
        print("  |cffff1493/djlanim fps <number>|r - Set animation speed (1-60)")
        print("|cff00bfff[TIP]|r Drag the animation with left mouse button to reposition (when unlocked)")
    end
end

-- Initialize on load
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:RegisterEvent("PLAYER_LOGOUT")
initFrame:SetScript("OnEvent", function(self, event, loadedAddon)
    if event == "ADDON_LOADED" and loadedAddon == addonName then
        UpdateTexture()
        
        if FishLustDB then
            if FishLustDB.animationSize then
                animFrame:SetSize(FishLustDB.animationSize, FishLustDB.animationSize)
            end
            if FishLustDB.animationFPS then
                animState.fps = FishLustDB.animationFPS
            end
            if FishLustDB.animationX and FishLustDB.animationY then
                animFrame:ClearAllPoints()
                animFrame:SetPoint("CENTER", UIParent, "CENTER", FishLustDB.animationX, FishLustDB.animationY)
            end
            -- Restore persisted lock state on load
            ApplyLockState()
        end
    elseif event == "PLAYER_LOGOUT" then
        CleanupAnimation()
    end
end)
