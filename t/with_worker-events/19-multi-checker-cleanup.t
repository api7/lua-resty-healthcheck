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

=== TEST 1: stale-target cleanup runs for every checker, not just the first one
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })

            local healthcheck = require("resty.healthcheck")
            -- shorten the cleanup window so it fires within the test
            healthcheck._set_cleanup_interval(0.2)

            local function new_checker(name)
                return assert(healthcheck.new({
                    name = name,
                    shm_name = "test_shm",
                    checks = {
                        active = {
                            type = "tcp",
                            healthy   = { interval = 0.1 },
                            unhealthy = { interval = 0.1 },
                        }
                    }
                }))
            end

            -- two upstreams, each with health checks enabled
            local checker1 = new_checker("upstream-1")
            local checker2 = new_checker("upstream-2")

            for i = 1, 3 do
                assert(checker1:add_target("127.0.0.1", 20000 + i, nil, true))
                assert(checker2:add_target("127.0.0.1", 30000 + i, nil, true))
            end

            -- mark every target on both checkers for immediate delayed removal
            assert(checker1:delayed_clear(0))
            assert(checker2:delayed_clear(0))

            -- wait long enough for several cleanup windows to elapse
            ngx.sleep(1.5)

            local list1 = healthcheck.get_target_list("upstream-1", "test_shm")
            local list2 = healthcheck.get_target_list("upstream-2", "test_shm")

            -- Before the fix only the first checker in `hcs` is cleaned each
            -- window, so checker2 keeps its purge-marked targets forever.
            ngx.say("checker1 remaining: ", #list1)
            ngx.say("checker2 remaining: ", #list2)
        }
    }
--- request
GET /t
--- response_body
checker1 remaining: 0
checker2 remaining: 0
--- timeout: 5
