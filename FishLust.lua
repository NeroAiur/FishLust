local addonName, addon = ...

local SATED_DEBUFF_IDS = {
    [57723]  = true, -- Exhaustion            (Heroism / Fury of the Aspects / Primal Rage)
    [57724]  = true, -- Sated                 (Bloodlust)
    [80354]  = true, -- Temporal Displacement (Time Warp)
    [95809]  = true, -- Insanity              (Ancient Hysteria - Core Hound pet)
    [160455] = true, -- Fatigued              (Drums of the Maelstrom)
    [264689] = true, -- Fatigued              (Hunter pet variant)
    [390435] = true, -- Exhaustion            (additional variant)
}

-- Track state
local isLusted      = false
local activeDebufID = nil  -- Sated-type debuff ID that triggered detection
local lustEndTimer  = nil  -- C_Timer handle; stops music after lust duration
local debugAddon    = false

-- Sound handle management
local soundHandlePool = {}
local lastPlayTime    = 0
local PLAY_COOLDOWN   = 0.5

-- CVar caching
local originalChannelVolume = nil
local cvarDirty             = false

-- Sound channel -> CVar mapping
local CHANNEL_CVARS = {
    Master   = "Sound_MasterVolume",
    SFX      = "Sound_SFXVolume",
    Dialog   = "Sound_DialogVolume",
    Music    = "Sound_MusicVolume",
    Ambience = "Sound_AmbienceVolume",
}

-- Built-in music file paths (defined early, no DB dependency)
local BUILTIN_MUSIC = {
    fish = "Interface\\AddOns\\FishLust\\fish.mp3"
}

-- Forward declarations so OnPlayerAuraUpdate (defined before the sound
-- functions) can reference them without resolving to nil globals.
local PlayFishLust, StopFishLust

-- Event frame
local frame = CreateFrame("Frame")

-- ─── DB INIT (deferred until SavedVariables are loaded) ──────────────────────
-- Mirrors BudgetPedro's EventUtil.ContinueOnAddOnLoaded pattern: all code that
-- touches FishLustDB runs after ADDON_LOADED, when SavedVariables are guaranteed
-- to be available. Without this, FishLustDB reads always return defaults.
EventUtil.ContinueOnAddOnLoaded(addonName, function()
    FishLustDB = FishLustDB or {}

    -- Schema migration v1 (theme/customSong) → v2 (animationStyle/music)
    if FishLustDB.theme and not FishLustDB.animationStyle then
        local styleMap = {fish = "fish"}
        FishLustDB.animationStyle = styleMap[FishLustDB.theme] or "fish"
        end
        FishLustDB.theme      = nil
    end
    -- get to work here, if I care to add the animations back in
    -- if FishLustDB.animationEnabled ~= nil then FishLustDB.animationEnabled = nil end
    -- Schema migration v2 (hasteThreshold) → v3 (aura-based, threshold unused)
    -- if FishLustDB.hasteThreshold ~= nil then FishLustDB.hasteThreshold = nil end

    -- FishLustDB.animationStyle = FishLustDB.animationStyle or "fish"
    FishLustDB.music          = FishLustDB.music          or ""
    FishLustDB.volume         = FishLustDB.volume         or 1.0
    FishLustDB.soundChannel   = FishLustDB.soundChannel   or "Master"
    if FishLustDB.animationLocked == nil then FishLustDB.animationLocked = false end
end)

-- Returns true + reason string if the given channel (or master) is muted/zero
local function IsChannelEffectivelyMuted(channel)
    if GetCVar("Sound_EnableAllSound") == "0" then
        return true, "all sound is globally disabled"
    end
    local masterVol = tonumber(GetCVar("Sound_MasterVolume")) or 0
    if masterVol <= 0 then
        return true, "master volume is 0"
    end
    local cvarName = CHANNEL_CVARS[channel]
    if cvarName then
        local vol = tonumber(GetCVar(cvarName)) or 0
        if vol <= 0 then
            return true, (channel .. " channel volume is 0")
        end
    end
    return false, nil
end

-- Get current music file path
local function GetMusicFile()
    if FishLustDB and FishLustDB.music and FishLustDB.music ~= "" then
        return FishLustDB.music
    end
    return BUILTIN_MUSIC.fish
end

-- Debug print helper
function printDebug(...)
    if not debugAddon then return end
    print("|cff00bfff[FishLust]|r |cffff8800[DEBUG]|r", ...)
end

local function SetDebug(enabled)
    debugAddon = enabled
    print(string.format("|cff00bfff[FishLust]|r Debug mode %s",
        enabled and "|cff00ff00ENABLED|r" or "|cffff0000DISABLED|r"))
end

-- ─── LUST DETECTION ──────────────────────────────────────────────────────────
-- Ported from BudgetPedro (MIT). Key insight: aura.spellId may be a secret
-- value in 12.0.5 — using it as a table key throws an error. issecretvalue()
-- lets us check first and skip protected IDs safely. Non-secret Sated debuff
-- IDs remain readable and are applied at the same instant as the lust buff.
--
-- Only fires on updateInfo.addedAuras (delta events). isFullUpdate events
-- (e.g. zoning in while already lusted) are intentionally skipped — the buff
-- has already been running and the music would be out of sync anyway.
--
-- Music stops via a 42-second timer (lust duration + 2s buffer) since we
-- can't watch for the buff to fall off without the same secret-value problem.
local LUST_DURATION = 42  -- seconds; all lust variants last 40s base

local function IsLust(spellId)
    if issecretvalue(spellId) then return false end
    return SATED_DEBUFF_IDS[spellId]
end

local function OnPlayerAuraUpdate(updateInfo)
    if isLusted then return end
    if not updateInfo or updateInfo.isFullUpdate then return end
    if not updateInfo.addedAuras or #updateInfo.addedAuras == 0 then return end

    for _, aura in ipairs(updateInfo.addedAuras) do
        if IsLust(aura.spellId) then
            isLusted      = true
            activeDebufID = aura.spellId
            printDebug("Lust detected via spellId:", aura.spellId)
            PlayFishLust()

            if lustEndTimer then lustEndTimer:Cancel() end
            lustEndTimer = C_Timer.NewTimer(LUST_DURATION, function()
                lustEndTimer  = nil
                isLusted      = false
                activeDebufID = nil
                StopFishLust()
                printDebug("Lust timer expired - stopping")
            end)
            return
        end
    end
end

-- ─── SOUND / ANIMATION ───────────────────────────────────────────────────────

local function CleanupSoundHandles()
    for i = #soundHandlePool, 1, -1 do
        local handle = soundHandlePool[i]
        if handle then StopSound(handle) end
        soundHandlePool[i] = nil
    end
    wipe(soundHandlePool)
end

local function RestoreChannelVolume()
    if cvarDirty and originalChannelVolume then
        local channel  = FishLustDB.soundChannel or "Master"
        local cvarName = CHANNEL_CVARS[channel] or "Sound_DialogVolume"
        SetCVar(cvarName, tostring(originalChannelVolume))
        cvarDirty = false
        originalChannelVolume = nil
        printDebug("Channel volume restored for", channel)
    end
end

-- Play music only (no animation) — used by the Test Music button
function addon:TestMusic()
    local now = GetTime()
    if now - lastPlayTime < PLAY_COOLDOWN then return end
    lastPlayTime = now

    StopMusic()
    CleanupSoundHandles()

    if FishLustDB.muteSound then
        print("|cff00bfff[FishLust]|r Sound is muted.")
        return
    end

    local channel   = FishLustDB.soundChannel or "Dialog"
    local musicFile = GetMusicFile()

    local isMuted, muteReason = IsChannelEffectivelyMuted(channel)
    if isMuted then
        print("|cff00bfff[FishLust]|r |cffff8800[!] Cannot play music:|r " .. muteReason)
        return
    end

    local volume   = FishLustDB.volume or 1.0
    local cvarName = CHANNEL_CVARS[channel] or "Sound_DialogVolume"
    if not originalChannelVolume then
        originalChannelVolume = tonumber(GetCVar(cvarName)) or 1.0
    end
    local targetVolume = tostring(volume)
    if GetCVar(cvarName) ~= targetVolume then
        SetCVar(cvarName, targetVolume)
        cvarDirty = true
    end

    local willPlay, soundHandle = PlaySoundFile(musicFile, channel)
    if willPlay then
        soundHandlePool[1] = soundHandle
        print("|cff00bfff[FishLust]|r Testing music: " .. musicFile)
    else
        print("|cff00bfff[FishLust]|r |cffff8800[!] Failed to play:|r " .. musicFile)
        RestoreChannelVolume()
    end
end

-- Play bloodlust music and animation
PlayFishLust = function()
    local now = GetTime()
    if now - lastPlayTime < PLAY_COOLDOWN then
        printDebug("Music play blocked - cooldown active (", string.format("%.1f", PLAY_COOLDOWN - (now - lastPlayTime)), "s remaining)")
        return
    end
    lastPlayTime = now

    StopMusic()
    CleanupSoundHandles()

    if FishLustDB.animationStyle ~= "none" then
        if addon.StartAnimation then addon:StartAnimation() end
    end

    if FishLustDB.muteSound then
        printDebug("Sound muted by user preference - animation only")
        return
    end

    local channel   = FishLustDB.soundChannel or "Dialog"
    local musicFile = GetMusicFile()

    local isMuted, muteReason = IsChannelEffectivelyMuted(channel)
    if isMuted then
        print(string.format(
            "|cff00bfff[FishLust]|r |cffff8800[!] Cannot play music:|r %s.\n"
            .. "  Open |cffff8800/FishLust settings|r to pick a different channel or mute sound intentionally.",
            muteReason
        ))
        return
    end

    local volume = (FishLustDB and FishLustDB.volume) or 1.0

    if type(musicFile) == "number" then
        PlaySound(musicFile, channel)
        printDebug("Playing default sound on channel:", channel)
    else
        local cvarName = CHANNEL_CVARS[channel] or "Sound_DialogVolume"

        if not originalChannelVolume then
            originalChannelVolume = tonumber(GetCVar(cvarName)) or 1.0
        end

        local targetVolume = tostring(volume)
        if GetCVar(cvarName) ~= targetVolume then
            SetCVar(cvarName, targetVolume)
            cvarDirty = true
        end

        local willPlay, soundHandle = PlaySoundFile(musicFile, channel)
        if willPlay then
            soundHandlePool[1] = soundHandle
            printDebug("Now playing:", musicFile, "on channel:", channel, "at volume", math.floor(volume * 100), "%")
        else
            print(string.format(
                "|cff00bfff[FishLust]|r |cffff8800[!] Failed to load music file.|r "
                .. "Check the file exists and the |cffff8800%s|r channel isn't muted. "
                .. "Use |cffff8800/FishLust settings|r to change channel.",
                channel
            ))
            RestoreChannelVolume()
        end
    end
end

-- Stop bloodlust music (stops both music and animation when lust ends)
StopFishLust = function()
    CleanupSoundHandles()
    RestoreChannelVolume()
    if addon.StopAnimation then addon:StopAnimation() end
    printDebug("Music stopped - Bloodlust ended")
end

-- Stop music only (used by the Stop Music button — leaves animation running)
function addon:StopMusic()
    CleanupSoundHandles()
    RestoreChannelVolume()
    printDebug("Music stopped by user")
end

-- Update volume for currently playing music
function addon:UpdateVolume(volume)
    if soundHandlePool[1] and originalChannelVolume then
        local channel  = FishLustDB.soundChannel or "Dialog"
        local cvarName = CHANNEL_CVARS[channel] or "MasterVolume"
        SetCVar(cvarName, tostring(volume))
        cvarDirty = true
        printDebug("Volume updated to", math.floor(volume * 100), "%")
    end
end

-- Change which WoW sound channel music plays on
function addon:SetSoundChannel(channel)
    if CHANNEL_CVARS[channel] then
        RestoreChannelVolume()
        FishLustDB.soundChannel = channel
        printDebug("Sound channel set to:", channel)
    else
        print("|cff00bfff[FishLust]|r Invalid channel. Valid options: Master, SFX, Dialog, Music, Ambience")
    end
end

-- Toggle addon-level sound mute (animation still plays)
function addon:SetMuteSound(muted)
    FishLustDB.muteSound = muted
    if muted then
        CleanupSoundHandles()
        RestoreChannelVolume()
        print("|cff00bfff[FishLust]|r Sound |cffff0000muted|r - animation will still play.")
    else
        print("|cff00bfff[FishLust]|r Sound |cff00ff00enabled|r.")
    end
end

-- Update animation style
function addon:UpdateTheme(style)
    FishLustDB.animationStyle = style
    if addon.UpdateAnimationTexture then addon:UpdateAnimationTexture() end
end

-- Update selected music
function addon:UpdateMusic(path)
    FishLustDB.music = path
end

-- ─── COMPREHENSIVE CLEANUP ───────────────────────────────────────────────────
local function Cleanup()
    printDebug("Running comprehensive cleanup...")
    if lustEndTimer then lustEndTimer:Cancel() ; lustEndTimer = nil end
    StopFishLust()
    isLusted      = false
    activeDebufID = nil
    lastPlayTime  = 0
    collectgarbage("collect")
    C_Timer.After(0.1, function()
        collectgarbage("collect")
        printDebug("Garbage collection complete")
    end)
end

-- ─── EVENT REGISTRATION ──────────────────────────────────────────────────────
frame:RegisterEvent("LOADING_SCREEN_DISABLED")
frame:RegisterEvent("PLAYER_DEAD")
frame:RegisterEvent("PLAYER_LOGOUT")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "LOADING_SCREEN_DISABLED" then
        printDebug("FishLust loaded - Style:", FishLustDB.animationStyle or "fish")
        -- Mirror BudgetPedro: only register UNIT_AURA in raid/party instances.
        -- This avoids unnecessary aura processing in the open world.
        local _, instanceType = GetInstanceInfo()
        if instanceType == "raid" or instanceType == "party" then
            self:RegisterUnitEvent("UNIT_AURA", "player")
            printDebug("UNIT_AURA registered (instanceType:", instanceType, ")")
        else
            self:UnregisterEvent("UNIT_AURA")
            printDebug("UNIT_AURA not registered (instanceType:", instanceType, ")")
        end

    elseif event == "UNIT_AURA" then
        local _, updateInfo = ...
        OnPlayerAuraUpdate(updateInfo)

    elseif event == "PLAYER_DEAD" then
        -- Stop music if the player dies mid-lust
        if lustEndTimer then lustEndTimer:Cancel() ; lustEndTimer = nil end
        isLusted      = false
        activeDebufID = nil
        StopFishLust()

    elseif event == "PLAYER_LOGOUT" then
        Cleanup()
    end
end)

-- ─── SLASH COMMANDS ──────────────────────────────────────────────────────────
SLASH_FishLust1 = "/fshl"
SLASH_FishLust2 = "/FishLust"
SlashCmdList["FishLust"] = function(msg)
    if msg == "test" then
        local style = FishLustDB.animationStyle or "fish"
        print("[FishLust] [TEST] Testing playback (style: " .. style .. ")")
        PlayFishLust()

    elseif msg == "stop" then
        print("[FishLust] [STOP] Stopping music...")
        addon:StopMusic()
        if lustEndTimer then lustEndTimer:Cancel() ; lustEndTimer = nil end
        isLusted      = false
        activeDebufID = nil

    elseif msg == "status" then
        print("|cff00bfff[FishLust]|r [STATUS]:")
        print("  Bloodlusted:", isLusted and "|cff00ff00YES|r" or "|cffff0000NO|r")
        if activeDebufID then
            print("  Triggered by:", SATED_DEBUFF_IDS[activeDebufID] or "Unknown", "(ID: " .. activeDebufID .. ")")
        end
        print("  In combat:", InCombatLockdown() and "YES" or "NO")
        print("  Music timer active:", lustEndTimer and "|cff00ff00YES|r" or "NO")
        print("  Sound handles active:", #soundHandlePool)
        print("  Last play:", string.format("%.1fs ago", GetTime() - lastPlayTime))
        print("  Detection method: Sated-type HARMFUL debuff via UNIT_AURA")
        print("  Tracking", (function() local n=0 for _ in pairs(SATED_DEBUFF_IDS) do n=n+1 end return n end)(), "debuff IDs")

    elseif msg == "reset" then
        print("[FishLust] [RESET] Resetting detection state...")
        if lustEndTimer then lustEndTimer:Cancel() ; lustEndTimer = nil end
        isLusted      = false
        activeDebufID = nil
        StopFishLust()
        print("|cff00bfff[FishLust]|r Detection reset. Watching for Sated-type debuffs.")

    elseif msg == "config" then
        print("|cff00bfff[FishLust]|r [CONFIG]\nConfiguration:")
        print("  Animation style:", FishLustDB.animationStyle or "fish")
        print("  Music:", (FishLustDB.music ~= "") and FishLustDB.music or "(default: fish.mp3)")
        print("  Volume:", math.floor(FishLustDB.volume * 100) .. "%")
        print("  Detection: issecretvalue() guard on UNIT_AURA addedAuras (BudgetPedro method)")
        print("  Animation locked:", FishLustDB.animationLocked and "YES" or "NO")
        print("\nTo change settings, use /FishLust settings")

    elseif msg:match("^debug") then
        local arg = msg:match("^debug%s*(%S*)")
        if arg == "on" then
            SetDebug(true)
        elseif arg == "off" then
            SetDebug(false)
        else
            print("|cff00bfff[FishLust]|r Usage:")
            print("  /FishLust debug on  - Enable debug output")
            print("  /FishLust debug off - Disable debug output")
        end

    elseif msg:match("^volume") then
        local vol = tonumber(msg:match("^volume%s+(%d+)"))
        if vol and vol >= 0 and vol <= 100 then
            FishLustDB.volume = vol / 100
            if addon.UpdateVolume then addon:UpdateVolume(FishLustDB.volume) end
            print(string.format("|cff00bfff[FishLust]|r Volume set to %d%%", vol))
        else
            print("|cff00bfff[FishLust]|r Usage: /FishLust volume <0-100>")
            print(string.format("  Current volume: %d%%", math.floor((FishLustDB.volume or 1.0) * 100)))
        end

    elseif msg == "cleanup" then
        Cleanup()
        print("|cff00bfff[FishLust]|r Cleanup complete - all resources freed")

    elseif msg == "mem" then
        UpdateAddOnMemoryUsage()
        local mem = GetAddOnMemoryUsage("FishLust")
        print(string.format("|cff00bfff[FishLust]|r Memory usage: %.2f KB", mem))
        print("  Sound handles:", #soundHandlePool)

    else
        print("|cff00bfff[FishLust] [HELP]\nAvailable Commands:|r")
        print("  |cffff8800/FishLust status|r - Show current status and active auras")
        print("  |cffff8800/FishLust test|r - Test music playback")
        print("  |cffff8800/FishLust stop|r - Stop music")
        print("  |cffff8800/FishLust reset|r - Reset detection state")
        print("  |cffff8800/FishLust config|r - Show configuration")
        print("  |cffff8800/FishLust volume <0-100>|r - Set music volume")
        print("  |cffff8800/FishLust debug on/off|r - Toggle debug output")
        print("  |cffff8800/FishLust cleanup|r - Force cleanup and garbage collection")
        print("  |cffff8800/FishLust mem|r - Show memory usage")
        print("|cff00bfff[TIP]|r |cffff8800/djl|r can be used as shortcut/alias of |cffff8800/FishLust|r")
    end
end

print("|cff00bfff[FishLust]|r Type |cffff8800/FishLust|r for all available commands.")
