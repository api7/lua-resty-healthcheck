-- Measures what the health checkers keep in their shm, and how many targets
-- fit: it adds targets until the first write that evicts an entry or fails.
-- Not a test; the figures in the readme ("Sizing the shm") come from it.
--
-- Run it with resty, one scenario per process, with this library and
-- lua-resty-worker-events on the Lua path:
--
--   TARGETS_PER_CHECKER=10 HOSTNAME_LEN=0 COUNTERS=0 \
--     resty --shdict "hc 10m" --shdict "ev 32m" \
--           --main-conf "env TARGETS_PER_CHECKER; env HOSTNAME_LEN; env COUNTERS;" \
--           t/shm-sizing/measure_shm.lua
--
-- TARGETS_PER_CHECKER  targets added to each checker (default 10)
-- HOSTNAME_LEN         0 for targets without a hostname, or its length
-- COUNTERS             1 to report one failed request per target, which
--                      creates its counter key
local hc = require "resty.healthcheck"
local we = require "resty.worker.events"
assert(we.configure{ shm = "ev", interval = 1 })

local per_checker = tonumber(os.getenv("TARGETS_PER_CHECKER") or "10")
assert(per_checker and per_checker >= 1 and per_checker % 1 == 0,
       "TARGETS_PER_CHECKER must be a positive integer")
local host_len = tonumber(os.getenv("HOSTNAME_LEN")) or 0
local with_counters = os.getenv("COUNTERS") == "1"
local shm = ngx.shared.hc

-- note the first write that evicts entries or fails, whoever makes it
-- (the library, or resty.lock for its lock keys)
local full
local mt = getmetatable(shm).__index
for _, name in ipairs({ "set", "add", "replace", "incr" }) do
    local orig = mt[name]
    mt[name] = function(dict, key, ...)
        local ok, err, forcible = orig(dict, key, ...)
        if dict == shm and not full and (forcible or err == "no memory") then
            full = name .. " of " .. tostring(key):gsub("%d+%.%d+%.%d+%.%d+.*", "<target>") ..
                   (err == "no memory"
                    and (" failed: no memory" .. (forcible and ", after evicting entries" or ""))
                    or " evicted entries")
        end
        return ok, err, forcible
    end
end

local function hostname(i)
    if host_len == 0 then return nil end
    local base = "svc-" .. i .. ".ns.svc.cluster.local"
    return (base .. string.rep("x", host_len)):sub(1, host_len)
end

local capacity = shm:capacity()
local free0 = shm:free_space()
local checkers, targets = 0, 0
local used_at = {}        -- targets => bytes used, sampled
local next_sample = 1000

while not full do
    checkers = checkers + 1
    -- named as Apache APISIX names the checker of an upstream
    local checker, new_err = hc.new({
        name = "upstream#/apisix/upstreams/" .. (100000000 + checkers),
        shm_name = "hc",
        checks = { active = { healthy = { interval = 0 }, unhealthy = { interval = 0 } },
                   passive = { unhealthy = { http_failures = 3 } } },
    })
    -- creating a checker can be what fills the shm: it is not counted then
    if full then
        checkers = checkers - 1
        break
    end
    assert(checker, "new() failed: " .. tostring(new_err))
    for t = 1, per_checker do
        local i = targets + 1
        local ip = "10." .. (math.floor(i / 62500) % 250) .. "." .. (math.floor(i / 250) % 250) .. "." .. (i % 250)
        local host = hostname(i)
        local ok, err = checker:add_target(ip, 8080, host, true)
        if full then break end
        -- any other failure would leave the loop adding nothing for ever
        assert(ok, "add_target() failed: " .. tostring(err))
        if with_counters then
            -- one failed request: creates the counter key (the threshold is 3)
            local reported, report_err = checker:report_http_status(ip, 8080, host, 500, "passive")
            if full then break end
            assert(reported, "report_http_status() failed: " .. tostring(report_err))
        end
        targets = i
        if targets == next_sample then
            used_at[#used_at + 1] = { targets, capacity - shm:free_space() }
            next_sample = next_sample * 2
        end
    end
    if checkers % 200 == 0 then collectgarbage() end
end

local last = used_at[#used_at]
print(string.format("targets_per_checker=%d hostname_len=%d counters=%s", per_checker, host_len, tostring(with_counters)))
print(string.format("  capacity=%d bytes, free before=%d", capacity, free0))
for _, s in ipairs(used_at) do
    print(string.format("  %6d targets: %8d bytes in use (free_space), %.0f bytes per target", s[1], s[2] - (capacity - free0), (s[2] - (capacity - free0)) / s[1]))
end
print(string.format("  first full write after %d targets in %d checkers: %s", targets, checkers, full))
print(string.format("  free_space at that point: %d bytes (%.1f%% of capacity)", shm:free_space(), shm:free_space() / capacity * 100))
