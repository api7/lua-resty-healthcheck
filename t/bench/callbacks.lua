-- Times the callbacks of this library with a real shm: the event callback of
-- a checker and the timer callbacks of the worker. Not a test.
--
-- The timers and the event transport are replaced: timer callbacks are
-- captured and called by the script, and events are queued and delivered by
-- the script, so that each call can be timed on its own and nothing else runs
-- in between. Everything else is the library as it is, on a real shm.
--
-- Run with resty, with this library on the Lua path:
--
--   SCENARIO=clear TARGETS=10000 \
--     resty --shdict "hc 256m" --main-conf "env SCENARIO; env TARGETS; env CHECKERS; env ROUNDS;" \
--           -I lib t/bench/callbacks.lua
--
-- SCENARIO  clear          a checker with TARGETS targets receives `clear`
--           idle           the timers of a worker with CHECKERS checkers of
--                          TARGETS targets each, when nothing changes, over
--                          ROUNDS passes (100 passes include the periodic
--                          full comparison of every checker)
--           status         a target changes state and the event is delivered
--           missed         a target changes state and the event is lost
--           remove         TARGETS targets are removed one by one, each event
--                          delivered
--           remove-missed  half of the TARGETS targets are removed and the
--                          events are lost
-- ROUNDS    how many times the scenario is measured (default 11)
local ffi = require "ffi"
ffi.cdef[[
  typedef struct { long tv_sec; long tv_nsec; } bench_timespec;
  int clock_gettime(int clk_id, bench_timespec *tp);
]]
local ts = ffi.new("bench_timespec")
local function now_ms()
  ffi.C.clock_gettime(1, ts)  -- CLOCK_MONOTONIC
  return tonumber(ts.tv_sec) * 1000 + tonumber(ts.tv_nsec) / 1e6
end
-- CPU time of this thread: what a stretch of work costs, without the time the
-- process was not scheduled (Linux)
local function cpu_ms()
  ffi.C.clock_gettime(3, ts)  -- CLOCK_THREAD_CPUTIME_ID
  return tonumber(ts.tv_sec) * 1000 + tonumber(ts.tv_nsec) / 1e6
end

-- gives access to the counters of the reconciliation
rawset(_G, "__TESTING_HEALTHCHECKER", true)

-- timers: captured, not started. The timer of the active checks and of the
-- purge is created with resty.timer; the one that reconciles the copy of the
-- worker with shm, where the library has one, with ngx.timer.every.
local check_timers, reconcile_timers = {}, {}
ngx.timer.every = function(_, fn)
  reconcile_timers[#reconcile_timers + 1] = function() return fn(false) end
  return true
end
package.loaded["resty.timer"] = function(opts)
  if opts.recurring then
    check_timers[#check_timers + 1] = opts.expire
  end
  return { cancel = function() end }
end

-- events: queued by post(), delivered by deliver(). "*" holds the callbacks
-- registered for every event.
local subscribers, queue = { ["*"] = {} }, {}
package.loaded["resty.worker.events"] = {
  _VERSION = "0.3.3",
  configure = function() return true end,
  configured = function() return true end,
  poll = function() return "done" end,
  post = function(source, event, data)
    queue[#queue + 1] = { source, event, data }
    return true
  end,
  register = function(callback, source)
    source = source or "*"
    subscribers[source] = subscribers[source] or {}
    table.insert(subscribers[source], callback)
  end,
  unregister = function(callback, source)
    local list = subscribers[source or "*"]
    for i = list and #list or 0, 1, -1 do
      if list[i] == callback then
        table.remove(list, i)
      end
    end
  end,
}
package.loaded["resty.worker.events"].register_weak = package.loaded["resty.worker.events"].register

-- the longest stretch without a yield, as seen through ngx.sleep: in elapsed
-- time, and in CPU time
local slice_start, longest_slice, yields = now_ms(), 0, 0
local slice_cpu_start, longest_slice_cpu = cpu_ms(), 0
local real_sleep = ngx.sleep
ngx.sleep = function(...)
  longest_slice = math.max(longest_slice, now_ms() - slice_start)
  longest_slice_cpu = math.max(longest_slice_cpu, cpu_ms() - slice_cpu_start)
  yields = yields + 1
  local res, err = real_sleep(...)
  slice_start, slice_cpu_start = now_ms(), cpu_ms()
  return res, err
end
local function reset_slices()
  slice_start, longest_slice, yields = now_ms(), 0, 0
  slice_cpu_start, longest_slice_cpu = cpu_ms(), 0
end
-- returns the longest stretch in elapsed time, and in CPU time
local function close_slice()
  longest_slice = math.max(longest_slice, now_ms() - slice_start)
  longest_slice_cpu = math.max(longest_slice_cpu, cpu_ms() - slice_cpu_start)
  return longest_slice, longest_slice_cpu
end

local hc = require "resty.healthcheck"
local buffer = require "string.buffer"
local shm = ngx.shared.hc

local scenario = os.getenv("SCENARIO") or "clear"
local n_targets = tonumber(os.getenv("TARGETS")) or 10000
local n_checkers = tonumber(os.getenv("CHECKERS")) or 1
local rounds = tonumber(os.getenv("ROUNDS")) or 11

local function addr(i)
  return "10." .. (math.floor(i / 62500) % 250) .. "." .. (math.floor(i / 250) % 250) .. "." .. (i % 250)
end

-- writes the targets of a checker to the shm the way add_target() leaves them
local function populate(name, count)
  local list = {}
  for i = 1, count do
    local ip = addr(i)
    list[i] = { ip = ip, port = 8080, hostname = ip }
    assert(shm:set("lua-resty-healthcheck:" .. name .. ":state:" .. ip .. ":8080:" .. ip, 1))
  end
  assert(shm:set("lua-resty-healthcheck:" .. name .. ":target_list", buffer.encode(list)))
end

local function new_checker(name)
  return assert(hc.new({
    name = name,
    shm_name = "hc",
    checks = { active = { healthy = { interval = 0 }, unhealthy = { interval = 0 } } },
  }))
end

-- Delivers the queued events, or loses them all (`lose`): a lost event
-- reaches no callback of the worker. Returns the time spent in the callback
-- `only` (or in all callbacks), and the longest single call.
local function deliver(only, lose)
  local total, longest = 0, 0
  local events = queue
  queue = {}
  if lose then
    return 0, 0
  end
  for _, e in ipairs(events) do
    for _, list in ipairs({ subscribers["*"], subscribers[e[1]] or {} }) do
      for _, callback in ipairs(list) do
        local t0 = now_ms()
        callback(e[3], e[2], e[1])
        local dt = now_ms() - t0
        if not only or callback == only then
          total = total + dt
          longest = math.max(longest, dt)
        end
      end
    end
  end
  return total, longest
end

-- one pass of every timer of the worker; returns the time it took, and the
-- part of it spent reconciling
local function tick()
  local t0 = now_ms()
  for _, callback in ipairs(check_timers) do
    callback()
  end
  local t1 = now_ms()
  for _, callback in ipairs(reconcile_timers) do
    callback()
  end
  local t2 = now_ms()
  return t2 - t0, t2 - t1
end

local function median(values)
  local sorted = { unpack(values) }
  table.sort(sorted)
  return sorted[math.ceil(#sorted / 2)]
end

local function report(what, values, extra)
  local sorted = { unpack(values) }
  table.sort(sorted)
  local sum = 0
  for _, v in ipairs(sorted) do sum = sum + v end
  print(string.format("%-56s median %9.3f ms   min %9.3f   max %9.3f   sum %10.3f%s",
                      what, median(values), sorted[1], sorted[#sorted], sum, extra or ""))
end

local function stats()
  local s = hc._reconcile_stats and hc._reconcile_stats()
  if not s then
    return nil
  end
  local copy = {}
  for k, v in pairs(s) do copy[k] = v end
  return copy
end

local function report_stats(before)
  local after = stats()
  if not (before and after) then
    return
  end
  local parts = {}
  for _, k in ipairs({ "runs", "scans", "compared", "members", "corrected", "yields", "queued" }) do
    parts[#parts + 1] = k .. "=" .. (after[k] - before[k])
  end
  print("  reconciliation while measured: " .. table.concat(parts, " "))
end

-- keep the purge of delayed_clear() targets out of the measurements: its
-- election key is taken, as if another worker had won it
shm:set("lua-resty-healthcheck::period_lock::cleanup", 1, 3600)

print(string.format("scenario=%s targets=%d checkers=%d rounds=%d", scenario, n_targets, n_checkers, rounds))

if scenario == "clear" then
  local times = {}
  for r = 1, rounds do
    local name = "clear-" .. r
    populate(name, n_targets)
    local a, b = new_checker(name), new_checker(name)
    assert(a:clear())
    times[r] = deliver(b.ev_callback)
    tick()
    assert(#b.targets == 0, "the receiving checker still has targets")
  end
  report("event callback of the receiving checker, on `clear`", times)

elseif scenario == "idle" then
  for c = 1, n_checkers do
    populate("idle-" .. c, n_targets)
    new_checker("idle-" .. c)
  end
  -- the first full comparison of every checker is not what is measured
  for _ = 1, 110 do tick() end
  local before = stats()
  local times, reconcile_times, slices, cpu_slices = {}, {}, {}, {}
  for r = 1, rounds do
    reset_slices()
    times[r], reconcile_times[r] = tick()
    slices[r], cpu_slices[r] = close_slice()
  end
  report("one pass of the timers, nothing changed", times)
  report("  of which the reconcile timer", reconcile_times)
  report("longest stretch without a yield in a pass", slices)
  report("  the same in CPU time", cpu_slices)
  report_stats(before)

elseif scenario == "status" or scenario == "missed" then
  local a, b = {}, {}
  for c = 1, n_checkers do
    populate(scenario .. "-" .. c, n_targets)
    a[c], b[c] = new_checker(scenario .. "-" .. c), new_checker(scenario .. "-" .. c)
  end
  for _ = 1, 110 do tick() end
  local before = stats()
  local event_times, tick_times, reconcile_times, slices, cpu_slices = {}, {}, {}, {}, {}
  local healthy, wrong = true, 0
  for r = 1, rounds do
    healthy = not healthy
    local c = (r - 1) % n_checkers + 1
    assert(a[c]:set_target_status(addr(1), 8080, nil, healthy))
    event_times[r] = deliver(b[c].ev_callback, scenario == "missed")
    reset_slices()
    -- one pass of the timers puts the copy right, unless nothing does
    tick_times[r], reconcile_times[r] = tick()
    slices[r], cpu_slices[r] = close_slice()
    if b[c]:get_target_status(addr(1), 8080) ~= healthy then
      wrong = wrong + 1
      -- put the copies right for the next round
      b[c]:event_handler(healthy and "healthy" or "unhealthy", addr(1), 8080, addr(1))
      a[c]:event_handler(healthy and "healthy" or "unhealthy", addr(1), 8080, addr(1))
    end
  end
  if scenario == "status" then
    report("event callback of the receiving checker", event_times)
  end
  report("one pass of the timers after the change", tick_times)
  report("  of which the reconcile timer", reconcile_times)
  report("longest stretch without a yield in that pass", slices)
  report("  the same in CPU time", cpu_slices)
  print(string.format("  copy still wrong after the pass: %d of %d rounds", wrong, rounds))
  report_stats(before)

elseif scenario == "remove" then
  local totals, longest_calls = {}, {}
  for r = 1, rounds do
    local name = "remove-" .. r
    populate(name, n_targets)
    local a, b = new_checker(name), new_checker(name)
    local total, longest = 0, 0
    for i = 1, n_targets do
      assert(a:remove_target(addr(i), 8080, addr(i)))
      local t, l = deliver(b.ev_callback)
      total, longest = total + t, math.max(longest, l)
    end
    totals[r], longest_calls[r] = total, longest
    assert(#b.targets == 0, "the receiving checker still has targets")
  end
  report("event callbacks of the receiving checker, all removals", totals)
  report("longest single event callback", longest_calls)

elseif scenario == "remove-missed" then
  local before = stats()
  local tick_times, slices, cpu_slices, yielded = {}, {}, {}, {}
  local wrong = 0
  for r = 1, rounds do
    local name = "remove-missed-" .. r
    populate(name, n_targets)
    local a, b = new_checker(name), new_checker(name)
    tick()
    -- every other target leaves the list, as when remove_target() is called
    -- for each of them, and no event arrives
    local list = {}
    for i = 1, n_targets do
      local ip = addr(i)
      if i % 2 == 0 then
        list[#list + 1] = { ip = ip, port = 8080, hostname = ip }
      else
        shm:delete("lua-resty-healthcheck:" .. name .. ":state:" .. ip .. ":8080:" .. ip)
      end
    end
    assert(shm:set("lua-resty-healthcheck:" .. name .. ":target_list", buffer.encode(list)))
    a:raise_event(a.events.remove, addr(1), 8080, addr(1))
    deliver(nil, true)

    reset_slices()
    tick_times[r] = tick()
    slices[r], cpu_slices[r] = close_slice()
    yielded[r] = yields
    if #b.targets ~= #list then
      wrong = wrong + 1
    end
  end
  report("one pass of the timers after the removals", tick_times)
  report("longest stretch without a yield in that pass", slices)
  report("  the same in CPU time", cpu_slices)
  report("yields in that pass (a count, not ms)", yielded)
  print(string.format("  copy still wrong after the pass: %d of %d rounds", wrong, rounds))
  report_stats(before)

else
  error("unknown SCENARIO: " .. scenario)
end
