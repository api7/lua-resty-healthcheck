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

=== TEST 1: a missed event of one checker does not have the checkers compared whose copy waits for a state key
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local N = 20
            local owners, copies = {}, {}
            for i = 1, N do
                owners[i] = new_checker("checker-" .. i)
                copies[i] = new_checker("checker-" .. i)
                assert(owners[i]:add_target(ip, 11111, nil, true))
                assert(owners[i]:add_target(ip, 22222, nil, true))
            end
            flush_events()
            -- as evicted from a full shm: one state key of each checker
            for i = 1, N do
                shm:delete(key_of(owners[i].TARGET_STATE, 22222))
            end
            healthcheck._set_sweep(100000, 1)   -- every checker, on this run
            healthcheck._reconcile()
            healthcheck._set_sweep(20, 100)
            local unset = 0
            for i = 1, N do
                if copies[i].version_applied == nil then
                    unset = unset + 1
                end
            end
            lose_events(function()
                assert(owners[1]:set_target_status(ip, 11111, nil, false))
            end)
            local before = stats()
            healthcheck._reconcile()
            ngx.say("copies without version_applied=", unset, " compared=", since(before, "compared"),
                    " copy=", status(copies[1], 11111))
        }
    }
--- request
GET /t
--- response_body
copies without version_applied=20 compared=2 copy=false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 2: a copy without a target, when the list is gone after a change was announced, still takes the late event of that change
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local send = hold_events(function()
                assert(a:add_target(ip, 11111, nil, true))
            end)
            -- as evicted from a full shm
            shm:delete(a.TARGET_LIST)
            healthcheck._reconcile()
            send()
            flush_events()
            ngx.say("a=", status(a, 11111), " b=", status(b, 11111))
        }
    }
--- request
GET /t
--- response_body
a=true b=true
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 3: when the version key is gone, the version kept for a target whose state cannot be read is dropped, so that a key made again from an earlier time does not keep its events out
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
            local version = shm:get(a.TARGET_VERSION)
            -- as evicted from a full shm
            shm:delete(a.TARGET_VERSION)
            shm:delete(key_of(a.TARGET_STATE, 11111))
            healthcheck._set_sweep(1000, 1)   -- every checker, on this run
            healthcheck._reconcile()
            healthcheck._set_sweep(20, 100)
            -- made again from an earlier time
            assert(shm:set(a.TARGET_VERSION, version - 500))
            assert(a:set_target_status(ip, 11111, nil, false))
            assert(a:set_target_status(ip, 22222, nil, false))
            flush_events()
            ngx.say("the target whose state was not read=", status(b, 11111),
                    " one whose state was read=", status(b, 22222))
        }
    }
--- request
GET /t
--- response_body
the target whose state was not read=false one whose state was read=false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 4: the event of the very version a comparison read is not applied over the state it read
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
                assert(a:set_target_status(ip, 22222, nil, false))
            end)
            -- another worker has written the next change (healthy again), and
            -- has not incremented the version yet
            shm:set(key_of(a.TARGET_STATE, 22222), 1)
            -- as evicted from a full shm
            shm:delete(key_of(a.TARGET_STATE, 11111))
            healthcheck._reconcile()
            send()
            flush_events()
            ngx.say("after the event of the version that was read=", status(b, 22222))
        }
    }
--- request
GET /t
--- response_body
after the event of the version that was read=true
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 5: two events of one target that arrive out of order leave the status of the later change, with nothing lost from shm
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            flush_events()
            healthcheck._reconcile()
            local _, held = hold_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
                assert(a:set_target_status(ip, 11111, nil, true))
            end)
            local we = events()
            local ver = b.status_ver
            we.post(held[2][1], held[2][2], held[2][3])
            flush_events()
            we.post(held[1][1], held[1][2], held[1][3])
            flush_events()
            ngx.say("b=", status(b, 11111), " status_ver+", b.status_ver - ver)
        }
    }
--- request
GET /t
--- response_body
b=true status_ver+0
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 6: a removal that arrives after the event that added its target again is not applied while the state of the target cannot be read
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
                assert(a:remove_target(ip, 33333, ip))
            end)
            assert(a:add_target(ip, 33333, nil, false))
            flush_events()
            -- as evicted from a full shm
            shm:delete(key_of(a.TARGET_STATE, 33333))
            healthcheck._reconcile()
            local compared = status(b, 33333)
            send()
            flush_events()
            local late = status(b, 33333)
            healthcheck._reconcile()
            ngx.say("after the comparison=", compared, " after the late removal=", late,
                    " after a run=", status(b, 33333))
        }
    }
--- request
GET /t
--- response_body
after the comparison=false after the late removal=false after a run=false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/
