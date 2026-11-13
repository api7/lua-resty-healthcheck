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

=== TEST 1: the purge of a delayed_clear() target updates the target list in that checker's own shm
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
            -- the first checker created in a worker starts the timer that
            -- purges the targets of every checker
            local a = new_checker("a", "test_shm")
            local b = new_checker("b", "test_shm2")
            local removes = 0
            local on_event = function(_, event)
                if event == "remove" then
                    removes = removes + 1
                end
            end
            require("resty.events.compat").register(on_event, b.EVENT_SOURCE)
            assert(b:add_target("127.0.0.1", 11111, nil, true))
            assert(b:delayed_clear(0.1))

            local deadline = ngx.now() + 3
            repeat
                ngx.sleep(0.05)
                ngx.update_time()
            until #healthcheck.get_target_list("b", "test_shm2") == 0
                  or ngx.now() >= deadline

            -- the target is gone from b's list, and nothing of b was written
            -- to the shm of `a`
            ngx.say(#healthcheck.get_target_list("b", "test_shm2"), " ",
                    tostring(ngx.shared.test_shm:get(b.TARGET_LIST)), " ",
                    a ~= nil)
            -- a few more cleanup rounds (0.2s each): the target must not be
            -- purged again
            ngx.sleep(0.7)
            ngx.say("remove events: ", removes)
        }
    }
--- request
GET /t
--- response_body
0 nil true
remove events: 1
--- no_error_log
[error]
--- timeout: 6
