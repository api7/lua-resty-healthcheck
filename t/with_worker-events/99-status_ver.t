use Test::Nginx::Socket::Lua 'no_plan';
use Cwd qw(cwd);

workers(2);
master_on();

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;

    init_worker_by_lua_block {
        local we = require "resty.worker.events"
        assert(we.configure{ shm = "my_worker_events", interval = 0.1 })

        -- Cross-worker delivery barrier: the status-change event must be seen
        -- by every worker. To make the test deterministic we first confirm
        -- that events propagate to every worker before adding the target.
        -- Each worker repeatedly posts a ping carrying its own id; on receiving
        -- a ping every worker records the sender id in the shared dict. Once
        -- all worker ids have been observed, event propagation is proven and we
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
            -- be broadcast before every worker is subscribed.
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
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
            local deadline = ngx.now() + 5  -- bound the barrier wait so a
                                            -- missing worker fails loudly
                                            -- instead of spinning forever
            while true do
                we.post("barrier", "ping", my_id)
                we.poll()
                local seen = 0
                for i = 0, worker_count - 1 do
                    if shm:get("barrier:" .. tostring(i)) then
                        seen = seen + 1
                    end
                end
                if seen >= worker_count then
                    break
                end
                ngx.update_time()
                if ngx.now() >= deadline then
                    error("barrier not reached: " .. seen .. "/" ..
                          worker_count .. " workers synced before timeout")
                end
                ngx.sleep(0.05)
            end

            local ok, err = checker:add_target("127.0.0.1", 11111)
            if not ok then
                error(err)
            end
        end)
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
