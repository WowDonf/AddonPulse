-- =============================================================================
-- AddonPulse — Minimap.lua
--
-- Registers a LibDataBroker launcher and a LibDBIcon minimap button. LibDBIcon
-- handles the orbiting, drag-to-reposition, round/square minimap shape, and
-- persisting the angle in db.minimap. We just supply an icon, an OnClick and a
-- tooltip.
--
-- The libraries are fetched by the packager at build time and are absent from a
-- raw dev checkout; the LibStub lookups then return nil and this file no-ops,
-- so the addon still works — you just don't get a minimap button.
-- =============================================================================
local _, ns = ...

local ICON_NAME = "AddonPulse"

local LDB     = LibStub and LibStub("LibDataBroker-1.1", true)
local LDBIcon = LibStub and LibStub("LibDBIcon-1.0",      true)

if not LDB or not LDBIcon then
    return
end

-- Named so we can re-render it in place after a right-click toggle.
local function TooltipShow(tt)
    tt:AddLine("AddonPulse", 1, 1, 1)
    local enabled = not ns.db or ns.db.enabled
    tt:AddLine(enabled and "|cff66dd66Active|r" or "|cffff7070Paused|r")
    if enabled then
        tt:AddLine(("Memory: |cffffffff%s|r"):format(ns.FmtMem and ns.FmtMem(ns.totalMem) or "?"),
            0.8, 0.8, 0.8)
        if ns.Prof and ns.Prof.hasAddOnProfiler then
            tt:AddLine(("CPU: |cffffffff%s ms/f|r"):format(ns.FmtMs and ns.FmtMs(ns.totalCPU) or "?"),
                0.8, 0.8, 0.8)
        elseif ns.profiling then
            tt:AddLine(("CPU: |cffffffff%s ms/s|r"):format(ns.FmtCPU and ns.FmtCPU(ns.totalCPU) or "?"),
                0.8, 0.8, 0.8)
        end
    end
    tt:AddLine(" ")
    tt:AddLine("|cffffff00Left-click|r: toggle the window", 0.7, 0.7, 0.7)
    tt:AddLine("|cffffff00Right-click|r: " .. (enabled and "pause" or "resume") .. " AddonPulse", 0.7, 0.7, 0.7)
end

local launcher = LDB:NewDataObject(ICON_NAME, {
    type = "launcher",
    text = "AddonPulse",
    icon = "Interface\\AddOns\\AddonPulse\\Icon.png",

    OnClick = function(self, button)
        if button == "RightButton" then
            if ns.API and ns.API.SetEnabled then
                ns.API.SetEnabled(not (ns.db and ns.db.enabled))
            end
            -- Rebuild the tooltip in place so the Active/Paused line updates
            -- without having to un-hover and re-hover. (We're hovering our own
            -- icon to have clicked it, so the shown tooltip is ours.)
            if GameTooltip:IsShown() then
                GameTooltip:ClearLines()
                TooltipShow(GameTooltip)
                GameTooltip:Show()
            end
        else
            if ns.UI and ns.UI.Toggle then ns.UI.Toggle() end
        end
    end,

    OnTooltipShow = TooltipShow,
})

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
    AddonPulseDB         = AddonPulseDB or {}
    AddonPulseDB.minimap = AddonPulseDB.minimap or { hide = false }
    LDBIcon:Register(ICON_NAME, launcher, AddonPulseDB.minimap)
end)

ns.API = ns.API or {}

ns.API.SetMinimapButtonShown = function(shown)
    if not AddonPulseDB or not AddonPulseDB.minimap then return end
    AddonPulseDB.minimap.hide = not shown
    if shown then LDBIcon:Show(ICON_NAME) else LDBIcon:Hide(ICON_NAME) end
end

ns.API.IsMinimapButtonShown = function()
    return AddonPulseDB and AddonPulseDB.minimap and not AddonPulseDB.minimap.hide
end
