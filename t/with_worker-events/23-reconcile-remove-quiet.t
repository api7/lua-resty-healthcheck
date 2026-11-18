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
        -- events are polled once per second, the reconciliation runs every
        -- 0.1 s: the other worker reconciles a removal before its event
        assert(we.configure{ shm = "my_worker_events", interval = 1 })
        ngx.timer.at(0, function()
            local healthcheck = require("resty.healthcheck")
            local checker = assert(healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            }))
            if ngx.worker.id() == 0 then
                ngx.sleep(1.5)
                for port = 20001, 20010 do
                    assert(checker:add_target("127.0.0.1", port, nil, true))
                end
                ngx.sleep(2.5)
                for port = 20001, 20010 do
                    assert(checker:remove_target("127.0.0.1", port, "127.0.0.1"))
                end
            end
        end)
    }
};

run_tests();

__DATA__

=== TEST 1: a removal reconciled before its event arrives does not log a warning
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            ngx.sleep(6)
            ngx.say("done")
        }
    }
--- request
GET /t
--- response_body
done
--- no_error_log
trying to remove an unknown target
[error]
--- timeout: 10
