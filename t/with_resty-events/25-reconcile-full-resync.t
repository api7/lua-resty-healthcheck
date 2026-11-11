use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * blocks() * 3;

my $pwd = cwd();
$ENV{TEST_NGINX_SERVROOT} = server_root();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict test_shm2 8m;

    init_worker_by_lua_block {
        _G.__TESTING_HEALTHCHECKER = true
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

=== TEST 1: a change that never bumped the versions is repaired by the periodic full resync
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local healthcheck = require("resty.healthcheck")
            healthcheck._set_full_resync_interval(0.5)
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

            -- e.g. written by a worker that still runs the previous version
            -- of this module during a reload: no version bump, and this
            -- worker misses the event
            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            local shm = ngx.shared.test_shm
            assert(shm:set(checker.TARGET_STATE .. ":127.0.0.1:11111:127.0.0.1", 2))

            local deadline = ngx.now() + 3
            repeat
                ngx.sleep(0.05)
                ngx.update_time()
            until checker:get_target_status("127.0.0.1", 11111) == false
                  or ngx.now() >= deadline
            ngx.say(checker:get_target_status("127.0.0.1", 11111))
        }
    }
--- request
GET /t
--- response_body
false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/
--- timeout: 6



=== TEST 2: the purge of a delayed_clear() target writes the list of that checker's shm
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            healthcheck._set_cleanup_interval(0.2)
            local function new_checker(name, shm_name)
                return assert(healthcheck.new({
                    name = name,
                    shm_name = shm_name,
                    events_module = "resty.events",
                    checks = {
                        active = {
                            healthy = { interval = 0 },
                            unhealthy = { interval = 0 },
                        },
                    },
                }))
            end
            -- the first checker created starts the timer, with its own shm
            local a = new_checker("a", "test_shm")
            local b = new_checker("b", "test_shm2")
            assert(b:add_target("127.0.0.1", 11111, nil, true))
            assert(b:delayed_clear(0.1))

            local deadline = ngx.now() + 3
            repeat
                ngx.sleep(0.05)
                ngx.update_time()
            until #healthcheck.get_target_list("b", "test_shm2") == 0
                  or ngx.now() >= deadline
            ngx.say(#healthcheck.get_target_list("b", "test_shm2"), " ",
                    tostring(ngx.shared.test_shm:get(b.TARGET_LIST)), " ",
                    a ~= nil)
        }
    }
--- request
GET /t
--- response_body
0 nil true
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/
--- timeout: 6
