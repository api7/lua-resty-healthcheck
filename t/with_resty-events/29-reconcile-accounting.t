use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * blocks() * 3;

my $pwd = cwd();
$ENV{TEST_NGINX_SERVROOT} = server_root();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict other_shm 8m;

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
        local real_sleep = ngx.sleep
        ngx.sleep = function(seconds)
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
            return require "resty.events.compat"
        end

        -- two checkers with the same name stand for the checkers of two
        -- workers: each has its own copy of the targets
        function new_checker(name, shm_name)
            return assert(require("resty.healthcheck").new({
                name = name or "testing",
                shm_name = shm_name or "test_shm",
                events_module = "resty.events",
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

    init_worker_by_lua_block {
        local we = require "resty.events.compat"
        assert(we.configure({
            unique_timeout = 5,
            broker_id = 0,
            listening = "unix:$ENV{TEST_NGINX_SERVROOT}/worker_events.sock"
        }))
        assert(we.configured())
    }

    server {
        server_name kong_worker_events;
        listen unix:$ENV{TEST_NGINX_SERVROOT}/worker_events.sock;
        access_log off;
        location / {
            content_by_lua_block {
                require("resty.events.compat").run()
            }
        }
    }
};

run_tests();

__DATA__

=== TEST 1: a change made while a checker was stopped is applied on the run after it starts again
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
            b:stop()
            assert(a:set_target_status(ip, 11111, nil, false))
            flush_events()
            healthcheck._reconcile()
            local while_stopped = status(b, 11111)
            b:start()
            local before = stats()
            healthcheck._reconcile()
            ngx.say(while_stopped, " ", status(b, 11111), " scans=", since(before, "scans"),
                    " compared=", since(before, "compared"))
        }
    }
--- request
GET /t
--- response_body
true false scans=0 compared=1
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 2: when every event arrives, the timer compares nothing
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            -- counted from the start: creating checkers and adding their
            -- targets has nothing compared either
            local before = stats()
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            local c = new_checker("other")
            assert(c:add_target(ip, 55555, nil, true))
            flush_events()
            for i = 1, 10 do
                assert(a:set_target_status(ip, 11111, nil, i % 2 == 0))
                assert(c:set_target_status(ip, 55555, nil, i % 2 == 0))
                flush_events()
                healthcheck._reconcile()
            end
            ngx.say("runs=", since(before, "runs"), " scans=", since(before, "scans"),
                    " compared=", since(before, "compared"), " b=", status(b, 11111),
                    " c=", status(c, 55555))
        }
    }
--- request
GET /t
--- response_body
runs=10 scans=0 compared=0 b=true c=true
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 3: an event that arrives after its change was compared is not applied again
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
            local send = hold_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            healthcheck._reconcile()
            local compared = status(b, 11111)
            -- a newer change, whose event arrives first
            assert(a:set_target_status(ip, 11111, nil, true))
            flush_events()
            local ver = b.status_ver
            send()
            flush_events()
            ngx.say(compared, " b=", status(b, 11111), " a=", status(a, 11111),
                    " status_ver+", b.status_ver - ver)
        }
    }
--- request
GET /t
--- response_body
false b=true a=true status_ver+0
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 4: events that arrive out of order are applied as they come, and the checker is compared on the next run
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
            local before = stats()
            local send = hold_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            assert(a:set_target_status(ip, 22222, nil, false))
            flush_events()
            local first = status(b, 11111) .. "," .. status(b, 22222)
            send()
            flush_events()
            local second = status(b, 11111) .. "," .. status(b, 22222)
            healthcheck._reconcile()
            ngx.say(first, " ", second, " scans=", since(before, "scans"),
                    " compared=", since(before, "compared"))
        }
    }
--- request
GET /t
--- response_body
true,false false,false scans=0 compared=2
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 5: while a checker is compared its events are kept and applied afterwards, and the timer does not run twice at a time
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
            healthcheck._set_sync_batch(1)   -- yield after every unit of work
            lose_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            local before = stats()
            local kept, nested
            yield_hook = {
                cond = function() return b.syncing end,
                fn = function()
                    -- an event for `b` arrives now. It has no version, as from
                    -- a worker that runs an older version of this module, so
                    -- only the event tells of the change.
                    b.ev_callback({ ip = ip, port = 33333, hostname = ip }, "unhealthy")
                    kept = status(b, 33333)
                    -- and the timer fires again
                    local at = stats()
                    healthcheck._reconcile()
                    nested = since(at, "runs") .. "/" .. tostring(b.syncing)
                end,
            }
            healthcheck._reconcile()
            ngx.say("kept=", tostring(kept), " nested=", tostring(nested),
                    " queued=", since(before, "queued"), " runs=", since(before, "runs"),
                    " b=", status(b, 11111), ",", status(b, 22222), ",", status(b, 33333))
        }
    }
--- request
GET /t
--- response_body
kept=true nested=0/true queued=1 runs=2 b=false,true,false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 6: more events than are kept during a comparison have the checker compared again
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
            healthcheck._set_sync_batch(1)
            healthcheck._set_max_queued_events(1)
            lose_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            yield_hook = {
                cond = function() return b.syncing end,
                fn = function()
                    b.ev_callback({ ip = ip, port = 22222, hostname = ip }, "unhealthy")
                    b.ev_callback({ ip = ip, port = 33333, hostname = ip }, "unhealthy")
                end,
            }
            healthcheck._reconcile()
            local first = status(b, 22222) .. "," .. status(b, 33333)
            local before = stats()
            healthcheck._reconcile()
            -- 22222 was kept and applied; shm, which says healthy, wins after
            ngx.say(first, " compared=", since(before, "compared"), " ",
                    status(b, 22222), ",", status(b, 33333))
        }
    }
--- request
GET /t
--- response_body
false,true compared=1 true,true
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 7: a comparison yields after every batch of work, and only compares statuses when the list did not change
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            healthcheck._set_sync_batch(10)
            local a = new_checker()
            for port = 20001, 20040 do
                assert(a:add_target(ip, port, nil, true))
            end
            flush_events()
            lose_events(function()
                assert(a:set_target_status(ip, 20001, nil, false))
            end)
            local before = stats()
            healthcheck._reconcile()
            local first = since(before, "yields")
            ngx.say("members=", since(before, "members"), " yields>=10=", tostring(first >= 10),
                    " ", status(a, 20001))

            lose_events(function()
                assert(a:set_target_status(ip, 20001, nil, true))
            end)
            before = stats()
            healthcheck._reconcile()
            local second = since(before, "yields")
            ngx.say("members=", since(before, "members"), " yields=4..8=",
                    tostring(second >= 4 and second <= 8), " ", status(a, 20001))
        }
    }
--- request
GET /t
--- response_body
members=1 yields>=10=true false
members=0 yields=4..8=true true
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 8: a checker that is cleared while it is compared ends up empty everywhere
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
            healthcheck._set_sync_batch(1)
            lose_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            yield_hook = {
                cond = function() return b.syncing end,
                fn = function()
                    assert(b:clear())
                end,
            }
            healthcheck._reconcile()
            flush_events()
            healthcheck._reconcile()
            ngx.say("a=", #a.targets, " b=", #b.targets, " listed=",
                    #healthcheck.get_target_list("testing", "test_shm"))
        }
    }
--- request
GET /t
--- response_body
a=0 b=0 listed=0
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 9: the background comparison takes the checkers in turn, a fixed amount of work per run, and a round no more often than set
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            -- 4 units of work a run, which is one checker with two targets;
            -- a round every 8 runs at most
            healthcheck._set_sweep(4, 8)
            local checkers = {}
            for i = 1, 6 do
                checkers[i] = new_checker("checker-" .. i)
                assert(checkers[i]:add_target(ip, 11111, nil, true))
                assert(checkers[i]:add_target(ip, 22222, nil, true))
            end
            flush_events()
            local compared = {}
            for run = 1, 20 do
                local before = stats()
                healthcheck._reconcile()
                compared[run] = since(before, "compared")
            end
            ngx.say(table.concat(compared))
        }
    }
--- request
GET /t
--- response_body
00000001111110011111
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 10: the shm being ahead is not taken for a lost event when the event arrives within the grace period
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
            healthcheck._set_event_grace(0.3)
            local send = hold_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            local before = stats()
            -- finds the shm ahead, and waits
            local run = ngx.thread.spawn(healthcheck._reconcile)
            send()
            flush_events()
            assert(ngx.thread.wait(run))
            ngx.say("scans=", since(before, "scans"), " compared=", since(before, "compared"),
                    " b=", status(b, 11111))
        }
    }
--- request
GET /t
--- response_body
scans=0 compared=0 b=false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 11: a change whose event was dispatched just before a new checker subscribed is compared on the next run
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local we = events()
            local a = new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            flush_events()
            local register_weak = we.register_weak
            we.register_weak = function(...)
                we.register_weak = register_weak
                -- new() has loaded the targets and is about to subscribe
                assert(a:set_target_status(ip, 11111, nil, false))
                flush_events()
                return register_weak(...)
            end
            local b = new_checker()
            we.register_weak = register_weak
            local at_once = status(b, 11111)
            local before = stats()
            healthcheck._reconcile()
            ngx.say(at_once, " ", status(b, 11111), " scans=", since(before, "scans"),
                    " compared=", since(before, "compared"))
        }
    }
--- request
GET /t
--- response_body
true false scans=0 compared=1
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 12: an event without a version, as from a worker that runs an older version of this module, is applied as before
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
            local before = stats()
            events().post(b.EVENT_SOURCE, "unhealthy", { ip = ip, port = 11111, hostname = ip })
            flush_events()
            healthcheck._reconcile()
            ngx.say(status(a, 11111), " ", status(b, 11111), " scans=", since(before, "scans"),
                    " compared=", since(before, "compared"))
        }
    }
--- request
GET /t
--- response_body
false false scans=0 compared=0
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 13: a shm version that is gone, or went back, has every checker looked at
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
            local shm_version = "lua-resty-healthcheck::shm_version"
            healthcheck._reconcile()
            local before = stats()
            shm:delete(shm_version)
            healthcheck._reconcile()
            local gone = since(before, "scans")
            healthcheck._reconcile()
            local settled = since(before, "scans")
            lose_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            -- lower than what this worker counted before
            assert(shm:set(shm_version, 5))
            healthcheck._reconcile()
            ngx.say(gone, " ", settled, " ", since(before, "scans"), " b=", status(b, 11111))
        }
    }
--- request
GET /t
--- response_body
1 1 2 b=false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 14: a listed target whose state key is missing is added when its state is back
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
            healthcheck._set_sweep(1000, 1)   -- every checker, on every run
            lose_events(function()
                assert(a:add_target(ip, 44444, nil, true))
            end)
            -- evicted from a full shm
            shm:delete(key_of(a.TARGET_STATE, 44444))
            healthcheck._reconcile()
            local without = status(b, 44444)
            healthcheck._reconcile()
            -- written again, as by the next report for the target
            assert(shm:set(key_of(a.TARGET_STATE, 44444), 2))
            healthcheck._reconcile()
            ngx.say(without, " ", status(b, 44444), " ", status(a, 44444))
        }
    }
--- request
GET /t
--- response_body
nil/target not found false false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 15: each shm is counted on its own
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
            local c = new_checker("testing", "other_shm")
            local d = new_checker("testing", "other_shm")
            assert(c:add_target(ip, 11111, nil, true))
            flush_events()
            healthcheck._reconcile()
            local before = stats()
            lose_events(function()
                assert(c:set_target_status(ip, 11111, nil, false))
            end)
            -- same name and target in the other shm: an event that arrives
            assert(a:set_target_status(ip, 11111, nil, false))
            flush_events()
            healthcheck._reconcile()
            ngx.say("scans=", since(before, "scans"), " compared=", since(before, "compared"),
                    " a=", status(a, 11111), " b=", status(b, 11111),
                    " c=", status(c, 11111), " d=", status(d, 11111))
        }
    }
--- request
GET /t
--- response_body
scans=1 compared=2 a=false b=false c=false d=false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 16: a target that an event put in the copies without it being listed is removed by the next comparison
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
            healthcheck._set_sweep(1000, 1)   -- every checker, on every run
            -- the members are compared, and the list is remembered
            healthcheck._reconcile()
            -- as a report that races with the removal of its target raises it
            events().post(b.EVENT_SOURCE, "unhealthy", { ip = ip, port = 44444, hostname = ip })
            flush_events()
            local before = status(b, 44444)
            local ver = b.status_ver
            healthcheck._reconcile()
            ngx.say(before, " b=", status(b, 44444), " a=", status(a, 44444),
                    " targets=", #b.targets, " status_ver+", b.status_ver - ver)
        }
    }
--- request
GET /t
--- response_body
false b=nil/target not found a=nil/target not found targets=3 status_ver+1
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/
