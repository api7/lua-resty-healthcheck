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

=== TEST 1: an event delivered after a newer change was reconciled does not roll the copy back
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
            ngx.sleep(0.3)

            -- a slow subscriber to another source keeps this worker's queue busy
            local slow_done = false
            we.register(function() ngx.sleep(0.6); slow_done = true end, "filler", "slow")
            we.register(function() end, "filler", "fast")
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
                    " slow_done=", tostring(slow_done))
        }
    }
--- request
GET /t
--- response_body
shm=healthy local=true slow_done=true
--- error_log
queue overflow
--- timeout: 8
