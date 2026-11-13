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

        -- two checkers with the same name stand for the checkers of two
        -- workers: each has its own copy of the targets and its own status_ver
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

        function status(checker, port)
            local ok, err = checker:get_target_status("127.0.0.1", port)
            return tostring(ok) .. (err and ("/" .. err) or "")
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

=== TEST 1: a target first seen as unhealthy bumps status_ver (unknown, which callers treat as usable, to unhealthy)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local a, b = new_checker(), new_checker()
            local ver = b.status_ver
            assert(a:add_target("127.0.0.1", 11111, nil, false))
            wait_until(function() return status(b, 11111) == "false" end)
            ngx.say(status(b, 11111), " ", b.status_ver > ver)
        }
    }
--- request
GET /t
--- response_body
false true
--- no_error_log
[error]



=== TEST 2: removing an unhealthy target bumps status_ver (unhealthy to unknown)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local a, b = new_checker(), new_checker()
            assert(a:add_target("127.0.0.1", 11111, nil, false))
            assert(wait_until(function() return status(b, 11111) == "false" end))
            local ver = b.status_ver
            -- remove_target() does not default the hostname to the ip
            assert(a:remove_target("127.0.0.1", 11111, "127.0.0.1"))
            wait_until(function() return status(b, 11111) == "nil/target not found" end)
            ngx.say(status(b, 11111), " ", b.status_ver > ver)
        }
    }
--- request
GET /t
--- response_body
nil/target not found true
--- no_error_log
[error]



=== TEST 3: clear() bumps status_ver in the worker that calls it, at once, and in the others
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local a, b = new_checker(), new_checker()
            assert(a:add_target("127.0.0.1", 11111, nil, false))
            assert(wait_until(function()
                return status(a, 11111) == "false" and status(b, 11111) == "false"
            end))
            local ver_a, ver_b = a.status_ver, b.status_ver
            assert(a:clear())
            -- the caller's copy is emptied by clear() itself
            local at_once = status(a, 11111) .. " " .. tostring(a.status_ver > ver_a)
            wait_until(function() return status(b, 11111) == "nil/target not found" end)
            ngx.say(at_once, " | ", status(b, 11111), " ", b.status_ver > ver_b)
        }
    }
--- request
GET /t
--- response_body
nil/target not found true | nil/target not found true
--- no_error_log
[error]



=== TEST 4: clear() on a checker without targets does not bump status_ver
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local a, b = new_checker(), new_checker()
            ngx.sleep(0.2)
            local ver_a, ver_b = a.status_ver, b.status_ver
            assert(a:clear())
            ngx.sleep(0.3)
            ngx.say(a.status_ver == ver_a, " ", b.status_ver == ver_b)
        }
    }
--- request
GET /t
--- response_body
true true
--- no_error_log
[error]



=== TEST 5: what did not bump before still does not: a healthy target added, and a state that keeps the same side
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local a, b = new_checker(), new_checker()
            local ver = b.status_ver
            -- unknown -> healthy: one bump, as before
            assert(a:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return status(b, 11111) == "true" end))
            local added = b.status_ver - ver
            -- removing a healthy target: it is usable before and after for a
            -- caller, but the copy changed, so this bumps as well
            ver = b.status_ver
            assert(a:remove_target("127.0.0.1", 11111, "127.0.0.1"))
            assert(wait_until(function() return status(b, 11111) == "nil/target not found" end))
            ngx.say(added, " ", b.status_ver - ver)
        }
    }
--- request
GET /t
--- response_body
1 1
--- no_error_log
[error]
