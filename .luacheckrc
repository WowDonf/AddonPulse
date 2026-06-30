-- Luacheck configuration for the AddonPulse addon.
--
-- WoW runs Lua 5.1. The client injects a large API surface (C_* namespaces,
-- widget constructors, font objects, global helpers like wipe) that luacheck
-- would otherwise flag as undefined. We declare the slice this addon touches as
-- read_globals, and the handful of globals it writes as writable globals.
--
-- Run from the addon folder:   luacheck .

std = "lua51"

exclude_files = {
	".luacheckrc",
	".release/",   -- BigWigs packager build output (a copy of the source)
}

ignore = {
	"212", -- unused argument (event/script handlers take args we don't always use)
	"432", -- shadowing an upvalue argument
}

max_line_length = false

-- Globals the addon legitimately creates / assigns.
globals = {
	"AddonPulseDB",                  -- SavedVariables (account-wide settings)
	"AddonPulseCharDB",              -- SavedVariablesPerCharacter (sessions, baseline)
	"SLASH_ADDONPULSE1",
	"SLASH_ADDONPULSE2",
	"SLASH_ADDONPULSE3",
	"SlashCmdList",
	"AddonPulse_OnAddonCompartmentClick",
	"StaticPopupDialogs",            -- we add one dialog entry
	"AddonPulse_ToggleBinding",      -- key-binding actions (Bindings.xml)
	"AddonPulse_PauseBinding",
	"BINDING_HEADER_ADDONPULSE",     -- key-binding display names
	"BINDING_NAME_ADDONPULSE_TOGGLE",
	"BINDING_NAME_ADDONPULSE_PAUSE",
}

-- The slice of the WoW API this addon reads.
read_globals = {
	-- Namespaces
	"C_AddOns",
	"C_AddOnProfiler",
	"C_CVar",
	"C_Timer",
	"C_ChatInfo",
	"Enum",
	"LibStub",

	-- Addon resource metering (still globals in 12.x)
	"GetNumAddOns",
	"GetAddOnInfo",
	"IsAddOnLoaded",
	"UpdateAddOnMemoryUsage",
	"GetAddOnMemoryUsage",
	"UpdateAddOnCPUUsage",
	"GetAddOnCPUUsage",
	"ResetCPUUsage",
	"GetCVar",
	"SetCVar",
	"GetFramerate",
	"GetNetStats",
	"GetTime",
	"GetServerTime",
	"IsInInstance",
	"GetInstanceInfo",
	"InCombatLockdown",
	"GetDifficultyInfo",
	"C_ChallengeMode",
	"collectgarbage",
	"wipe",
	"hooksecurefunc",

	-- Frame / UI
	"CreateFrame",
	"UIParent",
	"GameTooltip",
	"UIErrorsFrame",
	"GetCursorPosition",
	"FauxScrollFrame_Update",
	"FauxScrollFrame_GetOffset",
	"FauxScrollFrame_OnVerticalScroll",
	"SearchBoxTemplate_OnTextChanged",
	"StaticPopup_Show",
	"ReloadUI",
	"UISpecialFrames",
	"tinsert",
	"Settings",
	"SettingsPanel",
	"HideUIPanel",
}
