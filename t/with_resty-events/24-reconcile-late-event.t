use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * blocks() * 3;

my $pwd = cwd();
$ENV{TEST_NGINX_SERVROOT} = server_root();

# a tiny event queue, so that it overflows on purpose
our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;

    init_worker_by_lua_block {
        local we = require "resty.events.compat"
        assert(we.configure({
            unique_timeout = 5,
            broker_id = 0,
            max_queue_len = 5,
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

=== TEST 1: an event is applied from the state in shm, not from its payload (status, remove, clear)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            local function status(port)
                local ok, err = checker:get_target_status("127.0.0.1", port)
                return tostring(ok) .. (err and ("/" .. err) or "")
            end
            local function late(port, event)
                checker.ev_callback({ ip = "127.0.0.1", port = port, hostname = "127.0.0.1" },
                                    checker.events[event])
            end

            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(checker:add_target("127.0.0.1", 22222, nil, true))
            local deadline = ngx.now() + 2
            while not (checker:get_target_status("127.0.0.1", 11111)
                       and checker:get_target_status("127.0.0.1", 22222))
                  and ngx.now() < deadline do
                ngx.sleep(0.01)
                ngx.update_time()
            end
            assert(checker:remove_target("127.0.0.1", 22222, "127.0.0.1"))
            deadline = ngx.now() + 2
            while checker:get_target_status("127.0.0.1", 22222) ~= nil
                  and ngx.now() < deadline do
                ngx.sleep(0.01)
                ngx.update_time()
            end

            -- older events delivered late, after newer changes were applied:
            -- 11111 is healthy in shm, 22222 is gone from shm
            late(11111, "unhealthy")
            late(22222, "healthy")
            late(11111, "remove")
            -- a clear raised before 11111 was (re-)added
            checker.ev_callback({}, checker.events.clear)
            ngx.say(status(11111), " ", status(22222))
        }
    }
--- request
GET /t
--- response_body
true nil/target not found
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 2: end to end: the older event arrives after the newer change was reconciled, the newer event dropped by a full queue
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            -- lua-resty-events 0.1.x has no max_queue_len, so its queue does
            -- not overflow here and the scenario cannot be produced
            local events_version = require("resty.events")._VERSION
            if ngx.re.match(events_version, [[^0\.1\.]], "jo") then
                ngx.log(ngx.WARN, "skipped: lua-resty-events ", events_version,
                        " has no max_queue_len")
                ngx.say("shm=healthy local=true overflowed=true delivered=unhealthy@healthy")
                return
            end

            local we = require "resty.events.compat"
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            ngx.sleep(0.3)

            -- records which events of the target reach the checker, and what
            -- shm holds at that moment
            local state_key = checker.TARGET_STATE .. ":127.0.0.1:11111:127.0.0.1"
            local deliveries = {}
            local function spy(data, event, ...)
                if data.port == 11111 then
                    local state = ngx.shared.test_shm:get(state_key)
                    deliveries[#deliveries + 1] = event .. "@" .. tostring(state and
                        ({ "healthy", "unhealthy", "mostly_healthy", "mostly_unhealthy" })[state])
                end
                return checker.ev_callback(data, event, ...)
            end
            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            we.register(spy, checker.EVENT_SOURCE)

            -- a slow subscriber to another source keeps this worker's queue busy
            local fast_delivered = 0
            we.register(function() ngx.sleep(0.6) end, "filler", "slow")
            we.register(function() fast_delivered = fast_delivered + 1 end, "filler", "fast")
            we.post("filler", "slow", 1)
            ngx.sleep(0.05)

            -- E1 (unhealthy) waits in the queue, the queue fills up, and E2
            -- (healthy again) is dropped. The timer reconciles to healthy
            -- meanwhile; E1 is delivered afterwards.
            assert(checker:set_target_status("127.0.0.1", 11111, nil, false))
            for i = 1, 6 do
                we.post("filler", "fast", i)
            end
            ngx.sleep(0.05)
            assert(checker:set_target_status("127.0.0.1", 11111, nil, true))

            ngx.sleep(3)
            local list = healthcheck.get_target_list("testing", "test_shm")
            ngx.say("shm=", list[1].status,
                    " local=", tostring(checker:get_target_status("127.0.0.1", 11111)),
                    -- some events were dropped: the scenario did happen
                    " overflowed=", tostring(fast_delivered < 6),
                    -- only E1 reached the checker, after E2's change was in shm
                    " delivered=", table.concat(deliveries, ","))
        }
    }
--- request
GET /t
--- response_body
shm=healthy local=true overflowed=true delivered=unhealthy@healthy
--- no_error_log
failed to reconcile
--- timeout: 8



=== TEST 3: a late remove for a target that was removed and added again applies its shm state
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            local function status(port)
                local ok, err = checker:get_target_status("127.0.0.1", port)
                return tostring(ok) .. (err and ("/" .. err) or "")
            end

            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            local deadline = ngx.now() + 2
            while not checker:get_target_status("127.0.0.1", 11111)
                  and ngx.now() < deadline do
                ngx.sleep(0.01)
                ngx.update_time()
            end
            assert(checker:remove_target("127.0.0.1", 11111, "127.0.0.1"))
            deadline = ngx.now() + 2
            while checker:get_target_status("127.0.0.1", 11111) ~= nil
                  and ngx.now() < deadline do
                ngx.sleep(0.01)
                ngx.update_time()
            end

            -- another worker adds it again; before its event (or the timer)
            -- reaches this worker, the remove event of an earlier removal is
            -- delivered. Nothing below yields, so neither can run meanwhile.
            assert(checker:add_target("127.0.0.1", 11111, nil, false))
            local before = status(11111)
            local ver = checker.status_ver
            checker.ev_callback({ ip = "127.0.0.1", port = 11111, hostname = "127.0.0.1" },
                                checker.events.remove)
            ngx.say("before=", before, " after=", status(11111), " ",
                    checker.status_ver > ver)
        }
    }
--- request
GET /t
--- response_body
before=nil/target not found after=false true
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 4: a late remove for a target still in the local copy, removed and added again meanwhile, applies its new state
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            assert(checker:add_target("127.0.0.1", 11111, nil, false))
            local deadline = ngx.now() + 2
            while checker:get_target_status("127.0.0.1", 11111) ~= false
                  and ngx.now() < deadline do
                ngx.sleep(0.01)
                ngx.update_time()
            end

            -- another worker removes the target and adds it again as healthy;
            -- this worker has seen neither event yet, and the remove is
            -- delivered first. Nothing below yields, so the timer cannot run.
            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            assert(checker:remove_target("127.0.0.1", 11111, "127.0.0.1"))
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            local before = checker:get_target_status("127.0.0.1", 11111)
            checker.ev_callback({ ip = "127.0.0.1", port = 11111, hostname = "127.0.0.1" },
                                checker.events.remove)
            ngx.say("before=", tostring(before), " after=",
                    tostring(checker:get_target_status("127.0.0.1", 11111)))
        }
    }
--- request
GET /t
--- response_body
before=false after=true
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/
