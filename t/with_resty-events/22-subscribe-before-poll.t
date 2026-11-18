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

        function new_checker()
            return assert(require("resty.healthcheck").new({
                name = "testing",
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

=== TEST 1: an event dispatched while new() polls, after it loaded the targets, reaches the new checker
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            -- the reconcile timer would correct the copy of `b` as well:
            -- without it, only the event does
            ngx.timer.every = function() return true end
            local we = require "resty.events.compat"
            local a = new_checker()
            assert(a:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return a:get_target_status("127.0.0.1", 11111) end))

            -- new() loads the targets from shm and then calls poll(). Flip the
            -- target at that moment, and let the event be dispatched before
            -- poll() returns: `a` has it, so it has been dispatched.
            local orig_poll = we.poll
            we.poll = function(...)
                we.poll = orig_poll
                assert(a:set_target_status("127.0.0.1", 11111, nil, false))
                assert(wait_until(function()
                    return a:get_target_status("127.0.0.1", 11111) == false
                end))
                return orig_poll(...)
            end
            local b = new_checker()
            we.poll = orig_poll

            -- nothing changes any more: `b` only gets this from that event
            wait_until(function() return b:get_target_status("127.0.0.1", 11111) == false end)
            ngx.say(b:get_target_status("127.0.0.1", 11111))
        }
    }
--- request
GET /t
--- response_body
false
--- no_error_log
[error]



=== TEST 2: a checker is subscribed once: an event is handled once
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local checker = new_checker()
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))

            local calls = 0
            local orig_handler = checker.event_handler
            checker.event_handler = function(...)
                calls = calls + 1
                return orig_handler(...)
            end
            assert(checker:set_target_status("127.0.0.1", 11111, nil, false))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) == false end))
            -- a second delivery of the same event would have arrived by now
            ngx.sleep(0.3)
            ngx.say(calls)
        }
    }
--- request
GET /t
--- response_body
1
--- no_error_log
[error]



=== TEST 3: stop() unsubscribes the checker: no event is handled afterwards
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local checker = new_checker()
            -- keeps the target changing after `checker` is stopped
            local other = new_checker()
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function()
                return checker:get_target_status("127.0.0.1", 11111)
                       and other:get_target_status("127.0.0.1", 11111)
            end))

            checker:stop()
            local calls = 0
            local orig_handler = checker.event_handler
            checker.event_handler = function(...)
                calls = calls + 1
                return orig_handler(...)
            end
            assert(other:set_target_status("127.0.0.1", 11111, nil, false))
            -- `other` got the event, so it has been dispatched
            assert(wait_until(function() return other:get_target_status("127.0.0.1", 11111) == false end))
            ngx.sleep(0.3)
            ngx.say(calls)
        }
    }
--- request
GET /t
--- response_body
0
--- no_error_log
[error]



=== TEST 4: when the poll fails, new() leaves no subscription behind
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local registered = {}
            local orig_register, orig_poll = we.register_weak, we.poll
            we.register_weak = function(callback, ...)
                registered[#registered + 1] = callback
                return orig_register(callback, ...)
            end
            -- as lua-resty-events' poll() does in a phase where it cannot sleep
            we.poll = function() error("poll failed") end
            local ok, err = pcall(new_checker)
            we.register_weak, we.poll = orig_register, orig_poll

            -- the checker that new() never returned must not handle events
            local handled = 0
            if registered[1] then
                local never_returned
                for i = 1, 10 do
                    local name, value = debug.getupvalue(registered[1], i)
                    if name == "self" then
                        never_returned = value
                    end
                end
                assert(never_returned)
                never_returned.event_handler = function() handled = handled + 1 end
            end
            local a = new_checker()
            assert(a:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return a:get_target_status("127.0.0.1", 11111) end))
            assert(a:set_target_status("127.0.0.1", 11111, nil, false))
            assert(wait_until(function() return a:get_target_status("127.0.0.1", 11111) == false end))
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
