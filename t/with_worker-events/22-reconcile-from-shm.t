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
    }
};

run_tests();

__DATA__

=== TEST 1: an event raised while new() is between its shm read and its subscription is not lost
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local opts = {
                name = "testing",
                shm_name = "test_shm",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            }

            local a = healthcheck.new(opts)
            assert(a:add_target("127.0.0.1", 11111, nil, true))

            -- new() reads the initial state from shm and then calls poll(),
            -- which dispatches the event before the second checker subscribes
            local orig_poll = we.poll
            we.poll = function(...)
                we.poll = orig_poll
                assert(a:set_target_status("127.0.0.1", 11111, nil, false))
                return orig_poll(...)
            end
            local b = healthcheck.new(opts)
            we.poll = orig_poll

            ngx.say(b:get_target_status("127.0.0.1", 11111))
        }
    }
--- request
GET /t
--- response_body
false
--- no_error_log
[error]



=== TEST 2: a missed status event is corrected from shm by the reconcile timer
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            local ver = checker.status_ver

            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            assert(checker:set_target_status("127.0.0.1", 11111, nil, false))

            wait_until(function() return checker:get_target_status("127.0.0.1", 11111) == false end)
            ngx.say(checker:get_target_status("127.0.0.1", 11111), " ",
                    checker.status_ver > ver)
        }
    }
--- request
GET /t
--- response_body
false true
--- no_error_log
[error]



=== TEST 3: a missed remove event drops the local target
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(checker:add_target("127.0.0.1", 22222, nil, true))

            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            -- remove_target() does not default the hostname to the ip
            assert(checker:remove_target("127.0.0.1", 11111, "127.0.0.1"))

            wait_until(function() return select(2, checker:get_target_status("127.0.0.1", 11111)) == "target not found" end)
            local ok, err = checker:get_target_status("127.0.0.1", 11111)
            ngx.say(tostring(ok), " ", tostring(err))
            ngx.say(checker:get_target_status("127.0.0.1", 22222))
        }
    }
--- request
GET /t
--- response_body
nil target not found
true
--- no_error_log
[error]



=== TEST 4: a target whose add event was missed shows up with its shm state
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            local ver = checker.status_ver

            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            assert(checker:add_target("127.0.0.1", 11111, nil, false))

            wait_until(function() return checker:get_target_status("127.0.0.1", 11111) == false end)
            ngx.say(tostring(checker:get_target_status("127.0.0.1", 11111)), " ",
                    checker.status_ver > ver)
        }
    }
--- request
GET /t
--- response_body
false true
--- no_error_log
[error]



=== TEST 5: a remove delivered after the reconciliation removed the target does not log a warning
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))

            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            assert(checker:remove_target("127.0.0.1", 11111, "127.0.0.1"))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) == nil end))

            -- the remove event is delivered after the timer removed the target
            checker.ev_callback({ ip = "127.0.0.1", port = 11111, hostname = "127.0.0.1" },
                                checker.events.remove)
            local ok, err = checker:get_target_status("127.0.0.1", 11111)
            ngx.say(tostring(ok), " ", tostring(err))
        }
    }
--- request
GET /t
--- response_body
nil target not found
--- no_error_log
trying to remove an unknown target
