--[[--------------------------------------------------------------------------
    AddonPulse — Profiler.lua
    --------------------------------------------------------------------------
    Thin wrapper over Blizzard's native addon profiler, C_AddOnProfiler
    (11.0.7+). It is always on — no `scriptProfile` CVar, no reload. Timings are
    milliseconds *per tick (frame)*: recent / session / encounter averages, the
    session peak, the last tick, and counts of how many ticks an addon blew past
    1/5/10/50/100/500/1000 ms.

    Blizzard's own addons can't be queried, so their rows read 0.
----------------------------------------------------------------------------]]

local _, ns = ...

ns.Prof = ns.Prof or {}

local CAP = C_AddOnProfiler

local E = Enum and Enum.AddOnProfilerMetric
local METRIC = {
    session   = (E and E.SessionAverageTime)   or 0,
    recent    = (E and E.RecentAverageTime)    or 1,
    encounter = (E and E.EncounterAverageTime) or 2,
    last      = (E and E.LastTime)             or 3,
    peak      = (E and E.PeakTime)             or 4,
    over1     = (E and E.CountTimeOver1Ms)     or 5,
    over5     = (E and E.CountTimeOver5Ms)     or 6,
    over10    = (E and E.CountTimeOver10Ms)    or 7,
    over50    = (E and E.CountTimeOver50Ms)    or 8,
    over100   = (E and E.CountTimeOver100Ms)   or 9,
    over500   = (E and E.CountTimeOver500Ms)   or 10,
    over1000  = (E and E.CountTimeOver1000Ms)  or 11,
}
ns.Prof.METRIC = METRIC

ns.Prof.hasAddOnProfiler =
    (CAP and CAP.GetAddOnMetric and CAP.IsEnabled and CAP.IsEnabled()) and true or false

function ns.Prof.AddOn(name, key)
    if not ns.Prof.hasAddOnProfiler or not name then return 0 end
    return CAP.GetAddOnMetric(name, METRIC[key]) or 0
end

function ns.Prof.Overall(key)
    if not ns.Prof.hasAddOnProfiler then return 0 end
    return (CAP.GetOverallMetric and CAP.GetOverallMetric(METRIC[key])) or 0
end
