--[[--------------------------------------------------------------------------
    AddonPulse — Graph.lua
    --------------------------------------------------------------------------
    A small line-graph widget that plots one addon's history (CPU or memory,
    per db.metric). Lines are drawn with frame:CreateLine() and recycled from a
    pool, so a redraw just repositions existing line objects — no garbage.

    Annotations:
      * Event markers — coloured vertical lines at combat / pull / death, passed
        in (normalised 0..1) by the UI for the live graph and stored sessions.
      * Hover readout — mousing over the plot shows a crosshair and the value /
        time at that point (and the nearest event). The hover OnUpdate only runs
        while the cursor is actually over the graph.
----------------------------------------------------------------------------]]

local _, ns = ...

ns.Graph = ns.Graph or {}

local floor = math.floor
local abs   = math.abs
local format = string.format

local function FmtDur(s)
    s = floor((s or 0) + 0.5)
    return ("%d:%02d"):format(floor(s / 60), s % 60)
end

local INSET   = 6     -- plot inset from the panel edge
local TOP_PAD = 32    -- room for the title + stats rows above the plot

local MARKER = {
    combat    = { 1.00, 0.85, 0.20 },   -- combat start
    combatend = { 0.55, 0.55, 0.55 },   -- combat end
    pull      = { 1.00, 0.30, 0.30 },   -- boss pull / encounter
    death     = { 0.95, 0.95, 0.95 },   -- player death
}
local function MarkerColor(kind)
    local c = MARKER[kind]
    if c then return c[1], c[2], c[3] end
    return 0.6, 0.6, 0.85
end

-- Hover handler: runs only while the cursor is over the graph.
local function HoverUpdate(self)
    local plot = self.plot
    if not plot or not plot.hist then
        self.cross:Hide(); self.readout:SetText("")
        return
    end
    local mx = GetCursorPosition() / self:GetEffectiveScale() - self:GetLeft()
    local fx = (mx - plot.x0) / plot.w
    if fx < 0 then fx = 0 elseif fx > 1 then fx = 1 end
    local idx = floor(fx * (plot.n - 1) + 0.5) + 1
    if idx < 1 then idx = 1 elseif idx > plot.n then idx = plot.n end
    local val = plot.hist[idx] or 0

    local sx = plot.x0 + ((idx - 1) / (plot.n - 1)) * plot.w
    self.cross:ClearAllPoints()
    self.cross:SetStartPoint("BOTTOMLEFT", self, sx, plot.y0)
    self.cross:SetEndPoint("BOTTOMLEFT", self, sx, plot.y0 + plot.h)
    self.cross:Show()

    local vtxt
    if plot.metric == "comms" then vtxt = ns.FmtBytes(val) .. "/s"
    elseif plot.metric == "mem" then vtxt = ns.FmtMem(val)
    else vtxt = ns.FmtCPUDisplay(val) .. ns.CPUUnit() end

    -- FPS at this point (session graphs carry a parallel fps series).
    local ftxt = ""
    if plot.fps and #plot.fps >= 1 then
        local fn = #plot.fps
        local fi = floor(fx * (fn - 1) + 0.5) + 1
        if fi < 1 then fi = 1 elseif fi > fn then fi = fn end
        ftxt = ("  |cff8fd98f%d fps|r"):format(floor((plot.fps[fi] or 0) + 0.5))
    end
    local ttxt
    if plot.isSession then
        local tin = fx * (plot.duration or 0)
        ttxt = ("%d:%02d"):format(floor(tin / 60), floor(tin) % 60)
    else
        local ago = (1 - fx) * (plot.span or 0)
        ttxt = (ago < 1) and "now" or ("-%ds"):format(floor(ago))
    end
    local near, best = nil, 0.04
    if plot.markers then
        for i = 1, #plot.markers do
            local d = abs(plot.markers[i].x - fx)
            if d < best then best = d; near = plot.markers[i].label end
        end
    end
    self.readout:SetText(("|cffffffff%s|r%s |cffaaaaaa%s|r%s"):format(
        vtxt, ftxt, ttxt, near and ("  |cffffd479" .. near .. "|r") or ""))
end

-- ---------------------------------------------------------------------------
-- Build the panel. `parent` is the main window; the returned frame is anchored
-- by the UI layout code.
-- ---------------------------------------------------------------------------
function ns.Graph.Create(parent)
    local g = CreateFrame("Frame", "AddonPulseGraph", parent, "BackdropTemplate")
    g:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    g:SetBackdropColor(0, 0, 0, 0.35)
    g:SetBackdropBorderColor(1, 1, 1, 0.10)

    g.title = g:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    g.title:SetPoint("TOPLEFT", INSET, -4)
    g.title:SetText("")

    g.stats = g:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    g.stats:SetPoint("TOPLEFT", g.title, "BOTTOMLEFT", 0, -2)
    g.stats:SetJustifyH("LEFT")
    g.stats:SetText("")

    g.peak = g:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    g.peak:SetPoint("TOPRIGHT", -INSET, -4)
    g.peak:SetJustifyH("RIGHT")

    -- Hover readout sits where the peak label is (peak hides while hovering).
    g.readout = g:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    g.readout:SetPoint("TOPRIGHT", -INSET, -4)
    g.readout:SetJustifyH("RIGHT")
    g.readout:Hide()

    local function gridline()
        local t = g:CreateTexture(nil, "ARTWORK")
        t:SetColorTexture(1, 1, 1, 0.07)
        t:SetHeight(1)
        return t
    end
    g.baseline = gridline()
    g.midline  = gridline()

    g.cross = g:CreateLine(nil, "OVERLAY")
    g.cross:SetThickness(1)
    g.cross:SetColorTexture(1, 1, 1, 0.45)
    g.cross:Hide()

    g.lines  = {}   -- pooled series Line objects
    g.mlines = {}   -- pooled marker Line objects
    g.dots   = {}   -- pooled spike-annotation dots
    g.fps2   = {}   -- pooled FPS-overlay Line objects (sessions)

    g:EnableMouse(true)
    g:SetScript("OnEnter", function(self)
        self.peak:Hide(); self.readout:Show()
        self:SetScript("OnUpdate", HoverUpdate)
    end)
    g:SetScript("OnLeave", function(self)
        self:SetScript("OnUpdate", nil)
        self.cross:Hide(); self.readout:Hide(); self.peak:Show()
    end)

    ns.graphFrame = g
    return g
end

-- Fetch (or grow) series line #i from the pool.
local function GetLine(g, i)
    local ln = g.lines[i]
    if not ln then
        ln = g:CreateLine(nil, "ARTWORK")
        ln:SetThickness(1.5)
        g.lines[i] = ln
    end
    return ln
end

-- ---------------------------------------------------------------------------
-- Redraw for the given entry. `markers` is an optional array of
-- { x = 0..1, kind, label } to annotate the timeline.
-- ---------------------------------------------------------------------------
function ns.Graph.Draw(entry, markers, fps)
    local g = ns.graphFrame
    if not g or not g:IsShown() then return end

    local db = ns.db
    local comms = entry and entry.isComms
    local metric = comms and "comms" or db.metric
    local hist = comms and entry.bytesHist
              or (entry and (metric == "mem" and entry.memHist or entry.cpuHist))

    local w = g:GetWidth()  - INSET * 2
    local h = g:GetHeight() - INSET - TOP_PAD
    g.baseline:ClearAllPoints()
    g.baseline:SetPoint("BOTTOMLEFT",  g, INSET, INSET)
    g.baseline:SetPoint("BOTTOMRIGHT", g, -INSET, INSET)
    g.midline:ClearAllPoints()
    g.midline:SetPoint("BOTTOMLEFT",  g, INSET, INSET + h / 2)
    g.midline:SetPoint("BOTTOMRIGHT", g, -INSET, INSET + h / 2)

    local function clearPlot()
        g.plot = nil
        for i = 1, #g.lines do g.lines[i]:Hide() end
        for i = 1, #g.mlines do g.mlines[i]:Hide() end
        for i = 1, #g.dots do g.dots[i]:Hide() end
        for i = 1, #g.fps2 do g.fps2[i]:Hide() end
        g.cross:Hide()
    end

    if not entry then
        g.title:SetText("|cffaaaaaaNo addon selected — click a row|r")
        g.stats:SetText(""); g.peak:SetText("")
        clearPlot()
        return
    end

    local native = ns.Prof and ns.Prof.hasAddOnProfiler
    local cpuUnit = (ns.db and ns.db.cpuPercent) and "% frame" or "ms/frame"
    local unit, r, gr, b
    if comms then
        unit = "network (bytes/s)"
        r, gr, b = 0.40, 0.80, 0.85
    elseif metric == "mem" then
        unit = "memory"
        r, gr, b = 0.45, 0.75, 1.00
    else
        unit = native and ("CPU (" .. cpuUnit .. ")") or "CPU (ms/s)"
        r, gr, b = 1.00, 0.70, 0.30
    end
    g.title:SetText(("|cffffffff%s|r  •  %s"):format(entry.name or entry.prefix, unit))

    local s
    if comms then
        s = format(
            "in |cffffffff%s|r · out |cffffffff%s|r · rate |cffffffff%s/s|r · peak |cffffffff%s/s|r",
            ns.FmtBytes(entry.bytesIn or 0), ns.FmtBytes(entry.bytesOut or 0),
            ns.FmtBytes(entry.rate or 0), ns.FmtBytes(entry.peakRate or 0))
    elseif entry.isSession then
        s = format(
            "%s |cffffffff%s|r · cpu peak |cffffffff%s|r avg |cffffffff%s|r%s · mem peak |cffffffff%s|r",
            entry.kind or "fight", FmtDur(entry.sessionDur),
            ns.FmtCPUDisplay(entry.cpuPeak), ns.FmtCPUDisplay(entry.cpuSession), ns.CPUUnit(), ns.FmtMem(entry.memPeak))
    elseif native then
        local o50  = ns.Prof.AddOn(entry.name, "over50")    -- not sampled per tick
        local o100 = ns.Prof.AddOn(entry.name, "over100")
        s = format(
            "recent |cffffffff%s|r · peak |cffffffff%s|r · session |cffffffff%s|r · enc |cffffffff%s|r%s · spikes >10/50/100ms |cffffffff%d/%d/%d|r",
            ns.FmtCPUDisplay(entry.cpuRecent), ns.FmtCPUDisplay(entry.cpuPeak), ns.FmtCPUDisplay(entry.cpuSession),
            ns.FmtCPUDisplay(entry.cpuEncounter), ns.CPUUnit(), entry.over10 or 0, o50, o100)
    else
        local _, mx, av = ns.HistStats(entry.memHist)
        s = format("memory peak |cffffffff%s|r · avg |cffffffff%s|r%s",
            ns.FmtMem(mx), ns.FmtMem(av), entry.leaking and " · |cffffa030leak?|r" or "")
    end
    if fps and #fps >= 2 and not comms then s = s .. "  ·  |cff8fd98ffps overlay|r" end
    g.stats:SetText(s)

    local n = hist and #hist or 0
    if n < 2 then
        g.peak:SetText(n == 0 and "" or "collecting…")
        clearPlot()
        return
    end

    local peak, lo = hist[1], hist[1]
    for i = 1, n do
        local v = hist[i]
        if v > peak then peak = v end
        if v < lo then lo = v end
    end

    -- Y axis. CPU is read against 0 (absolute load is what matters). Memory is
    -- usually large and changes only a little, so a 0-based axis pins it as a
    -- flat line near the top — instead we "zoom to fit" its min..max so growth /
    -- churn is visible. When memory genuinely didn't move (e.g. a fight recorded
    -- with the window closed, where per-addon memory isn't sampled), say so.
    local memVaries = (peak - lo) > (peak * 0.01 + 1)   -- >1% and >1 KB
    local base, top
    if metric == "mem" and memVaries then
        local pad = (peak - lo) * 0.12
        base, top = lo - pad, peak + pad
        if base < 0 then base = 0 end
    else
        base, top = 0, (peak > 0) and peak * 1.10 or 1
    end
    local range = (top - base > 0) and (top - base) or 1

    if comms then
        g.peak:SetText("peak " .. ns.FmtBytes(peak) .. "/s")
    elseif metric == "mem" and not memVaries then
        g.peak:SetText("steady " .. ns.FmtMem(peak))
    else
        g.peak:SetText("peak " .. ((metric == "mem") and ns.FmtMem(peak)
            or (native and (ns.FmtCPUDisplay(peak) .. ns.CPUUnit()) or (ns.FmtMs(peak) .. " ms/s"))))
    end

    local span = db.history * db.interval

    local stepX = w / (n - 1)
    local function px(i) return INSET + (i - 1) * stepX end
    local function py(v)
        local t = (v - base) / range
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        return INSET + t * h
    end

    -- Event markers (behind the series).
    local mi = 0
    if markers then
        for k = 1, #markers do
            local m = markers[k]
            if m.x >= 0 and m.x <= 1 then
                mi = mi + 1
                local ln = g.mlines[mi]
                if not ln then
                    ln = g:CreateLine(nil, "BORDER")
                    ln:SetThickness(1.5)
                    g.mlines[mi] = ln
                end
                local cr, cg, cb = MarkerColor(m.kind)
                ln:SetColorTexture(cr, cg, cb, 0.55)
                local mxp = INSET + m.x * w
                ln:SetStartPoint("BOTTOMLEFT", g, mxp, INSET)
                ln:SetEndPoint("BOTTOMLEFT",   g, mxp, INSET + h)
                ln:Show()
            end
        end
    end
    for k = mi + 1, #g.mlines do g.mlines[k]:Hide() end

    -- The series line.
    local count = 0
    for i = 1, n - 1 do
        count = count + 1
        local ln = GetLine(g, count)
        ln:SetColorTexture(r, gr, b, 0.95)
        ln:SetStartPoint("BOTTOMLEFT", g, px(i),     py(hist[i]))
        ln:SetEndPoint("BOTTOMLEFT",   g, px(i + 1), py(hist[i + 1]))
        ln:Show()
    end
    for i = count + 1, #g.lines do g.lines[i]:Hide() end

    -- FPS overlay (sessions): a faint green line on its own scale, so a frame-rate
    -- dip lines up under the addon's CPU / memory spike. Drawn on BORDER (behind
    -- the series); hover stays on the primary; the footer carries the avg / min.
    local fc = 0
    if fps and #fps >= 2 then
        local fn, fmax = #fps, 1
        for i = 1, fn do if fps[i] > fmax then fmax = fps[i] end end
        local fscale, fstepX = fmax * 1.10, w / (fn - 1)
        for i = 1, fn - 1 do
            fc = fc + 1
            local ln = g.fps2[fc]
            if not ln then
                ln = g:CreateLine(nil, "BORDER")
                ln:SetThickness(1)
                g.fps2[fc] = ln
            end
            ln:SetColorTexture(0.55, 0.85, 0.55, 0.32)
            ln:SetStartPoint("BOTTOMLEFT", g, INSET + (i - 1) * fstepX, INSET + (fps[i] / fscale) * h)
            ln:SetEndPoint("BOTTOMLEFT",   g, INSET + i * fstepX,       INSET + (fps[i + 1] / fscale) * h)
            ln:Show()
        end
    end
    for k = fc + 1, #g.fps2 do g.fps2[k]:Hide() end

    -- Spike annotations: a red tick along the top for each interval in which this
    -- addon had a frame over 50 ms. Live addons use a dense spikeHist (parallel
    -- to the series); saved sessions use a sparse spikes table { index -> count }.
    local sp  = entry.spikeHist
    local sps = entry.spikes
    local di = 0
    if (sp and #sp == n) or sps then
        for k = 1, n do
            local cnt = (sp and sp[k]) or (sps and sps[k]) or 0
            if cnt > 0 then
                di = di + 1
                local dot = g.dots[di]
                if not dot then
                    dot = g:CreateTexture(nil, "OVERLAY")
                    dot:SetSize(3, 4)
                    g.dots[di] = dot
                end
                dot:SetColorTexture(1, 0.30, 0.30, 0.95)
                dot:ClearAllPoints()
                dot:SetPoint("CENTER", g, "BOTTOMLEFT", px(k), INSET + h - 2)
                dot:Show()
            end
        end
    end
    for k = di + 1, #g.dots do g.dots[k]:Hide() end

    -- Context for the hover handler.
    g.plot = {
        hist = hist, n = n, metric = metric,
        x0 = INSET, y0 = INSET, w = w, h = h,
        isSession = entry.isSession,
        span = span, duration = entry.sessionDur,
        markers = markers,
        fps = fps,
    }
end
