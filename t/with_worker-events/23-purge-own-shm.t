use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * blocks() * 3;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict test_shm2 8m;
    lua_shared_dict my_worker_events 8m;

    init_worker_by_lua_block {
        -- Every run of the periodic cleanup begins by taking a key that ends
        -- in ":cleanup" with add(), in the shm of the first checker of the
        -- worker: the runs are counted.
        local cleanup_runs = 0
        local shm_methods = getmetatable(ngx.shared.test_shm).__index
        local shm_add = shm_methods.add
        shm_methods.add = function(dict, key, ...)
            local ok, err, forcible = shm_add(dict, key, ...)
            if ok and type(key) == "string" and key:sub(-8) == ":cleanup" then
                cleanup_runs = cleanup_runs + 1
            end
            return ok, err, forcible
        end

        -- waits until `runs` more of them have begun (5 s at most). A run is
        -- short and the next one begins an interval later: when two have
        -- begun, the first one is done.
        function wait_cleanups(runs)
            local target = cleanup_runs + runs
            local deadline = ngx.now() + 5
            while cleanup_runs < target do
                ngx.update_time()
                if ngx.now() >= deadline then
                    return false
                end
                ngx.sleep(0.01)
            end
            return true
        end

        _G.__TESTING_HEALTHCHECKER = true
    }
};

run_tests();

__DATA__

=== TEST 1: the purge of a delayed_clear() target updates the target list in that checker's own shm
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })

            local healthcheck = require("resty.healthcheck")
            healthcheck._set_cleanup_interval(0.2)
            local function new_checker(name, shm_name)
                return assert(healthcheck.new({
                    name = name,
                    shm_name = shm_name,
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
            we.register(on_event, b.EVENT_SOURCE)
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
            -- the event of that removal, and then a few more runs of the
            -- cleanup: the target must not be purged again
            deadline = ngx.now() + 5
            while removes == 0 and ngx.now() < deadline do
                ngx.sleep(0.01)
                ngx.update_time()
            end
            assert(wait_cleanups(3), "the periodic cleanup did not run")
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
--- timeout: 15
