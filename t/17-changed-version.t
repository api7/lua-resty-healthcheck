use Test::Nginx::Socket::Lua 'no_plan';
use Cwd qw(cwd);

workers(1);


my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
};

run_tests();

__DATA__

=== TEST 1: add_target() adds an unhealthy target
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
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
            local ok, err = checker:add_target("127.0.0.1", 11111, nil)
            ngx.say(ok)
            ngx.sleep(0.4) -- wait twice the interval
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
checking healthy targets: nothing to do
checking unhealthy targets: nothing to do
checking unhealthy targets: #1

--- no_error_log
checking healthy targets: #1
