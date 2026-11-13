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
            ngx.sleep(0.2)
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
