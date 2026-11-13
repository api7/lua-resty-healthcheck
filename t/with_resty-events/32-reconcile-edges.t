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
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



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
