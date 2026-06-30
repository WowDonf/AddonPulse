--[[--------------------------------------------------------------------------
    AddonPulse
    --------------------------------------------------------------------------
    Built for World of Warcraft: Midnight (12.x)

    A live per-addon resource monitor. The window lists every installed addon
    with its current memory footprint and — when script profiling is on — how
    much CPU time it is burning per second. Columns are sortable, the list is
    filterable by name, any addon can be graphed over time, and the window
    minimises to its title bar.

    Design note on cost: nothing is sampled while the window is closed or
    minimised. The sampling loop is an OnUpdate on the main frame that only
    fires when the frame is shown, throttled to the configured interval
    (default 2s). UpdateAddOnMemoryUsage / UpdateAddOnCPUUsage walk every addon,
    so we call them exactly once per sample, never per frame. Closed idle cost
    is therefore zero.

    A word on "process": WoW runs the entire UI — every addon — inside one Lua
    state in a single client process. There are no per-addon OS processes, so
    "by process" here means "by addon", which is the finest granularity the
    client exposes (GetAddOn*Usage). Shared libraries are billed to whichever
    addon's code was on the stack when the allocation happened.
----------------------------------------------------------------------------]]

local addonName, ns = ...

ns.API = ns.API or {}

-- WoW 11.x moved the AddOn roster functions under C_AddOns; keep a global
-- fallback so the file still loads on an older client.
local GetNumAddOns  = (C_AddOns and C_AddOns.GetNumAddOns)  or _G.GetNumAddOns
local GetAddOnInfo   = (C_AddOns and C_AddOns.GetAddOnInfo)   or _G.GetAddOnInfo
local IsAddOnLoaded  = (C_AddOns and C_AddOns.IsAddOnLoaded)  or _G.IsAddOnLoaded

-- The memory / CPU meters are still globals in 12.x.
local UpdateMem  = UpdateAddOnMemoryUsage
local GetMem     = GetAddOnMemoryUsage
local UpdateCPU  = UpdateAddOnCPUUsage
local GetCPU     = GetAddOnCPUUsage
local ResetCPU   = ResetCPUUsage

local CVarGet = (C_CVar and C_CVar.GetCVar) or _G.GetCVar
local CVarSet = (C_CVar and C_CVar.SetCVar) or _G.SetCVar
local GetTime = GetTime
local GetServerTime = GetServerTime
local GetFramerate = GetFramerate

local format, floor, max = string.format, math.floor, math.max
local sort, wipe = table.sort, wipe

-- ---------------------------------------------------------------------------
-- Saved-variable defaults. Account-wide: this is a dev/diagnostic tool, so the
-- window position and view settings should follow you across characters.
-- ---------------------------------------------------------------------------
local DEFAULTS = {
    enabled      = true,     -- master switch: sample + auto-record, or fully paused
    memProfiler  = true,     -- per-addon memory scan (the heavy part); off = CPU only
    memInCombat  = false,    -- allow the memory walk during combat (off = defer it, no combat spikes)
    interval     = 2,        -- seconds between CPU samples
    memSeconds   = 10,       -- how often to refresh per-addon memory (expensive walk)
    history      = 90,       -- samples kept per addon (90 * 2s = 3 minutes)
    fightMinDur  = 5,        -- ignore "fights" shorter than this (seconds)
    maxFights    = 8,        -- saved combat snapshots to keep
    maxRuns      = 4,        -- saved dungeon/raid snapshots to keep
    sessionMaxDays = 14,     -- auto-drop saved sessions older than this (0 = never)
    sessionSpikes  = true,   -- capture per-tick >50ms spike timing into sessions
    -- sessions / baseline / activeRun live in the PER-CHARACTER db (ns.cdb), not
    -- here: combat captures and the memory baseline are character-specific (addons
    -- differ per character), while these settings stay shared account-wide.
    cpuPercent   = false,    -- show CPU as % of a frame budget instead of ms
    targetFPS    = 60,       -- frame budget for the % display (1000/fps ms = 100%)
    scale        = 1.0,      -- window scale (0.7 - 1.3)
    opacity      = 0.9,      -- window background opacity (0.3 - 1.0)
    ignored      = {},       -- addon names hidden from the table (name -> true)
    pinned       = {},       -- addon names pinned to the top (name -> true)
    showIgnored  = false,    -- reveal ignored addons (dimmed) so they can be un-ignored
    sortKey      = "recent", -- any column key (name | mem | recent | peak | ...)
    sortDir      = "desc",   -- "asc" | "desc"
    -- addonCols (the user-selected Addons columns) is intentionally NOT here:
    -- ApplyDefaults deep-merges arrays by index, which would re-add a column the
    -- user removed. It's seeded once in InitDB instead.
    tab          = "addons", -- active tab: addons | comms
    metric       = "cpu",    -- which series the graph plots: "cpu" | "mem"
    markerMode   = "all",    -- graph event markers: all | key (pulls+deaths) | off
    bar          = { fps = true, cpu = true, mem = true, comms = false, home = false, world = false },  -- brief title-bar stats
    loadedOnly   = true,     -- hide addons that are installed but not loaded
    hideInactive = false,    -- hide addons using almost nothing
    showGraph    = true,     -- graph panel visible
    collapsed    = false,    -- minimised to title bar
    selected     = nil,      -- addon name pinned to the graph
    shown        = false,    -- window open at logout -> reopen at login
    point        = nil,      -- { point, x, y } remembered position
    size         = { w = 580, h = 480 },
    minimap      = { hide = false },
}
ns.DEFAULTS = DEFAULTS    -- exposed so the options panel can reset to defaults

-- An addon counts as "inactive" below this much memory AND CPU.
ns.INACTIVE_KB  = 60     -- KB
ns.INACTIVE_CPU = 0.1    -- ms/s

-- ---------------------------------------------------------------------------
-- Live data model. One entry per installed addon, plus a name index. Rebuilt
-- once at login; the addon roster is fixed for the session (on-demand addons
-- already appear here, just flagged unloaded until they load).
-- ---------------------------------------------------------------------------
ns.addons = {}   -- array, indexed by addon index
ns.byName = {}   -- [name] = entry
ns.view   = {}   -- scratch array reused by GetView (filtered + sorted)

ns.totalMem  = 0
ns.totalCPU  = 0
ns.profiling = false
ns.sampleCount = 0

-- ---------------------------------------------------------------------------
-- Formatting + colour helpers (shared with UI / Graph).
-- ---------------------------------------------------------------------------
function ns.FmtMem(kb)
    kb = kb or 0
    if kb >= 1024 then
        return format("%.1f MB", kb / 1024)
    end
    return format("%.0f KB", kb)
end

-- With C_AddOnProfiler, CPU is milliseconds of work per *tick* (frame). At
-- 60 fps the frame budget is ~16.7 ms, so an addon averaging >1 ms/frame is
-- already a real slice of it. FmtMs keeps small values legible.
function ns.FmtMs(v)
    v = v or 0
    if v < 0 then v = 0 end
    if v < 10 then return format("%.2f", v) end
    if v < 100 then return format("%.1f", v) end
    return format("%.0f", v)
end

-- CPU display honouring db.cpuPercent: either ms/frame (FmtMs) or a percentage
-- of one frame's budget (1000/targetFPS ms = 100%). The colour ramp stays
-- ms-based (CPUColor) so severity is consistent regardless of the unit shown.
function ns.FmtCPUDisplay(v)
    v = v or 0
    if v < 0 then v = 0 end
    if ns.db and ns.db.cpuPercent then
        local pct = v * (ns.db.targetFPS or 60) / 10   -- v / (1000/fps) * 100
        if pct < 10 then return format("%.1f%%", pct) end
        return format("%.0f%%", pct)
    end
    return ns.FmtMs(v)
end

-- Unit suffix to append after a CPU value in labels ("" in percent mode, since
-- FmtCPUDisplay already prints the % sign).
function ns.CPUUnit()
    return (ns.db and ns.db.cpuPercent) and "" or " ms/f"
end

-- Legacy formatter (ms/s) for the no-native-profiler fallback path.
function ns.FmtCPU(v)
    v = v or 0
    if v < 0 then v = 0 end
    if v >= 100 then return format("%.0f", v) end
    return format("%.1f", v)
end

function ns.FmtRate(kbps)
    kbps = kbps or 0
    local s = kbps >= 0 and "+" or "-"
    local a = kbps < 0 and -kbps or kbps
    if a >= 1024 then return format("%s%.1f MB/s", s, a / 1024) end
    return format("%s%.0f KB/s", s, a)
end

function ns.FmtBytes(b)
    b = b or 0
    if b >= 1048576 then return format("%.1f MB", b / 1048576) end
    if b >= 1024    then return format("%.1f KB", b / 1024) end
    return format("%d B", b)
end

-- Green -> yellow -> orange -> red severity ramps. CPU thresholds are in
-- ms per frame (native profiler): >1 ms/frame is notable, >5 ms/frame is heavy.
function ns.CPUColor(v)
    v = v or 0
    if v < 0.2   then return 0.55, 0.90, 0.55 end
    if v < 1     then return 0.95, 0.90, 0.40 end
    if v < 5     then return 1.00, 0.65, 0.25 end
    return 1.00, 0.35, 0.35
end

function ns.MemColor(kb)
    kb = kb or 0
    if kb < 5120   then return 0.55, 0.90, 0.55 end   -- < 5 MB
    if kb < 20480  then return 0.95, 0.90, 0.40 end   -- < 20 MB
    if kb < 51200  then return 1.00, 0.65, 0.25 end   -- < 50 MB
    return 1.00, 0.35, 0.35
end

-- Memory delta vs a baseline (KB). Signed; growth is the leak signal.
function ns.FmtDelta(kb)
    kb = kb or 0
    local s = kb >= 0 and "+" or "-"
    local a = kb < 0 and -kb or kb
    if a < 1 then return "0" end
    if a >= 1024 then return format("%s%.1f MB", s, a / 1024) end
    return format("%s%.0f KB", s, a)
end

-- Grey near zero, green when memory shrank, warm ramp as it grows.
function ns.DeltaColor(kb)
    kb = kb or 0
    if kb < 0 then return 0.55, 0.90, 0.55 end        -- shrank
    if kb < 256   then return 0.6, 0.6, 0.6 end        -- < 0.25 MB: noise
    if kb < 5120  then return 0.95, 0.90, 0.40 end     -- < 5 MB
    if kb < 20480 then return 1.00, 0.65, 0.25 end     -- < 20 MB
    return 1.00, 0.35, 0.35
end

-- ---------------------------------------------------------------------------
-- Rolling history. Plain ordered array (oldest -> newest) so every consumer can
-- read it by index. Rather than shift the whole array on every push once full
-- (table.remove(t, 1) is O(n) and this runs for every addon's cpu/mem/spike
-- buffer each tick), we let it overshoot a little and drop the oldest batch in a
-- single pass — O(1) amortised. The surplus is just a marginally longer tail;
-- parallel buffers (cpu/mem/spike, fps) stay length-synced since they share the
-- cap and push cadence.
-- ---------------------------------------------------------------------------
local function Push(hist, value, maxLen)
    hist[#hist + 1] = value
    local n = #hist
    if n > maxLen * 1.125 then
        local drop = n - maxLen
        for i = 1, maxLen do hist[i] = hist[i + drop] end
        for i = maxLen + 1, n do hist[i] = nil end
    end
end

-- min, max, average over a history buffer.
function ns.HistStats(hist)
    local n = hist and #hist or 0
    if n == 0 then return 0, 0, 0 end
    local mn, mx, sum = hist[1], hist[1], 0
    for i = 1, n do
        local v = hist[i]
        if v < mn then mn = v end
        if v > mx then mx = v end
        sum = sum + v
    end
    return mn, mx, sum / n
end

-- A coarse leak heuristic: memory is "leaking" if the average of the most
-- recent third of history sits well above the oldest third (a sustained climb,
-- not the sawtooth of normal allocate-then-GC).
local function DetectLeak(hist)
    local n = hist and #hist or 0
    if n < 12 then return false end
    local third = floor(n / 3)
    local a, b = 0, 0
    for i = 1, third do a = a + hist[i] end
    for i = n - third + 1, n do b = b + hist[i] end
    a, b = a / third, b / third
    return b > a * 1.20 and (b - a) > 256   -- climbing >20% and >256 KB
end

-- Column key -> the entry field it reads. Shared by the table, sorting, and the
-- adaptive sampler (so we only read the profiler metrics that are on screen).
ns.METRIC_FIELD = {
    mem = "mem", churn = "memRate", dmem = "dMem",
    recent = "cpuRecent", peak = "cpuPeak", session = "cpuSession",
    encounter = "cpuEncounter", last = "cpuLast",
    over1 = "over1", over5 = "over5", over10 = "over10", over50 = "over50",
    over100 = "over100", over500 = "over500", over1000 = "over1000",
}

-- Value of any sortable metric on an addon entry, by column key.
function ns.MetricVal(e, key)
    local f = ns.METRIC_FIELD[key]
    return (f and e[f]) or 0
end

-- ---------------------------------------------------------------------------
-- (Re)build the addon list. Titles can carry colour codes / texture escapes;
-- we keep the raw title for the tooltip and lean on the folder name (which is
-- what the user means by "by name") as the table identifier.
-- ---------------------------------------------------------------------------
function ns.API.Rebuild()
    wipe(ns.addons)
    wipe(ns.byName)
    local n = GetNumAddOns and GetNumAddOns() or 0
    for i = 1, n do
        local name, title = GetAddOnInfo(i)
        if name then
            local e = {
                index   = i,
                name    = name,
                title   = (title and title ~= "") and title or name,
                loaded  = IsAddOnLoaded(i) and true or false,
                mem     = 0,
                memRate = 0,            -- KB/s (memory churn)
                primed  = false,        -- has a previous sample to diff against
                cpuRecent    = 0,       -- ms/frame, last 60 ticks  (native)
                cpuPeak      = 0,       -- ms/frame, session high
                cpuSession   = 0,       -- ms/frame, session average
                cpuEncounter = 0,       -- ms/frame, current encounter average
                cpuLast      = 0,       -- ms, most recent tick
                over1 = 0, over5 = 0,   -- ticks over N ms this session (cumulative)
                over10 = 0, over50 = 0, over100 = 0, over500 = 0, over1000 = 0,
                leaking      = false,
                memHist  = {},
                cpuHist  = {},
                spikeHist = {},        -- new >50 ms frames per sample (graph annotation)
            }
            ns.addons[#ns.addons + 1] = e
            ns.byName[name] = e
        end
    end
end

-- ---------------------------------------------------------------------------
-- Is script profiling on? CPU metering returns 0 for everything unless the
-- scriptProfile CVar is set, and that CVar only takes effect after a reload.
-- ---------------------------------------------------------------------------
-- `scriptProfile` gates the *legacy* per-event profiler (the Events tab). The
-- native per-addon CPU (C_AddOnProfiler) needs no CVar and is always on.
-- `scriptProfile` only matters for the legacy fallback meter used when the
-- native C_AddOnProfiler is unavailable (pre-12.0.7 clients).
function ns.API.RefreshProfiling()
    ns.profiling = (CVarGet and CVarGet("scriptProfile") == "1") or false
    return ns.profiling
end

-- Writes the CVar; the caller is responsible for prompting the reload that
-- actually flips metering on or off.
function ns.API.SetProfilingCVar(on)
    if CVarSet then CVarSet("scriptProfile", on and "1" or "0") end
end

-- Clears our live sparkline/graph history (CPU + memory) and the legacy
-- script-profile counters. The native C_AddOnProfiler peak/session/encounter
-- figures belong to Blizzard and repopulate on the next tick — only a /reload
-- zeroes those, so the columns repopulate immediately after this.
function ns.API.ResetCPU()
    if ResetCPU then ResetCPU() end
    for i = 1, #ns.addons do
        local e = ns.addons[i]
        e.cpuRecent, e.cpuPeak, e.cpuSession, e.cpuEncounter, e.cpuLast = 0, 0, 0, 0, 0
        e._cpuPrev, e.primed = nil, false
        wipe(e.cpuHist)
        wipe(e.memHist)
        wipe(e.spikeHist)
        e._prevOver50 = nil
    end
    wipe(ns.fpsHist)
    ns.sampleCount = 0
end

-- ---------------------------------------------------------------------------
-- Take one sample. dt is the real elapsed time since the previous sample, used
-- to turn the cumulative CPU counter and the memory delta into per-second
-- rates. Totals are cached on ns for the footer.
-- ---------------------------------------------------------------------------
function ns.API.Sample(dt)
    local db = ns.db
    if not db then return end
    if not dt or dt <= 0 then dt = db.interval end

    -- Anchor + prune the live event markers to the visible history window.
    ns.lastSampleTime = (GetTime and GetTime()) or ns.lastSampleTime
    local mcut = ns.lastSampleTime - (db.history * db.interval)
    while ns.markers[1] and ns.markers[1].t < mcut do table.remove(ns.markers, 1) end

    ns.sampleCount = (ns.sampleCount or 0) + 1

    local Prof = ns.Prof
    local hasAP = Prof and Prof.hasAddOnProfiler
    local legacy = (not hasAP) and ns.profiling   -- cumulative-meter fallback
    if legacy and UpdateCPU then UpdateCPU() end

    -- When the window is hidden or minimised we're only recording (history +
    -- fight/run), which needs nothing but `recent` CPU. Skip the other per-addon
    -- profiler reads and the leak scan — they're only for the on-screen table.
    local full = (not db.collapsed) and ns.UI and ns.UI.IsShown and ns.UI.IsShown() and true or false

    -- Per-addon memory needs UpdateAddOnMemoryUsage(), which walks every addon
    -- and is expensive. Do it on a slow cadence (~db.memSeconds) and only while
    -- the full table is on screen — so no walk (and no self-spike) while closed
    -- or minimised. The title-bar Memory readout uses cheap total UI memory
    -- (collectgarbage) instead, so it never needs this walk.
    -- The memory scan (UpdateAddOnMemoryUsage) is the expensive bit. Skip it
    -- entirely when memProfiler is off (CPU-only mode = no memory spikes).
    -- The walk is a single blocking call: WoW's Lua is single-threaded, so it
    -- can't be backgrounded, split across frames, or run as a coroutine without
    -- still spiking the frame it lands on. Instead we keep it OUT of combat by
    -- default, where a one-off hitch is invisible; the per-addon numbers just
    -- hold until the fight ends. A walk requested mid-combat (e.g. a baseline,
    -- or opening the window) is deferred — ns._forceMem stays set — until then.
    local memEvery = max(1, floor((db.memSeconds or 10) / (dt > 0 and dt or 2)))
    local skipCombat = InCombatLockdown and InCombatLockdown() and not db.memInCombat
    local doMem = db.memProfiler and (ns._forceMem or (full and (ns.sampleCount % memEvery == 0)))
                  and not skipCombat
    if doMem then
        ns._forceMem = false
        if UpdateMem then UpdateMem() end
    end

    local wasFull = ns._wasFull   -- was the previous sample full (window on screen)?
    ns._wasFull = full

    -- Adaptive CPU reads: when the table is up, read `recent` (history/total),
    -- `over10` (the spike flag) and `over50` (the graph spike track) always, plus
    -- exactly the profiler metrics the chosen columns ask for.
    local reads
    if full and hasAP then
        reads = {}
        local seen = { recent = true, over10 = true, over50 = true }
        local cols = db.addonCols
        for c = 1, #cols do
            local k = cols[c]
            if Prof.METRIC[k] and not seen[k] then seen[k] = true; reads[#reads + 1] = k end
        end
    end
    local FIELD = ns.METRIC_FIELD

    local histLen = db.history
    local totalMem, totalCPU = 0, 0

    for i = 1, #ns.addons do
        local e = ns.addons[i]
        -- `loaded` is refreshed on ADDON_LOADED (addons only ever load, never
        -- unload mid-session), so there's no need to poll IsAddOnLoaded per tick.

        -- Memory (KB). memRate is the churn / leak signal: KB per *real* second
        -- since the previous walk (combat deferral makes the gap uneven, so a
        -- fixed cadence divisor would be wrong).
        local mem
        if doMem then
            mem = (GetMem and GetMem(e.index)) or 0
            local now = (GetTime and GetTime()) or 0
            local span = e._memT and (now - e._memT) or 0
            e.memRate = (e.primed and span > 0) and ((mem - e.mem) / span) or 0
            e.mem = mem
            e._memT = now
            e.primed = true
        else
            mem = e.mem or 0
        end

        -- Memory delta vs the captured baseline (nil when there's no baseline for
        -- this addon, so the ΔMem column can show "-" rather than a fake 0).
        local base = ns.cdb and ns.cdb.baseline and ns.cdb.baseline.mem
        local bm = base and base[e.name]
        e.dMem = bm and (mem - bm) or nil

        -- CPU (native reads need no Update; cheap). Only `recent` every tick;
        -- the rest are read for the on-screen table, and the tooltip/graph pull
        -- last / over50 / over100 live for the single addon they show.
        if hasAP then
            e.cpuRecent = Prof.AddOn(e.name, "recent")
            if full then
                e.over10 = Prof.AddOn(e.name, "over10")     -- spike flag
                e.over50 = Prof.AddOn(e.name, "over50")     -- graph spike track
                for j = 1, #reads do
                    e[FIELD[reads[j]]] = Prof.AddOn(e.name, reads[j])
                end
            end
        elseif legacy then
            local cpu = (GetCPU and GetCPU(e.index)) or 0
            local rate = e._cpuPrev and ((cpu - e._cpuPrev) / dt) or 0
            if rate < 0 then rate = 0 end          -- counter reset mid-window
            e._cpuPrev  = cpu
            e.cpuRecent = rate                     -- ms/s in this mode
            if rate > (e.cpuPeak or 0) then e.cpuPeak = rate end
        else
            e.cpuRecent = 0
        end

        Push(e.memHist, mem, histLen)
        Push(e.cpuHist, e.cpuRecent, histLen)
        -- New >50 ms frames since the last full sample (0 when not on screen).
        -- On the first full sample after the window was closed, just re-baseline:
        -- over50 is cumulative since login, so the backlog accumulated while closed
        -- would otherwise render as one huge false spike on the live graph.
        local sd = 0
        if full and hasAP then
            if wasFull then
                sd = (e.over50 or 0) - (e._prevOver50 or e.over50 or 0)
                if sd < 0 then sd = 0 end
            end
            e._prevOver50 = e.over50
        end
        Push(e.spikeHist, sd, histLen)
        if doMem and full then e.leaking = DetectLeak(e.memHist) end

        totalMem = totalMem + mem
        totalCPU = totalCPU + (e.cpuRecent or 0)
    end

    ns.totalMem = totalMem
    ns.totalCPU = hasAP and Prof.Overall("recent") or totalCPU
    Push(ns.fpsHist, (GetFramerate and GetFramerate()) or 0, histLen)
end

-- ---------------------------------------------------------------------------
-- Session capture (fights + dungeon/raid runs).
--
-- A "fight" is one combat segment (PLAYER_REGEN_DISABLED -> _ENABLED), named
-- after the boss if an ENCOUNTER_START fired during it. A "run" is one stay
-- inside a dungeon/raid (instance enter -> leave). Both accumulate per-addon
-- CPU/memory series the same way; on finish we trim to the addons that did
-- something, downsample, and push a snapshot into AddonPulseDB.sessions so it
-- survives reloads (common after M+ / raids).
-- ---------------------------------------------------------------------------
ns.fight = nil   -- active combat buffer
ns.run   = nil   -- active instance buffer

ns.markers = {}          -- rolling event markers for the live graph
ns.lastSampleTime = 0     -- GetTime() of the most recent sample (anchors markers)
ns.fpsHist = {}          -- live rolling FPS history (overlaid on the Addons graph)

local FIGHT_CAP    = 160    -- working-buffer cap (halve, averaging pairs, beyond this)
local STORE_FIGHT  = 100    -- stored series cap for fights
local STORE_RUN    = 160    -- stored series cap for runs
-- An addon is kept in a saved session (a row WITH its CPU/memory timeline) if it
-- was notable on either axis. Inclusion == has-timeline, so every session row
-- gets a sparkline/graph; the thresholds + MAX_ROWS keep the list focused and
-- the saved-variables size bounded.
local INCLUDE_CPU  = 0.03   -- cpu peak >= this (ms/frame)
local INCLUDE_MEM  = 3072   -- ...or memory peak >= this (KB, = 3 MB)
local MAX_ROWS     = 40     -- cap on addons kept per session (top by impact)

local function DownsampleHalf(t)   -- average pairs (for cpu/mem series)
    local n = #t
    local m = floor(n / 2)
    for i = 1, m do t[i] = (t[2 * i - 1] + t[2 * i]) / 2 end
    for i = m + 1, n do t[i] = nil end
end

local function DownsampleSum(t)    -- sum pairs (for spike counts — preserve totals)
    local n = #t
    local m = floor(n / 2)
    for i = 1, m do t[i] = (t[2 * i - 1] or 0) + (t[2 * i] or 0) end
    for i = m + 1, n do t[i] = nil end
end

-- Append the latest sample into a capture buffer, plus the per-tick >50ms spike
-- delta (read here so it's captured even while the window is closed; cheap).
local function RecordInto(buf)
    if not buf then return end
    buf.samples = buf.samples + 1
    -- Session-level FPS timeline (one point per tick, alongside the per-addon
    -- series), so you can line an addon's CPU spike up against the frame-rate dip.
    buf.fps = buf.fps or {}
    buf.fps[#buf.fps + 1] = (GetFramerate and GetFramerate()) or 0
    if #buf.fps > FIGHT_CAP then DownsampleHalf(buf.fps) end
    local hasAP = ns.Prof and ns.Prof.hasAddOnProfiler
    buf.prevOver = buf.prevOver or {}
    for i = 1, #ns.addons do
        local e = ns.addons[i]
        if e.loaded then
            local a = buf.addons[e.name]
            if not a then a = { cpu = {}, mem = {}, spike = {} }; buf.addons[e.name] = a end
            a.cpu[#a.cpu + 1] = e.cpuRecent or 0
            a.mem[#a.mem + 1] = e.mem or 0
            local sd = 0
            if hasAP and ns.db.sessionSpikes then
                local cur = ns.Prof.AddOn(e.name, "over50")
                local prev = buf.prevOver[e.name]
                sd = prev and (cur - prev) or 0
                if sd < 0 then sd = 0 end
                buf.prevOver[e.name] = cur
            end
            a.spike[#a.spike + 1] = sd
            if #a.cpu > FIGHT_CAP then
                DownsampleHalf(a.cpu)
                DownsampleHalf(a.mem)
                DownsampleSum(a.spike)
            end
        end
    end
end

-- Turn a finished buffer into a stored, reload-safe snapshot. Returns nil for
-- trivial segments. Entries are shaped so the table / tooltip / graph render
-- them unchanged; only CPU consumers keep their timeline (to bound saved size).
local function Finalize(buf, kind)
    if not buf then return nil end
    local dur = ((GetTime and GetTime()) or 0) - (buf.start or 0)
    if dur < (ns.db.fightMinDur or 5) or (buf.samples or 0) < 2 then return nil end
    local cap = (kind == "run") and STORE_RUN or STORE_FIGHT

    -- Collect the notable addons, then keep the top MAX_ROWS by impact so a huge
    -- UI can't blow up the saved file. cpu peak ranks first; memory breaks ties
    -- (and orders the pure-memory ones).
    local cands = {}
    for name, a in pairs(buf.addons) do
        local _, cpuPeak, cpuAvg = ns.HistStats(a.cpu)
        local _, memPeak, memAvg = ns.HistStats(a.mem)
        if cpuPeak >= INCLUDE_CPU or memPeak >= INCLUDE_MEM then
            cands[#cands + 1] = { a = a, name = name,
                cpuPeak = cpuPeak, cpuAvg = cpuAvg, memPeak = memPeak, memAvg = memAvg }
        end
    end
    sort(cands, function(x, y)
        if x.cpuPeak ~= y.cpuPeak then return x.cpuPeak > y.cpuPeak end
        return x.memPeak > y.memPeak
    end)

    local hasAP = ns.Prof and ns.Prof.hasAddOnProfiler
    local list = {}
    for i = 1, (#cands < MAX_ROWS and #cands or MAX_ROWS) do
        local c = cands[i]
        local cpu, mem, spike = c.a.cpu, c.a.mem, c.a.spike or {}
        while #cpu > cap do DownsampleHalf(cpu); DownsampleHalf(mem); DownsampleSum(spike) end

        -- Sparse spike-timing for the session graph: only the (downsampled)
        -- intervals that had a >50ms frame. nil when there were none.
        local spikes
        for k = 1, #spike do
            if (spike[k] or 0) > 0 then spikes = spikes or {}; spikes[k] = spike[k] end
        end

        -- Per-fight spike counts: how many frames this addon went over each
        -- threshold during the session (current cumulative minus the baseline).
        local s10, s50, s100 = 0, 0, 0
        local base = buf.baseOver and buf.baseOver[c.name]
        if base and hasAP then
            s10  = max(0, ns.Prof.AddOn(c.name, "over10")  - (base[1] or 0))
            s50  = max(0, ns.Prof.AddOn(c.name, "over50")  - (base[2] or 0))
            s100 = max(0, ns.Prof.AddOn(c.name, "over100") - (base[3] or 0))
        end

        list[#list + 1] = {
            name = c.name, title = c.name, loaded = true,
            isSession = true, kind = kind, sessionDur = dur,
            cpuHist = cpu, memHist = mem, spikes = spikes,
            cpuPeak = c.cpuPeak, cpuSession = c.cpuAvg,
            cpuRecent = cpu[#cpu] or c.cpuPeak, cpuLast = 0, cpuEncounter = 0,
            mem = c.memPeak, memPeak = c.memPeak, memAvg = c.memAvg,
            spike10 = s10, spike50 = s50, spike100 = s100,   -- spikes during the fight
            over10 = 0, over50 = 0, over100 = 0, leaking = false,
        }
    end
    if #list == 0 then return nil end

    -- Session-level FPS timeline + its min / average.
    local fps = buf.fps or {}
    while #fps > cap do DownsampleHalf(fps) end
    local fmin, fsum = nil, 0
    for i = 1, #fps do
        local v = fps[i]; fsum = fsum + v
        if not fmin or v < fmin then fmin = v end
    end

    -- Addon comms that flowed during the session (total + top prefixes).
    local cd = (buf.commsBase and ns.Comms and ns.Comms.Delta) and ns.Comms.Delta(buf.commsBase) or nil

    return {
        kind = kind,
        name = buf.name or (kind == "run" and "Instance" or "Combat"),
        duration = dur,
        ended = (GetServerTime and GetServerTime()) or 0,
        list = list,
        markers = buf.markers,   -- event times relative to start; clamped at draw
        result = buf.result,        -- "kill" | "wipe" | nil
        difficulty = buf.difficulty, -- short tag: N / H / M / LFR, or "+18" for M+
        groupSize = buf.groupSize,
        keyLevel = buf.keyLevel, affixes = buf.affixes,
        fps = (#fps >= 2) and fps or nil,
        fpsMin = fmin or 0,
        fpsAvg = (#fps > 0) and (fsum / #fps) or 0,
        commsIn = cd and cd.commsIn or 0,
        commsOut = cd and cd.commsOut or 0,
        commsTop = cd and cd.top or nil,   -- sorted [{ prefix, bytes }]
    }
end

-- Short difficulty tag from an ENCOUNTER difficultyID (raid/dungeon).
local function DifficultyTag(difficultyID)
    if not difficultyID or difficultyID == 0 then return nil end
    local name = GetDifficultyInfo and GetDifficultyInfo(difficultyID)
    if not name then return nil end
    if name:find("Looking") then return "LFR" end
    return name:sub(1, 1):upper()   -- Mythic→M, Heroic→H, Normal→N
end
ns.DifficultyTag = DifficultyTag

-- Record a timeline event: into the live rolling list and into any active
-- fight/run (relative to its start). Called from event handlers, never per frame.
function ns.API.AddMarker(kind, label)
    local now = (GetTime and GetTime()) or 0
    ns.markers[#ns.markers + 1] = { t = now, kind = kind, label = label }
    if #ns.markers > 60 then table.remove(ns.markers, 1) end
    if ns.fight then
        ns.fight.markers = ns.fight.markers or {}
        ns.fight.markers[#ns.fight.markers + 1] = { t = now - (ns.fight.start or 0), kind = kind, label = label }
    end
    if ns.run then
        ns.run.markers = ns.run.markers or {}
        ns.run.markers[#ns.run.markers + 1] = { t = now - (ns.run.start or 0), kind = kind, label = label }
    end
end

-- Auto-rotate saved sessions: drop any older than db.sessionMaxDays (0 = keep).
-- Bounds total saved size regardless of how many fights/runs you do.
function ns.API.PruneSessions()
    if not (ns.cdb and ns.cdb.sessions) then return end
    local days = ns.db.sessionMaxDays or 14
    local now = (GetServerTime and GetServerTime()) or 0
    if days <= 0 or now == 0 then return end
    local cutoff = now - days * 86400
    for _, which in ipairs({ "fights", "runs" }) do
        local t = ns.cdb.sessions[which]
        for i = #t, 1, -1 do
            local en = t[i].ended
            if en and en > 0 and en < cutoff then table.remove(t, i) end
        end
    end
end

local function PushSession(which, s, maxN)
    local t = ns.cdb.sessions[which]
    table.insert(t, 1, s)
    while #t > maxN do t[#t] = nil end   -- count cap
    ns.API.PruneSessions()               -- age cap
    if ns.UI and ns.UI.OnSessionStored then ns.UI.OnSessionStored() end
end

-- Snapshot each loaded addon's cumulative over-threshold counts at the start of
-- a capture, so the per-fight delta can be computed at the end. Cheap (a handful
-- of profiler reads per addon, once) — not the memory walk.
local function SnapshotBaseline(buf)
    -- Comms baseline (independent of the CPU profiler) so we can report the
    -- addon traffic that flowed during this session.
    buf.commsBase = ns.Comms and ns.Comms.Snapshot and ns.Comms.Snapshot() or nil
    if not (ns.Prof and ns.Prof.hasAddOnProfiler) then return end
    local base = {}
    for i = 1, #ns.addons do
        local e = ns.addons[i]
        if e.loaded then
            base[e.name] = {
                ns.Prof.AddOn(e.name, "over10"),
                ns.Prof.AddOn(e.name, "over50"),
                ns.Prof.AddOn(e.name, "over100"),
            }
        end
    end
    buf.baseOver = base
end

function ns.API.BeginFight()
    if ns.fight or not (ns.db and ns.db.enabled) then return end
    ns.fight = { name = nil, start = (GetTime and GetTime()) or 0, samples = 0, addons = {} }
    SnapshotBaseline(ns.fight)
end

function ns.API.NameFight(name)
    if ns.fight then ns.fight.name = name end
end

function ns.API.EndFight()
    local s = Finalize(ns.fight, "fight")
    ns.fight = nil
    if s then PushSession("fights", s, ns.db.maxFights or 8) end
end

function ns.API.BeginRun(name)
    if ns.run or not (ns.db and ns.db.enabled) then return end
    ns.run = { name = name, start = (GetTime and GetTime()) or 0, samples = 0, addons = {} }
    SnapshotBaseline(ns.run)
end

function ns.API.EndRun()
    local s = Finalize(ns.run, "run")
    ns.run = nil
    if s then PushSession("runs", s, ns.db.maxRuns or 4) end
end

-- Persist an in-progress run so it survives a reload. Called once, at logout —
-- NOT per frame. We store elapsed time (GetTime resets across reload) and the
-- raw buffers; on the next instance-enter the run resumes from here.
function ns.API.SaveActiveRun()
    if not ns.cdb then return end
    if ns.run then
        ns.cdb.activeRun = {
            name    = ns.run.name,
            elapsed = ((GetTime and GetTime()) or 0) - (ns.run.start or 0),
            samples = ns.run.samples or 0,
            addons  = ns.run.addons,
        }
    else
        ns.cdb.activeRun = nil
    end
end

-- Remove a stored session (by reference) from whichever list holds it.
function ns.API.RemoveSession(s)
    if not (ns.cdb and ns.cdb.sessions) then return end
    for _, which in ipairs({ "fights", "runs" }) do
        local t = ns.cdb.sessions[which]
        for i = #t, 1, -1 do
            if t[i] == s then table.remove(t, i) end
        end
    end
    if ns.UI and ns.UI.OnSessionStored then ns.UI.OnSessionStored() end
end

-- ---------------------------------------------------------------------------
-- The sampling tick. Driven by an always-present timer (created at login), so
-- it is independent of whether the window is open or minimised.
--   * Enabled  -> full per-addon sampling + recording (in the background too),
--                 repainting the table only when the window is showing.
--   * Paused   -> no per-addon work; just keep the lightweight title-bar stats
--                 alive while the bar is visible.
-- The Active/Paused toggle is the on/off for all background work.
-- ---------------------------------------------------------------------------
function ns.API.Tick(dt)
    if not ns.db then return end
    local shown = ns.UI and ns.UI.IsShown and ns.UI.IsShown()
    -- Comms traffic flows through always-on hooks, so roll up its rate / history
    -- every tick regardless of pause state (cheap; just a loop over prefixes).
    if ns.Comms and ns.Comms.Sample then ns.Comms.Sample(dt) end
    if ns.db.enabled then
        ns.API.Sample(dt)
        if ns.fight then RecordInto(ns.fight) end
        if ns.run   then RecordInto(ns.run)   end
        if shown and ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
    elseif shown then
        if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
    end
end

-- ---------------------------------------------------------------------------
-- Build the filtered, sorted view the UI renders. Returns a shared scratch
-- table (do not hold a reference past the next call).
-- ---------------------------------------------------------------------------
local function PassesFilter(e, db, q)
    if db.ignored and db.ignored[e.name] and not db.showIgnored then return false end
    if db.loadedOnly and not e.loaded then return false end
    if db.hideInactive
        and (e.mem or 0) < ns.INACTIVE_KB
        and (e.cpuRecent or 0) < ns.INACTIVE_CPU
        and e.name ~= db.selected then
        return false
    end
    if q ~= "" then
        local n = e.name:lower()
        local t = e.title:lower()
        if not (n:find(q, 1, true) or t:find(q, 1, true)) then return false end
    end
    return true
end

local function Comparator(a, b)
    local db = ns.db
    -- Pinned addons always sort above unpinned, regardless of sort direction.
    if db.pinned then
        local ap, bp = db.pinned[a.name], db.pinned[b.name]
        if (ap and true or false) ~= (bp and true or false) then return ap and true or false end
    end
    local key, asc = db.sortKey, (db.sortDir == "asc")
    local av, bv
    if key == "name" then
        av, bv = a.name:lower(), b.name:lower()
    else
        av, bv = ns.MetricVal(a, key), ns.MetricVal(b, key)
    end
    if av == bv then
        return a.name:lower() < b.name:lower()   -- stable tiebreak by name
    end
    if asc then return av < bv end
    return av > bv
end

function ns.API.GetView(filterText)
    local db = ns.db
    local out = ns.view
    wipe(out)
    local q = (filterText or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    for i = 1, #ns.addons do
        local e = ns.addons[i]
        if PassesFilter(e, db, q) then
            out[#out + 1] = e
        end
    end
    sort(out, Comparator)
    return out
end

function ns.API.SetSort(key)
    local db = ns.db
    if db.sortKey == key then
        db.sortDir = (db.sortDir == "asc") and "desc" or "asc"
    else
        db.sortKey = key
        db.sortDir = (key == "name") and "asc" or "desc"
    end
end

-- ---------------------------------------------------------------------------
-- SavedVariables bootstrap.
-- ---------------------------------------------------------------------------
local function ApplyDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            ApplyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

local function InitDB()
    AddonPulseDB = AddonPulseDB or {}
    ApplyDefaults(AddonPulseDB, DEFAULTS)
    -- Seed the selected columns only when absent (don't merge — see DEFAULTS).
    if type(AddonPulseDB.addonCols) ~= "table" or #AddonPulseDB.addonCols == 0 then
        AddonPulseDB.addonCols = { "mem", "recent", "peak", "session", "encounter" }
    end
    ns.db = AddonPulseDB

    -- Per-character store: sessions, baseline, and the in-progress run. One-time
    -- migration moves anything left in the old account-wide slots into THIS
    -- character's store (so the character you're on keeps its recent captures).
    AddonPulseCharDB = AddonPulseCharDB or {}
    local cdb = AddonPulseCharDB
    if AddonPulseDB.sessions and not cdb.sessions then
        cdb.sessions = AddonPulseDB.sessions
    end
    if AddonPulseDB.baseline ~= nil and cdb.baseline == nil then
        cdb.baseline = AddonPulseDB.baseline
    end
    if AddonPulseDB.activeRun ~= nil and cdb.activeRun == nil then
        cdb.activeRun = AddonPulseDB.activeRun
    end
    AddonPulseDB.sessions, AddonPulseDB.baseline, AddonPulseDB.activeRun = nil, nil, nil
    cdb.sessions = cdb.sessions or { fights = {}, runs = {} }
    cdb.sessions.fights = cdb.sessions.fights or {}
    cdb.sessions.runs = cdb.sessions.runs or {}
    ns.cdb = cdb
end

ns.inEncounter = false
ns.encounterName = nil

-- The always-on sampling driver. A C_Timer ticker (NOT an OnUpdate) so there is
-- zero per-frame work — it only wakes once per interval. ns.API.Tick then does
-- the full sample when enabled, or just the cheap bar refresh when paused.
local function StartDriver()
    if ns.driver then return end
    local iv = (ns.db and ns.db.interval) or 2
    if C_Timer and C_Timer.NewTicker then
        ns.driver = C_Timer.NewTicker(iv, function() ns.API.Tick(iv) end)
    else
        -- Fallback for clients without C_Timer (shouldn't happen on 12.x).
        local d = CreateFrame("Frame")
        d.accum = 0
        d:SetScript("OnUpdate", function(self, elapsed)
            self.accum = self.accum + elapsed
            if self.accum >= iv then ns.API.Tick(self.accum); self.accum = 0 end
        end)
        ns.driver = d
    end
end

-- Recreate the sample driver with the current db.interval (the ticker's period
-- is fixed at creation). Called when the interval is changed in the options.
function ns.API.RestartDriver()
    if ns.driver then
        if ns.driver.Cancel then ns.driver:Cancel()
        elseif ns.driver.SetScript then ns.driver:SetScript("OnUpdate", nil) end
        ns.driver = nil
    end
    StartDriver()
end

-- Memory baseline: snapshot every loaded addon's current memory so the ΔMem
-- column can show growth since this moment. Forces one memory walk (the only
-- way to get fresh per-addon numbers), so it costs a single scan on click.
function ns.API.SetBaseline()
    if UpdateMem then UpdateMem() end
    local b = { t = (GetServerTime and GetServerTime()) or 0, mem = {} }
    for i = 1, #ns.addons do
        local e = ns.addons[i]
        if e.loaded then
            local m = (GetMem and GetMem(e.index)) or e.mem or 0
            b.mem[e.name] = m
            e.mem = m            -- keep the cached value consistent with the snapshot
            e.dMem = 0           -- delta is zero at the instant of capture
        end
    end
    ns.cdb.baseline = b
    return b
end

function ns.API.ClearBaseline()
    ns.cdb.baseline = nil
    for i = 1, #ns.addons do ns.addons[i].dMem = nil end
end

-- Trim saved sessions down to the current count caps (after lowering them).
function ns.API.TrimSessions()
    if not (ns.cdb and ns.cdb.sessions) then return end
    local f = ns.cdb.sessions.fights
    while #f > (ns.db.maxFights or 8) do f[#f] = nil end
    local r = ns.cdb.sessions.runs
    while #r > (ns.db.maxRuns or 4) do r[#r] = nil end
end

-- Master enable/disable. Disabled = no per-addon sampling, no auto-recording,
-- and the table shows no detail — but the cheap title-bar stats keep updating,
-- so it works as a lightweight FPS/CPU/Mem bar. The driver keeps running (its
-- tick does almost nothing while paused + the bar is hidden).
function ns.API.SetEnabled(on)
    if not ns.db then return end
    ns.db.enabled = on and true or false
    if not ns.db.enabled then
        ns.fight, ns.run = nil, nil   -- drop any in-progress capture
    end
    if ns.UI and ns.UI.OnEnabledChanged then ns.UI.OnEnabledChanged() end

    -- Announce clearly (chat + a brief on-screen note), since this can be
    -- toggled from the button, the minimap, or a slash command.
    if ns.db.enabled then
        print("|cff52c7e0AddonPulse|r: |cff55ee55enabled|r.")
        if UIErrorsFrame and UIErrorsFrame.AddMessage then
            UIErrorsFrame:AddMessage("AddonPulse enabled", 0.4, 0.9, 0.4, 1, 3)
        end
    else
        print("|cff52c7e0AddonPulse|r: |cffff5555paused|r — no sampling or recording until re-enabled.")
        if UIErrorsFrame and UIErrorsFrame.AddMessage then
            UIErrorsFrame:AddMessage("AddonPulse paused", 1.0, 0.6, 0.2, 1, 3)
        end
    end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("ENCOUNTER_START")
boot:RegisterEvent("ENCOUNTER_END")
boot:RegisterEvent("PLAYER_REGEN_DISABLED")
boot:RegisterEvent("PLAYER_REGEN_ENABLED")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:RegisterEvent("PLAYER_LOGOUT")
boot:RegisterEvent("PLAYER_DEAD")
boot:RegisterEvent("CHALLENGE_MODE_START")
boot:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4, arg5)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then InitDB() end
        -- Keep the per-addon loaded flag current without polling every tick: an
        -- addon only ever transitions unloaded -> loaded during a session.
        local e = ns.byName and ns.byName[arg1]
        if e then e.loaded = true end
    elseif event == "PLAYER_LOGIN" then
        InitDB()
        ns.API.PruneSessions()                 -- drop sessions past sessionMaxDays
        ns.API.RefreshProfiling()
        ns.API.Rebuild()
        if ns.Comms and ns.Comms.SeedRegistered then ns.Comms.SeedRegistered() end
        if ns.UI and ns.UI.Init then ns.UI.Init() end
        if ns.Options and ns.Options.RegisterBlizzard then ns.Options.RegisterBlizzard() end
        StartDriver()
    elseif event == "PLAYER_REGEN_DISABLED" then
        ns.API.BeginFight()                 -- entered combat
        ns.API.AddMarker("combat", "Combat")
    elseif event == "PLAYER_REGEN_ENABLED" then
        ns.API.AddMarker("combatend", "Combat end")
        ns.API.EndFight()                   -- left combat -> freeze the fight
    elseif event == "ENCOUNTER_START" then
        ns.inEncounter = true
        ns.encounterName = arg2
        ns.API.BeginFight()                 -- in case the combat-log event lagged
        ns.API.NameFight(arg2)
        if ns.fight then
            ns.fight.difficulty = DifficultyTag(arg3)   -- arg3 = difficultyID
            ns.fight.groupSize  = arg4                  -- arg4 = groupSize
        end
        ns.API.AddMarker("pull", arg2 or "Pull")
    elseif event == "ENCOUNTER_END" then
        ns.inEncounter = false
        if ns.fight then                                -- arg5 = success (1 = kill)
            ns.fight.result     = (arg5 == 1 or arg5 == true) and "kill" or "wipe"
            ns.fight.difficulty = ns.fight.difficulty or DifficultyTag(arg3)
            ns.fight.groupSize  = ns.fight.groupSize or arg4
        end
    elseif event == "CHALLENGE_MODE_START" then
        -- A Mythic+ key just activated; tag the active run with its level / affixes.
        if ns.run and C_ChallengeMode then
            local level, affixes = C_ChallengeMode.GetActiveKeystoneInfo()
            if level and level > 0 then
                ns.run.keyLevel = level
                ns.run.difficulty = "+" .. level
            end
            local mapID = C_ChallengeMode.GetActiveChallengeMapID
                and C_ChallengeMode.GetActiveChallengeMapID()
            if mapID and C_ChallengeMode.GetMapUIInfo then
                local mapName = C_ChallengeMode.GetMapUIInfo(mapID)
                if mapName and mapName ~= "" then ns.run.name = mapName end
            end
            if affixes and C_ChallengeMode.GetAffixInfo then
                local names = {}
                for _, aid in ipairs(affixes) do
                    local an = C_ChallengeMode.GetAffixInfo(aid)
                    if an then names[#names + 1] = an end
                end
                if #names > 0 then ns.run.affixes = table.concat(names, ", ") end
            end
        end
    elseif event == "PLAYER_DEAD" then
        ns.API.AddMarker("death", "Death")
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Start a "run" on entering a dungeon/raid; finish it on leaving. If a
        -- run was saved across a reload and we're back in an instance, resume it.
        local inInstance, instanceType = IsInInstance()
        if inInstance and (instanceType == "party" or instanceType == "raid") then
            if not ns.run then
                local saved = ns.cdb and ns.cdb.activeRun
                if saved then
                    ns.run = {
                        name    = saved.name,
                        start   = ((GetTime and GetTime()) or 0) - (saved.elapsed or 0),
                        samples = saved.samples or 0,
                        addons  = saved.addons or {},
                    }
                    -- Re-baseline the spike counts: the reload zeroed the native
                    -- profiler counters, so capture a fresh baseline for the
                    -- resumed run (without it, per-fight spike counts stay 0).
                    SnapshotBaseline(ns.run)
                else
                    ns.API.BeginRun((GetInstanceInfo and GetInstanceInfo()) or "Instance")
                end
            end
            if ns.cdb then ns.cdb.activeRun = nil end
        else
            if ns.run then ns.API.EndRun() end
            if ns.cdb then ns.cdb.activeRun = nil end
        end
    elseif event == "PLAYER_LOGOUT" then
        ns.API.SaveActiveRun()      -- single write at reload/quit, not per frame
    end
end)

-- ---------------------------------------------------------------------------
-- Slash command. The window is the real interface; this just toggles it and
-- exposes the two reload-sensitive actions.
-- ---------------------------------------------------------------------------
local PREFIX = "|cff52c7e0AddonPulse|r: "

local function Status()
    local native = ns.Prof and ns.Prof.hasAddOnProfiler
    print(PREFIX
        .. (ns.db.enabled and "|cff55ee55enabled|r" or "|cffff5555paused (bar only)|r")
        .. "  •  CPU profiler: " .. (native and "native (always on)" or "legacy fallback"))
end

SLASH_ADDONPULSE1 = "/addonpulse"
SLASH_ADDONPULSE2 = "/pulse"
SLASH_ADDONPULSE3 = "/ap"
SlashCmdList.ADDONPULSE = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "on" or msg == "enable" then
        ns.API.SetEnabled(true)
    elseif msg == "off" or msg == "disable" then
        ns.API.SetEnabled(false)
    elseif msg == "toggle" then
        ns.API.SetEnabled(not ns.db.enabled)
    elseif msg == "cpu" or msg == "profile" then
        if ns.Prof and ns.Prof.hasAddOnProfiler then
            print(PREFIX .. "CPU profiling is native and always on — nothing to toggle. Use |cffffd100/pulse off|r to pause AddonPulse.")
        elseif ns.UI and ns.UI.PromptProfiling then
            ns.UI.PromptProfiling(not ns.profiling)
        end
    elseif msg == "reset" then
        ns.API.ResetCPU()
        print(PREFIX .. "Live graph history cleared. (Peak/Sess come from the game profiler — |cffffd100/reload|r to zero those.)")
    elseif msg == "status" then
        Status()
    elseif msg == "options" or msg == "config" or msg == "opts" then
        if ns.Options and ns.Options.Toggle then ns.Options.Toggle() end
    else
        if ns.UI and ns.UI.Toggle then ns.UI.Toggle() end
    end
end

-- Addon Compartment (the menu under the minimap): left-click toggles the
-- window, matching the rest of the suite.
function AddonPulse_OnAddonCompartmentClick()
    if ns.UI and ns.UI.Toggle then ns.UI.Toggle() end
end
