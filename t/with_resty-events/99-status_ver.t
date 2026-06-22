use Test::Nginx::Socket::Lua 'no_plan';
use Cwd qw(cwd);

workers(2);
master_on();

my $pwd = cwd();
$ENV{TEST_NGINX_SERVROOT} = server_root();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;

    init_worker_by_lua_block {
        local we = require "resty.events.compat"
        assert(we.configure({
            unique_timeout = 5,
            broker_id = 0,
            listening = "unix:$ENV{TEST_NGINX_SERVROOT}/worker_events.sock"
        }))
        assert(we.configured())

        -- Cross-worker delivery barrier: the status-change event is broadcast
        -- only to workers connected to the broker at publish time (there is no
        -- replay). To make the test deterministic we first confirm that
        -- broadcasts reach every worker before adding the target. Each worker
        -- repeatedly broadcasts a ping carrying its own id; on receiving a
        -- ping every worker records the sender id in the shared dict. Once all
        -- worker ids have been observed, broadcast delivery is proven and we
        -- add the target (whose later status change will then reach all
        -- workers).
        local worker_count = ngx.worker.count()
        local shm = ngx.shared.test_shm

        we.register(function(data)
            shm:set("barrier:" .. tostring(data), true)
        end, "barrier", "ping")

        ngx.timer.at(0, function()
            -- Create the checker (and thus register its event subscription)
            -- up front, but do not add the target yet, so no status change can
            -- be broadcast before every worker is subscribed and connected.
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy  = {
                            interval = 0.1
                        },
                        unhealthy  = {
                            interval = 0.1
                        }
                    }
                }
            })

            local my_id = ngx.worker.id()
            while true do
                we.post("barrier", "ping", my_id)
                local seen = 0
                for i = 0, worker_count - 1 do
                    if shm:get("barrier:" .. tostring(i)) then
                        seen = seen + 1
                    end
                end
                if seen >= worker_count then
                    break
                end
                ngx.sleep(0.05)
            end

            local ok, err = checker:add_target("127.0.0.1", 11111)
            if not ok then
                error(err)
            end
        end)
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

=== TEST 1: add_target() adds an unhealthy target
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            ngx.say(true)
            ngx.sleep(1) -- wait for the barrier handshake and status change
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
checking unhealthy targets: nothing to do
checking unhealthy targets: #1
--- grep_error_log eval: qr/from 'true' to 'false', ver: \d+/
--- grep_error_log_out eval
[
"from 'true' to 'false', ver: 2
from 'true' to 'false', ver: 2
",
]
