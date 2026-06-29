use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * (blocks() * 2);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;

    init_worker_by_lua_block {
        _G.__TESTING_HEALTHCHECKER = true
    }
};

run_tests();

__DATA__

=== TEST 1: stale-target cleanup runs for a passive-only checker (no active checks)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })

            local healthcheck = require("resty.healthcheck")
            -- shorten the cleanup window so it fires within the test
            healthcheck._set_cleanup_interval(0.2)

            -- A passive-only checker: no active interval is configured, so
            -- checks.active.*.active stays false on every worker and the
            -- periodic timer never holds the lock for active probing. The
            -- delayed_clear() cleanup must still run, otherwise purge-marked
            -- targets leak forever (apache/apisix#13385).
            local checker = assert(healthcheck.new({
                name = "passive-only",
                shm_name = "test_shm",
                checks = {
                    passive = {
                        type = "http",
                        healthy   = { successes = 1 },
                        unhealthy = { http_failures = 1 },
                    }
                }
            }))

            for i = 1, 3 do
                assert(checker:add_target("127.0.0.1", 20000 + i, nil, true))
            end

            -- no active checker exists on this worker
            ngx.say("has active: ", not not (checker.checks.active.healthy.active or
                                  checker.checks.active.unhealthy.active))

            -- mark every target for immediate delayed removal
            assert(checker:delayed_clear(0))

            -- wait long enough for several cleanup windows to elapse
            ngx.sleep(1.5)

            local list = healthcheck.get_target_list("passive-only", "test_shm")
            ngx.say("remaining: ", #list)
        }
    }
--- request
GET /t
--- response_body
has active: false
remaining: 0
--- timeout: 5
