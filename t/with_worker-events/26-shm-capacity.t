use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * (blocks() * 3 + 1);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict small_shm 16k;
    lua_shared_dict my_worker_events 8m;

    init_by_lua_block {
        _G.__TESTING_HEALTHCHECKER = true
        ip = "127.0.0.1"

        function new_checker(shm_name)
            if not worker_events_configured then
                local we = require "resty.worker.events"
                assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
                worker_events_configured = true
            end
            return assert(require("resty.healthcheck").new({
                name = "testing",
                shm_name = shm_name,
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            }))
        end

        -- fills a shm until it starts evicting entries to store new ones
        function fill(shm)
            local n = 0
            repeat
                n = n + 1
                local ok, err, forcible = shm:set("filler:" .. n, string.rep("x", 64))
                assert(ok, err)
            until forcible
            return n
        end
    }
};

run_tests();

__DATA__

=== TEST 1: a write that evicts other entries is reported, with the name of the shm and what to do
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local checker = new_checker("small_shm")
            fill(ngx.shared.small_shm)
            for port = 11111, 11115 do
                -- the result does not matter here: the shm is full
                checker:add_target(ip, port, nil, true)
            end
            ngx.say("done")
        }
    }
--- request
GET /t
--- response_body
done
--- error_log eval
qr/\[warn\].*\[healthcheck\] shm 'small_shm' is full: storing [a-z ]+ \('lua-resty-healthcheck:testing:[^']+'\) evicted other entries\. This shm holds .* increase the size of this lua_shared_dict/



=== TEST 2: a write that fails for lack of memory is reported, and add_target() returns the error
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local checker = new_checker("small_shm")
            -- the metadata of the target makes its list larger than the shm
            local ok, err = checker:add_target(ip, 11111, nil, true, nil,
                                               { blob = string.rep("x", 100000) })
            ngx.say(tostring(ok), " ", tostring(err))
        }
    }
--- request
GET /t
--- response_body
nil failed to store target_list in shm: no memory
--- error_log eval
qr/\[error\].*\[healthcheck\] shm 'small_shm' is full: a target list \('lua-resty-healthcheck:testing:target_list'\) could not be stored(?:, and other entries were evicted trying)?\. This shm holds .* increase the size of this lua_shared_dict/



=== TEST 3: at most one report per interval for a shm, and the next one says how many were skipped
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = new_checker("small_shm")
            local key = checker.TARGET_STATE .. ":" .. ip .. ":11111:" .. ip
            local too_large = string.rep("x", 100000)
            for _ = 1, 5 do
                local ok, err = checker.shm:set(key, too_large)
                assert(not ok and err == "no memory")
            end
            healthcheck._set_shm_report_interval(0)
            checker.shm:set(key, too_large)
            ngx.say("done")
        }
    }
--- request
GET /t
--- response_body
done
--- error_log
increase the size of this lua_shared_dict (4 more report(s) like this were skipped since the last one)
--- grep_error_log eval
qr/shm 'small_shm' is full: the state of a target|increase the size of this lua_shared_dict(?: \(\d+ more report\(s\) like this were skipped since the last one\))?/
--- grep_error_log_out
shm 'small_shm' is full: the state of a target
shm 'small_shm' is full: the state of a target



=== TEST 4: a checker whose target list is gone from the shm is reported, without any API call
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            healthcheck._set_cleanup_interval(0.2)
            local checker = new_checker("test_shm")
            assert(checker:add_target(ip, 11111, nil, true))
            assert(checker:add_target(ip, 22222, nil, true))
            local deadline = ngx.now() + 2
            while not (checker:get_target_status(ip, 11111) and checker:get_target_status(ip, 22222))
                  and ngx.now() < deadline do
                ngx.sleep(0.01)
                ngx.update_time()
            end

            -- evicted from a full shm; the periodic cleanup reads the list
            ngx.shared.test_shm:delete(checker.TARGET_LIST)
            ngx.sleep(0.8)
            ngx.say("done")
        }
    }
--- request
GET /t
--- response_body
done
--- error_log eval
qr/\[error\].*\[healthcheck\] shm 'test_shm' no longer has the target list of checker 'testing', for which this worker has 2 target\(s\): it was evicted, most likely because the shm is full\. This shm holds .* increase the size of this lua_shared_dict/



=== TEST 5: nothing is reported in normal operation, nor for a checker that has no targets yet
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            healthcheck._set_cleanup_interval(0.2)
            local checker = new_checker("test_shm")
            -- no target list in the shm yet, and no targets in this worker
            ngx.sleep(0.5)
            assert(checker:add_target(ip, 11111, nil, true))
            assert(checker:set_target_status(ip, 11111, nil, false) ~= nil)
            assert(checker:remove_target(ip, 11111, ip))
            assert(checker:clear())
            ngx.sleep(0.5)
            ngx.say("done")
        }
    }
--- request
GET /t
--- response_body
done
--- no_error_log eval
qr/\[healthcheck\] shm '/
