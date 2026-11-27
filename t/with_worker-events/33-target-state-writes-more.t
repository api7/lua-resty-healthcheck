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

        -- returns when the events posted so far have been dispatched: the
        -- events of a worker are dispatched in the order they were posted
        local flush_seq = 0
        function flush_events()
            local we = require "resty.worker.events"
            flush_seq = flush_seq + 1
            local seq, seen = flush_seq, false
            local callback = function(data)
                if data == seq then
                    seen = true
                end
            end
            we.register(callback, "test-flush", "marker")
            we.post("test-flush", "marker", seq)
            local ok = wait_until(function()
                we.poll()
                return seen
            end)
            we.unregister(callback, "test-flush", "marker")
            assert(ok, "the events were not dispatched")
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
        function failing_shm(real, failing_key, methods, delete_on_failure)
            local failing = {}
            for _, name in ipairs(methods or { "set" }) do
                failing[name] = true
            end
            return setmetatable({}, {
                __index = function(_, name)
                    local method = real[name]
                    return function(_, key, ...)
                        if failing[name] and key == failing_key then
                            if delete_on_failure then
                                method(real, key, nil)
                            end
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

=== TEST 1: set_target_status() whose state cannot be written tells the other workers, logs the failure before "forced", and resets the counter
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local shm = ngx.shared.test_shm
            local a, b = new_checker(3), new_checker(3)
            local state_key = key_of(a.TARGET_STATE, 11111)
            local counter_key = key_of(a.TARGET_COUNTER, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            assert(a:report_http_status(ip, 11111, nil, 500, "passive"))
            assert(wait_until(function()
                return a.targets[1].internal_health == "mostly_healthy"
                   and b.targets[1].internal_health == "mostly_healthy"
            end))
            local before = shm:get(counter_key)
            shm:delete(state_key)
            local real = a.shm
            a.shm = failing_shm(real, state_key)
            local ok, err = a:set_target_status(ip, 11111, nil, false)
            a.shm = real
            local told = wait_until(function() return status(b, 11111) == "false" end)
            ngx.say(tostring(ok), " ", tostring(err), " told=", tostring(told),
                    " counter=", tostring(before), "->", tostring(shm:get(counter_key)),
                    " state=", tostring(shm:get(state_key)),
                    " a=", tostring(a.targets[1].internal_health))
        }
    }
--- request
GET /t
--- response_body
nil no memory told=true counter=256->0 state=nil a=unhealthy
--- grep_error_log eval
qr/unhealthy forced for \S+ [\d.]+:\d+|failed to write state '\w+'/
--- grep_error_log_out
failed to write state 'unhealthy'
unhealthy forced for 127.0.0.1 127.0.0.1:11111



=== TEST 2: re-adding a target whose state key was evicted fills it in with the exact status this worker has, and keeps its counter
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local shm = ngx.shared.test_shm
            local a, b = new_checker(3), new_checker(3)
            local state_key = key_of(a.TARGET_STATE, 11111)
            local counter_key = key_of(a.TARGET_COUNTER, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            assert(a:report_http_status(ip, 11111, nil, 500, "passive"))
            assert(wait_until(function()
                return a.targets[1].internal_health == "mostly_healthy"
                   and b.targets[1].internal_health == "mostly_healthy"
            end))
            assert(a:delayed_clear(10))
            shm:delete(state_key)
            local events = {}
            we.register(function(_, event) events[#events + 1] = event end, a.EVENT_SOURCE)
            assert(a:add_target(ip, 11111, nil, true))
            wait_until(function() return #events > 0 end)
            flush_events()   -- a second event, which must not come, would have arrived
            ngx.say("state=", tostring(shm:get(state_key)), " events=", table.concat(events, ","),
                    " counter=", tostring(shm:get(counter_key)))
        }
    }
--- request
GET /t
--- response_body
state=3 events=mostly_healthy counter=256
--- no_error_log
[error]



=== TEST 3: re-adding a target inside the purge window keeps its counter
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local shm = ngx.shared.test_shm
            local a = new_checker(3)
            local state_key = key_of(a.TARGET_STATE, 11111)
            local counter_key = key_of(a.TARGET_COUNTER, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function() return status(a, 11111) == "true" end))
            assert(a:report_http_status(ip, 11111, nil, 500, "passive"))
            assert(a:report_http_status(ip, 11111, nil, 500, "passive"))
            assert(wait_until(function()
                return a.targets[1].internal_health == "mostly_healthy"
            end))
            assert(a:delayed_clear(10))
            assert(a:add_target(ip, 11111, nil, true))
            local kept = shm:get(counter_key)
            -- the third failure since it was first added reaches the threshold
            assert(a:report_http_status(ip, 11111, nil, 500, "passive"))
            ngx.say("counter=", tostring(kept), " state=", tostring(shm:get(state_key)))
        }
    }
--- request
GET /t
--- response_body
counter=512 state=2
--- no_error_log
[error]



=== TEST 4: set_target_status() for a target that another worker removed creates no counter, and says so at debug level
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local counter_key = key_of(a.TARGET_COUNTER, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            we.unregister(b.ev_callback, b.EVENT_SOURCE)
            assert(a:remove_target(ip, 11111, ip))
            assert(wait_until(function() return status(a, 11111) == "nil/target not found" end))
            local ok = b:set_target_status(ip, 11111, nil, false)
            ngx.say(tostring(ok), " counter=", tostring(shm:get(counter_key)))
        }
    }
--- request
GET /t
--- response_body
true counter=nil
--- grep_error_log eval
qr/not setting the status of a target that was removed: \S+ [\d.]+:\d+/
--- grep_error_log_out
not setting the status of a target that was removed: 127.0.0.1 127.0.0.1:11111



=== TEST 5: a report for a removed target says so at debug level
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            we.unregister(b.ev_callback, b.EVENT_SOURCE)
            assert(a:remove_target(ip, 11111, ip))
            assert(wait_until(function() return status(a, 11111) == "nil/target not found" end))
            ngx.say(tostring(b:report_http_status(ip, 11111, nil, 500, "passive")))
        }
    }
--- request
GET /t
--- response_body
true
--- grep_error_log eval
qr/not changing the state of a target that was removed: \S+ [\d.]+:\d+/
--- grep_error_log_out
not changing the state of a target that was removed: 127.0.0.1 127.0.0.1:11111



=== TEST 6: successful state replacement does not read the target list
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local a = new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function() return status(a, 11111) == "true" end))
            local reads, real = 0, a.shm
            -- Count reads without changing any shared dictionary operation.
            local counted = setmetatable({}, {
                __index = function(_, name)
                    return function(_, key, ...)
                        if name == "get" and key == a.TARGET_LIST then
                            reads = reads + 1
                        end
                        return real[name](real, key, ...)
                    end
                end,
            })
            a.shm = counted
            assert(a:set_target_status(ip, 11111, nil, false))
            a.shm = real
            assert(wait_until(function() return status(a, 11111) == "false" end))
            ngx.say("forced target_list reads=", reads)

            assert(a:set_target_status(ip, 11111, nil, true))
            assert(wait_until(function() return status(a, 11111) == "true" end))
            reads = 0
            a.shm = counted
            assert(a:report_http_status(ip, 11111, nil, 500, "passive"))
            a.shm = real
            assert(wait_until(function() return status(a, 11111) == "false" end))
            ngx.say("report target_list reads=", reads)
        }
    }
--- request
GET /t
--- response_body
forced target_list reads=0
report target_list reads=0
--- no_error_log
[error]




=== TEST 7: reconstructing a lost list keeps the newer shared state and the transition counter
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            local shm = ngx.shared.test_shm
            local a, b = new_checker(3), new_checker(3)
            local state_key = key_of(a.TARGET_STATE, 11111)
            local counter_key = key_of(a.TARGET_COUNTER, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))

            we.unregister(b.ev_callback, b.EVENT_SOURCE)
            assert(a:report_http_status(ip, 11111, nil, 500, "passive"))
            assert(wait_until(function()
                return a.targets[1].internal_health == "mostly_healthy"
            end))
            assert(b.targets[1].internal_health == "healthy")
            shm:delete(a.TARGET_LIST)

            we.register(b.ev_callback, b.EVENT_SOURCE)
            assert(b:add_target(ip, 11111, nil, true))
            flush_events()
            ngx.say("state=", shm:get(state_key), " counter=", shm:get(counter_key),
                    " a=", a.targets[1].internal_health,
                    " b=", b.targets[1].internal_health)
        }
    }
--- request
GET /t
--- response_body
state=3 counter=256 a=mostly_healthy b=mostly_healthy
--- no_error_log
lua entry thread aborted



=== TEST 8: removing a local ghost lets a later addition start with the caller's default
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            local counter_key = key_of(a.TARGET_COUNTER, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
                       and status(a, 22222) == "true" and status(b, 22222) == "true"
            end))
            assert(a:set_target_status(ip, 11111, nil, false))
            assert(wait_until(function()
                return status(a, 11111) == "false" and status(b, 11111) == "false"
            end))

            local real = a.shm
            a.shm = failing_shm(real, a.TARGET_LIST, { "set" }, true)
            local ok, err = a:remove_target(ip, 11111, ip)
            a.shm = real
            assert(ok == nil and err == "failed to store target_list in shm: no memory")
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:remove_target(ip, 11111, ip))
            flush_events()
            local removed = status(a, 11111)
            assert(status(b, 11111) == "nil/target not found")
            assert(shm:get(state_key) == nil)
            assert(shm:get(counter_key) == nil)

            local initial = a:get_target_status(ip, 11111)
            if initial == nil then
                initial = true
            end
            assert(a:add_target(ip, 11111, nil, initial))
            flush_events()
            assert(status(b, 11111) == "true")
            ngx.say("removed=", removed, " readded=", status(a, 11111),
                    " other=", status(a, 22222))
        }
    }
--- request
GET /t
--- response_body
removed=nil/target not found readded=true other=true
--- no_error_log
lua entry thread aborted



=== TEST 9: a failed list reconstruction does not delete a state that already existed
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local shm = ngx.shared.test_shm
            local a = new_checker(3)
            local state_key = key_of(a.TARGET_STATE, 11111)
            local counter_key = key_of(a.TARGET_COUNTER, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function() return status(a, 11111) == "true" end))
            assert(a:report_http_status(ip, 11111, nil, 500, "passive"))
            assert(wait_until(function()
                return a.targets[1].internal_health == "mostly_healthy"
            end))
            shm:delete(a.TARGET_LIST)

            local real = a.shm
            a.shm = failing_shm(real, a.TARGET_LIST)
            local ok, err = a:add_target(ip, 11111, nil, true)
            a.shm = real
            assert(ok == nil and err == "failed to store target_list in shm: no memory")
            ngx.say("state=", shm:get(state_key), " counter=", shm:get(counter_key))
        }
    }
--- request
GET /t
--- response_body
state=3 counter=256
--- no_error_log
lua entry thread aborted




=== TEST 10: remove_target with the hostname omitted removes a listed target everywhere
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            local counter_key = key_of(a.TARGET_COUNTER, 11111)
            assert(a:add_target(ip, 11111, nil, false))
            assert(wait_until(function()
                return status(a, 11111) == "false" and status(b, 11111) == "false"
            end))
            assert(a:remove_target(ip, 11111))
            flush_events()
            local c = new_checker()
            ngx.say("listed=", #require("resty.healthcheck").get_target_list("testing", "test_shm"),
                    " state=", tostring(shm:get(state_key)),
                    " counter=", tostring(shm:get(counter_key)),
                    " a=", status(a, 11111), " b=", status(b, 11111),
                    " c=", status(c, 11111))
        }
    }
--- request
GET /t
--- response_body
listed=0 state=nil counter=nil a=nil/target not found b=nil/target not found c=nil/target not found
--- no_error_log
lua entry thread aborted



=== TEST 11: a health report cannot overtake reconstruction with an older state
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            shm:delete(a.TARGET_LIST)

            local report_done = false
            local triggered = false
            local real = b.shm
            b.shm = setmetatable({}, {
                __index = function(_, name)
                    local method = real[name]
                    return function(_, key, ...)
                        if name == "get" and key == state_key and not triggered then
                            triggered = true
                            local value, err = method(real, key, ...)
                            assert(ngx.timer.at(0, function()
                                local ok, report_err = a:set_target_status(ip, 11111, nil, false)
                                assert(ok, report_err)
                                report_done = true
                            end))
                            ngx.sleep(0.2)
                            return value, err
                        end
                        return method(real, key, ...)
                    end
                end,
            })
            assert(b:add_target(ip, 11111, nil, true))
            b.shm = real
            assert(wait_until(function() return report_done end))
            flush_events()
            ngx.say("shared=", shm:get(state_key), " a=", status(a, 11111),
                    " b=", status(b, 11111))
        }
    }
--- request
GET /t
--- response_body
shared=2 a=false b=false
--- no_error_log
lua entry thread aborted
--- timeout: 15



=== TEST 12: a health report cannot overtake a ghost removal
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            shm:delete(a.TARGET_LIST)

            local report_started = false
            local raise_event = b.raise_event
            b.raise_event = function(self, event, ...)
                if event == self.events.unhealthy then
                    report_started = true
                    ngx.sleep(0.2)
                end
                return raise_event(self, event, ...)
            end
            assert(ngx.timer.at(0, function()
                assert(b:set_target_status(ip, 11111, nil, false))
            end))
            assert(wait_until(function() return report_started end))
            local ok, err = a:remove_target(ip, 11111, ip)
            assert(ok, err)
            flush_events()
            ngx.say("listed=", #require("resty.healthcheck").get_target_list("testing", "test_shm"),
                    " state=", tostring(shm:get(state_key)),
                    " a=", status(a, 11111), " b=", status(b, 11111))
        }
    }
--- request
GET /t
--- response_body
listed=0 state=nil a=nil/target not found b=nil/target not found
--- no_error_log
lua entry thread aborted
--- timeout: 15



=== TEST 13: eviction between add and get does not publish a target without state
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local shm = ngx.shared.test_shm
            local a = new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function() return status(a, 11111) == "true" end))
            shm:delete(a.TARGET_LIST)

            local triggered = false
            local real = a.shm
            a.shm = setmetatable({}, {
                __index = function(_, name)
                    local method = real[name]
                    return function(_, key, ...)
                        if name == "get" and key == state_key and not triggered then
                            triggered = true
                            real:delete(state_key)
                        end
                        return method(real, key, ...)
                    end
                end,
            })
            local ok, err = a:add_target(ip, 11111, nil, true)
            a.shm = real
            ngx.say("ok=", tostring(ok), " err=", tostring(err),
                    " listed=", #require("resty.healthcheck").get_target_list("testing", "test_shm"),
                    " state=", tostring(shm:get(state_key)))
        }
    }
--- request
GET /t
--- response_body
ok=nil err=initial health status disappeared from shm listed=0 state=nil
--- no_error_log
lua entry thread aborted



=== TEST 14: a new checker rebuilding a lost list keeps the shared state and counter
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local shm = ngx.shared.test_shm
            local a = new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            local counter_key = key_of(a.TARGET_COUNTER, 11111)
            assert(a:add_target(ip, 11111))
            flush_events()
            assert(a:report_http_status(ip, 11111, nil, 500, "passive"))
            flush_events()
            assert(status(a, 11111) == "false")

            -- Leave older entries for the allocator to evict during replacement.
            for i = 1, 100 do
                assert(shm:set("filler-" .. i, i))
            end
            assert(shm:get(state_key) == 2 and shm:get(counter_key) == 256)
            local ok, err = shm:set(a.TARGET_LIST, string.rep("x", shm:capacity() + 1))
            assert(not ok and err == "no memory")
            assert(shm:get(a.TARGET_LIST) == nil)

            local b = new_checker()
            assert(b:get_target_status(ip, 11111) == nil)
            assert(shm:get(state_key) == 2 and shm:get(counter_key) == 256)
            assert(b:add_target(ip, 11111, nil, true))
            flush_events()
            ngx.say("state=", shm:get(state_key), " counter=", shm:get(counter_key),
                    " a=", status(a, 11111), " b=", status(b, 11111))
        }
    }
--- request
GET /t
--- response_body
state=2 counter=256 a=false b=false
--- no_error_log
lua entry thread aborted
