# Changelog

## v0.10.0

- **Sessions now record context.** Each saved fight is tagged with its
  **difficulty** (N / H / M / LFR) and **Kill / Wipe** result; dungeon runs get
  their **Mythic+ key level** (and affixes). Shown in the session dropdown and
  footer, so "Boss X" becomes "Boss X — M · Kill" and a run becomes "+18".
- **FPS overlay on every graph.** Sessions record the **frame rate** over time
  (avg / min in the footer), and the **live Addons graph** keeps a rolling FPS
  history too — both overlay a faint green FPS line, and the hover readout reports
  the FPS at that point, so you can line an addon's CPU spike up with the actual
  frame-rate dip.

- **Per-character sessions & baseline.** Recorded fights/runs, the in-progress
  run, and the memory baseline are now saved **per character** (via
  `SavedVariablesPerCharacter`) instead of account-wide — your alts load different
  addons, so their captures and baselines shouldn't mix. Settings (columns,
  layout, rates, bar) stay shared account-wide. Existing data is migrated to the
  character you're on at first login.

- **Comms tab gained graphs and depth.** Each prefix now has a **traffic graph**
  (bytes/sec over time) and a per-row sparkline, **Rate** and **Peak** columns
  (sortable — burst-happy addons rise to the top), a **channel breakdown** in the
  tooltip (Party / Raid / Guild / Whisper / Instance), and **average message
  size** + message rate. Lets you actually see *when* an addon floods the network
  (e.g. a sync storm on joining a group) instead of just a running total.

- **Appears in the game's options.** AddonPulse now registers under **Game Menu →
  Options → AddOns**, with a panel that summarises the addon and opens the full
  options window / the main window, plus the slash reference — so it's
  discoverable where people look for settings first.

- **Column header help.** Hovering any column header now shows a short bubble
  explaining what it measures (and a reminder it's click-to-sort).
- **Memory graph zooms to fit.** Memory is usually large and changes only a
  little, so a 0-based axis showed it as a flat line near the top. The memory
  graph now scales to its own min–max so growth / churn is visible; when memory
  genuinely didn't move (e.g. a fight recorded with the window closed, where
  per-addon memory isn't sampled), it labels the line `steady` instead of looking
  broken.

- **Minimised bar shrinks to fit.** When you minimise, the bar now narrows to a
  compact ~600px (its stats + title), instead of staying as wide as the full
  table — so the collapsed monitor takes far less screen. It restores to the full
  width when you expand.

- **`Reset CPU` renamed to `Reset graph`.** The old name overpromised — it can't
  clear the Peak / Sess / Enc columns (those come from the game's native profiler
  and only a `/reload` zeroes them). It now honestly clears the live CPU + memory
  sparkline / graph history, with a tooltip spelling that out.

- **Memory scan pauses in combat.** The per-addon memory walk
  (`UpdateAddOnMemoryUsage`) is a single blocking call that can't be made async
  (WoW's Lua is single-threaded), so it's now kept **out of combat by default** —
  the unavoidable hitch lands where it's harmless instead of mid-pull. Per-addon
  memory holds during a fight and refreshes when it ends. Re-enable with Options →
  Profiling → **Scan memory in combat**.
- **Memory baseline / diff (`ΔMem`).** The **Tools** button on the Addons tab
  snapshots every addon's current memory; the **dMem** column (added automatically,
  also in the Columns picker) then shows each addon's growth since that moment —
  green when it shrank, warming as it grows. The leak/regression hunter's tool:
  set a baseline, raid for an hour, see exactly what ballooned. The snapshot is
  tiny and survives reloads.
- **Pin & ignore addons.** Right-click any Addons row to **pin** it to the top
  (teal edge marker) or **ignore** it (hidden from the list). Tools → **Show
  ignored** reveals ignored rows dimmed so you can right-click to un-ignore.
  Your pin/ignore lists persist and aren't touched by Reset to Defaults.
- **CPU as % of frame budget.** Options → Display → **Show CPU as % of frame**
  switches every CPU figure from milliseconds to a percentage of one frame's
  budget (set by **target FPS**, default 60 → 16.7 ms = 100%). "12%" reads
  faster than "2.0 ms" when you're judging frame impact.
- **Window scale & opacity.** Options → Appearance — size the window from 70-130%
  and set its background opacity. Applied live.
- **Options window.** A panel for tuning everything that has a default — sample
  interval, memory-scan interval, live history, the session caps, auto-delete
  age, and the two profiler toggles (memory profiler, spike-timing capture) —
  each with a **Reset to Defaults** button. Open it from the title-bar cog menu
  (**Options...**) or `/pulse options`. Changes apply live.
- **Spike-timing capture is now optional.** The per-fight spike *timing* (the
  extra `>50ms` reads each tick while recording) can be turned off in the options
  (**Capture spike timing**); the per-fight spike *counts* still come for free
  from start/end snapshots. Lets you trim recording cost to the bone.
- **Memory-profiler toggle (`Mem prof`).** Unchecking it skips the per-addon
  memory scan (`UpdateAddOnMemoryUsage`) entirely — that scan is the one heavy,
  spike-prone thing AddonPulse does, so CPU-only mode is much lighter (no
  per-addon memory columns, but no memory spikes either). The title-bar Memory
  readout still works (it's the cheap total-UI figure).
- **Spike annotations on the graph.** Red ticks along the top of a live addon's
  graph mark each interval it had a frame over 50 ms — so you can see *when* it
  stuttered, which the averaged CPU line hides.
- **Sessions capture spike counts + timing.** Each saved fight/run records how
  many frames each addon went over 10 / 50 / 100 ms *during that fight* (row
  tooltip), and now also **when** the >50ms spikes happened — so the saved
  session graph gets the same red spike ticks as the live one. The timing is
  stored **sparsely** (only the intervals that spiked), so it adds only ~10–25 KB
  across all sessions.
- **Sessions auto-rotate by age.** Saved sessions older than `sessionMaxDays`
  (default 14) are dropped automatically (on save and at login), on top of the
  existing count cap — so the saved file can't grow without bound.
- **Selectable Addons columns.** A **Columns** button on the Addons tab picks
  which columns the table shows, from: Mem, Churn (mem/s), Recent, Peak, Session,
  Encounter, Last, and the spike counts **>10ms / >50ms / >100ms / >500ms / >1s**
  (cumulative frames over each threshold, straight from `C_AddOnProfiler`). Each
  is sortable. The sampler only reads the metrics for the columns you've enabled,
  so showing more costs a little more and showing fewer costs less. The window
  **widens automatically to fit the columns** you enable (and won't shrink below
  that), so the table can't overflow onto the addon names; the per-row sparkline
  also steps aside when space is tight. Remove columns to let it shrink again.
- **Compatible with patch 12.0.7 and 12.1** (`## Interface: 120007, 120100`), so
  it loads without the "out of date" flag on either. None of the APIs it uses
  changed in 12.1.
- **Title-bar stats + cogwheel.** A gear button in the title bar picks which
  brief readouts show on the bar — **FPS, CPU, Memory, Comms**. They stay live
  even while **minimised**, so the collapsed bar is a compact at-a-glance
  monitor. Your selection is saved.
- Putting **Memory** on the bar is the only one that costs anything (it triggers
  the per-addon memory walk, on the same slow ~10 s cadence, and only while the
  bar is visible); FPS / CPU / Comms are free.
- The cog sits to the **left of the minimize button**, and the bar stats are
  right-aligned (the **AddonPulse** title stays on the left).
- Added **Home** and **World latency** to the bar options (off by default).
  They're free — `GetNetStats()` just reads the client's cached latency values.
- **Sessions picker is now a searchable dropdown** instead of `< >` arrows. It
  lists every saved fight/run with its name, duration and how long ago it was,
  and you can type to filter by name.
- **Every session row now has a sparkline/graph.** Previously the per-tick
  timeline was kept only for the few top CPU users, so only those rows had
  graphs; now every addon kept in a session (notable on CPU or ≥3 MB, up to 40)
  keeps its timeline. Applies to **newly captured** sessions.
- **Fixed** the minimap tooltip not updating its Active/Paused line on
  right-click (it rebuilds in place now instead of needing a re-hover).
- **Enable / disable is now obvious:** every toggle (button, minimap, or slash)
  prints to chat and shows a brief on-screen note, and the minimap tooltip's
  Active/Paused line updates **live** on right-click instead of needing a
  re-hover.
- **The bar keeps working while paused.** Pausing only drops *new* per-addon
  sampling and recording — the title-bar **FPS / CPU / Memory / Comms** readouts
  stay live, so you can run AddonPulse as a lightweight stats bar with the heavy
  profiling off. (Those readouts are all cheap: FPS and comms are free, the
  native CPU profiler is always on, and bar Memory is total UI memory rather than
  the per-addon walk.)
- **Everything already captured stays viewable while paused** — saved sessions,
  comms, the existing graphs, and the last Addons snapshot all still open; the
  footer shows `paused` so it's clear the per-addon numbers are frozen. (Pause
  stops collecting, not viewing.)
- **Removed the separate Background checkbox** (and `/pulse bg`). The
  **Active / Paused** toggle is now the single on/off for all background work:
  enabled = sample + record everywhere (closed/minimised included); paused =
  bar stats only. One control instead of two overlapping ones.

## v0.9.0

- **Master enable / disable.** A new **Active / Paused** toggle pauses AddonPulse's
  per-addon sampling and auto-recording — for when you don't need the detailed
  profiling running. Toggle it three ways: the
  **Active / Paused** button in the toolbar, **right-click the minimap button**,
  or `/pulse on` · `/pulse off` · `/pulse toggle`. The state is saved.
  - Note: this pauses *AddonPulse's own work*. Blizzard's native CPU profiler
    can't be turned off (it's built into the client and costs ~nothing). Closing
    the window also parks most of the work, but combat/instances still
    auto-record unless you pause.
- Repurposed the old CPU-profiling button — obsolete since CPU is now native and
  always on — into the Active/Paused toggle. `/pulse cpu` now just says so on
  modern clients.

## v0.8.0

- **AddonPulse no longer shows up as its own CPU spike.** Per-addon memory needs
  `UpdateAddOnMemoryUsage()`, which walks every addon and is expensive; sampling
  it every 2 s made our own ticks register as a periodic >10 ms spike. Memory is
  now refreshed on a slow cadence (`memSeconds`, default 10 s) and **only while
  the window is on screen** — there's no memory walk at all while closed or
  minimised, even mid-fight. It refreshes immediately when you open the window.
- Trimmed the per-tick CPU reads to what the table shows (recent / peak /
  session / encounter + the spike flag); the tooltip and graph read last /
  over50 / over100 live for just the one addon they display.
- Reminder: the **>10/50/100 ms spike counts are cumulative since login**, so
  they only grow — a `/reload` zeroes them.

## v0.7.0

- **Graph annotations.**
  - **Event markers** — coloured vertical lines mark **combat start/end**, **boss
    pulls** (encounters), and **deaths** on the timeline, so you can line a
    CPU/memory spike up with what was happening. They're recorded live and
    stored with each saved fight/run, so they persist.
  - **Hover readout** — mouse over the plot for a crosshair plus the exact
    value and time at that point, and the name of the nearest event. The hover
    only does work while the cursor is actually over the graph.
  - **Marker toggle** — a dedicated strip below the graph cycles markers
    **all → pulls + deaths → off** (to cut the clutter on long runs) and shows
    the graph's time window (e.g. `Last 3m00s`).
- **Fixed** a Comms-tab error when another addon sends a non-string addon
  message payload (e.g. ElvUI's numeric version broadcast) — byte counting no
  longer assumes the payload is a string.

## v0.6.0

- **Lower footprint.** The sampler is now a `C_Timer` ticker instead of a
  per-frame `OnUpdate`, so there's no per-frame work at all. While the window is
  closed or minimised, only `recent` CPU + memory are read per addon (the other
  profiler metrics and the leak scan are skipped) — so background recording is
  much cheaper.
- **Active runs survive reloads.** An in-progress dungeon/raid run is now saved
  once at logout (not every frame) and resumes when you re-enter the instance,
  so reloading mid-key no longer restarts the run.
- **Sparkline follows the Graph toggle.** Each row's sparkline now plots CPU or
  Memory to match the **Graph: CPU / Mem** button, and matches its colour.
- Minimap tooltip drops the redundant "drag to move" hint.

## v0.5.0

- **Sessions persist across reloads.** Captured fights are now saved to disk, so
  the reload after a raid or M+ no longer wipes them — open the window any time
  afterwards to review. Saved snapshots keep the full timeline only for the
  addons that actually used CPU, so the saved-variables file stays small.
- **Whole dungeon / raid tracking.** Entering a dungeon or raid starts a **run**
  that records across the *entire* instance (trash and bosses), finishing when
  you leave. So you get both the per-pull fights and the whole-run picture.
- **"Last Fight" tab is now "Sessions"**, with a **< name (kind, duration) >**
  picker to browse every saved fight and run, newest first. Each shows its
  per-addon CPU peak / average and memory peak; click a row to graph the
  timeline. **Clear** removes the shown session.
- Keeps the last 8 fights and 4 runs by default.
- Note: an *in-progress* run is still in memory, so reloading mid-instance
  restarts the run (completed fights are already saved). Sessions persist once
  finished.

## v0.4.0

- **Background recording.** Sampling no longer stops when the window is closed
  or minimised — an always-on driver keeps the history filling, so you can close
  the window during a fight and open it afterwards to see what happened. Toggle
  with the **Background** checkbox or `/pulse bg` (on by default). Even with it
  off, recording still runs *while you're in combat* so fights are never missed.
- **Last Fight tab.** Every combat segment is captured into a frozen snapshot —
  named after the boss when there's an encounter — covering the **whole fight**
  regardless of length. The tab lists each addon's CPU **peak / average** and
  memory peak for that fight; click a row to graph its full timeline. Clears
  with the **Clear fight** button. Stored in memory (not across reloads).
- The footer shows **recording fight** / **in encounter** while combat is live.
- Fixes the previous behaviour where minimising the window threw away history.

## v0.3.0

- **Removed the Events tab** — the per-event view wasn't pulling its weight.
- **All CPU metrics are now columns**, not a cycle button: the Addons table
  shows **Recent / Peak / Session / Encounter** side by side, each sortable.
- **Wider CPU sparkline** with a faint chart background, so it's easier to read.
- **Fixed the status flags.** The leak/spike markers were Unicode glyphs the
  default font doesn't have, so they showed as empty boxes. They're now solid
  colour dots: **orange = possible memory leak** (steady climb), **red = CPU
  spike** (has used over 10 ms in a frame). Both are explained in the tooltip.
- Sort arrows and other indicators switched to font-safe textures so nothing
  renders as a missing-glyph box.
- The window is a little wider by default to fit the extra columns; the minimap
  button is now plain left-click to toggle (it no longer touches profiling).

## v0.2.0

- **Native profiler.** CPU now comes from Blizzard's `C_AddOnProfiler`, which is
  always on — no `scriptProfile`, no reload. CPU is reported as milliseconds per
  frame, and each addon carries native **recent / peak / session / encounter**
  averages plus counts of how many frames it blew past 10/50/100 ms.
- **CPU metric selector.** The **CPU: …** button cycles the CPU column (and the
  sort) between Recent, Peak, Session, and Encounter — so you can rank addons by
  their worst spike or by their cost during the current boss fight.
- **Tabs.** The window now has three tabs sharing one table:
  - **Addons** — the per-addon view, now with a **CPU sparkline** per row, a
    **leak** flag (▲, sustained memory climb) and a **spike** flag (◆, has gone
    over 10 ms/frame), and a richer tooltip + detail graph (peak/session/
    encounter, spike counts, memory peak/avg/churn).
  - **Events** — global per-event CPU **and call count** (`GetEventCPUUsage`),
    e.g. how many times `UNIT_AURA` fired and what it cost. Needs script
    profiling; the **CPU** button prompts the reload.
  - **Comms** — per-prefix addon-message traffic, **bytes + messages in/out**,
    captured from `SendAddonMessage` / `CHAT_MSG_ADDON`.
- **Encounter awareness.** The footer flags when you're in a boss encounter, and
  the Encounter CPU metric reflects per-fight cost.
- Memory churn (KB/s) and a coarse leak heuristic are surfaced in the tooltip
  and the detail panel.

## v0.1.0

- First release. A live per-addon resource monitor.
  - **Table:** every installed addon with its current **memory** footprint and,
    when script profiling is on, its **CPU/s** (milliseconds of CPU time per
    real second). Values are colour-coded green → yellow → orange → red by
    severity, with an inline bar showing each addon's share of the sorted
    metric.
  - **Sorting:** click the **Addon**, **Memory**, or **CPU/s** header to sort;
    click again to flip the direction.
  - **Filter:** type in the search box to narrow the list by name; toggle
    **Loaded only** (hide installed-but-unloaded addons) and **Hide idle**
    (hide addons using almost nothing).
  - **Graph:** click any row to pin it to the history graph at the bottom.
    Switch the graphed series between **CPU** and **Memory**, or hide the graph
    entirely. History covers the last ~3 minutes.
  - **Minimise:** the **–** button collapses the window to its title bar; **+**
    restores it.
  - **CPU profiling:** CPU metering needs the `scriptProfile` CVar, which only
    takes effect after a reload. The **CPU** button (or `/pulse cpu`) flips it
    and offers to reload. **Reset CPU** zeroes the counters for a fresh
    baseline.
- The window is movable (drag the title bar) and resizable (bottom-right grip);
  position, size, sort, filters and the pinned addon are all remembered.
- Nothing is sampled while the window is closed or minimised, so idle cost is
  zero.
- Slash commands: `/pulse`, `/addonpulse`, `/ap` — toggle the window;
  `/pulse cpu` toggle profiling; `/pulse reset` reset CPU counters;
  `/pulse status` print the profiling state.
- Optional minimap button (left-click toggles the window, right-click toggles
  profiling) when the LibDBIcon library is present.
