use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * blocks() * 3;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;

    init_by_lua_block {
        -- A checker that stands for a worker which missed an event has to
        -- keep the copy it has: the reconcile timer is not started.
        ngx.timer.every = function() return true end

        ip = "127.0.0.1"

        -- polls cond() until it returns true or the timeout (2 s) expires
        function wait_until(cond, timeout)
            local deadline = ngx.now() + (timeout or 2)
            while not cond() do
                ngx.update_time()
                if ngx.now() >= deadline then
                    return false
                end
                ngx.sleep(0.01)
            end
            return true
        end

        -- two checkers with the same name stand for the checkers of two
        -- workers: each has its own copy of the targets
        function new_checker(http_failures)
            if not worker_events_configured then
                local we = require "resty.worker.events"
                assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
                worker_events_configured = true
            end
            return assert(require("resty.healthcheck").new({
                name = "testing",
                shm_name = "test_shm",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                    passive = {
                        unhealthy = { http_failures = http_failures or 1 },
                    },
                },
            }))
        end

        function status(checker, port, hostname)
            local ok, err = checker:get_target_status(ip, port, hostname)
            return tostring(ok) .. (err and ("/" .. err) or "")
        end

        function key_of(prefix, port, hostname)
            return prefix .. ":" .. ip .. ":" .. port .. ":" .. (hostname or ip)
        end

        -- a shm whose `methods` (set() if not given) fail for one key, as
        -- when the shm is full
        function failing_shm(real, failing_key, methods)
            local failing = {}
            for _, name in ipairs(methods or { "set" }) do
                failing[name] = true
            end
            return setmetatable({}, {
                __index = function(_, name)
                    local method = real[name]
                    return function(_, key, ...)
                        if failing[name] and key == failing_key then
                            return nil, "no memory"
                        end
                        return method(real, key, ...)
                    end
                end,
            })
        end
    }
};

run_tests();

__DATA__

=== TEST 1: a failed request reported for a target that another worker removed does not bring it back, and leaves no counter
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            -- `b` does not get the removal: its copy still has the target
            we.unregister(b.ev_callback, b.EVENT_SOURCE)
            assert(a:remove_target(ip, 11111, ip))
            assert(wait_until(function() return status(a, 11111) == "nil/target not found" end))

            -- one failed request is enough to mark it unhealthy
            assert(b:report_http_status(ip, 11111, nil, 500, "passive"))
            ngx.sleep(0.3)
            ngx.say("listed=", #healthcheck.get_target_list("testing", "test_shm"),
                    " a=", status(a, 11111), " state=", tostring(shm:get(state_key)),
                    " counter=", tostring(shm:get(key_of(a.TARGET_COUNTER, 11111))))
        }
    }
--- request
GET /t
--- response_body
listed=0 a=nil/target not found state=nil counter=nil
--- no_error_log
[error]



=== TEST 2: set_target_status() for a target that another worker removed writes nothing, not even a counter, raises no event and does not log "forced"
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            we.unregister(b.ev_callback, b.EVENT_SOURCE)
            assert(a:remove_target(ip, 11111, ip))
            assert(wait_until(function() return status(a, 11111) == "nil/target not found" end))

            local events = 0
            local count = function() events = events + 1 end
            we.register(count, a.EVENT_SOURCE)
            local ok = b:set_target_status(ip, 11111, nil, false)
            ngx.sleep(0.3)
            ngx.say(tostring(ok), " state=", tostring(shm:get(state_key)), " events=", events,
                    " counter=", tostring(shm:get(key_of(a.TARGET_COUNTER, 11111))))
        }
    }
--- request
GET /t
--- response_body
true state=nil events=0 counter=nil
--- no_error_log eval
qr/unhealthy forced for|\[error\]/



=== TEST 3: a state change writes the state key of a listed target again after it was evicted
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            shm:delete(state_key)
            assert(a:set_target_status(ip, 11111, nil, false))
            wait_until(function() return status(b, 11111) == "false" end)
            ngx.say("state=", tostring(shm:get(state_key)), " b=", status(b, 11111))
        }
    }
--- request
GET /t
--- response_body
state=2 b=false
--- no_error_log
[error]



=== TEST 4: it is written again as well when the target list was evicted with it
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            shm:delete(state_key)
            shm:delete(a.TARGET_LIST)
            assert(a:set_target_status(ip, 11111, nil, false))
            wait_until(function() return status(b, 11111) == "false" end)
            ngx.say("state=", tostring(shm:get(state_key)), " b=", status(b, 11111))
        }
    }
--- request
GET /t
--- response_body
state=2 b=false
--- no_error_log
[error]



=== TEST 5: re-adding a target inside the purge window keeps the state it has in shm
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            -- another worker marks it unhealthy, and `a` misses that event
            we.unregister(a.ev_callback, a.EVENT_SOURCE)
            assert(b:set_target_status(ip, 11111, nil, false))
            assert(wait_until(function() return status(b, 11111) == "false" end))

            assert(a:delayed_clear(10))
            assert(a:add_target(ip, 11111, nil, true))
            ngx.say("a=", status(a, 11111), " state=", tostring(shm:get(state_key)))
        }
    }
--- request
GET /t
--- response_body
a=true state=2
--- no_error_log
[error]



=== TEST 6: re-adding a target whose state key was evicted fills it in with the status this worker has for it, and raises an event
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            assert(a:set_target_status(ip, 11111, nil, false))
            assert(wait_until(function()
                return status(a, 11111) == "false" and status(b, 11111) == "false"
            end))
            assert(a:delayed_clear(10))
            shm:delete(state_key)

            local events = {}
            we.register(function(_, event) events[#events + 1] = event end, a.EVENT_SOURCE)
            -- the caller says healthy, as callers do by default
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function() return #events > 0 end))
            ngx.sleep(0.1)   -- room for a second event, which must not come
            ngx.say("state=", tostring(shm:get(state_key)), " events=", table.concat(events, ","),
                    " a=", status(a, 11111))
        }
    }
--- request
GET /t
--- response_body
state=2 events=unhealthy a=false
--- no_error_log
[error]


=== TEST 7: a target whose initial state cannot be written is not published
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a = new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            local real = a.shm
            a.shm = failing_shm(real, state_key)
            local ok, err = a:add_target(ip, 11111, nil, true)
            a.shm = real
            ngx.say(tostring(ok), " ", tostring(err), " listed=",
                    #healthcheck.get_target_list("testing", "test_shm"))
        }
    }
--- request
GET /t
--- response_body
nil failed to set initial health status in shm: no memory listed=0
--- no_error_log
[error]



=== TEST 8: a new target whose list write fails leaves no state behind
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a = new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            local real = a.shm
            a.shm = failing_shm(real, a.TARGET_LIST)
            local ok, err = a:add_target(ip, 11111, nil, true)
            a.shm = real
            ngx.say(tostring(ok), " ", tostring(err), " state=", tostring(shm:get(state_key)))
        }
    }
--- request
GET /t
--- response_body
nil failed to store target_list in shm: no memory state=nil
--- no_error_log
[error]



=== TEST 9: set_target_status() announces the state it wrote, and logs "forced", even if resetting the counter fails
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            local real = a.shm
            a.shm = failing_shm(real, key_of(a.TARGET_COUNTER, 11111))
            local ok, err = a:set_target_status(ip, 11111, nil, false)
            a.shm = real
            wait_until(function() return status(b, 11111) == "false" end)
            ngx.say(tostring(ok), " ", tostring(err), " state=", tostring(shm:get(state_key)),
                    " b=", status(b, 11111))
        }
    }
--- request
GET /t
--- response_body
nil no memory state=2 b=false
--- grep_error_log eval
qr/unhealthy forced for \S+ [\d.]+:\d+|\[error\]/
--- grep_error_log_out
unhealthy forced for 127.0.0.1 127.0.0.1:11111



=== TEST 10: set_target_status() deferred to a timer logs "forced" when the state is written, not before
--- http_config eval: $::HttpConfig
--- config
    location = /locked {
        content_by_lua_block {
            -- the target lock is busy for 0.5 s
            local checker = package.loaded.test_checker
            local lock = assert(require("resty.lock"):new("test_shm", { exptime = 0.5, timeout = 0 }))
            assert(lock:lock(key_of(checker.TARGET_LOCK, 11111)))
            -- a collected lock object releases its lock
            package.loaded.test_lock = lock
            ngx.say("locked")
        }
        log_by_lua_block {
            -- this phase cannot yield and the lock is busy: deferred to a timer
            local checker = package.loaded.test_checker
            local ok = checker:set_target_status(ip, 11111, nil, false)
            ngx.log(ngx.WARN, "set_target_status returned ", tostring(ok))
        }
    }
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a = new_checker()
            package.loaded.test_checker = a
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function() return status(a, 11111) == "true" end))

            local sock = ngx.socket.tcp()
            assert(sock:connect("127.0.0.1", ngx.var.server_port))
            assert(sock:send("GET /locked HTTP/1.0\r\nHost: localhost\r\n\r\n"))
            assert(sock:receive("*a"))
            sock:close()

            local done = wait_until(function() return status(a, 11111) == "false" end, 3)
            ngx.log(ngx.WARN, "applied: ", tostring(done))
            ngx.say(tostring(done))
        }
    }
--- request
GET /t
--- response_body
true
--- grep_error_log eval
qr/set_target_status returned \w+|unhealthy forced for|applied: \w+/
--- grep_error_log_out
set_target_status returned scheduled
unhealthy forced for
applied: true
--- timeout: 6



=== TEST 11: re-adding a target inside the purge window raises no event when the state was kept
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            we.unregister(a.ev_callback, a.EVENT_SOURCE)
            assert(b:set_target_status(ip, 11111, nil, false))
            assert(wait_until(function() return status(b, 11111) == "false" end))

            local events = 0
            we.register(function() events = events + 1 end, a.EVENT_SOURCE)
            assert(a:delayed_clear(10))
            assert(a:add_target(ip, 11111, nil, true))
            ngx.sleep(0.3)
            ngx.say("b=", status(b, 11111), " state=", tostring(shm:get(state_key)),
                    " events=", events)
        }
    }
--- request
GET /t
--- response_body
b=false state=2 events=0
--- no_error_log
[error]



=== TEST 12: a re-added target keeps its state when the list write fails
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a = new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function() return status(a, 11111) == "true" end))
            assert(a:set_target_status(ip, 11111, nil, false))
            assert(a:delayed_clear(10))
            local real = a.shm
            a.shm = failing_shm(real, a.TARGET_LIST)
            local ok, err = a:add_target(ip, 11111, nil, true)
            a.shm = real
            ngx.say(tostring(ok), " ", tostring(err), " state=", tostring(shm:get(state_key)),
                    " listed=", #healthcheck.get_target_list("testing", "test_shm"))
        }
    }
--- request
GET /t
--- response_body
nil failed to store target_list in shm: no memory state=2 listed=1
--- no_error_log
[error]



=== TEST 13: a re-added target whose missing state cannot be filled in stays marked for removal
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a = new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function() return status(a, 11111) == "true" end))
            assert(a:delayed_clear(10))
            shm:delete(state_key)
            local real = a.shm
            a.shm = failing_shm(real, state_key, { "add", "set" })
            local ok, err = a:add_target(ip, 11111, nil, true)
            a.shm = real
            local list = healthcheck.get_target_list("testing", "test_shm")
            ngx.say(tostring(ok), " ", tostring(err), " state=", tostring(shm:get(state_key)),
                    " marked=", tostring(list[1].purge_time ~= nil))
        }
    }
--- request
GET /t
--- response_body
nil failed to set initial health status in shm: no memory state=nil marked=true
--- no_error_log
[error]



=== TEST 14: a state that cannot be written is logged and returned as an error, and the other workers are still told
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            local real = a.shm

            -- the state key was evicted and the shm refuses to take it again
            shm:delete(state_key)
            a.shm = failing_shm(real, state_key)
            local ok1, err1 = a:set_target_status(ip, 11111, nil, false)
            a.shm = real
            local told1 = wait_until(function() return status(b, 11111) == "false" end)

            assert(a:set_target_status(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))

            -- the same for a failed request that reaches the threshold
            shm:delete(state_key)
            a.shm = failing_shm(real, state_key)
            local ok2, err2 = a:report_http_status(ip, 11111, nil, 500, "passive")
            a.shm = real
            local told2 = wait_until(function() return status(b, 11111) == "false" end)

            ngx.say(tostring(ok1), " ", tostring(err1), " told=", tostring(told1), "; ",
                    tostring(ok2), " ", tostring(err2), " told=", tostring(told2),
                    "; state=", tostring(shm:get(state_key)))
        }
    }
--- request
GET /t
--- response_body
nil no memory told=true; nil no memory told=true; state=nil
--- grep_error_log eval
qr/failed to write state '\w+' of \S+ [\d.]+:\d+ to shm: no memory/
--- grep_error_log_out
failed to write state 'unhealthy' of 127.0.0.1 127.0.0.1:11111 to shm: no memory
failed to write state 'unhealthy' of 127.0.0.1 127.0.0.1:11111 to shm: no memory



=== TEST 15: a report for a removed target does not bring it back when the same address is still listed under another hostname
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, "one.test", true))
            assert(a:add_target(ip, 11111, "two.test", true))
            assert(wait_until(function()
                return status(a, 11111, "one.test") == "true" and status(a, 11111, "two.test") == "true"
                   and status(b, 11111, "one.test") == "true" and status(b, 11111, "two.test") == "true"
            end))
            we.unregister(b.ev_callback, b.EVENT_SOURCE)
            assert(a:remove_target(ip, 11111, "one.test"))
            assert(wait_until(function()
                return status(a, 11111, "one.test") == "nil/target not found"
            end))
            assert(b:report_http_status(ip, 11111, "one.test", 500, "passive"))
            ngx.sleep(0.3)
            ngx.say("listed=", #healthcheck.get_target_list("testing", "test_shm"),
                    " one=", status(a, 11111, "one.test"),
                    " state=", tostring(shm:get(key_of(a.TARGET_STATE, 11111, "one.test"))),
                    " two=", status(a, 11111, "two.test"))
        }
    }
--- request
GET /t
--- response_body
listed=1 one=nil/target not found state=nil two=true
--- no_error_log
[error]



=== TEST 16: re-adding a target this worker has no status for fills a missing state key from the argument
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a = new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function() return status(a, 11111) == "true" end))
            assert(a:delayed_clear(10))
            shm:delete(state_key)

            -- a checker created now finds the target listed without a state
            local c = new_checker()
            local events = {}
            we.register(function(_, event) events[#events + 1] = event end, c.EVENT_SOURCE)
            assert(c:add_target(ip, 11111, nil, true))
            assert(wait_until(function() return #events > 0 end))
            ngx.sleep(0.1)   -- room for a second event, which must not come
            ngx.say("state=", tostring(shm:get(state_key)), " events=", table.concat(events, ","))
        }
    }
--- request
GET /t
--- response_body
state=1 events=healthy
--- no_error_log
[error]



=== TEST 17: a target added again does not inherit a counter left by a report made after it was removed
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            -- three failed requests mark a target unhealthy
            local a, b = new_checker(3), new_checker(3)
            local state_key = key_of(a.TARGET_STATE, 11111)
            local counter_key = key_of(a.TARGET_COUNTER, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            assert(b:report_http_status(ip, 11111, nil, 500, "passive"))
            assert(wait_until(function()
                return b.targets[1].internal_health == "mostly_healthy"
            end))

            -- `b` does not get the removal, and counts one more failure for
            -- the target: no state changes, so nothing tells it of the removal
            we.unregister(b.ev_callback, b.EVENT_SOURCE)
            assert(a:remove_target(ip, 11111, ip))
            assert(wait_until(function() return status(a, 11111) == "nil/target not found" end))
            assert(b:report_http_status(ip, 11111, nil, 500, "passive"))
            local left = shm:get(counter_key) ~= nil

            assert(a:add_target(ip, 11111, nil, true))
            local after_add = shm:get(counter_key)
            assert(wait_until(function() return status(a, 11111) == "true" end))
            -- two failures since it was added: one short of the threshold
            assert(a:report_http_status(ip, 11111, nil, 500, "passive"))
            assert(a:report_http_status(ip, 11111, nil, 500, "passive"))
            ngx.say("left=", tostring(left), " after_add=", tostring(after_add),
                    " state=", tostring(shm:get(state_key)))
        }
    }
--- request
GET /t
--- response_body
left=true after_add=nil state=3
--- no_error_log
[error]
