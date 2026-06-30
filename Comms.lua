--[[--------------------------------------------------------------------------
    AddonPulse — Comms.lua
    --------------------------------------------------------------------------
    Per-prefix addon-communication tracking. WoW exposes no per-addon network
    metering, but addon traffic flows through a small set of channels we can
    watch directly:

      * outgoing — post-hook C_ChatInfo.SendAddonMessage / *Logged,
      * incoming — the CHAT_MSG_ADDON event.

    Both carry an addon message *prefix*, which addons register for themselves
    and which almost always identifies the addon, so we attribute traffic by
    prefix. Bytes are counted as #prefix + #message (a close stand-in for what
    goes on the wire; each chunk is capped at 255 bytes by the client).

    This is independent of the CPU profiler — it needs no CVar and no reload.
----------------------------------------------------------------------------]]

local _, ns = ...

ns.Comms = ns.Comms or {}

local byPrefix = {}
ns.Comms.byPrefix = byPrefix
ns.Comms.view = {}
ns.Comms.totalIn = 0
ns.Comms.totalOut = 0

local sort, wipe = table.sort, wipe

-- Rolling history with amortised front-trim (see the same helper in
-- AddonPulse.lua): overshoot a little, then drop the oldest batch in one pass so
-- a busy prefix isn't shifting an O(n) array every tick.
local function Push(hist, v, maxLen)
    hist[#hist + 1] = v
    local n = #hist
    if n > maxLen * 1.125 then
        local drop = n - maxLen
        for i = 1, maxLen do hist[i] = hist[i + drop] end
        for i = maxLen + 1, n do hist[i] = nil end
    end
end

-- Normalise the addon-message distribution to a short, friendly label.
local CHAN = {
    PARTY = "Party", RAID = "Raid", INSTANCE_CHAT = "Instance", GUILD = "Guild",
    OFFICER = "Officer", WHISPER = "Whisper", CHANNEL = "Channel",
    BATTLEGROUND = "BG", SAY = "Say", YELL = "Yell",
}
local function NormChannel(c)
    if not c then return nil end
    return CHAN[c] or tostring(c)
end

local function Entry(prefix)
    prefix = prefix or "?"
    local e = byPrefix[prefix]
    if not e then
        e = {
            prefix = prefix, bytesIn = 0, bytesOut = 0, msgsIn = 0, msgsOut = 0,
            chan = {},          -- channel label -> bytes (in + out combined)
            isComms = true,     -- tells the graph to plot bytesHist on a byte axis
            bytesHist = {},     -- bytes per sample interval (sparkline / detail graph)
            rate = 0, peakRate = 0, msgRate = 0,
            _accBytes = 0, _accMsgs = 0,
        }
        byPrefix[prefix] = e
    end
    return e
end

-- Byte length of an addon-message payload. The API expects a string, but some
-- addons pass a number (e.g. ElvUI sends a version like 15.17), and `#` errors
-- on a number — so coerce anything non-string to its string form first.
local function Len(v)
    if type(v) == "string" then return #v end
    if v == nil then return 0 end
    return #tostring(v)
end

local function Bump(e, n, channel)
    e._accBytes = e._accBytes + n
    e._accMsgs = e._accMsgs + 1
    local c = NormChannel(channel)
    if c then e.chan[c] = (e.chan[c] or 0) + n end
end

local function CountOut(prefix, message, channel)
    local e = Entry(prefix)
    local n = Len(message) + Len(prefix)
    e.bytesOut = e.bytesOut + n
    e.msgsOut = e.msgsOut + 1
    Bump(e, n, channel)
    ns.Comms.totalOut = ns.Comms.totalOut + n
end

local function CountIn(prefix, message, channel)
    local e = Entry(prefix)
    local n = Len(message) + Len(prefix)
    e.bytesIn = e.bytesIn + n
    e.msgsIn = e.msgsIn + 1
    Bump(e, n, channel)
    ns.Comms.totalIn = ns.Comms.totalIn + n
end

-- Outgoing hooks. SendAddonMessage(prefix, message, channel, target).
if C_ChatInfo and C_ChatInfo.SendAddonMessage then
    hooksecurefunc(C_ChatInfo, "SendAddonMessage", function(prefix, message, channel)
        CountOut(prefix, message, channel)
    end)
end
if C_ChatInfo and C_ChatInfo.SendAddonMessageLogged then
    hooksecurefunc(C_ChatInfo, "SendAddonMessageLogged", function(prefix, message, channel)
        CountOut(prefix, message, channel)
    end)
end

-- Incoming: CHAT_MSG_ADDON(prefix, message, channel, sender).
local rx = CreateFrame("Frame")
rx:RegisterEvent("CHAT_MSG_ADDON")
rx:SetScript("OnEvent", function(_, _, prefix, message, channel)
    CountIn(prefix, message, channel)
end)

-- Per-interval roll-up: turn the bytes / messages accumulated since the last call
-- into a rate, track the peak burst, and push a point onto the traffic history
-- for the sparkline + detail graph. Runs every driver tick regardless of pause
-- state (the hooks fire either way, so the history has to keep moving).
function ns.Comms.Sample(dt)
    if not dt or dt <= 0 then dt = 1 end
    local histLen = (ns.db and ns.db.history) or 90
    for _, e in pairs(byPrefix) do
        local acc = e._accBytes or 0
        e.rate = acc / dt
        if e.rate > (e.peakRate or 0) then e.peakRate = e.rate end
        e.msgRate = (e._accMsgs or 0) / dt
        Push(e.bytesHist, e.rate, histLen)   -- bytes/sec, matches the Rate column
        e._accBytes = 0
        e._accMsgs = 0
    end
end

-- Seed the list with prefixes addons have registered, so they show up at 0
-- before any traffic flows.
function ns.Comms.SeedRegistered()
    if C_ChatInfo and C_ChatInfo.GetRegisteredAddonMessagePrefixes then
        local list = C_ChatInfo.GetRegisteredAddonMessagePrefixes()
        if type(list) == "table" then
            for i = 1, #list do Entry(list[i]) end
        end
    end
end

function ns.Comms.Reset()
    wipe(byPrefix)
    ns.Comms.totalIn = 0
    ns.Comms.totalOut = 0
    ns.Comms.SeedRegistered()
end

-- Snapshot the cumulative comms counters, for a session baseline.
function ns.Comms.Snapshot()
    local s = { tin = ns.Comms.totalIn, tout = ns.Comms.totalOut, prefixes = {} }
    for prefix, e in pairs(byPrefix) do
        s.prefixes[prefix] = { e.bytesIn, e.bytesOut }
    end
    return s
end

-- Comms that flowed since a snapshot: totals + the top prefixes by bytes.
function ns.Comms.Delta(snap)
    if not snap then return nil end
    local out = {
        commsIn  = (ns.Comms.totalIn  or 0) - (snap.tin  or 0),
        commsOut = (ns.Comms.totalOut or 0) - (snap.tout or 0),
        top = {},
    }
    local per = {}
    for prefix, e in pairs(byPrefix) do
        local b = snap.prefixes[prefix]
        local din  = (e.bytesIn  or 0) - (b and b[1] or 0)
        local dout = (e.bytesOut or 0) - (b and b[2] or 0)
        if din + dout > 0 then per[#per + 1] = { prefix = prefix, bytes = din + dout } end
    end
    sort(per, function(a, b) return a.bytes > b.bytes end)
    for i = 1, (#per < 6 and #per or 6) do out.top[i] = per[i] end
    return out
end

-- Filtered + sorted view for the Comms tab. sortKey: "name" | "in" | "out".
function ns.Comms.GetView(filterText, sortKey, asc)
    local out = ns.Comms.view
    wipe(out)
    local q = (filterText or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    for _, e in pairs(byPrefix) do
        if q == "" or e.prefix:lower():find(q, 1, true) then
            out[#out + 1] = e
        end
    end
    sort(out, function(a, b)
        local av, bv
        if sortKey == "name" then
            av, bv = a.prefix:lower(), b.prefix:lower()
        elseif sortKey == "in" then
            av, bv = a.bytesIn, b.bytesIn
        elseif sortKey == "out" then
            av, bv = a.bytesOut, b.bytesOut
        elseif sortKey == "rate" then
            av, bv = a.rate or 0, b.rate or 0
        elseif sortKey == "peak" then
            av, bv = a.peakRate or 0, b.peakRate or 0
        else
            av, bv = a.bytesIn + a.bytesOut, b.bytesIn + b.bytesOut
        end
        if av == bv then return a.prefix:lower() < b.prefix:lower() end
        if asc then return av < bv end
        return av > bv
    end)
    return out
end
