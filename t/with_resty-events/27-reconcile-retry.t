use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * blocks() * 3;

my $pwd = cwd();
$ENV{TEST_NGINX_SERVROOT} = server_root();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;

    init_by_lua_block {
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

        -- makes every read of the checker's target list fail, until the
        -- returned function is called
        function fail_target_list_reads(checker)
            local real = checker.shm
            local proxy = setmetatable({}, {
                __index = function(_, name)
                    local method = real[name]
                    return function(_, ...)
                        return method(real, ...)
                    end
                end,
            })
            proxy.get = function(_, key)
                if key == checker.TARGET_LIST then
                    return nil, "injected failure"
                end
                return real:get(key)
            end
            checker.shm = proxy
            return function()
                checker.shm = real
            end
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

=== TEST 1: a resync that fails on a timer run is retried on the next runs
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
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))
            ngx.sleep(0.3)

            -- the event of the next change is missed, and the resync that
            -- follows its version bump fails
            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            local restore = fail_target_list_reads(checker)
            assert(checker:set_target_status("127.0.0.1", 11111, nil, false))
            ngx.sleep(0.3)
            local before = checker:get_target_status("127.0.0.1", 11111)

            -- nothing changes any more, and the next full resync is at least
            -- 10 s away: only the retry can correct the copy within 2 s
            restore()
            local corrected = wait_until(function()
                return checker:get_target_status("127.0.0.1", 11111) == false
            end)
            ngx.say("before=", tostring(before), " corrected=", tostring(corrected))
        }
    }
--- request
GET /t
--- response_body
before=true corrected=true
--- error_log
failed to reconcile targets with shm: failed to fetch target_list from shm: injected failure
--- timeout: 6



=== TEST 2: a resync that fails in start() is retried by the timer
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local function new_checker(name)
                return assert(healthcheck.new({
                    name = name,
                    shm_name = "test_shm",
                    events_module = "resty.events",
                    checks = {
                        active = {
                            healthy = { interval = 0 },
                            unhealthy = { interval = 0 },
                        },
                    },
                }))
            end
            local checker = new_checker("testing")
            -- keeps the timer recording the version shared by the shm
            local other = new_checker("other")
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))

            -- a change made while the checker is stopped is not delivered to it
            checker:stop()
            assert(checker:set_target_status("127.0.0.1", 11111, nil, false))
            ngx.sleep(0.3)

            -- the resync of start() fails
            local restore = fail_target_list_reads(checker)
            assert(checker:start())
            ngx.sleep(0.3)
            local before = checker:get_target_status("127.0.0.1", 11111)

            restore()
            local corrected = wait_until(function()
                return checker:get_target_status("127.0.0.1", 11111) == false
            end)
            ngx.say("before=", tostring(before), " corrected=", tostring(corrected),
                    " ", other ~= nil)
        }
    }
--- request
GET /t
--- response_body
before=true corrected=true true
--- error_log
failed to reconcile targets with shm: failed to fetch target_list from shm: injected failure
--- timeout: 6



=== TEST 3: a reconcile timer that could not be created is created by the next new()
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local healthcheck = require("resty.healthcheck")
            local function new_checker(name)
                return assert(healthcheck.new({
                    name = name,
                    shm_name = "test_shm",
                    events_module = "resty.events",
                    checks = {
                        active = {
                            healthy = { interval = 0 },
                            unhealthy = { interval = 0 },
                        },
                    },
                }))
            end
            -- e.g. too many pending timers
            local orig_every = ngx.timer.every
            ngx.timer.every = function()
                return nil, "injected failure"
            end
            local checker = new_checker("testing")
            ngx.timer.every = orig_every

            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))

            -- without the timer, a missed event is not corrected
            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            assert(checker:set_target_status("127.0.0.1", 11111, nil, false))
            ngx.sleep(0.5)
            local before = checker:get_target_status("127.0.0.1", 11111)

            -- the next checker created in this worker starts the timer, which
            -- serves every checker
            local other = new_checker("other")
            local corrected = wait_until(function()
                return checker:get_target_status("127.0.0.1", 11111) == false
            end)
            ngx.say("before=", tostring(before), " corrected=", tostring(corrected),
                    " ", other ~= nil)
        }
    }
--- request
GET /t
--- response_body
before=true corrected=true true
--- error_log
could not start the reconcile timer: injected failure
--- timeout: 6
