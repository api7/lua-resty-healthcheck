use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * blocks() * 3;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict other_shm 8m;
    lua_shared_dict my_worker_events 8m;

    init_by_lua_block {
        _G.__TESTING_HEALTHCHECKER = true
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

        -- The library takes its references to ngx.sleep and ngx.timer.every
        -- when it is loaded, which is in the first new_checker() of a test.
        -- `yield_hook = { cond = f, fn = g }` calls g() the next time the
        -- library yields (ngx.sleep(0)) while f() holds.
        -- With `sleep_log = {}` every sleep is noted there.
        local real_sleep = ngx.sleep
        ngx.sleep = function(seconds)
            if sleep_log then
                sleep_log[#sleep_log + 1] = seconds
            end
            local hook = yield_hook
            if hook and seconds == 0 and hook.cond() then
                yield_hook = nil
                hook.fn()
            end
            return real_sleep(seconds)
        end

        -- the reconcile timer is not started: the test makes each of its runs
        -- with _reconcile(). To be called before the first new_checker().
        function no_reconcile_timer()
            ngx.timer.every = function() return true end
        end

        function events()
            local we = require "resty.worker.events"
            if not worker_events_configured then
                assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
                worker_events_configured = true
            end
            return we
        end

        -- two checkers with the same name stand for the checkers of two
        -- workers: each has its own copy of the targets
        function new_checker(name, shm_name)
            events()
            return assert(require("resty.healthcheck").new({
                name = name or "testing",
                shm_name = shm_name or "test_shm",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            }))
        end

        function status(checker, port)
            local ok, err = checker:get_target_status(ip, port)
            return tostring(ok) .. (err and ("/" .. err) or "")
        end

        function key_of(prefix, port)
            return prefix .. ":" .. ip .. ":" .. port .. ":" .. ip
        end

        -- runs fn() with the events it raises lost: no worker gets them
        function lose_events(fn)
            local we = events()
            local post = we.post
            we.post = function() return true end
            local ok, err = pcall(fn)
            we.post = post
            assert(ok, err)
        end

        -- runs fn() with the events it raises held back; returns a function
        -- that sends them, and the events
        function hold_events(fn)
            local we = events()
            local post = we.post
            local held = {}
            we.post = function(source, event, data)
                held[#held + 1] = { source, event, data }
                return true
            end
            local ok, err = pcall(fn)
            we.post = post
            assert(ok, err)
            return function()
                for _, e in ipairs(held) do
                    post(e[1], e[2], e[3])
                end
            end, held
        end

        -- returns when the events posted so far have been dispatched
        local flush_seq = 0
        function flush_events()
            local we = events()
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

        -- the counters of the reconciliation: a copy, and what was added to
        -- one of them since that copy
        function stats()
            local copy = {}
            for k, v in pairs(require("resty.healthcheck")._reconcile_stats()) do
                copy[k] = v
            end
            return copy
        end

        function since(before, key)
            return require("resty.healthcheck")._reconcile_stats()[key] - before[key]
        end
    }
};

run_tests();

__DATA__

=== TEST 1: a status change whose event is lost is corrected by the timer, in every copy
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            local ver = b.status_ver
            lose_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            -- correcting a copy raises no event
            local raised = 0
            events().register(function() raised = raised + 1 end, a.EVENT_SOURCE)
            local ok = wait_until(function()
                return status(a, 11111) == "false" and status(b, 11111) == "false"
            end, 1)
            ngx.sleep(0.3)
            -- what was raised until now has been dispatched
            flush_events()
            ngx.say(tostring(ok), " a=", status(a, 11111), " b=", status(b, 11111),
                    " status_ver+", b.status_ver - ver, " events=", raised)
        }
    }
--- request
GET /t
--- response_body
true a=false b=false status_ver+1 events=0
--- error_log
reconciled 1 target(s) with shm



=== TEST 2: a target added or removed with the event lost shows up, or goes, with its state in shm
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            local ver = b.status_ver
            lose_events(function()
                assert(a:add_target(ip, 44444, nil, false))
                assert(a:remove_target(ip, 11111, ip))
            end)
            local gone = "nil/target not found"
            local ok = wait_until(function()
                return status(a, 11111) == gone and status(b, 11111) == gone
                   and status(a, 44444) == "false" and status(b, 44444) == "false"
            end, 1)
            -- one for the target that came, one for the removal
            ngx.say(tostring(ok), " 11111=", status(b, 11111), " 44444=", status(b, 44444),
                    " targets=", #b.targets, " status_ver+", b.status_ver - ver)
        }
    }
--- request
GET /t
--- response_body
true 11111=nil/target not found 44444=false targets=3 status_ver+2
--- no_error_log
[error]



=== TEST 3: a clear() whose event is lost empties the other copies, and what follows is applied
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            lose_events(function()
                assert(a:clear())
            end)
            local cleared = wait_until(function() return #b.targets == 0 end, 1)
            assert(a:add_target(ip, 44444, nil, true))
            local added = wait_until(function()
                return status(a, 44444) == "true" and status(b, 44444) == "true"
            end, 1)
            ngx.say(tostring(cleared), " ", tostring(added), " targets=", #b.targets)
        }
    }
--- request
GET /t
--- response_body
true true targets=1
--- no_error_log
[error]



=== TEST 4: a stopped checker is not compared
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            require("resty.healthcheck")._set_sweep(1000, 1)   -- every checker, on every run
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            b:stop()
            lose_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            assert(wait_until(function() return status(a, 11111) == "false" end, 1))
            ngx.sleep(0.4)
            ngx.say(status(b, 11111))
        }
    }
--- request
GET /t
--- response_body
true
--- no_error_log
[error]



=== TEST 5: the background comparison repairs a change that no version announced
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            require("resty.healthcheck")._set_sweep(1000, 1)   -- every checker, on every run
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            -- as a worker that still runs an older version of this module
            -- leaves it, when its event is lost: a state, no version
            assert(shm:set(key_of(a.TARGET_STATE, 11111), 2))
            local ok = wait_until(function()
                return status(a, 11111) == "false" and status(b, 11111) == "false"
            end, 1)
            ngx.say(tostring(ok))
        }
    }
--- request
GET /t
--- response_body
true
--- no_error_log
[error]



=== TEST 6: a comparison that fails is tried again on the next runs, and logged once
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local a = new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function() return status(a, 11111) == "true" end))
            -- the next three reads of the target list fail
            local real, failures = a.shm, 3
            a.shm = setmetatable({}, {
                __index = function(_, name)
                    local method = real[name]
                    return function(_, key, ...)
                        if name == "get" and key == a.TARGET_LIST and failures > 0 then
                            failures = failures - 1
                            return nil, "boom"
                        end
                        return method(real, key, ...)
                    end
                end,
            })
            lose_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            local ok = wait_until(function() return status(a, 11111) == "false" end, 2)
            ngx.say(tostring(ok), " failures left=", failures)
        }
    }
--- request
GET /t
--- response_body
true failures left=0
--- grep_error_log eval
qr/failed to reconcile targets with shm \([^)]*\): .*boom/
--- grep_error_log_out
failed to reconcile targets with shm (it is tried again on every run of the timer): failed to fetch target_list from shm: boom



=== TEST 7: a reconcile timer that could not be created is created by the next new()
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local every, failed = ngx.timer.every, false
            ngx.timer.every = function(...)
                if not failed then
                    failed = true
                    return nil, "no timers"
                end
                return every(...)
            end
            local a = new_checker()
            local b = new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            lose_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            local ok = wait_until(function()
                return status(a, 11111) == "false" and status(b, 11111) == "false"
            end, 1)
            ngx.say(tostring(failed), " ", tostring(ok))
        }
    }
--- request
GET /t
--- response_body
true true
--- error_log
could not start the reconcile timer: no timers



=== TEST 8: version keys evicted from the shm are made again from the time, and changes keep being noticed
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            local shm_version = "lua-resty-healthcheck::shm_version"
            ngx.sleep(0.01)   -- the keys are made again from a later time
            shm:delete(a.TARGET_VERSION)
            shm:delete(shm_version)
            lose_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            local lost = wait_until(function()
                return status(a, 11111) == "false" and status(b, 11111) == "false"
            end, 1)
            assert(a:set_target_status(ip, 11111, nil, true))
            local delivered = wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end, 1)
            ngx.say(tostring(lost), " ", tostring(delivered), " ",
                    tostring(shm:get(a.TARGET_VERSION) > 1e12), " ",
                    tostring(shm:get(shm_version) > 1e12))
        }
    }
--- request
GET /t
--- response_body
true true true true
--- no_error_log
[error]



=== TEST 9: the timer runs every 0.1 s
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local interval
            ngx.timer.every = function(delay)
                interval = delay
                return true
            end
            new_checker()
            ngx.say(tostring(interval))
        }
    }
--- request
GET /t
--- response_body
0.1
--- no_error_log
[error]



=== TEST 10: an event of the checker that has the same name in another shm is not applied
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            -- created first, so that the versions of the other shm are ahead
            -- of its own: an event from there is not taken for a late one
            local c = new_checker("testing", "other_shm")
            assert(c:add_target(ip, 11111, nil, true))
            flush_events()
            ngx.sleep(0.02)
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            flush_events()
            healthcheck._reconcile()
            local before = stats()
            assert(a:set_target_status(ip, 11111, nil, false))
            flush_events()
            ngx.say("a=", status(a, 11111), " b=", status(b, 11111), " c=", status(c, 11111))
            healthcheck._reconcile()
            ngx.say("compared=", since(before, "compared"))
        }
    }
--- request
GET /t
--- response_body
a=false b=false c=true
compared=0
--- no_error_log
[error]



=== TEST 11: a checker whose targets are not loaded yet takes an event and a run of the timer without an error
--- http_config eval: $::HttpConfig
--- config
    location = /locked {
        content_by_lua_block {
            -- the target list is locked until the test unlocks it
            local lock = assert(require("resty.lock"):new("test_shm", { exptime = 5, timeout = 0 }))
            assert(lock:lock(package.loaded.list_lock_key))
            package.loaded.list_lock = lock
            ngx.say("locked")
        }
        log_by_lua_block {
            -- this phase cannot yield and the list is locked: new() leaves
            -- the load of the targets to a timer
            package.loaded.deferred = new_checker()
        }
    }
    location = /t {
        content_by_lua_block {
            local a = new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function() return status(a, 11111) == "true" end))
            package.loaded.list_lock_key = a.TARGET_LIST_LOCK

            local sock = ngx.socket.tcp()
            assert(sock:connect("127.0.0.1", ngx.var.server_port))
            assert(sock:send("GET /locked HTTP/1.0\r\nHost: localhost\r\n\r\n"))
            assert(sock:receive("*a"))
            sock:close()
            assert(wait_until(function() return package.loaded.deferred end))
            local c = package.loaded.deferred
            local loaded = c.targets ~= nil

            -- an event for it, and runs of the timer, before its targets are loaded
            assert(a:set_target_status(ip, 11111, nil, false))
            ngx.sleep(0.25)
            local still = c.targets ~= nil
            assert(package.loaded.list_lock:unlock())
            local ok = wait_until(function()
                return c.targets ~= nil and status(c, 11111) == "false"
            end, 3)
            ngx.say("loaded=", tostring(loaded), ",", tostring(still), " then ", tostring(ok))
        }
    }
--- request
GET /t
--- response_body
loaded=false,false then true
--- no_error_log
[error]
