-- ---------------------------------------------------------------------------
-- Options.lua — a small standalone window for tuning AddonPulse's defaults.
--
-- Every value here is a key in AddonPulseDB with a default in ns.DEFAULTS, so
-- "Reset to defaults" just copies ns.DEFAULTS back. Numeric values use +/-
-- steppers (no slider templates to worry about across patches); toggles use the
-- standard check button. Changes apply live and re-sync the main window.
-- ---------------------------------------------------------------------------
local _, ns = ...
ns.Options = ns.Options or {}

local floor = math.floor
local ACCENT = { 0.32, 0.78, 0.88 }

-- The tunables shown, in display order. apply() runs after a value changes so
-- the change takes effect immediately (restart the driver, trim sessions, ...).
local SETTINGS = {
    { kind = "header", label = "Profiling" },
    { kind = "check", key = "memProfiler", label = "Memory profiler (per-addon scan)",
      tip = "The per-addon memory walk. The one heavy thing AddonPulse does; turn it off for CPU-only monitoring.",
      apply = function() if ns.db.memProfiler then ns._forceMem = true end end },
    { kind = "check", key = "memInCombat", label = "Scan memory in combat",
      tip = "Off (default): pause the memory walk during combat so it can't cause a frame spike mid-fight. The numbers refresh the moment combat ends. The walk can't be made async — WoW Lua is single-threaded — so this controls when it runs, not how." },
    { kind = "step", key = "interval", label = "Sample interval", lo = 1, hi = 10, step = 1,
      unit = "s", tip = "How often the sampler wakes. Higher = cheaper, coarser history.",
      apply = function() if ns.API.RestartDriver then ns.API.RestartDriver() end end },
    { kind = "step", key = "memSeconds", label = "Memory scan every", lo = 5, hi = 60, step = 5,
      unit = "s", tip = "How often the (heavy) per-addon memory scan runs, when the window is open." },
    { kind = "step", key = "history", label = "Live history", lo = 30, hi = 300, step = 30,
      unit = " samples", tip = "How many samples the live graph/sparkline keeps." },

    { kind = "header", label = "Sessions" },
    { kind = "check", key = "sessionSpikes", label = "Capture spike timing (>50ms)",
      tip = "Record WHEN >50ms spikes happen during a fight, for the session graph ticks. Adds a few cheap profiler reads per tick while recording." },
    { kind = "step", key = "fightMinDur", label = "Ignore fights under", lo = 1, hi = 30, step = 1,
      unit = "s", tip = "Combat shorter than this isn't saved as a fight." },
    { kind = "step", key = "maxFights", label = "Saved fights", lo = 0, hi = 20, step = 1,
      tip = "How many past fights to keep.",
      apply = function() if ns.API.TrimSessions then ns.API.TrimSessions() end
                         if ns.UI.OnSessionStored then ns.UI.OnSessionStored() end end },
    { kind = "step", key = "maxRuns", label = "Saved runs", lo = 0, hi = 10, step = 1,
      tip = "How many past dungeon/raid runs to keep.",
      apply = function() if ns.API.TrimSessions then ns.API.TrimSessions() end
                         if ns.UI.OnSessionStored then ns.UI.OnSessionStored() end end },
    { kind = "step", key = "sessionMaxDays", label = "Auto-delete after", lo = 0, hi = 90, step = 1,
      unit = "d", zero = "off", tip = "Drop saved sessions older than this. 0 = keep until pushed out by the caps above.",
      apply = function() if ns.API.PruneSessions then ns.API.PruneSessions() end
                         if ns.UI.OnSessionStored then ns.UI.OnSessionStored() end end },

    { kind = "header", label = "Display" },
    { kind = "check", key = "cpuPercent", label = "Show CPU as % of frame",
      tip = "Show CPU as a percentage of one frame's budget (set by the target FPS below) instead of milliseconds." },
    { kind = "step", key = "targetFPS", label = "Frame budget (target FPS)", lo = 30, hi = 240, step = 30,
      unit = " fps", tip = "1000 / this = the ms budget that counts as 100%. Only affects the % display." },

    { kind = "header", label = "Appearance" },
    { kind = "step", key = "scale", label = "Window scale", lo = 0.7, hi = 1.3, step = 0.05, pct = true,
      tip = "Size of the AddonPulse window.",
      apply = function() if ns.UI.ApplyAppearance then ns.UI.ApplyAppearance() end end },
    { kind = "step", key = "opacity", label = "Window opacity", lo = 0.3, hi = 1.0, step = 0.05, pct = true,
      tip = "Background opacity of the AddonPulse window.",
      apply = function() if ns.UI.ApplyAppearance then ns.UI.ApplyAppearance() end end },
}

local frame
local controls = {}   -- each has :Refresh() to re-read its db value

-- Called after any change: keep the main window's controls/table in sync.
local function AfterChange()
    if ns.UI and ns.UI.SyncControls then ns.UI.SyncControls() end
end

local function FmtVal(def, v)
    if def.zero and (v == 0) then return def.zero end
    if def.pct then return floor(v * 100 + 0.5) .. "%" end
    return tostring(v) .. (def.unit or "")
end

local function Tooltip(widget, title, body)
    if not body then return end
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title, 1, 1, 1)
        GameTooltip:AddLine(body, 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- A "- value +" stepper bound to ns.db[def.key].
local function MakeStepper(parent, def)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(24)

    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", 4, 0)
    lbl:SetText(def.label)

    local plus = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    plus:SetSize(24, 20); plus:SetText("+")
    plus:SetPoint("RIGHT", -4, 0)

    local val = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    val:SetWidth(64); val:SetJustifyH("CENTER")
    val:SetPoint("RIGHT", plus, "LEFT", -3, 0)

    local minus = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    minus:SetSize(24, 20); minus:SetText("-")
    minus:SetPoint("RIGHT", val, "LEFT", -3, 0)

    function row.Refresh()
        val:SetText(FmtVal(def, ns.db[def.key] or def.lo))
        minus:SetEnabled((ns.db[def.key] or def.lo) > def.lo)
        plus:SetEnabled((ns.db[def.key] or def.lo) < def.hi)
    end
    local function Bump(d)
        local v = (ns.db[def.key] or def.lo) + d * def.step
        if v < def.lo then v = def.lo elseif v > def.hi then v = def.hi end
        ns.db[def.key] = v
        row.Refresh()
        if def.apply then def.apply() end
        AfterChange()
    end
    minus:SetScript("OnClick", function() Bump(-1) end)
    plus:SetScript("OnClick", function() Bump(1) end)
    Tooltip(row, def.label, def.tip)
    row:EnableMouse(true)
    return row
end

-- A checkbox bound to ns.db[def.key].
local function MakeCheck(parent, def)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(24)
    local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("LEFT", 2, 0)
    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    lbl:SetText(def.label)

    function row.Refresh() cb:SetChecked(ns.db[def.key] and true or false) end
    cb:SetScript("OnClick", function(self)
        ns.db[def.key] = self:GetChecked() and true or false
        if def.apply then def.apply() end
        AfterChange()
    end)
    Tooltip(cb, def.label, def.tip)
    return row
end

local function Build()
    frame = CreateFrame("Frame", "AddonPulseOptionsFrame", UIParent, "BackdropTemplate")
    frame:SetSize(360, 100)   -- height set after layout
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(0.05, 0.05, 0.07, 0.96)
    frame:SetBackdropBorderColor(0, 0, 0, 1)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "AddonPulseOptionsFrame")   -- Escape closes it

    local titleBar = CreateFrame("Frame", nil, frame)
    titleBar:SetPoint("TOPLEFT"); titleBar:SetPoint("TOPRIGHT"); titleBar:SetHeight(26)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
    local tbg = titleBar:CreateTexture(nil, "BACKGROUND")
    tbg:SetAllPoints(); tbg:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.10)

    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", 10, 0)
    title:SetText("AddonPulse Options")
    title:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])

    local close = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
    close:SetPoint("RIGHT", 2, 0)
    close:SetScript("OnClick", function() frame:Hide() end)

    -- Lay the settings out top-to-bottom.
    local y = -34
    local PAD = 14
    for _, def in ipairs(SETTINGS) do
        if def.kind == "header" then
            local h = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            h:SetPoint("TOPLEFT", PAD, y)
            h:SetText(def.label)
            h:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
            local line = frame:CreateTexture(nil, "ARTWORK")
            line:SetColorTexture(0.3, 0.3, 0.34, 0.5)
            line:SetPoint("LEFT", h, "RIGHT", 6, 0)
            line:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
            line:SetHeight(1)
            y = y - 20
        else
            local row = (def.kind == "check") and MakeCheck(frame, def) or MakeStepper(frame, def)
            row:SetPoint("TOPLEFT", PAD, y)
            row:SetPoint("TOPRIGHT", -PAD, y)
            controls[#controls + 1] = row
            y = y - 26
        end
    end

    y = y - 8
    local reset = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    reset:SetSize(140, 22)
    reset:SetPoint("TOP", 0, y)
    reset:SetText("Reset to Defaults")
    reset:SetScript("OnClick", function() ns.Options.ResetDefaults() end)
    Tooltip(reset, "Reset to Defaults", "Restore every value on this panel to its default.")
    y = y - 30

    local note = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOP", 0, y)
    note:SetText("Also: /pulse options")
    y = y - 18

    frame:SetHeight(-y + 6)
    frame:Hide()   -- start hidden; Toggle/Show reveal it (a new frame shows by default)
end

-- Set every keyed setting back to its ns.DEFAULTS value, apply, and refresh.
function ns.Options.ResetDefaults()
    local def = ns.DEFAULTS or {}
    for _, s in ipairs(SETTINGS) do
        if s.key and def[s.key] ~= nil then ns.db[s.key] = def[s.key] end
    end
    -- Apply side effects once each (driver/trim/prune/appearance), then refresh.
    if ns.API.RestartDriver then ns.API.RestartDriver() end
    if ns.API.TrimSessions then ns.API.TrimSessions() end
    if ns.API.PruneSessions then ns.API.PruneSessions() end
    if ns.UI.ApplyAppearance then ns.UI.ApplyAppearance() end
    if ns.db.memProfiler then ns._forceMem = true end
    ns.Options.RefreshControls()
    if ns.UI.OnSessionStored then ns.UI.OnSessionStored() end
    AfterChange()
end

function ns.Options.RefreshControls()
    for _, c in ipairs(controls) do c.Refresh() end
end

function ns.Options.Toggle()
    if not frame then Build() end
    if frame:IsShown() then
        frame:Hide()
    else
        ns.Options.RefreshControls()
        frame:Show()
    end
end

function ns.Options.Show()
    if not frame then Build() end
    ns.Options.RefreshControls()
    frame:Show()
end

-- Register a panel under Game Menu > Options > AddOns, where most people look for
-- a config first. It's a launcher: a short summary + buttons that open the full
-- options window / the AddonPulse window, plus the slash reference. (The detailed
-- tuning lives in the standalone window so it can be moved and resized.)
function ns.Options.RegisterBlizzard()
    if ns.Options._blizz then return end
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then
        return
    end

    local panel = CreateFrame("Frame", "AddonPulseBlizzPanel")
    panel.name = "AddonPulse"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("AddonPulse")
    title:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])

    local meta = C_AddOns and C_AddOns.GetAddOnMetadata
    local ver = meta and meta("AddonPulse", "Version")
    if ver then
        local vfs = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        vfs:SetPoint("LEFT", title, "RIGHT", 8, -1)
        vfs:SetText(ver)
    end

    local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    desc:SetPoint("RIGHT", panel, "RIGHT", -24, 0)
    desc:SetJustifyH("LEFT")
    desc:SetText("Live per-addon CPU and memory monitor: a sortable, filterable table of where "
        .. "your CPU time and memory go, with history graphs, leak / spike flags, per-fight and "
        .. "per-dungeon session recording, and addon-comms tracking.")

    local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    open:SetSize(210, 26)
    open:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
    open:SetText("Open AddonPulse options")
    open:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
        ns.Options.Show()
    end)

    local win = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    win:SetSize(210, 26)
    win:SetPoint("TOPLEFT", open, "BOTTOMLEFT", 0, -8)
    win:SetText("Open the AddonPulse window")
    win:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
        if ns.UI and ns.UI.Show then ns.UI.Show() end
    end)

    local help = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", win, "BOTTOMLEFT", 0, -20)
    help:SetPoint("RIGHT", panel, "RIGHT", -24, 0)
    help:SetJustifyH("LEFT")
    help:SetText("Slash commands:\n"
        .. "|cffffd100/pulse|r  toggle the window\n"
        .. "|cffffd100/pulse options|r  open these options\n"
        .. "|cffffd100/pulse on|r / |cffffd100off|r  enable / pause all background work\n"
        .. "|cffffd100/pulse reset|r  clear the live graph history\n"
        .. "|cffffd100/pulse status|r  print the current state\n\n"
        .. "Or left-click the minimap button to toggle, right-click to pause.")

    local category = Settings.RegisterCanvasLayoutCategory(panel, "AddonPulse")
    category.ID = "AddonPulse"
    Settings.RegisterAddOnCategory(category)
    ns.Options._blizz = category
end
