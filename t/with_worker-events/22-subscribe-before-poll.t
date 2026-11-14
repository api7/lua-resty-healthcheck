use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * blocks() * 3;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
};

run_tests();

__DATA__

=== TEST 1: an event dispatched while new() polls, after it loaded the targets, reaches the new checker
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

            -- new() loads the targets from shm and then calls poll(), which
            -- dispatches the event of a change made in between
            local orig_poll = we.poll
            we.poll = function(...)
                we.poll = orig_poll
                assert(a:set_target_status("127.0.0.1", 11111, nil, false))
                return orig_poll(...)
            end
            local b = healthcheck.new(opts)
            we.poll = orig_poll

            -- nothing changes any more: `b` only gets this from that event
            ngx.sleep(0.3)
            ngx.say(a:get_target_status("127.0.0.1", 11111), " ",
                    b:get_target_status("127.0.0.1", 11111))
        }
    }
--- request
GET /t
--- response_body
false false
--- no_error_log
[error]



=== TEST 2: a checker is subscribed once, also after stop() and start(); stop() unsubscribes it
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
            local checker = healthcheck.new(opts)
            -- keeps the target changing while `checker` is stopped
            local other = healthcheck.new(opts)
            assert(checker:add_target("127.0.0.1", 11111, nil, true))

            local calls = 0
            local orig_handler = checker.event_handler
            checker.event_handler = function(...)
                calls = calls + 1
                return orig_handler(...)
            end

            -- post() dispatches the event to every subscriber before it returns
            assert(other:set_target_status("127.0.0.1", 11111, nil, false))
            ngx.say("after new(): ", calls)

            checker:stop()
            checker:start()
            assert(other:set_target_status("127.0.0.1", 11111, nil, true))
            ngx.say("after stop() and start(): ", calls)

            checker:stop()
            assert(other:set_target_status("127.0.0.1", 11111, nil, false))
            ngx.say("after stop(): ", calls)
        }
    }
--- request
GET /t
--- response_body
after new(): 1
after stop() and start(): 2
after stop(): 2
--- no_error_log
[error]



=== TEST 3: when the load is deferred to a timer, the checker does not subscribe before it has targets
--- http_config eval
qq{
    $::HttpConfig

    init_worker_by_lua_block {
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
        a = healthcheck.new(opts)
        assert(a:add_target("127.0.0.1", 11111, nil, true))

        -- an event is pending for this worker: posted, not dispatched yet
        local orig_poll = we.poll
        we.poll = function() return "done" end
        assert(a:set_target_status("127.0.0.1", 11111, nil, false))
        we.poll = orig_poll

        -- another worker holds the target-list lock, and this phase cannot
        -- wait for it: new() defers the load to a timer and polls
        assert(ngx.shared.test_shm:add(a.TARGET_LIST_LOCK, true, 10))
        b = healthcheck.new(opts)
        targets_after_new = tostring(b.targets)
        ngx.shared.test_shm:delete(a.TARGET_LIST_LOCK)
    }
}
--- config
    location = /t {
        content_by_lua_block {
            ngx.sleep(0.5)
            ngx.say("targets right after new(): ", targets_after_new)
            ngx.say("loaded later: ", type(b.targets), " ",
                    tostring(b:get_target_status("127.0.0.1", 11111)))
        }
    }
--- request
GET /t
--- response_body
targets right after new(): nil
loaded later: table false
--- no_error_log
[error]



=== TEST 4: when the poll fails, new() leaves no subscription behind
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

            local registered = {}
            local orig_register, orig_poll = we.register_weak, we.poll
            we.register_weak = function(callback, ...)
                registered[#registered + 1] = callback
                return orig_register(callback, ...)
            end
            we.poll = function() error("poll failed") end
            local ok, err = pcall(healthcheck.new, opts)
            we.register_weak, we.poll = orig_register, orig_poll

            -- the checker that new() never returned must not handle events
            local handled = 0
            if registered[1] then
                local name, never_returned = debug.getupvalue(registered[1], 1)
                assert(name == "self")
                never_returned.event_handler = function() handled = handled + 1 end
            end
            local a = healthcheck.new(opts)
            assert(a:add_target("127.0.0.1", 11111, nil, true))
            assert(a:set_target_status("127.0.0.1", 11111, nil, false))
            ngx.sleep(0.2)
            ngx.say(tostring(ok), " ", tostring(err):match("poll failed"), " handled=", handled)
        }
    }
--- request
GET /t
--- response_body
false poll failed handled=0
--- no_error_log
[error]
