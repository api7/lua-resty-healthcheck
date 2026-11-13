-- Load generator, run by run.sh with `resty` inside the container.
--   UPSTREAMS routes exist (/hello/<n>); every worker first serves each of
--   them once, so that it has a checker for each upstream; then CONNS
--   connections request the first HOT routes in turn for DURATION seconds.
-- Prints one line of JSON: requests, requests per second, latency (ms), the
-- CPU time of the nginx workers as a share of one core each, the health check
-- events seen and lost by the workers, and the counters of the reconciliation
-- where the library has them.
local http = require "resty.http"
local json = require "cjson.safe"
local ffi = require "ffi"
ffi.cdef[[ typedef struct { long tv_sec; long tv_nsec; } load_timespec; int clock_gettime(int clk_id, load_timespec *tp); ]]
local ts = ffi.new("load_timespec")
local function now_us() ffi.C.clock_gettime(1, ts); return tonumber(ts.tv_sec) * 1e6 + tonumber(ts.tv_nsec) / 1e3 end

local upstreams = tonumber(os.getenv("UPSTREAMS"))
local workers = tonumber(os.getenv("WORKERS") or "2")
local conns = tonumber(os.getenv("CONNS") or "16")
local hot = math.min(tonumber(os.getenv("HOT") or "20"), upstreams)
local duration = tonumber(os.getenv("DURATION") or "15")
local settle = tonumber(os.getenv("SETTLE") or "8")

local function connect()
    local c = http.new()
    c:set_timeout(10000)
    assert(c:connect("127.0.0.1", 9080))
    return c
end
local function get(c, path)
    local res, err = c:request{ path = path, headers = { Host = "bench" } }
    if not res then return nil, err end
    local body = res:read_body()
    return res.status, body
end
local function conn_to(worker)
    for _ = 1, 500 do
        local c = connect()
        local _, body = get(c, "/whoami")
        if tonumber(body) == worker then return c end
        c:close()
    end
    error("could not reach worker " .. worker)
end

-- nginx worker pids and their CPU time (user + system), in clock ticks
local function worker_cpu()
    local total, n = 0, 0
    local p = io.popen("for d in /proc/[0-9]*; do if grep -qa '^nginx: worker process' $d/cmdline 2>/dev/null; then cat $d/stat; fi; done")
    for line in p:lines() do
        local rest = line:match("%) (.*)$")
        local fields = {}
        for f in rest:gmatch("%S+") do fields[#fields + 1] = f end
        total = total + tonumber(fields[12]) + tonumber(fields[13])   -- utime, stime
        n = n + 1
    end
    p:close()
    return total, n
end

-- every worker gets a checker for every upstream
local pinned = {}
for w = 0, workers - 1 do
    pinned[w] = conn_to(w)
    for i = 1, upstreams do
        get(pinned[w], "/hello/" .. i)
    end
end
ngx.sleep(settle)

local function hookstats()
    local out = {}
    for w = 0, workers - 1 do
        -- a new connection: the server closes one after a number of requests
        local c = conn_to(w)
        local _, body = get(c, "/hookstats")
        c:close()
        out[#out + 1] = json.decode(body or "") or body
    end
    return out
end

local before = hookstats()
local cpu0, nworkers = worker_cpu()
local t_start = now_us()
local deadline = t_start + duration * 1e6
local lat, count, reconnects, non200 = {}, 0, 0, 0
local threads = {}
for k = 1, conns do
    threads[k] = ngx.thread.spawn(function()
        local c = connect()
        local i = k
        while true do
            local t0 = now_us()
            if t0 >= deadline then break end
            i = i % hot + 1
            local status = get(c, "/hello/" .. i)
            local dt = now_us() - t0
            if not status then
                -- the server closes a connection after a number of requests
                reconnects = reconnects + 1
                c = connect()
            else
                count = count + 1
                lat[count] = dt
                if status ~= 200 then non200 = non200 + 1 end
            end
        end
    end)
end
for k = 1, conns do ngx.thread.wait(threads[k]) end
local elapsed = (now_us() - t_start) / 1e6
local cpu1 = worker_cpu()
local after = hookstats()
table.sort(lat)
local function pct(p) return lat[math.max(1, math.ceil(count * p))] / 1000 end
local out = {
    requests = count, reconnects = reconnects, non_200 = non200,
    rps = math.floor(count / elapsed),
    p50_ms = pct(0.50), p99_ms = pct(0.99), p999_ms = pct(0.999), max_ms = lat[count] / 1000,
    worker_cpu_percent = (cpu1 - cpu0) / 100 / elapsed / nworkers * 100,   -- 100 ticks a second
    workers = nworkers,
}
local ev_seen, ev_lost, rec = 0, 0, {}
for w = 1, #after do
    if type(after[w]) == "table" and type(before[w]) == "table" then
        ev_seen = ev_seen + after[w].events_seen - before[w].events_seen
        ev_lost = ev_lost + after[w].events_lost - before[w].events_lost
        if after[w].reconcile and before[w].reconcile then
            for k, v in pairs(after[w].reconcile) do
                rec[k] = (rec[k] or 0) + v - before[w].reconcile[k]
            end
        end
    end
end
out.events_seen, out.events_lost = ev_seen, ev_lost
out.reconcile = next(rec) and rec or nil
print(json.encode(out))
