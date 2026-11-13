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

=== TEST 1: a comparison that throws leaves the other checkers compared in that run, and is tried again on the next
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local N = 6
            local owners, copies, thrown = {}, {}, 0
            for i = 1, N do
                owners[i] = new_checker("checker-" .. i)
                copies[i] = new_checker("checker-" .. i)
                assert(owners[i]:add_target(ip, 11111, nil, true))
            end
            flush_events()
            healthcheck._reconcile()
            lose_events(function()
                for i = 1, N do
                    assert(owners[i]:set_target_status(ip, 11111, nil, false))
                end
            end)
            -- the comparison of each copy throws once: on the read that
            -- follows the look at its version
            for i = 1, N do
                local c = copies[i]
                local real, reads = c.shm, 0
                c.shm = setmetatable({}, {
                    __index = function(_, name)
                        local method = real[name]
                        return function(_, key, ...)
                            if name == "get" and key == c.TARGET_VERSION then
                                reads = reads + 1
                                if reads == 2 then
                                    thrown = thrown + 1
                                    error("boom")
                                end
                            end
                            return method(real, key, ...)
                        end
                    end,
                })
            end
            healthcheck._reconcile()
            local first, owners_ok, fixed = thrown, 0, 0
            for i = 1, N do
                if status(owners[i], 11111) == "false" then
                    owners_ok = owners_ok + 1
                end
            end
            healthcheck._reconcile()
            for i = 1, N do
                if status(copies[i], 11111) == "false" then
                    fixed = fixed + 1
                end
            end
            ngx.say("thrown in the first run=", first, " owners compared in the first run=", owners_ok,
                    " copies corrected after the second=", fixed)
        }
    }
--- request
GET /t
--- response_body
thrown in the first run=6 owners compared in the first run=6 copies corrected after the second=6
--- grep_error_log eval
qr/failed to reconcile targets with shm \(it is tried again on every run of the timer\)/
--- grep_error_log_out
failed to reconcile targets with shm (it is tried again on every run of the timer)
failed to reconcile targets with shm (it is tried again on every run of the timer)
failed to reconcile targets with shm (it is tried again on every run of the timer)
failed to reconcile targets with shm (it is tried again on every run of the timer)
failed to reconcile targets with shm (it is tried again on every run of the timer)
failed to reconcile targets with shm (it is tried again on every run of the timer)



=== TEST 2: events that arrive after their changes were compared are ignored, and nothing is compared again for them
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            healthcheck._reconcile()
            local send = hold_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
                assert(a:set_target_status(ip, 22222, nil, false))
            end)
            sleep_log = {}
            healthcheck._reconcile()
            -- what that run waited for: the 5 ms, and nothing else
            local waits = {}
            for _, seconds in ipairs(sleep_log) do
                if seconds > 0 then
                    waits[#waits + 1] = seconds
                end
            end
            sleep_log = nil
            local compared = status(b, 11111) .. "," .. status(b, 22222)
            send()
            flush_events()
            local before = stats()
            healthcheck._reconcile()
            ngx.say(compared, " waits=", table.concat(waits, ","), " scans=", since(before, "scans"),
                    " compared=", since(before, "compared"))
        }
    }
--- request
GET /t
--- response_body
false,false waits=0.005 scans=0 compared=0
--- no_error_log
[error]



=== TEST 3: a comparison that keeps failing is logged once a minute, and a failure that follows a success is logged
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local a = new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            flush_events()
            healthcheck._reconcile()
            -- reads of the target list fail when `fail` is set
            local real, fail = a.shm, nil
            a.shm = setmetatable({}, {
                __index = function(_, name)
                    local method = real[name]
                    return function(_, key, ...)
                        if name == "get" and key == a.TARGET_LIST and fail then
                            return nil, fail
                        end
                        return method(real, key, ...)
                    end
                end,
            })
            lose_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            fail = "boom-1"
            healthcheck._reconcile()
            fail = "boom-2"                        -- within the minute: not logged
            healthcheck._reconcile()
            a.sync_error_logged = ngx.now() - 61   -- as a minute later
            fail = "boom-3"
            healthcheck._reconcile()
            fail = nil
            healthcheck._reconcile()
            local recovered = status(a, 11111)
            lose_events(function()
                assert(a:set_target_status(ip, 11111, nil, true))
            end)
            fail = "boom-4"                        -- after a success: a new failure
            healthcheck._reconcile()
            fail = nil
            healthcheck._reconcile()
            ngx.say("recovered=", recovered, " end=", status(a, 11111))
        }
    }
--- request
GET /t
--- response_body
recovered=false end=true
--- grep_error_log eval
qr/boom-\d/
--- grep_error_log_out
boom-1
boom-3
boom-4



=== TEST 4: the event of a change is applied when it comes after a comparison that could not read the state of its target
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            -- from here on the statuses are compared, not the members
            lose_events(function()
                assert(a:set_target_status(ip, 33333, nil, false))
            end)
            healthcheck._reconcile()
            local send = hold_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            -- as evicted from a full shm
            shm:delete(key_of(a.TARGET_STATE, 11111))
            local before = stats()
            healthcheck._reconcile()
            local kept = status(b, 11111)
            send()
            flush_events()
            ngx.say("members compared=", since(before, "members"), " kept=", kept,
                    " after the late event=", status(b, 11111),
                    " version_applied=", tostring(b.version_applied))
        }
    }
--- request
GET /t
--- response_body
members compared=0 kept=true after the late event=false version_applied=nil
--- no_error_log
[error]



=== TEST 5: while shm cannot tell the state of a target, its events are applied in the order of its changes
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            healthcheck._reconcile()
            local _, held = hold_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
                assert(a:set_target_status(ip, 11111, nil, true))
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            -- as evicted from a full shm
            shm:delete(key_of(a.TARGET_STATE, 11111))
            healthcheck._reconcile()
            local kept = status(b, 11111)
            -- the event of the last change arrives first
            local we = events()
            for _, i in ipairs({ 3, 1, 2 }) do
                we.post(held[i][1], held[i][2], held[i][3])
                flush_events()
            end
            healthcheck._reconcile()
            ngx.say("kept=", kept, " end=", status(b, 11111), " owner=", status(a, 11111))
        }
    }
--- request
GET /t
--- response_body
kept=true end=false owner=false
--- no_error_log
[error]



=== TEST 6: a late event does not put back the status of a target whose state was read, in a comparison that could not read another
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            healthcheck._reconcile()
            local we = events()
            local out = {}
            -- the first comparison is one of the members, the second one of
            -- the statuses
            for round, port in ipairs({ 22222, 33333 }) do
                local _, held = hold_events(function()
                    assert(a:set_target_status(ip, port, nil, false))
                    assert(a:set_target_status(ip, port, nil, true))
                end)
                -- as evicted from a full shm
                shm:delete(key_of(a.TARGET_STATE, 11111))
                local before = stats()
                healthcheck._reconcile()
                local ver = b.status_ver
                -- the first of the two events arrives, the second is lost
                we.post(held[1][1], held[1][2], held[1][3])
                flush_events()
                out[round] = "members=" .. since(before, "members") .. " " .. status(b, port)
                             .. " status_ver+" .. (b.status_ver - ver)
            end
            ngx.say(table.concat(out, "; "))
        }
    }
--- request
GET /t
--- response_body
members=2 true status_ver+0; members=0 true status_ver+0
--- no_error_log
[error]



=== TEST 7: without the list, the event of a target that was added is applied when it comes after the comparison
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            healthcheck._reconcile()
            local send = hold_events(function()
                assert(a:add_target(ip, 44444, nil, true))
            end)
            -- as evicted from a full shm
            shm:delete(a.TARGET_LIST)
            healthcheck._reconcile()
            local kept = #b.targets .. " " .. status(b, 44444)
            send()
            flush_events()
            ngx.say("after the comparison: ", kept, "; after the late event: ", #b.targets, " ",
                    status(b, 44444))
        }
    }
--- request
GET /t
--- response_body
after the comparison: 3 nil/target not found; after the late event: 4 true
--- no_error_log
[error]



=== TEST 8: once a comparison reads everything again, late events are ignored again
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            healthcheck._reconcile()
            lose_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            -- as evicted from a full shm
            shm:delete(key_of(a.TARGET_STATE, 11111))
            healthcheck._reconcile()
            local unset = b.version_applied == nil
            -- until then, the run that follows an event compares the checker
            assert(a:set_target_status(ip, 22222, nil, false))
            flush_events()
            local before = stats()
            healthcheck._reconcile()
            local unread = since(before, "compared")
            -- the next change of the target writes its state again
            assert(a:set_target_status(ip, 11111, nil, false))
            flush_events()
            healthcheck._reconcile()
            local set = b.version_applied == shm:get(b.TARGET_VERSION)
            local send = hold_events(function()
                assert(a:set_target_status(ip, 22222, nil, true))
            end)
            healthcheck._reconcile()
            send()
            flush_events()
            before = stats()
            healthcheck._reconcile()
            ngx.say("unset=", tostring(unset), " compared after an event=", unread,
                    " set again=", tostring(set),
                    " compared after a late event=", since(before, "compared"),
                    " ", status(b, 11111), ",", status(b, 22222))
        }
    }
--- request
GET /t
--- response_body
unset=true compared after an event=2 set again=true compared after a late event=0 false,true
--- no_error_log
[error]



=== TEST 9: a checker created while the state of a target cannot be read takes the late event of its change, and no older one for the others
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a = new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            flush_events()
            local _, held = hold_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
                assert(a:set_target_status(ip, 22222, nil, false))
                assert(a:set_target_status(ip, 22222, nil, true))
            end)
            -- as evicted from a full shm
            shm:delete(key_of(a.TARGET_STATE, 11111))
            local b = new_checker()
            local function health(port)
                return tostring(b.targets[ip][port][ip].internal_health)
            end
            local loaded = health(11111) .. "," .. health(22222)
            -- the last of the three events is lost
            local we = events()
            we.post(held[1][1], held[1][2], held[1][3])
            we.post(held[2][1], held[2][2], held[2][3])
            flush_events()
            ngx.say("loaded=", loaded, " after the late events=", health(11111), ",", health(22222))
        }
    }
--- request
GET /t
--- response_body
loaded=nil,healthy after the late events=unhealthy,healthy
--- no_error_log
[error]



=== TEST 10: a version key that was made again from an earlier time does not keep the events of a target out
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            healthcheck._reconcile()
            -- as evicted from a full shm, and made again after the clock was
            -- set back
            shm:set(a.TARGET_VERSION, shm:get(a.TARGET_VERSION) - 5000)
            lose_events(function()
                assert(a:set_target_status(ip, 22222, nil, false))
            end)
            shm:delete(key_of(a.TARGET_STATE, 11111))
            healthcheck._reconcile()
            local compared = status(b, 11111) .. "," .. status(b, 22222)
            assert(a:set_target_status(ip, 11111, nil, false))
            flush_events()
            -- before the next run of the timer: by the event alone
            ngx.say("after the comparison=", compared, " after the event=", status(b, 11111))
        }
    }
--- request
GET /t
--- response_body
after the comparison=true,false after the event=false
--- no_error_log
[error]



=== TEST 11: a target that is listed without a state is added by the event of its change, and keeps the latest one
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            healthcheck._reconcile()
            local we = events()
            -- only the owner gets the event of the new target
            we.unregister(b.ev_callback, b.EVENT_SOURCE)
            assert(a:add_target(ip, 44444, nil, true))
            flush_events()
            we.register(b.ev_callback, b.EVENT_SOURCE)
            local _, held = hold_events(function()
                assert(a:set_target_status(ip, 44444, nil, false))
                assert(a:set_target_status(ip, 44444, nil, true))
            end)
            -- as evicted from a full shm
            shm:delete(key_of(a.TARGET_STATE, 44444))
            healthcheck._reconcile()
            local compared = status(b, 44444)
            -- the event of the second change arrives before the first
            we.post(held[2][1], held[2][2], held[2][3])
            flush_events()
            we.post(held[1][1], held[1][2], held[1][3])
            flush_events()
            ngx.say("after the comparison=", compared, " after the late events=", status(b, 44444))
        }
    }
--- request
GET /t
--- response_body
after the comparison=nil/target not found after the late events=true
--- no_error_log
[error]



=== TEST 12: a checker without a list and without a target has nothing left to read
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local a = new_checker()
            a:stop()
            a:start()
            local before = stats()
            healthcheck._reconcile()
            ngx.say("compared=", since(before, "compared"), " version_applied is the version in shm=",
                    tostring(a.version_applied == ngx.shared.test_shm:get(a.TARGET_VERSION)))
        }
    }
--- request
GET /t
--- response_body
compared=1 version_applied is the version in shm=true
--- no_error_log
[error]
