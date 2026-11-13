-- Loaded by APISIX through apisix.lua_module_hook. With LOSE_PERCENT set, that
-- share of the health check events reaches no callback in the worker that
-- should get them: events lost in transport.
-- gives access to the counters of the reconciliation, where the library has them
rawset(_G, "__TESTING_HEALTHCHECKER", true)
local we = require("resty.events.compat")
local json = require("cjson.safe")
local lose = tonumber(os.getenv("LOSE_PERCENT") or "0") or 0
local lost, seen = 0, 0

if lose > 0 then
    local wrapped = setmetatable({}, { __mode = "k" })
    -- every callback of a worker gets the same data table for an event
    local verdict = setmetatable({}, { __mode = "k" })
    local function wrap(callback)
        local w = wrapped[callback]
        if not w then
            w = function(data, event, source, ...)
                if type(data) == "table" and data.port and type(source) == "string"
                   and source:sub(1, 21) == "lua-resty-healthcheck"
                then
                    local drop = verdict[data]
                    if drop == nil then
                        seen = seen + 1
                        drop = math.random(100) <= lose
                        verdict[data] = drop
                        if drop then
                            lost = lost + 1
                        end
                    end
                    if drop then
                        return
                    end
                end
                return callback(data, event, source, ...)
            end
            wrapped[callback] = w
        end
        return w
    end
    for _, name in ipairs({ "register", "register_weak" }) do
        local orig = we[name]
        we[name] = function(callback, ...)
            return orig(wrap(callback), ...)
        end
    end
    local orig_unregister = we.unregister
    we.unregister = function(callback, ...)
        return orig_unregister(wrapped[callback] or callback, ...)
    end
end

local _M = {}

function _M.stats()
    local out = { worker = ngx.worker.id(), events_seen = seen, events_lost = lost }
    local hc = require("resty.healthcheck")
    if hc._reconcile_stats then
        out.reconcile = hc._reconcile_stats()
    end
    return json.encode(out) .. "\n"
end

return _M
