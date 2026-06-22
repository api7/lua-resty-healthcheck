use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * (blocks() * 2);

my $pwd = cwd();
$ENV{TEST_NGINX_SERVROOT} = server_root();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;

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

=== TEST 1: periodic lock is released once no checker is active
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            -- the periodic lock is a single global key shared by every checker
            -- on this worker; see SHM_PREFIX .. ":period_lock:"
            local PERIODIC_LOCK = "lua-resty-healthcheck::period_lock:"
            local shm = ngx.shared.test_shm

            local checker = assert(healthcheck.new({
                name = "lock-release",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        type = "tcp",
                        healthy   = { interval = 0.1 },
                        unhealthy = { interval = 0.1 },
                    }
                }
            }))
            assert(checker:add_target("127.0.0.1", 21111, nil, true))

            -- let the periodic timer acquire the lock
            ngx.sleep(0.5)
            ngx.say("lock held while active: ", shm:get(PERIODIC_LOCK) ~= nil)

            -- stop the only checker: no active checker remains on this worker.
            -- Before the fix the timer keeps renewing the lock forever; after
            -- the fix the lock holder releases it so another worker that still
            -- owns active checkers can take over.
            checker:stop()

            -- wait past LOCK_PERIOD (CHECK_INTERVAL * 15 = 1.5s) and several ticks
            ngx.sleep(2)
            ngx.say("lock released after stop: ", shm:get(PERIODIC_LOCK) == nil)
        }
    }
--- request
GET /t
--- response_body
lock held while active: true
lock released after stop: true
--- timeout: 5
