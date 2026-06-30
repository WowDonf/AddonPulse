--[[--------------------------------------------------------------------------
    AddonPulse — UI.lua
    --------------------------------------------------------------------------
    The main window. A movable / resizable panel with two tabs that share one
    recycled FauxScrollFrame table:

      * Addons — per-addon Memory plus four native CPU columns (Recent / Peak /
        Session / Encounter, all from C_AddOnProfiler), a wide CPU sparkline,
        and leak (orange dot) / spike (red dot) status flags. Click a row to pin
        it to the detail graph.
      * Comms  — per-prefix addon-message bytes in / out (Comms.lua).

    The sampling loop is an OnUpdate on the frame, so it only runs while the
    window is open and not minimised.
----------------------------------------------------------------------------]]

local _, ns = ...

ns.UI = ns.UI or {}

local floor, max, sort = math.floor, math.max, table.sort

local function FmtDuration(s)
    s = floor((s or 0) + 0.5)
    return ("%d:%02d"):format(floor(s / 60), s % 60)
end

local function FmtSpan(s)
    s = floor((s or 0) + 0.5)
    return ("%dm%02ds"):format(floor(s / 60), s % 60)
end

local function FmtAgo(t)
    local now = GetServerTime and GetServerTime() or 0
    local d = now - (t or 0)
    if not t or t == 0 or d < 60 then return "just now" end
    if d < 3600  then return ("%dm ago"):format(floor(d / 60)) end
    if d < 86400 then return ("%dh ago"):format(floor(d / 3600)) end
    return ("%dd ago"):format(floor(d / 86400))
end

-- Layout constants -----------------------------------------------------------
local PADDING     = 10
local TITLE_H     = 26
local TAB_H       = 22
local ROW_H       = 18
local SCROLLBAR_W = 18
local HEADER_H    = 16
local FOOTER_H    = 20
local GRAPH_H     = 132
local GRAPHROW_H  = 16     -- graph control strip (marks filter + timespan)
local TOP         = 124    -- y where the scroll list starts
local SPARK_W     = 86     -- sparkline width (Addons tab)
local NAME_X      = 21     -- name inset (past the flag dots)
local NAME_MIN    = 60     -- below this, drop the sparkline to keep the name readable
local COLLAPSE_MINW = 600  -- minimum width of the minimised (title-bar-only) bar
local MAXCOLS     = 14      -- pool size; the Addons tab columns are user-selectable

-- Sort arrows as inline textures (the WoW default font lacks the ▲▼ glyphs, so
-- they'd render as tofu boxes). UI-SortArrow is the stock 8x8 column arrow;
-- the texel args flip it vertically for the two directions.
local ARROW_ASC  = " |TInterface\\Buttons\\UI-SortArrow:11:11:0:0:8:8:0:8:8:0|t"
local ARROW_DESC = " |TInterface\\Buttons\\UI-SortArrow:11:11:0:0:8:8:0:8:0:8|t"

-- Registry of every selectable Addons-tab column. `kind` drives format/colour;
-- the value comes from ns.MetricVal (which maps the key to an entry field). The
-- Addons column list (TABCOLS.addons) is built from db.addonCols in this order.
local COLDEF = {
    mem       = { label = "Mem",    w = 58, kind = "mem",   desc = "Current memory" },
    churn     = { label = "Churn",  w = 64, kind = "rate",  desc = "Memory growth/s" },
    dmem      = { label = "dMem",   w = 64, kind = "delta", desc = "Memory change since baseline" },
    recent    = { label = "Recent", w = 54, kind = "cpu",   desc = "CPU, last 60 frames" },
    peak      = { label = "Peak",   w = 46, kind = "cpu",   desc = "CPU, session high" },
    session   = { label = "Sess",   w = 46, kind = "cpu",   desc = "CPU, session avg" },
    encounter = { label = "Enc",    w = 44, kind = "cpu",   desc = "CPU, encounter avg" },
    last      = { label = "Last",   w = 46, kind = "cpu",   desc = "CPU, most recent frame" },
    over10    = { label = ">10ms",  w = 48, kind = "count", desc = "Frames over 10 ms" },
    over50    = { label = ">50ms",  w = 48, kind = "count", desc = "Frames over 50 ms" },
    over100   = { label = ">100ms", w = 54, kind = "count", desc = "Frames over 100 ms" },
    over500   = { label = ">500ms", w = 54, kind = "count", desc = "Frames over 500 ms" },
    over1000  = { label = ">1s",    w = 40, kind = "count", desc = "Frames over 1 s" },
}
local COL_ORDER = { "mem", "churn", "dmem", "recent", "peak", "session", "encounter", "last",
                    "over10", "over50", "over100", "over500", "over1000" }

-- Short help bubbles shown when hovering a column header. Keyed by column key;
-- the fight / comms tabs reuse some keys with a different meaning, so they have
-- their own maps.
local HDESC = {
    name      = "Addon folder name — its real title is in the row tooltip.",
    mem       = "Lua memory the addon is holding right now.",
    churn     = "How fast its memory is growing (+) or shrinking (-), per second.",
    dmem      = "Memory change since you set a baseline (Tools menu, Set baseline).",
    recent    = "CPU per frame, averaged over the last 60 frames — the live load.",
    peak      = "Worst single frame this session (often the login frame).",
    session   = "Average CPU per frame across the whole session.",
    encounter = "Average CPU per frame during the current boss encounter.",
    last      = "CPU used on the most recent frame.",
    over10    = "Frames that ran over 10 ms this session (a dropped frame).",
    over50    = "Frames that ran over 50 ms this session (a real hitch).",
    over100   = "Frames that ran over 100 ms this session.",
    over500   = "Frames that ran over 500 ms this session.",
    over1000  = "Frames that ran over 1 second this session.",
}
local HDESC_FIGHT = {
    name = "Addon active during this saved session.",
    mem  = "Peak memory this addon reached during the session.",
    peak = "Worst single CPU frame during the session.",
    avg  = "Average CPU per frame across the session.",
}
local HDESC_COMMS = {
    name    = "Addon-message prefix — usually identifies the sending addon.",
    ["in"]  = "Bytes received on this prefix (and message count).",
    out     = "Bytes sent on this prefix.",
}
local function HeaderDesc(tab, key)
    if tab == "fight" then return HDESC_FIGHT[key] end
    if tab == "comms" then return HDESC_COMMS[key] end
    return HDESC[key]
end

-- Per-tab numeric columns (left to right). The Addons set is filled by
-- BuildAddonCols(); fight/comms are fixed. Everything is right-aligned + sortable.
local TABCOLS = {
    addons = {},
    fight = {
        { key = "mem",  label = "MemPk", w = 58 },
        { key = "peak", label = "Peak",  w = 50, cpu = true },
        { key = "avg",  label = "Avg",   w = 50, cpu = true },
    },
    comms = {
        { key = "in",  label = "In",  w = 80 },
        { key = "out", label = "Out", w = 80 },
    },
}
local TABDEF = {
    addons = { name = "Addon",  tabLabel = "Addons",    graph = true },
    fight  = { name = "Addon",  tabLabel = "Sessions", graph = true },
    comms  = { name = "Prefix", tabLabel = "Comms",     graph = false },
}
local TAB_ORDER = { "addons", "fight", "comms" }

-- Module-local widget handles.
local f, titleBar, scroll, header, footer, graph, graphRow, grip
local searchBox, loadedCB, hideCB, memCB, enableBtn, resetBtn, graphBtn, metricBtn, minBtn
local sessBtn, sessMenu, sessSearch, markerBtn
local cogBtn, cogMenu, statusFS, colsBtn, colsMenu
local toolsBtn, toolsMenu, rowMenu
local hName, hCols = nil, {}
local tabButtons = {}
local rows = {}
local filterText = ""
local commsSort = { key = "out", dir = "desc" }   -- name | in | out
local fightSort = { key = "peak", dir = "desc" }  -- name | mem | peak | avg
local fightSelected = nil                          -- addon name pinned on the Sessions tab
local selectedSession = nil                        -- the session table shown on the Sessions tab
local sessionSearch = ""                            -- dropdown filter text

local Refresh, Relayout, UpdateTabColors, LayoutHeader, ShowRowMenu, RebuildToolsMenu

-- Colour ramp for spike-count columns (cumulative; more = worse).
local function CountColor(v)
    if v <= 0  then return 0.5, 0.5, 0.5 end
    if v < 10  then return 0.9, 0.9, 0.5 end
    if v < 100 then return 1.0, 0.65, 0.25 end
    return 1.0, 0.35, 0.35
end

-- Rebuild TABCOLS.addons from db.addonCols, in COL_ORDER. Always keeps >=1 col.
local function BuildAddonCols()
    local sel, out = {}, {}
    for _, k in ipairs(ns.db.addonCols or {}) do sel[k] = true end
    for _, k in ipairs(COL_ORDER) do
        if sel[k] and COLDEF[k] then
            out[#out + 1] = { key = k, label = COLDEF[k].label, w = COLDEF[k].w }
        end
    end
    if #out == 0 then out[1] = { key = "recent", label = COLDEF.recent.label, w = COLDEF.recent.w } end
    TABCOLS.addons = out
end

-- Frame width needed to show the current Addons columns without the table
-- overflowing into the name / flag dots. Columns are right-anchored, so when
-- they don't fit they march off the left edge; instead we keep the window at
-- least this wide. 38 = chrome (2*PADDING + scrollbar); the row also needs
-- NAME_X + NAME_MIN for the name. Never below the toolbar's 580.
local function RequiredAddonWidth()
    local room = 6
    for i = 1, #TABCOLS.addons do room = room + TABCOLS.addons[i].w + 8 end
    return max(580, NAME_X + NAME_MIN + room + 38)
end

-- Grow the window so the selected columns fit (clamped to the screen). The user
-- can still widen further; removing columns lets it shrink again.
function ns.UI.FitWidth()
    if not f then return end
    local req = RequiredAddonWidth()
    if f.SetResizeBounds then f:SetResizeBounds(req, 320) end
    local screenW = (UIParent:GetWidth() or req) - 16
    local target = (req > screenW) and screenW or req
    if f:GetWidth() < target - 0.5 then
        f:SetWidth(target)
        ns.db.size.w = target
    end
end

-- Toggle a column on/off and re-lay the Addons table + header.
local function ToggleColumn(key, on)
    local cols = ns.db.addonCols
    for i = #cols, 1, -1 do if cols[i] == key then table.remove(cols, i) end end
    if on then cols[#cols + 1] = key end
    BuildAddonCols()
    if ns.UI.FitWidth then ns.UI.FitWidth() end       -- widen if the new column needs room
    if not on and ns.db.sortKey == key then          -- sorted column removed
        ns.db.sortKey = (TABCOLS.addons[1] and TABCOLS.addons[1].key) or "recent"
    end
    for i = 1, #rows do rows[i]._laidTab = nil end   -- force column re-layout
    if ns.db.tab == "addons" then LayoutHeader() end
    Refresh()
end

-- Graph event-marker filtering: all | key (pulls+deaths) | off.
local MARKMODE_LABEL = { all = "marks: all", key = "marks: pulls+deaths", off = "marks: off" }

local function MarkerAllowed(kind)
    local m = ns.db.markerMode
    if m == "off" then return false end
    if m == "key" then return kind == "pull" or kind == "death" end
    return true
end

local function UpdateMarkerBtn()
    if markerBtn then markerBtn.fs:SetText(MARKMODE_LABEL[ns.db.markerMode] or MARKMODE_LABEL.all) end
end

-- Brief stats shown on the title bar (the chosen ones via the cogwheel). Cheap,
-- and updated even while minimised so the collapsed bar is a live readout.
local function UpdateStatusBar()
    if not statusFS then return end
    -- All four are cheap and stay valid even while paused (the native CPU
    -- profiler is always on; memory here is total UI memory, not the per-addon
    -- walk), so the bar works as a lightweight readout regardless of mode.
    local b = ns.db.bar or {}
    local parts = {}
    if b.fps then parts[#parts + 1] = ("|cffffffff%d|r fps"):format(floor(GetFramerate() + 0.5)) end
    if b.cpu then
        local cpu = (ns.Prof and ns.Prof.hasAddOnProfiler and ns.Prof.Overall("recent")) or ns.totalCPU or 0
        parts[#parts + 1] = ("|cffffffff%s|r%s"):format(ns.FmtCPUDisplay(cpu), ns.CPUUnit())
    end
    if b.mem then
        parts[#parts + 1] = ("|cffffffff%s|r"):format(ns.FmtMem(collectgarbage("count")))
    end
    if b.comms then
        local c = ns.Comms and (ns.Comms.totalIn + ns.Comms.totalOut) or 0
        parts[#parts + 1] = ("|cffffffff%s|r comms"):format(ns.FmtBytes(c))
    end
    if b.home or b.world then
        local _, _, lHome, lWorld = GetNetStats()   -- cached; free to read
        if b.home  then parts[#parts + 1] = ("home |cffffffff%d|r ms"):format(floor((lHome or 0) + 0.5)) end
        if b.world then parts[#parts + 1] = ("world |cffffffff%d|r ms"):format(floor((lWorld or 0) + 0.5)) end
    end
    statusFS:SetText(table.concat(parts, "  ·  "))
end

-- ---------------------------------------------------------------------------
-- Small construction helpers.
-- ---------------------------------------------------------------------------
local function MakeButton(parent, text, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 70, 20)
    b:SetText(text)
    b:GetFontString():SetFont(b:GetFontString():GetFont(), 11)
    return b
end

-- A clickable text row for the little dropdown menus (hover-highlighted).
local function MakeMenuAction(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(20)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("LEFT", 6, 0)
    b.hl = b:CreateTexture(nil, "BACKGROUND")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(0.32, 0.78, 0.88, 0.18)
    b.hl:Hide()
    b:SetScript("OnEnter", function(self) if self:IsEnabled() then self.hl:Show() end end)
    b:SetScript("OnLeave", function(self) self.hl:Hide() end)
    return b
end

local function MakeCheck(parent, label, getter, setter)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb.text = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    cb.text:SetPoint("LEFT", cb, "RIGHT", 1, 0)
    cb.text:SetText(label)
    cb:SetChecked(getter())
    cb:SetScript("OnClick", function(self) setter(self:GetChecked() and true or false) end)
    return cb
end

-- ---------------------------------------------------------------------------
-- Reload prompt for the scriptProfile CVar (only the legacy fallback meter,
-- used when C_AddOnProfiler is unavailable, needs it).
-- ---------------------------------------------------------------------------
StaticPopupDialogs["ADDONPULSE_RELOAD"] = {
    text = "AddonPulse: %s CPU profiling requires a UI reload to take effect.\n\nReload now?",
    button1 = "Reload",
    button2 = "Later",
    OnAccept = function() ReloadUI() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function ns.UI.PromptProfiling(enable)
    ns.API.SetProfilingCVar(enable)
    StaticPopup_Show("ADDONPULSE_RELOAD", enable and "Enabling" or "Disabling")
end

-- ---------------------------------------------------------------------------
-- Sort state / header column mapping for the active tab.
-- ---------------------------------------------------------------------------
local function ActiveSort()
    if ns.db.tab == "comms" then return commsSort.key, commsSort.dir end
    if ns.db.tab == "fight" then return fightSort.key, fightSort.dir end
    return ns.db.sortKey, ns.db.sortDir
end

local function HeaderClick(key)
    if not key then return end
    local tab = ns.db.tab
    if tab == "addons" then
        ns.API.SetSort(key)
    else
        local st = (tab == "comms") and commsSort or fightSort
        if st.key == key then
            st.dir = (st.dir == "asc") and "desc" or "asc"
        else
            st.key = key
            st.dir = (key == "name") and "asc" or "desc"
        end
    end
    Refresh()
end

-- ---------------------------------------------------------------------------
-- Row pool. Layout: flag dots · name · sparkline · numeric columns.
-- ---------------------------------------------------------------------------
local function DrawSparkline(r, hist)
    local sp = r.spark
    sp.lines = sp.lines or {}
    local w, h = sp:GetWidth(), sp:GetHeight()
    local n = hist and #hist or 0
    if w < 6 or n < 2 then
        for i = 1, #sp.lines do sp.lines[i]:Hide() end
        return
    end
    local MAXP = 40
    local startI = max(1, n - MAXP + 1)
    local pts = n - startI + 1
    local mx = 0
    for i = startI, n do if hist[i] > mx then mx = hist[i] end end
    if mx <= 0 then mx = 1 end
    -- Colour to match the detail graph's current series.
    local cr, cg, cb
    if ns.db.metric == "mem" then cr, cg, cb = 0.45, 0.75, 1.0 else cr, cg, cb = 1.0, 0.70, 0.30 end
    local stepX = (pts > 1) and (w / (pts - 1)) or 0
    local seg = 0
    for i = startI, n - 1 do
        seg = seg + 1
        local ln = sp.lines[seg]
        if not ln then
            ln = sp:CreateLine(nil, "ARTWORK")
            ln:SetThickness(1.5)
            sp.lines[seg] = ln
        end
        ln:SetColorTexture(cr, cg, cb, 0.95)
        ln:SetStartPoint("BOTTOMLEFT", sp, (i - startI) * stepX,     (hist[i] / mx) * h)
        ln:SetEndPoint("BOTTOMLEFT",   sp, (i + 1 - startI) * stepX, (hist[i + 1] / mx) * h)
        ln:Show()
    end
    for i = seg + 1, #sp.lines do sp.lines[i]:Hide() end
end

local function HideSparkline(r)
    if r.spark.lines then
        for i = 1, #r.spark.lines do r.spark.lines[i]:Hide() end
    end
end

-- Re-anchor a row's columns / sparkline / name for the given tab (once per tab).
local function LayoutCols(r, tab)
    if r._laidTab == tab then return end
    r._laidTab = tab
    local cols = TABCOLS[tab]
    local n = #cols
    for i = 1, MAXCOLS do
        local fs = r.cols[i]
        fs:ClearAllPoints()
        if i <= n then fs:SetWidth(cols[i].w); fs:Show() else fs:Hide() end
    end
    for i = n, 1, -1 do
        local fs = r.cols[i]
        if i == n then fs:SetPoint("RIGHT", r, "RIGHT", -6, 0)
        else fs:SetPoint("RIGHT", r.cols[i + 1], "LEFT", -8, 0) end
    end
    -- Name + sparkline fill the space left of the first column. The columns are
    -- right-anchored, so as more get enabled they march leftward; rather than let
    -- the name collapse to negative width (which renders as garbled overlap on the
    -- first column), give the NAME priority and let the sparkline yield — it only
    -- appears when there's room for it. Sized from the row width, so it re-fits on
    -- resize (OnSizeChanged invalidates the layout).
    local room = 6
    for i = 1, n do room = room + cols[i].w + 8 end          -- columns + their gaps
    local rowW = r:GetWidth()
    if rowW <= 1 then rowW = (scroll and scroll:GetWidth()) or 542 end
    local avail = rowW - room - NAME_X - 8                    -- usable px left of col 1
    if avail < 1 then avail = 1 end
    local hasSpark = (tab == "addons" or tab == "fight") and avail >= (NAME_MIN + 4 + SPARK_W)
    r.name:ClearAllPoints()
    r.name:SetPoint("LEFT", r, "LEFT", NAME_X, 0)
    r.spark:ClearAllPoints()
    r.spark:SetPoint("RIGHT", r.cols[1], "LEFT", -8, 0)
    if hasSpark then
        r.name:SetWidth(avail - SPARK_W - 4)
        r.spark:SetWidth(SPARK_W)
        r.spark:SetShown(true)
    else
        r.name:SetWidth(avail)
        r.spark:SetWidth(0.001)
        r.spark:SetShown(false)
    end
end

local function RowTooltip(self)
    self.hl:Show()
    local e = self.entry
    if not e then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")

    if ns.db.tab == "addons" then
        GameTooltip:AddLine(e.title, 1, 1, 1)
        if e.name ~= e.title then GameTooltip:AddLine(e.name, 0.6, 0.6, 0.6) end
        GameTooltip:AddLine(" ")
        local _, memPeak, memAvg = ns.HistStats(e.memHist)
        GameTooltip:AddDoubleLine("Memory", ns.FmtMem(e.mem), 0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:AddDoubleLine("  peak / avg", ns.FmtMem(memPeak) .. " / " .. ns.FmtMem(memAvg), 0.6, 0.6, 0.6, 0.9, 0.9, 0.9)
        GameTooltip:AddDoubleLine("  churn", ns.FmtRate(e.memRate), 0.6, 0.6, 0.6, 0.9, 0.9, 0.9)
        if e.dMem ~= nil then
            GameTooltip:AddDoubleLine("  vs baseline", ns.FmtDelta(e.dMem), 0.6, 0.6, 0.6, ns.DeltaColor(e.dMem))
        end
        if e.leaking then GameTooltip:AddLine("  leak? memory climbing steadily", 1, 0.63, 0.19) end
        GameTooltip:AddLine(" ")
        if ns.Prof.hasAddOnProfiler then
            -- last / over50 / over100 aren't sampled into the table each tick;
            -- read them live for just this hovered addon.
            local last = ns.Prof.AddOn(e.name, "last")
            local o50  = ns.Prof.AddOn(e.name, "over50")
            local o100 = ns.Prof.AddOn(e.name, "over100")
            local u = ns.CPUUnit()
            GameTooltip:AddDoubleLine("CPU recent", ns.FmtCPUDisplay(e.cpuRecent) .. u, 0.8, 0.8, 0.8, 1, 1, 1)
            GameTooltip:AddDoubleLine("  peak / session", ns.FmtCPUDisplay(e.cpuPeak) .. " / " .. ns.FmtCPUDisplay(e.cpuSession), 0.6, 0.6, 0.6, 0.9, 0.9, 0.9)
            GameTooltip:AddDoubleLine("  encounter / last", ns.FmtCPUDisplay(e.cpuEncounter) .. " / " .. ns.FmtCPUDisplay(last), 0.6, 0.6, 0.6, 0.9, 0.9, 0.9)
            GameTooltip:AddDoubleLine("  spikes >10/50/100ms", ("%d / %d / %d"):format(e.over10 or 0, o50, o100), 0.6, 0.6, 0.6, 0.9, 0.9, 0.9)
            if (e.over10 or 0) > 0 then GameTooltip:AddLine("  spike: has used over 10 ms in a frame", 1, 0.35, 0.35) end
        end
        if not e.loaded then GameTooltip:AddLine("Not loaded", 0.6, 0.6, 0.6) end
        GameTooltip:AddLine(" ")
        local pinned  = ns.db.pinned and ns.db.pinned[e.name]
        local ignored = ns.db.ignored and ns.db.ignored[e.name]
        GameTooltip:AddLine("Click to graph  •  right-click to "
            .. (pinned and "unpin" or "pin") .. " / " .. (ignored and "show" or "ignore"), 0.4, 0.8, 1)
    elseif ns.db.tab == "fight" then
        GameTooltip:AddLine(e.name, 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("CPU peak / avg", ns.FmtCPUDisplay(e.cpuPeak) .. " / " .. ns.FmtCPUDisplay(e.cpuSession) .. ns.CPUUnit(), 0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:AddDoubleLine("Mem peak / avg", ns.FmtMem(e.memPeak) .. " / " .. ns.FmtMem(e.memAvg), 0.8, 0.8, 0.8, 1, 1, 1)
        if (e.spike10 or 0) + (e.spike50 or 0) + (e.spike100 or 0) > 0 then
            GameTooltip:AddDoubleLine("Spikes >10/50/100ms",
                ("%d / %d / %d"):format(e.spike10 or 0, e.spike50 or 0, e.spike100 or 0),
                0.8, 0.8, 0.8, 1, 0.5, 0.5)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Click to graph this addon's fight.", 0.4, 0.8, 1)
    else -- comms
        GameTooltip:AddLine(e.prefix, 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Received", ns.FmtBytes(e.bytesIn) .. "  (" .. e.msgsIn .. " msgs)", 0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:AddDoubleLine("Sent", ns.FmtBytes(e.bytesOut) .. "  (" .. e.msgsOut .. " msgs)", 0.8, 0.8, 0.8, 1, 1, 1)
    end
    GameTooltip:Show()
end

local function MakeRow(i)
    local r = CreateFrame("Button", nil, f)
    r:SetHeight(ROW_H)
    if i == 1 then
        r:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
    else
        r:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT", 0, 0)
    end
    r:SetPoint("RIGHT", scroll, "RIGHT", 0, 0)

    r.hl = r:CreateTexture(nil, "BACKGROUND")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.05)
    r.hl:Hide()

    r.sel = r:CreateTexture(nil, "BACKGROUND")
    r.sel:SetAllPoints()
    r.sel:SetColorTexture(0.32, 0.78, 0.88, 0.18)
    r.sel:Hide()

    -- Left-edge accent strip marking a pinned addon.
    r.pin = r:CreateTexture(nil, "ARTWORK")
    r.pin:SetColorTexture(0.32, 0.78, 0.88, 0.95)
    r.pin:SetPoint("TOPLEFT", 0, 0)
    r.pin:SetPoint("BOTTOMLEFT", 0, 0)
    r.pin:SetWidth(2)
    r.pin:Hide()

    r.bar = r:CreateTexture(nil, "ARTWORK")
    r.bar:SetPoint("BOTTOMLEFT", 2, 0)
    r.bar:SetHeight(2)

    -- Status flag dots (textures, so they always render).
    r.flagLeak = r:CreateTexture(nil, "OVERLAY")
    r.flagLeak:SetColorTexture(1.0, 0.63, 0.19, 1)
    r.flagLeak:SetSize(7, 7)
    r.flagLeak:SetPoint("LEFT", 4, 0)
    r.flagLeak:Hide()

    r.flagSpike = r:CreateTexture(nil, "OVERLAY")
    r.flagSpike:SetColorTexture(1.0, 0.32, 0.32, 1)
    r.flagSpike:SetSize(7, 7)
    r.flagSpike:SetPoint("LEFT", 12, 0)
    r.flagSpike:Hide()

    r.cols = {}
    for c = 1, MAXCOLS do
        local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH("RIGHT")
        r.cols[c] = fs
    end

    r.spark = CreateFrame("Frame", nil, r)
    r.spark:SetHeight(ROW_H - 4)
    r.spark:SetPoint("RIGHT", r.cols[1], "LEFT", -8, 0)
    r.spark.bg = r.spark:CreateTexture(nil, "BACKGROUND")
    r.spark.bg:SetAllPoints()
    r.spark.bg:SetColorTexture(1, 1, 1, 0.05)

    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)

    r:SetScript("OnEnter", RowTooltip)
    r:SetScript("OnLeave", function(self) self.hl:Hide(); GameTooltip:Hide() end)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(self, button)
        if not self.entry then return end
        if button == "RightButton" then
            if ns.db.tab == "addons" and ShowRowMenu then ShowRowMenu(self.entry, self) end
            return
        end
        if ns.db.tab == "addons" then
            ns.db.selected = self.entry.name
            Refresh()
        elseif ns.db.tab == "fight" then
            fightSelected = self.entry.name
            Refresh()
        end
    end)

    rows[i] = r
    return r
end

-- ---------------------------------------------------------------------------
-- Per-tab row fill.
-- ---------------------------------------------------------------------------
local function FillAddon(r, e, ctx)
    LayoutCols(r, "addons")
    r.entry = e
    local memOn = ns.db.memProfiler
    r.flagLeak:SetShown(memOn and e.leaking and true or false)
    r.flagSpike:SetShown(ns.Prof.hasAddOnProfiler and (e.over10 or 0) > 0)
    r.name:SetText(e.loaded and e.name or ("|cff808080" .. e.name .. "|r"))

    -- Pin strip + dimming for ignored rows (only seen when "Show ignored" is on).
    r.pin:SetShown(ns.db.pinned and ns.db.pinned[e.name] and true or false)
    r:SetAlpha(ns.db.ignored and ns.db.ignored[e.name] and 0.45 or 1)

    local cols = TABCOLS.addons
    for i = 1, #cols do
        local fs = r.cols[i]
        local kind = COLDEF[cols[i].key].kind
        local v = ns.MetricVal(e, cols[i].key)
        if kind == "mem" or kind == "rate" then
            if not memOn then
                fs:SetText("|cff707070-|r")
            elseif kind == "mem" then
                fs:SetText(ns.FmtMem(v)); fs:SetTextColor(ns.MemColor(v))
            else
                fs:SetText(ns.FmtRate(v)); fs:SetTextColor(0.8, 0.8, 0.8)
            end
        elseif kind == "delta" then           -- ΔMem vs baseline
            if not memOn or e.dMem == nil then
                fs:SetText("|cff707070-|r")
            else
                fs:SetText(ns.FmtDelta(e.dMem)); fs:SetTextColor(ns.DeltaColor(e.dMem))
            end
        elseif kind == "count" then
            fs:SetText(v >= 1000 and ("%.1fk"):format(v / 1000) or ("%d"):format(v))
            fs:SetTextColor(CountColor(v))
        else  -- cpu (ms/frame, or % of frame budget)
            if ns.Prof.hasAddOnProfiler then
                fs:SetText(ns.FmtCPUDisplay(v)); fs:SetTextColor(ns.CPUColor(v))
            elseif ns.profiling then
                fs:SetText(ns.FmtCPU(v)); fs:SetTextColor(ns.CPUColor(v))
            else
                fs:SetText("|cff707070-|r")
            end
        end
    end

    DrawSparkline(r, (ns.db.metric == "mem") and e.memHist or e.cpuHist)

    local v = ns.MetricVal(e, ctx.barKey)
    local frac = v / ctx.maxBar
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    local bw = (r:GetWidth() - 8) * frac
    if bw < 1 then
        r.bar:Hide()
    else
        r.bar:SetWidth(bw)
        local cr, cg, cb
        if ctx.barKey == "mem" then cr, cg, cb = ns.MemColor(e.mem) else cr, cg, cb = ns.CPUColor(v) end
        r.bar:SetColorTexture(cr, cg, cb, 0.22)
        r.bar:Show()
    end
    r.sel:SetShown(e.name == ns.db.selected)
end

local function FillComms(r, e)
    LayoutCols(r, "comms")
    r.entry = e
    r.flagLeak:Hide(); r.flagSpike:Hide(); r.pin:Hide(); r:SetAlpha(1)
    r.name:SetText(e.prefix)
    r.cols[1]:SetText(ns.FmtBytes(e.bytesIn));  r.cols[1]:SetTextColor(0.55, 0.85, 0.95)
    r.cols[2]:SetText(ns.FmtBytes(e.bytesOut)); r.cols[2]:SetTextColor(0.95, 0.80, 0.55)
    HideSparkline(r)
    r.bar:Hide()
    r.sel:Hide()
end

local function FillFight(r, e)
    LayoutCols(r, "fight")
    r.entry = e
    r.flagLeak:Hide(); r.flagSpike:Hide(); r.pin:Hide(); r:SetAlpha(1)
    r.name:SetText(e.name)
    r.cols[1]:SetText(ns.FmtMem(e.memPeak));    r.cols[1]:SetTextColor(ns.MemColor(e.memPeak))
    r.cols[2]:SetText(ns.FmtCPUDisplay(e.cpuPeak));    r.cols[2]:SetTextColor(ns.CPUColor(e.cpuPeak))
    r.cols[3]:SetText(ns.FmtCPUDisplay(e.cpuSession)); r.cols[3]:SetTextColor(ns.CPUColor(e.cpuSession))
    DrawSparkline(r, (ns.db.metric == "mem") and e.memHist or e.cpuHist)
    r.bar:Hide()
    r.sel:SetShown(e.name == fightSelected)
end

-- All saved sessions (fights + runs), newest first.
local function AllSessions()
    local out = {}
    local s = ns.db and ns.db.sessions
    if s then
        for i = 1, #s.fights do out[#out + 1] = s.fights[i] end
        for i = 1, #s.runs do out[#out + 1] = s.runs[i] end
        sort(out, function(a, b) return (a.ended or 0) > (b.ended or 0) end)
    end
    return out
end

-- The session currently shown on the Sessions tab. Tracked by reference; if it's
-- no longer present (trimmed/cleared) it falls back to the newest.
local function SelectedSession()
    local all = AllSessions()
    if #all == 0 then selectedSession = nil; return nil, all end
    if selectedSession then
        for i = 1, #all do
            if all[i] == selectedSession then return selectedSession, all end
        end
    end
    selectedSession = all[1]   -- default to newest
    return selectedSession, all
end

local function FightView()
    local sess = SelectedSession()
    if not sess or not sess.list then return {} end
    local q = filterText:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local out = {}
    for i = 1, #sess.list do
        local e = sess.list[i]
        if q == "" or e.name:lower():find(q, 1, true) then out[#out + 1] = e end
    end
    local key, asc = fightSort.key, (fightSort.dir == "asc")
    sort(out, function(a, b)
        local av, bv
        if key == "name" then av, bv = a.name:lower(), b.name:lower()
        elseif key == "mem" then av, bv = a.memPeak or 0, b.memPeak or 0
        elseif key == "avg" then av, bv = a.cpuSession or 0, b.cpuSession or 0
        else av, bv = a.cpuPeak or 0, b.cpuPeak or 0 end
        if av == bv then return a.name:lower() < b.name:lower() end
        if asc then return av < bv end
        return av > bv
    end)
    return out
end

local function SessKindColor(s)
    return (s and s.kind == "run") and "|cff8be0ff" or "|cffffd479"   -- run / fight
end

-- Update the dropdown button text to the current selection.
local function UpdateSessionButton()
    if not sessBtn then return end
    local sess = SelectedSession()
    if not sess then
        sessBtn.text:SetText("|cffaaaaaano saved sessions yet|r")
        return
    end
    sessBtn.text:SetText(("%s%s|r  |cffaaaaaa%s|r"):format(
        SessKindColor(sess), sess.name or "?", FmtDuration(sess.duration)))
end

local function SetSessionSelection(sess)
    selectedSession = sess
    fightSelected = nil
    UpdateSessionButton()
    Refresh()
end

-- A row in the dropdown list.
local function MakeSessRow(i)
    local r = CreateFrame("Button", nil, sessMenu)
    r:SetHeight(18)
    r.hl = r:CreateTexture(nil, "BACKGROUND")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.10)
    r.hl:Hide()
    r:SetScript("OnEnter", function(self) self.hl:Show() end)
    r:SetScript("OnLeave", function(self) self.hl:Hide() end)
    r.info = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.info:SetPoint("RIGHT", -6, 0)
    r.info:SetJustifyH("RIGHT")
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.name:SetPoint("LEFT", 6, 0)
    r.name:SetPoint("RIGHT", r.info, "LEFT", -8, 0)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r:SetScript("OnClick", function(self)
        SetSessionSelection(self.session)
        sessMenu:Hide()
    end)
    sessMenu.rows[i] = r
    return r
end

-- Filter (by name) + (re)populate the dropdown list, and size the menu.
local function RebuildSessionMenu()
    if not sessMenu then return end
    sessMenu.rows = sessMenu.rows or {}
    local all = AllSessions()
    local q = (sessionSearch or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local list = {}
    for i = 1, #all do
        if q == "" or (all[i].name or ""):lower():find(q, 1, true) then list[#list + 1] = all[i] end
    end
    local TOPY = -30   -- below the search box
    for i = 1, #list do
        local r = sessMenu.rows[i] or MakeSessRow(i)
        local s = list[i]
        r.session = s
        r.name:SetText(SessKindColor(s) .. (s.name or "Combat") .. "|r")
        r.info:SetText(("%s · %s"):format(FmtDuration(s.duration), FmtAgo(s.ended)))
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 2, TOPY - (i - 1) * 18)
        r:SetPoint("TOPRIGHT", -2, TOPY - (i - 1) * 18)
        r:Show()
    end
    for i = #list + 1, #sessMenu.rows do sessMenu.rows[i]:Hide() end
    sessMenu.empty:SetShown(#list == 0)
    sessMenu:SetHeight(30 + (#list == 0 and 18 or #list * 18) + 6)
end

local function CurrentView()
    local tab = ns.db.tab
    if tab == "comms" then
        return ns.Comms.GetView(filterText, commsSort.key, commsSort.dir == "asc")
    end
    if tab == "fight" then return FightView() end
    return ns.API.GetView(filterText)
end

-- ---------------------------------------------------------------------------
-- Header columns: re-anchored per tab to mirror the rows.
-- ---------------------------------------------------------------------------
function LayoutHeader()
    local tab = ns.db.tab
    local cols = TABCOLS[tab]
    local n = #cols
    for i = 1, MAXCOLS do
        local b = hCols[i]
        b:ClearAllPoints()
        if i <= n then
            b:SetWidth(cols[i].w); b.key = cols[i].key; b:Show()
        else
            b:Hide(); b.key = nil
        end
    end
    for i = n, 1, -1 do
        local b = hCols[i]
        if i == n then b:SetPoint("RIGHT", header, "RIGHT", -6, 0)
        else b:SetPoint("RIGHT", hCols[i + 1], "LEFT", -8, 0) end
    end
    hName.key = "name"
    hName:ClearAllPoints()
    hName:SetPoint("LEFT", 6, 0)
    hName:SetPoint("RIGHT", hCols[1], "LEFT", -8, 0)
end

local function UpdateHeaderLabels()
    local tab = ns.db.tab
    local cols = TABCOLS[tab]
    local ak, ad = ActiveSort()
    local function arrow(key)
        if key ~= ak then return "" end
        return (ad == "asc") and ARROW_ASC or ARROW_DESC
    end
    hName.fs:SetText(TABDEF[tab].name .. arrow("name"))
    for i = 1, #cols do hCols[i].fs:SetText(cols[i].label .. arrow(cols[i].key)) end
end

-- ---------------------------------------------------------------------------
-- Footer line per tab.
-- ---------------------------------------------------------------------------
local function Footer(view)
    local fps = floor(GetFramerate() + 0.5)
    if ns.db.tab == "addons" then
        local cpuPart
        if ns.Prof.hasAddOnProfiler then
            cpuPart = "CPU |cffffffff" .. ns.FmtCPUDisplay(ns.totalCPU) .. "|r" .. ns.CPUUnit()
        elseif ns.profiling then
            cpuPart = "CPU |cffffffff" .. ns.FmtCPU(ns.totalCPU) .. "|r ms/s"
        else
            cpuPart = "CPU |cff909090native off|r"
        end
        local rec = ns.inEncounter and "  •  |cffff5050in encounter|r"
            or (ns.fight and "  •  |cffffd100recording fight|r" or "")
        local memPart = ns.db.memProfiler
            and ("Total |cffffffff%s|r"):format(ns.FmtMem(ns.totalMem))
            or "|cff909090mem prof off|r"
        footer:SetText(("%s  •  %s  •  |cffffffff%d|r addons  •  |cffffffff%d|r fps%s")
            :format(memPart, cpuPart, #view, fps, rec))
    elseif ns.db.tab == "fight" then
        local rec = (ns.fight or ns.run) and "  •  |cffffd100recording…|r" or ""
        local sess = SelectedSession()
        if sess then
            footer:SetText(("ended |cffffffff%s|r  •  |cffffffff%d|r addons  •  click a row to graph%s")
                :format(FmtAgo(sess.ended), #view, rec))
        elseif ns.fight or ns.run then
            footer:SetText("|cffffd100Recording now…|r it'll appear here when it ends.")
        else
            footer:SetText("|cffaaaaaaNo sessions yet — finish any combat, or run a dungeon/raid.|r")
        end
    else
        footer:SetText(("Comms in |cffffffff%s|r  •  out |cffffffff%s|r  •  |cffffffff%d|r prefixes")
            :format(ns.FmtBytes(ns.Comms.totalIn), ns.FmtBytes(ns.Comms.totalOut), #view))
    end
end

-- ---------------------------------------------------------------------------
-- Render pass.
-- ---------------------------------------------------------------------------
function Refresh()
    if not f or not f:IsShown() then return end
    UpdateStatusBar()                     -- works minimised + while paused
    if ns.db.collapsed then return end    -- skip the table while minimised
    -- While paused we still render everything that already exists (sessions,
    -- comms, the live Addons snapshot + its graph) — we just don't collect new
    -- per-addon data. The footer is flagged below so it's clear it's frozen.
    local tab = ns.db.tab
    local view = CurrentView()

    local numRows = max(1, floor((scroll:GetHeight() + 1) / ROW_H))
    FauxScrollFrame_Update(scroll, #view, numRows, ROW_H)
    local offset = FauxScrollFrame_GetOffset(scroll)

    -- Addons bar scaling against the currently-sorted metric.
    local ctx
    if tab == "addons" then
        local barKey = (ns.db.sortKey == "name") and "recent" or ns.db.sortKey
        local maxBar = 0.0001
        for i = 1, #view do
            local v = ns.MetricVal(view[i], barKey)
            if v > maxBar then maxBar = v end
        end
        ctx = { barKey = barKey, maxBar = maxBar }
    end

    for i = 1, numRows do
        local r = rows[i] or MakeRow(i)
        local item = view[i + offset]
        if item then
            if tab == "addons" then FillAddon(r, item, ctx)
            elseif tab == "fight" then FillFight(r, item)
            else FillComms(r, item) end
            r:Show()
        else
            r.entry = nil
            r:Hide()
        end
    end
    for i = numRows + 1, #rows do rows[i]:Hide() end

    UpdateHeaderLabels()
    if tab == "fight" then UpdateSessionButton() end
    Footer(view)
    if not ns.db.enabled then
        footer:SetText("|cffff8800paused|r  •  " .. (footer:GetText() or ""))
    end

    if TABDEF[tab].graph and ns.db.showGraph then
        if tab == "fight" then
            local s = SelectedSession()
            graphRow.timespan:SetText(s and ("Over " .. FmtSpan(s.duration)) or "")
        else
            graphRow.timespan:SetText("Last " .. FmtSpan(ns.db.history * ns.db.interval))
        end
        local sel, markers
        if tab == "fight" then
            local sess = SelectedSession()
            if sess and fightSelected then
                for i = 1, #sess.list do
                    if sess.list[i].name == fightSelected then sel = sess.list[i]; break end
                end
            end
            if sel and sess and sess.markers and (sess.duration or 0) > 0 and ns.db.markerMode ~= "off" then
                markers = {}
                for i = 1, #sess.markers do
                    local m = sess.markers[i]
                    local x = (m.t or 0) / sess.duration
                    if MarkerAllowed(m.kind) and x >= 0 and x <= 1 then
                        markers[#markers + 1] = { x = x, kind = m.kind, label = m.label }
                    end
                end
            end
        else
            sel = ns.db.selected and ns.byName[ns.db.selected] or nil
            if sel and ns.markers and #ns.markers > 0 and ns.db.markerMode ~= "off" then
                local series = (ns.db.metric == "mem") and sel.memHist or sel.cpuHist
                local n = series and #series or 0
                if n >= 2 then
                    local span = (n - 1) * (ns.db.interval or 2)
                    local last = ns.lastSampleTime or 0
                    markers = {}
                    for i = 1, #ns.markers do
                        local m = ns.markers[i]
                        local x = 1 - (last - m.t) / span
                        if MarkerAllowed(m.kind) and x >= 0 and x <= 1 then
                            markers[#markers + 1] = { x = x, kind = m.kind, label = m.label }
                        end
                    end
                end
            end
        end
        ns.Graph.Draw(sel, markers)
    end
end
ns.UI.Refresh = Refresh

-- Show/hide + relabel the toolbar controls that depend on the active tab.
local function ApplyTabVisibility()
    local tab = ns.db.tab
    local addons = (tab == "addons")
    local sessions = (tab == "fight")
    local graphTab = TABDEF[tab].graph
    loadedCB:SetShown(addons); loadedCB.text:SetShown(addons)
    hideCB:SetShown(addons);   hideCB.text:SetShown(addons)
    memCB:SetShown(addons);    memCB.text:SetShown(addons)
    colsBtn:SetShown(addons)
    if not addons then colsMenu:Hide() end
    toolsBtn:SetShown(addons)
    if not addons then toolsMenu:Hide() end
    sessBtn:SetShown(sessions)
    if not sessions then sessMenu:Hide() end
    metricBtn:SetShown(graphTab)
    graphBtn:SetShown(graphTab)
    enableBtn:Show()   -- master enable/disable, relevant on every tab
    resetBtn:Show()
    resetBtn:SetText(tab == "comms" and "Reset comms"
        or sessions and "Clear" or "Reset graph")
end

-- Width of the collapsed (title-bar-only) bar: just enough for the title, the
-- selected bar stats, and the cog/min/close cluster — floored at COLLAPSE_MINW.
-- (~188 = left margin + "AddonPulse" + gaps + the right-hand button cluster.)
local function CollapsedWidth()
    local statusW = (statusFS and statusFS:GetStringWidth()) or 0
    return max(COLLAPSE_MINW, statusW + 188)
end

-- ---------------------------------------------------------------------------
-- (Re)position the body. Handles minimise, the graph show/hide, and resize.
-- ---------------------------------------------------------------------------
function Relayout()
    local db = ns.db
    local bodyWidgets = { scroll, header, footer, searchBox, enableBtn, resetBtn,
                          graphBtn, metricBtn, loadedCB, hideCB, memCB, graphRow,
                          sessBtn, colsBtn, toolsBtn, grip }
    if db.collapsed then
        for _, w in ipairs(bodyWidgets) do if w then w:Hide() end end
        loadedCB.text:Hide(); hideCB.text:Hide(); memCB.text:Hide(); graph:Hide()
        sessMenu:Hide(); colsMenu:Hide(); toolsMenu:Hide(); rowMenu:Hide()
        for _, t in ipairs(tabButtons) do t:Hide() end
        for i = 1, #rows do rows[i]:Hide() end
        UpdateStatusBar()                -- refresh stats first so we can size to them
        f:SetWidth(CollapsedWidth())     -- shrink the bar to its content (min 600)
        f:SetHeight(TITLE_H)
        minBtn:SetText("+")
        return
    end

    f:SetWidth(db.size.w)               -- restore the full (column-fit) width
    f:SetHeight(db.size.h)
    minBtn:SetText("_")
    for _, t in ipairs(tabButtons) do t:Show() end
    scroll:Show(); header:Show(); footer:Show(); searchBox:Show(); grip:Show()
    ApplyTabVisibility()

    local graphOn = db.showGraph and TABDEF[db.tab].graph
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING, -TOP)
    if graphOn then
        graph:Show(); graphRow:Show()
        scroll:SetPoint("BOTTOMRIGHT", graph, "TOPRIGHT", -SCROLLBAR_W, 4)
    else
        graph:Hide(); graphRow:Hide()
        scroll:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", -SCROLLBAR_W, 4)
    end
    metricBtn:SetText(db.metric == "mem" and "Graph: Mem" or "Graph: CPU")
    graphBtn:SetText(db.showGraph and "Hide graph" or "Show graph")
    Refresh()
end
ns.UI.Relayout = Relayout

local function UpdateEnableButton()
    if not enableBtn then return end
    if ns.db.enabled then
        enableBtn:SetText("|cff66dd66Active|r")
    else
        enableBtn:SetText("|cffff7070Paused|r")
    end
end

function UpdateTabColors()
    for _, t in ipairs(tabButtons) do
        local active = (t.key == ns.db.tab)
        t.fs:SetTextColor(active and 1 or 0.6, active and 0.82 or 0.6, active and 0 or 0.6)
        t.underline:SetShown(active)
    end
end

function ns.UI.SetTab(key)
    if not TABDEF[key] then key = "addons" end
    ns.db.tab = key
    LayoutHeader()

    local sb = scroll.ScrollBar or _G["AddonPulseScrollScrollBar"]
    if sb then sb:SetValue(0) end

    UpdateTabColors()
    Relayout()
end

-- ---------------------------------------------------------------------------
-- Toolbar + control menus. Extracted from Init() so neither function exceeds
-- Lua 5.1's 60-upvalue-per-function limit (the client runs Lua 5.1).
-- ---------------------------------------------------------------------------
local function BuildToolbar()
    local db = ns.db
    -- Toolbar row 1 -----------------------------------------------------------
    searchBox = CreateFrame("EditBox", "AddonPulseSearch", f, "SearchBoxTemplate")
    searchBox:SetSize(160, 20)
    searchBox:SetPoint("TOPLEFT", PADDING + 2, -(TITLE_H + TAB_H + 6))
    searchBox:SetScript("OnTextChanged", function(self)
        SearchBoxTemplate_OnTextChanged(self)
        filterText = self:GetText() or ""
        Refresh()
    end)

    resetBtn = MakeButton(f, "Reset graph", 86)
    resetBtn:SetPoint("TOPRIGHT", -PADDING, -(TITLE_H + TAB_H + 6))
    resetBtn:SetScript("OnClick", function()
        local tab = ns.db.tab
        if tab == "comms" then
            ns.Comms.Reset()
        elseif tab == "fight" then
            local sess = SelectedSession()
            if sess then ns.API.RemoveSession(sess) end   -- drop the shown session
        else
            ns.API.ResetCPU()
        end
        Refresh()
    end)
    resetBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        local tab = ns.db.tab
        if tab == "comms" then
            GameTooltip:AddLine("Reset comms", 1, 1, 1)
            GameTooltip:AddLine("Clears the per-prefix byte and message counters.", 0.8, 0.8, 0.8, true)
        elseif tab == "fight" then
            GameTooltip:AddLine("Clear session", 1, 1, 1)
            GameTooltip:AddLine("Removes the saved session shown in the dropdown.", 0.8, 0.8, 0.8, true)
        else
            GameTooltip:AddLine("Reset graph", 1, 1, 1)
            GameTooltip:AddLine("Clears the live CPU + memory sparkline / graph history.", 0.8, 0.8, 0.8, true)
            GameTooltip:AddLine("The Peak / Sess / Enc columns come from the game's profiler — only a /reload zeroes those.", 0.6, 0.8, 1, true)
        end
        GameTooltip:Show()
    end)
    resetBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    enableBtn = MakeButton(f, "Active", 64)
    enableBtn:SetPoint("RIGHT", resetBtn, "LEFT", -4, 0)
    enableBtn:SetScript("OnClick", function() ns.API.SetEnabled(not ns.db.enabled) end)

    -- Toolbar row 2 -----------------------------------------------------------
    local row2 = -(TITLE_H + TAB_H + 32)
    loadedCB = MakeCheck(f, "Loaded",
        function() return db.loadedOnly end,
        function(v) db.loadedOnly = v; Refresh() end)
    loadedCB:SetPoint("TOPLEFT", PADDING, row2)

    hideCB = MakeCheck(f, "Hide idle",
        function() return db.hideInactive end,
        function(v) db.hideInactive = v; Refresh() end)
    hideCB:SetPoint("LEFT", loadedCB.text, "RIGHT", 8, 0)

    -- Memory-profiler toggle: off skips the heavy UpdateAddOnMemoryUsage scan
    -- (CPU-only mode — no per-addon memory, but no memory spikes either).
    memCB = MakeCheck(f, "Mem prof",
        function() return db.memProfiler end,
        function(v) db.memProfiler = v; if v then ns._forceMem = true end; Refresh()
            if ns.Options and ns.Options.RefreshControls then ns.Options.RefreshControls() end end)
    memCB:SetPoint("LEFT", hideCB.text, "RIGHT", 10, 0)
    memCB:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Memory profiler", 1, 1, 1)
        GameTooltip:AddLine("Scans every addon's memory each cycle — the heavy part.", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Uncheck for CPU only: much lighter, no per-addon memory.", 0.6, 0.8, 1)
        GameTooltip:Show()
    end)
    memCB:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Column picker (Addons tab): choose which columns the table shows.
    colsBtn = MakeButton(f, "Columns", 72)
    colsBtn:SetPoint("LEFT", memCB.text, "RIGHT", 12, 0)

    colsMenu = CreateFrame("Frame", nil, f, "BackdropTemplate")
    colsMenu:SetFrameStrata("DIALOG")
    colsMenu:SetPoint("TOPLEFT", colsBtn, "BOTTOMLEFT", 0, -2)
    colsMenu:SetWidth(150)
    colsMenu:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    colsMenu:SetBackdropColor(0.05, 0.05, 0.07, 0.97)
    colsMenu:SetBackdropBorderColor(0, 0, 0, 1)
    colsMenu:Hide()
    local ch = colsMenu:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ch:SetPoint("TOPLEFT", 8, -6)
    ch:SetText("Columns")
    local cyy = -22
    for _, key in ipairs(COL_ORDER) do
        local k = key
        local cb = MakeCheck(colsMenu, COLDEF[k].label,
            function()
                for _, sk in ipairs(ns.db.addonCols) do if sk == k then return true end end
                return false
            end,
            function(v) ToggleColumn(k, v) end)
        cb:SetPoint("TOPLEFT", 6, cyy)
        cyy = cyy - 22
    end
    colsMenu:SetHeight(-cyy + 6)
    colsBtn:SetScript("OnClick", function() colsMenu:SetShown(not colsMenu:IsShown()) end)

    -- Session picker (Sessions tab): a searchable dropdown of saved sessions.
    sessBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    sessBtn:SetSize(252, 18)
    sessBtn:SetPoint("TOPLEFT", PADDING, row2)
    sessBtn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    sessBtn:SetBackdropColor(0.12, 0.12, 0.15, 0.9)
    sessBtn:SetBackdropBorderColor(0.35, 0.35, 0.4, 1)
    sessBtn:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(0.5, 0.6, 0.7, 1) end)
    sessBtn:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(0.35, 0.35, 0.4, 1) end)
    local sArrow = sessBtn:CreateTexture(nil, "OVERLAY")
    sArrow:SetSize(10, 10)
    sArrow:SetPoint("RIGHT", -4, 0)
    sArrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
    sArrow:SetTexCoord(0, 1, 1, 0)   -- point down
    sessBtn.text = sessBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sessBtn.text:SetPoint("LEFT", 6, 0)
    sessBtn.text:SetPoint("RIGHT", sArrow, "LEFT", -2, 0)
    sessBtn.text:SetJustifyH("LEFT")
    sessBtn.text:SetWordWrap(false)

    sessMenu = CreateFrame("Frame", nil, f, "BackdropTemplate")
    sessMenu:SetFrameStrata("DIALOG")
    sessMenu:SetPoint("TOPLEFT", sessBtn, "BOTTOMLEFT", 0, -2)
    sessMenu:SetWidth(252)
    sessMenu:SetHeight(54)
    sessMenu:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    sessMenu:SetBackdropColor(0.05, 0.05, 0.07, 0.97)
    sessMenu:SetBackdropBorderColor(0, 0, 0, 1)
    sessMenu:Hide()
    sessMenu.rows = {}
    sessSearch = CreateFrame("EditBox", "AddonPulseSessSearch", sessMenu, "SearchBoxTemplate")
    sessSearch:SetSize(240, 20)
    sessSearch:SetPoint("TOPLEFT", 6, -5)
    sessSearch:SetScript("OnTextChanged", function(self)
        SearchBoxTemplate_OnTextChanged(self)
        sessionSearch = self:GetText() or ""
        RebuildSessionMenu()
    end)
    sessMenu.empty = sessMenu:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sessMenu.empty:SetPoint("TOPLEFT", 8, -33)
    sessMenu.empty:SetText("no matches")
    sessMenu.empty:Hide()

    -- Full-screen invisible closer so a click outside the list dismisses it
    -- (sits below the DIALOG-strata menu, above everything else).
    local sessCloser = CreateFrame("Button", nil, UIParent)
    sessCloser:SetAllPoints(UIParent)
    sessCloser:SetFrameStrata("HIGH")
    sessCloser:EnableMouse(true)
    sessCloser:Hide()
    sessCloser:SetScript("OnClick", function() sessMenu:Hide() end)
    sessMenu:SetScript("OnShow", function() sessCloser:Show() end)
    sessMenu:SetScript("OnHide", function() sessCloser:Hide() end)

    sessBtn:SetScript("OnClick", function()
        if sessMenu:IsShown() then
            sessMenu:Hide()
        else
            sessionSearch = ""
            sessSearch:SetText("")
            RebuildSessionMenu()
            sessMenu:Show()
            sessSearch:SetFocus()
        end
    end)

    graphBtn = MakeButton(f, "Hide graph", 80)
    graphBtn:SetPoint("TOPRIGHT", -PADDING, row2 + 1)
    graphBtn:SetScript("OnClick", function()
        db.showGraph = not db.showGraph
        Relayout()
    end)

    metricBtn = MakeButton(f, "Graph: CPU", 82)
    metricBtn:SetPoint("RIGHT", graphBtn, "LEFT", -4, 0)
    metricBtn:SetScript("OnClick", function()
        db.metric = (db.metric == "mem") and "cpu" or "mem"
        metricBtn:SetText(db.metric == "mem" and "Graph: Mem" or "Graph: CPU")
        Refresh()
    end)

    -- Tools menu (Addons tab): memory baseline + show-ignored toggle ----------
    toolsBtn = MakeButton(f, "Tools", 50)
    toolsBtn:SetPoint("RIGHT", metricBtn, "LEFT", -6, 0)

    toolsMenu = CreateFrame("Frame", nil, f, "BackdropTemplate")
    toolsMenu:SetFrameStrata("DIALOG")
    toolsMenu:SetPoint("TOPRIGHT", toolsBtn, "BOTTOMRIGHT", 0, -2)
    toolsMenu:SetWidth(186)
    toolsMenu:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    toolsMenu:SetBackdropColor(0.05, 0.05, 0.07, 0.97)
    toolsMenu:SetBackdropBorderColor(0, 0, 0, 1)
    toolsMenu:Hide()

    local th = toolsMenu:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    th:SetPoint("TOPLEFT", 8, -6)
    th:SetText("Memory baseline")
    th:SetTextColor(0.32, 0.78, 0.88)

    toolsMenu.setAct = MakeMenuAction(toolsMenu)
    toolsMenu.setAct:SetPoint("TOPLEFT", 4, -22)
    toolsMenu.setAct:SetPoint("TOPRIGHT", -4, -22)
    toolsMenu.setAct:SetScript("OnClick", function()
        ns.API.SetBaseline()
        local has = false
        for _, k in ipairs(db.addonCols) do if k == "dmem" then has = true break end end
        if not has then ToggleColumn("dmem", true) end   -- surface the ΔMem column
        toolsMenu:Hide()
        Refresh()
    end)

    toolsMenu.clearAct = MakeMenuAction(toolsMenu)
    toolsMenu.clearAct:SetPoint("TOPLEFT", 4, -44)
    toolsMenu.clearAct:SetPoint("TOPRIGHT", -4, -44)
    toolsMenu.clearAct:SetScript("OnClick", function()
        ns.API.ClearBaseline()
        toolsMenu:Hide()
        Refresh()
    end)

    toolsMenu.ageFS = toolsMenu:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    toolsMenu.ageFS:SetPoint("TOPLEFT", 8, -66)

    local tsep = toolsMenu:CreateTexture(nil, "ARTWORK")
    tsep:SetColorTexture(0.3, 0.3, 0.34, 0.6)
    tsep:SetPoint("TOPLEFT", 6, -80)
    tsep:SetPoint("TOPRIGHT", -6, -80)
    tsep:SetHeight(1)

    toolsMenu.showIgn = MakeCheck(toolsMenu, "Show ignored",
        function() return db.showIgnored end,
        function(v) db.showIgnored = v; Refresh() end)
    toolsMenu.showIgn:SetPoint("TOPLEFT", 6, -84)

    local tinfo = toolsMenu:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    tinfo:SetPoint("TOPLEFT", 8, -110)
    tinfo:SetPoint("TOPRIGHT", -8, -110)
    tinfo:SetJustifyH("LEFT")
    tinfo:SetText("Right-click a row to pin / ignore.")
    toolsMenu:SetHeight(148)

    -- Refresh the baseline action labels / age before the menu shows.
    function RebuildToolsMenu()
        local b = db.baseline
        toolsMenu.setAct.text:SetText(b and "Update baseline now" or "Set baseline now")
        toolsMenu.clearAct.text:SetText("Clear baseline")
        toolsMenu.clearAct:SetEnabled(b and true or false)
        toolsMenu.clearAct.text:SetTextColor(b and 1 or 0.45, b and 1 or 0.45, b and 1 or 0.45)
        if not db.memProfiler then
            toolsMenu.ageFS:SetText("|cffc0a040enable Mem prof to use dMem|r")
        elseif b then
            toolsMenu.ageFS:SetText("captured " .. FmtAgo(b.t))
        else
            toolsMenu.ageFS:SetText("no baseline set")
        end
    end

    local toolsCloser = CreateFrame("Button", nil, UIParent)
    toolsCloser:SetAllPoints(UIParent)
    toolsCloser:SetFrameStrata("HIGH")
    toolsCloser:Hide()
    toolsCloser:SetScript("OnClick", function() toolsMenu:Hide() end)
    toolsMenu:SetScript("OnShow", function() toolsCloser:Show() end)
    toolsMenu:SetScript("OnHide", function() toolsCloser:Hide() end)
    toolsBtn:SetScript("OnClick", function()
        if toolsMenu:IsShown() then toolsMenu:Hide()
        else RebuildToolsMenu(); toolsMenu:Show() end
    end)

    -- Row context menu (Addons tab): pin / ignore the right-clicked addon -----
    rowMenu = CreateFrame("Frame", nil, f, "BackdropTemplate")
    rowMenu:SetFrameStrata("DIALOG")
    rowMenu:SetWidth(132)
    rowMenu:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    rowMenu:SetBackdropColor(0.05, 0.05, 0.07, 0.97)
    rowMenu:SetBackdropBorderColor(0, 0, 0, 1)
    rowMenu:Hide()
    rowMenu.title = rowMenu:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rowMenu.title:SetPoint("TOPLEFT", 8, -6)
    rowMenu.title:SetPoint("TOPRIGHT", -8, -6)
    rowMenu.title:SetJustifyH("LEFT")
    rowMenu.title:SetWordWrap(false)
    rowMenu.title:SetTextColor(0.32, 0.78, 0.88)

    rowMenu.pin = MakeMenuAction(rowMenu)
    rowMenu.pin:SetPoint("TOPLEFT", 4, -22)
    rowMenu.pin:SetPoint("TOPRIGHT", -4, -22)
    rowMenu.pin:SetScript("OnClick", function()
        local n = rowMenu.target
        if n then db.pinned[n] = (not db.pinned[n]) or nil end
        rowMenu:Hide(); Refresh()
    end)
    rowMenu.ignore = MakeMenuAction(rowMenu)
    rowMenu.ignore:SetPoint("TOPLEFT", 4, -42)
    rowMenu.ignore:SetPoint("TOPRIGHT", -4, -42)
    rowMenu.ignore:SetScript("OnClick", function()
        local n = rowMenu.target
        if n then db.ignored[n] = (not db.ignored[n]) or nil end
        rowMenu:Hide(); Refresh()
    end)
    rowMenu:SetHeight(66)

    local rowCloser = CreateFrame("Button", nil, UIParent)
    rowCloser:SetAllPoints(UIParent)
    rowCloser:SetFrameStrata("HIGH")
    rowCloser:Hide()
    rowCloser:SetScript("OnClick", function() rowMenu:Hide() end)
    rowMenu:SetScript("OnShow", function() rowCloser:Show() end)
    rowMenu:SetScript("OnHide", function() rowCloser:Hide() end)

    function ShowRowMenu(entry, anchor)
        rowMenu.target = entry.name
        rowMenu.title:SetText(entry.name)
        rowMenu.pin.text:SetText(db.pinned[entry.name] and "Unpin" or "Pin to top")
        rowMenu.ignore.text:SetText(db.ignored[entry.name] and "Un-ignore" or "Ignore")
        rowMenu:ClearAllPoints()
        rowMenu:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -6, 0)
        rowMenu:Show()
    end
end

-- ---------------------------------------------------------------------------
-- Build the whole window. Called once at PLAYER_LOGIN.
-- ---------------------------------------------------------------------------
function ns.UI.Init()
    if f then return end
    local db = ns.db
    BuildAddonCols()   -- TABCOLS.addons from saved column selection

    if (db.size.w or 0) < 580 then db.size.w = 580 end   -- keep room for the toolbar

    f = CreateFrame("Frame", "AddonPulseFrame", UIParent, "BackdropTemplate")
    f:SetSize(db.size.w, db.size.h)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:SetResizable(true)
    f:EnableMouse(true)
    ns.UI.FitWidth()   -- sets resize bounds + widens to fit the selected columns
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    f:SetBackdropColor(0.05, 0.05, 0.07, db.opacity or 0.9)
    f:SetBackdropBorderColor(0, 0, 0, 1)
    f:SetScale(db.scale or 1)
    f:Hide()

    if db.point then
        f:SetPoint(db.point.point or "CENTER", UIParent, db.point.point or "CENTER",
            db.point.x or 0, db.point.y or 0)
    else
        f:SetPoint("CENTER")
    end

    -- Title bar ---------------------------------------------------------------
    titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetPoint("TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", 0, 0)
    titleBar:SetHeight(TITLE_H)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
    titleBar:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local point, _, _, x, y = f:GetPoint()
        db.point = { point = point, x = x, y = y }
    end)

    local tbg = titleBar:CreateTexture(nil, "BACKGROUND")
    tbg:SetAllPoints()
    tbg:SetColorTexture(0.32, 0.78, 0.88, 0.10)

    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("LEFT", 10, 0)
    titleText:SetText("|cff52c7e0AddonPulse|r")

    local close = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
    close:SetSize(26, 26)
    close:SetPoint("RIGHT", -2, 0)
    close:SetScript("OnClick", function() ns.UI.Toggle() end)

    minBtn = CreateFrame("Button", nil, titleBar, "UIPanelButtonTemplate")
    minBtn:SetSize(22, 18)
    minBtn:SetPoint("RIGHT", close, "LEFT", -2, 0)
    minBtn:SetText("_")
    minBtn:SetScript("OnClick", function()
        db.collapsed = not db.collapsed
        Relayout()
    end)

    -- Cogwheel + brief status readout on the title bar (live even when minimised).
    cogBtn = CreateFrame("Button", nil, titleBar)
    cogBtn:SetSize(15, 15)
    cogBtn:SetPoint("RIGHT", minBtn, "LEFT", -5, 0)
    local cogTex = cogBtn:CreateTexture(nil, "ARTWORK")
    cogTex:SetAllPoints()
    cogTex:SetTexture("Interface\\Buttons\\UI-OptionsButton")
    cogTex:SetVertexColor(0.75, 0.75, 0.75)
    cogBtn:SetScript("OnEnter", function() cogTex:SetVertexColor(1, 1, 1) end)
    cogBtn:SetScript("OnLeave", function() cogTex:SetVertexColor(0.75, 0.75, 0.75) end)

    statusFS = titleBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusFS:SetPoint("LEFT", titleText, "RIGHT", 12, 0)
    statusFS:SetPoint("RIGHT", cogBtn, "LEFT", -8, 0)
    statusFS:SetJustifyH("RIGHT")     -- stats hug the right, next to the cog
    statusFS:SetWordWrap(false)

    cogMenu = CreateFrame("Frame", nil, f, "BackdropTemplate")
    cogMenu:SetFrameStrata("DIALOG")
    cogMenu:SetPoint("TOPRIGHT", cogBtn, "BOTTOMRIGHT", 0, -3)   -- drops down-left, stays in frame
    cogMenu:SetWidth(120)
    cogMenu:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    cogMenu:SetBackdropColor(0.05, 0.05, 0.07, 0.96)
    cogMenu:SetBackdropBorderColor(0, 0, 0, 1)
    cogMenu:Hide()
    local mh = cogMenu:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mh:SetPoint("TOPLEFT", 8, -6)
    mh:SetText("Show on bar")
    local cy = -24
    for _, it in ipairs({ { k = "fps", l = "FPS" }, { k = "cpu", l = "CPU" },
                          { k = "mem", l = "Memory" }, { k = "comms", l = "Comms" },
                          { k = "home", l = "Home ms" }, { k = "world", l = "World ms" } }) do
        local key = it.k
        local cb = MakeCheck(cogMenu, it.l,
            function() return ns.db.bar and ns.db.bar[key] end,
            function(v) ns.db.bar = ns.db.bar or {}; ns.db.bar[key] = v; UpdateStatusBar() end)
        cb:SetPoint("TOPLEFT", 6, cy)
        cy = cy - 23
    end
    local sep = cogMenu:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(0.3, 0.3, 0.34, 0.6)
    sep:SetPoint("TOPLEFT", 6, cy - 2)
    sep:SetPoint("TOPRIGHT", -6, cy - 2)
    sep:SetHeight(1)
    cy = cy - 8
    local optBtn = CreateFrame("Button", nil, cogMenu)
    optBtn:SetPoint("TOPLEFT", 6, cy)
    optBtn:SetPoint("TOPRIGHT", -6, cy)
    optBtn:SetHeight(20)
    optBtn.text = optBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optBtn.text:SetPoint("LEFT", 2, 0)
    optBtn.text:SetText("Options...")
    local oh = optBtn:CreateTexture(nil, "BACKGROUND")
    oh:SetAllPoints()
    oh:SetColorTexture(0.32, 0.78, 0.88, 0.18)
    oh:Hide()
    optBtn:SetScript("OnEnter", function() oh:Show() end)
    optBtn:SetScript("OnLeave", function() oh:Hide() end)
    optBtn:SetScript("OnClick", function()
        cogMenu:Hide()
        if ns.Options and ns.Options.Toggle then ns.Options.Toggle() end
    end)
    cy = cy - 22
    cogMenu:SetHeight(-cy + 6)
    cogBtn:SetScript("OnClick", function() cogMenu:SetShown(not cogMenu:IsShown()) end)

    -- Tab bar -----------------------------------------------------------------
    local prevTab
    for _, key in ipairs(TAB_ORDER) do
        local b = CreateFrame("Button", nil, f)
        b:SetHeight(TAB_H)
        b.key = key
        b.fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.fs:SetPoint("CENTER")
        b.fs:SetText(TABDEF[key].tabLabel)
        b:SetWidth(b.fs:GetStringWidth() + 22)
        b.underline = b:CreateTexture(nil, "OVERLAY")
        b.underline:SetColorTexture(0.32, 0.78, 0.88, 1)
        b.underline:SetHeight(2)
        b.underline:SetPoint("BOTTOMLEFT", 4, 0)
        b.underline:SetPoint("BOTTOMRIGHT", -4, 0)
        if prevTab then
            b:SetPoint("LEFT", prevTab, "RIGHT", 6, 0)
        else
            b:SetPoint("TOPLEFT", PADDING, -(TITLE_H + 2))
        end
        b:SetScript("OnClick", function(self) ns.UI.SetTab(self.key) end)
        b:SetScript("OnEnter", function(self) self.fs:SetTextColor(1, 1, 1) end)
        b:SetScript("OnLeave", UpdateTabColors)
        tabButtons[#tabButtons + 1] = b
        prevTab = b
    end

    BuildToolbar()

    -- Column headers ----------------------------------------------------------
    header = CreateFrame("Frame", nil, f)
    header:SetPoint("TOPLEFT", PADDING, -(TOP - HEADER_H - 2))
    header:SetPoint("TOPRIGHT", -(PADDING + SCROLLBAR_W), -(TOP - HEADER_H - 2))
    header:SetHeight(HEADER_H)

    local hbg = header:CreateTexture(nil, "BACKGROUND")
    hbg:SetAllPoints()
    hbg:SetColorTexture(1, 1, 1, 0.04)

    local function MakeHeader(justify)
        local b = CreateFrame("Button", nil, header)
        b:SetHeight(HEADER_H)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetAllPoints()
        fs:SetJustifyH(justify)
        b.fs = fs
        b:SetScript("OnClick", function(self) HeaderClick(self.key) end)
        b:SetScript("OnEnter", function(self)
            self.fs:SetTextColor(1, 1, 1)
            local desc = HeaderDesc(ns.db.tab, self.key)
            if desc then
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                GameTooltip:AddLine(desc, 0.9, 0.9, 0.9, true)
                GameTooltip:AddLine("Click to sort.", 0.5, 0.7, 1)
                GameTooltip:Show()
            end
        end)
        b:SetScript("OnLeave", function(self)
            self.fs:SetTextColor(1, 0.82, 0)
            GameTooltip:Hide()
        end)
        return b
    end

    hName = MakeHeader("LEFT")
    for c = 1, MAXCOLS do hCols[c] = MakeHeader("RIGHT") end

    -- Scroll list -------------------------------------------------------------
    scroll = CreateFrame("ScrollFrame", "AddonPulseScroll", f, "FauxScrollFrameTemplate")
    scroll:SetScript("OnVerticalScroll", function(self, off)
        FauxScrollFrame_OnVerticalScroll(self, off, ROW_H, Refresh)
    end)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local sb = self.ScrollBar or _G[(self:GetName() or "") .. "ScrollBar"]
        if sb then sb:SetValue(sb:GetValue() - delta * ROW_H) end
    end)

    -- Footer ------------------------------------------------------------------
    footer = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footer:SetPoint("BOTTOMLEFT", PADDING, 7)
    footer:SetPoint("BOTTOMRIGHT", -PADDING, 7)
    footer:SetJustifyH("LEFT")
    footer:SetHeight(FOOTER_H)

    -- Graph -------------------------------------------------------------------
    graph = ns.Graph.Create(f)
    graph:SetPoint("BOTTOMLEFT", PADDING, 7 + FOOTER_H + GRAPHROW_H)
    graph:SetPoint("BOTTOMRIGHT", -PADDING, 7 + FOOTER_H + GRAPHROW_H)
    graph:SetHeight(GRAPH_H)

    -- Graph control strip (its own row, between the graph and the footer):
    -- marks filter on the left, time window on the right.
    graphRow = CreateFrame("Frame", nil, f)
    graphRow:SetPoint("BOTTOMLEFT", PADDING, 7 + FOOTER_H)
    graphRow:SetPoint("BOTTOMRIGHT", -PADDING, 7 + FOOTER_H)
    graphRow:SetHeight(GRAPHROW_H)

    markerBtn = CreateFrame("Button", nil, graphRow)
    markerBtn:SetSize(150, GRAPHROW_H)
    markerBtn:SetPoint("LEFT", 2, 0)
    markerBtn.fs = markerBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    markerBtn.fs:SetPoint("LEFT")
    markerBtn.fs:SetJustifyH("LEFT")
    markerBtn.fs:SetTextColor(0.75, 0.75, 0.75)
    markerBtn:SetScript("OnClick", function()
        local m = db.markerMode
        db.markerMode = (m == "all") and "key" or (m == "key") and "off" or "all"
        UpdateMarkerBtn()
        Refresh()
    end)
    markerBtn:SetScript("OnEnter", function(self) self.fs:SetTextColor(1, 1, 1) end)
    markerBtn:SetScript("OnLeave", function(self) self.fs:SetTextColor(0.75, 0.75, 0.75) end)
    UpdateMarkerBtn()

    graphRow.timespan = graphRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    graphRow.timespan:SetPoint("RIGHT", -2, 0)
    graphRow.timespan:SetJustifyH("RIGHT")
    graphRow.timespan:SetTextColor(0.6, 0.6, 0.6)

    -- Resize grip -------------------------------------------------------------
    grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    local gt = grip:CreateTexture(nil, "OVERLAY")
    gt:SetAllPoints()
    gt:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        db.size.w, db.size.h = f:GetWidth(), f:GetHeight()
    end)

    f:SetScript("OnSizeChanged", function(self)
        if not ns.db.collapsed then
            ns.db.size.w, ns.db.size.h = self:GetWidth(), self:GetHeight()
        end
        for i = 1, #rows do rows[i]._laidTab = nil end   -- re-fit name/sparkline to the new width
        Refresh()
    end)

    -- The sampling loop lives on an always-on driver in the core (so recording
    -- continues while the window is closed or minimised). On show we just take
    -- one immediate sample for snappiness, then lay the active tab out.
    f:SetScript("OnShow", function()
        ns.API.RefreshProfiling()
        UpdateEnableButton()
        if ns.db.enabled then
            ns._forceMem = true             -- refresh memory immediately on open
            ns.API.Sample(ns.db.interval)
        end
        ns.UI.SetTab(ns.db.tab)
    end)

    f:SetScript("OnHide", function()
        if cogMenu then cogMenu:Hide() end
        if sessMenu then sessMenu:Hide() end
        if colsMenu then colsMenu:Hide() end
    end)

    UpdateEnableButton()
    if db.shown then f:Show() end
end

-- ---------------------------------------------------------------------------
-- Public toggle.
-- ---------------------------------------------------------------------------
function ns.UI.Toggle()
    if not f then return end
    if f:IsShown() then f:Hide() else f:Show() end
    ns.db.shown = f:IsShown()
end

function ns.UI.Show()
    if f and not f:IsShown() then f:Show(); ns.db.shown = true end
end

-- True when the frame is visible (still true while minimised — the body is
-- hidden but the frame is shown). Used by the core driver to decide repaints.
function ns.UI.IsShown()
    return (f and f:IsShown()) and true or false
end

-- Master enable/disable changed (button, minimap, or slash): relabel and, if the
-- window is up, take an immediate sample so it isn't stale.
function ns.UI.OnEnabledChanged()
    UpdateEnableButton()
    if f and f:IsShown() then
        if ns.db.enabled then
            ns._forceMem = true
            ns.API.Sample(ns.db.interval)
        end
        Refresh()
    end
end

-- Called when a session is stored / removed, so the Sessions tab updates live.
function ns.UI.OnSessionStored()
    selectedSession = nil   -- fall back to the newest
    if sessMenu and sessMenu:IsShown() then RebuildSessionMenu() end
    if f and f:IsShown() and not ns.db.collapsed then Refresh() end
end

-- Apply window scale + background opacity (called live from the options panel).
function ns.UI.ApplyAppearance()
    if not f then return end
    f:SetScale(ns.db.scale or 1)
    f:SetBackdropColor(0.05, 0.05, 0.07, ns.db.opacity or 0.9)
end

-- Re-sync toolbar controls from the DB (after the options panel changes them)
-- and repaint, so the two stay consistent.
function ns.UI.SyncControls()
    if memCB then memCB:SetChecked(ns.db.memProfiler and true or false) end
    if loadedCB then loadedCB:SetChecked(ns.db.loadedOnly and true or false) end
    if hideCB then hideCB:SetChecked(ns.db.hideInactive and true or false) end
    if f and f:IsShown() then Refresh() end
end
