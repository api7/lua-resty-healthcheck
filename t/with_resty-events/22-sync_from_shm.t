use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * (blocks() * 3);

my $pwd = cwd();
$ENV{TEST_NGINX_SERVROOT} = server_root();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;

    init_by_lua_block {
        -- poll get_target_status() until it returns `want`, fail past the deadline
        function wait_status(checker, ip, port, want, timeout)
            local deadline = ngx.now() + (timeout or 3)
            while true do
                local ok = checker:get_target_status(ip, port)
                if ok == want then
                    return
                end
                ngx.update_time()
                if ngx.now() >= deadline then
                    error("target " .. ip .. ":" .. port .. " did not become " ..
                          tostring(want) .. " within " .. (timeout or 3) .. "s")
                end
                ngx.sleep(0.05)
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

=== TEST 1: local status follows an shm state change that arrived without an event
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
                        healthy  = { interval = 0 },
                        unhealthy  = { interval = 0 },
                    }
                }
            })
            assert(checker:add_target("127.0.0.1", 2113, nil, true))
            wait_status(checker, "127.0.0.1", 2113, true)
            local ver_before = checker.status_ver
            ngx.say(checker:get_target_status("127.0.0.1", 2113))

            -- another worker flipped the node in shm but its event never reached us
            local key = checker.TARGET_STATE .. ":127.0.0.1:2113:127.0.0.1"
            assert(checker.shm:set(key, 2)) -- 2 = unhealthy

            wait_status(checker, "127.0.0.1", 2113, false)
            ngx.say(checker:get_target_status("127.0.0.1", 2113))
            ngx.say(checker.status_ver - ver_before)
        }
    }
--- request
GET /t
--- response_body
true
false
1
--- no_error_log
[error]



=== TEST 2: a target present in shm but missing locally is picked up without an event
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local codec = require "string.buffer"
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy  = { interval = 0 },
                        unhealthy  = { interval = 0 },
                    }
                }
            })
            local ok, err = checker:get_target_status("127.0.0.1", 2114)
            ngx.say(tostring(ok), " ", tostring(err))

            -- another worker registered the target straight into shm
            local key = checker.TARGET_STATE .. ":127.0.0.1:2114:127.0.0.1"
            assert(checker.shm:set(key, 2)) -- 2 = unhealthy
            assert(checker.shm:set(checker.TARGET_LIST, codec.encode({
                { ip = "127.0.0.1", port = 2114, hostname = "127.0.0.1" },
            })))

            wait_status(checker, "127.0.0.1", 2114, false)
            ok, err = checker:get_target_status("127.0.0.1", 2114)
            ngx.say(tostring(ok), " ", tostring(err))
        }
    }
--- request
GET /t
--- response_body
nil target not found
false nil
--- no_error_log
[error]



=== TEST 3: re-adding a target inside the purge window keeps the shm state, not the local view
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
                        healthy  = { interval = 0 },
                        unhealthy  = { interval = 0 },
                    }
                }
            })
            assert(checker:add_target("127.0.0.1", 2115, nil, true))
            wait_status(checker, "127.0.0.1", 2115, true)

            -- shm says unhealthy, this worker's cache still says healthy
            local key = checker.TARGET_STATE .. ":127.0.0.1:2115:127.0.0.1"
            assert(checker.shm:set(key, 2))
            assert(checker:delayed_clear(5))
            assert(checker:add_target("127.0.0.1", 2115, nil, true))

            ngx.say(checker.shm:get(key))
        }
    }
--- request
GET /t
--- response_body
2
--- no_error_log
[error]
