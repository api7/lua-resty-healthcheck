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

        function new_checker(shm_name, name)
            if not worker_events_configured then
                local we = require "resty.worker.events"
                assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
                worker_events_configured = true
            end
            return assert(require("resty.healthcheck").new({
                name = name or "testing",
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
qr/\[error\].*\[healthcheck\] shm 'small_shm' is full: a target list \('lua-resty-healthcheck:testing:target_list'\) could not be stored(?:, other entries were evicted trying)?, and the value it had before, if any, is gone\. This shm holds .* increase the size of this lua_shared_dict/



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
qr/\[error\].*\[healthcheck\] shm 'test_shm' no longer has the target list of checker 'testing', for which this worker has 2 target\(s\): it was evicted, or a write of it failed, most likely because the shm is full\. This shm holds .* increase the size of this lua_shared_dict/



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



=== TEST 6: a warning about evictions does not hide the error about a lost target list
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            healthcheck._set_cleanup_interval(0.2)
            fill(ngx.shared.small_shm)
            local checker = new_checker("small_shm")
            -- these writes evict entries: one warning, and no other for a minute
            assert(checker:add_target(ip, 11111, nil, true))
            assert(checker:add_target(ip, 22222, nil, true))
            local deadline = ngx.now() + 2
            while not (checker:get_target_status(ip, 11111) and checker:get_target_status(ip, 22222))
                  and ngx.now() < deadline do
                ngx.sleep(0.01)
                ngx.update_time()
            end

            -- the list is lost; the periodic cleanup reads it
            ngx.shared.small_shm:delete(checker.TARGET_LIST)
            ngx.sleep(0.8)
            ngx.say("done")
        }
    }
--- request
GET /t
--- response_body
done
--- grep_error_log eval
qr/\[(?:warn|error)\] .*?\[healthcheck\] shm 'small_shm' (?:is full: storing|no longer has the target list)/
--- grep_error_log_out eval
qr/\A\[warn\] [^\n]*shm 'small_shm' is full: storing\n\[error\] [^\n]*shm 'small_shm' no longer has the target list\n\z/



=== TEST 7: add(), replace() and incr() are checked as well, with their return values unchanged, and other methods are passed through
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            healthcheck._set_shm_report_interval(0)
            local checker = new_checker("small_shm")
            local shm, raw = checker.shm, ngx.shared.small_shm
            local state_key = checker.TARGET_STATE .. ":added"
            local counter_key = checker.TARGET_COUNTER .. ":" .. string.rep("c", 64)
            fill(raw)
            local ok, err, forcible = shm:add(state_key, string.rep("x", 64))
            ngx.say("add: ", tostring(ok), " ", tostring(err), " ", tostring(forcible))
            local n
            n, err, forcible = shm:incr(counter_key, 256, 0)
            ngx.say("incr: ", tostring(n), " ", tostring(err), " ", tostring(forcible))
            -- as many return values as the dictionary gives
            local raw_incr = select("#", raw:incr(counter_key, 1))
            local raw_add = select("#", raw:add(state_key, 1))
            ngx.say("values: ", select("#", shm:incr(counter_key, 1)), " ", raw_incr, " ",
                    select("#", shm:add(state_key, 1)), " ", raw_add)
            ok, err = shm:replace(state_key, string.rep("x", 100000))
            ngx.say("replace: ", tostring(ok), " ", tostring(err))
            -- a key that is not a string
            ngx.say("number key: ", tostring((pcall(shm.set, shm, 123, string.rep("x", 100000)))))
            ngx.say("passed through: ", tostring(shm:capacity() == raw:capacity()), " ",
                    type(shm:free_space()), " ", tostring(shm:ttl("nosuch")))
        }
    }
--- request
GET /t
--- response_body
add: true nil true
incr: 256 nil true
values: 1 1 3 3
replace: false no memory
number key: true
passed through: true number nil
--- grep_error_log eval
qr/shm 'small_shm' is full: [a-z ]+ \('(?:lua-resty-healthcheck:testing:[a-z]+:[a-z]{5}|123)[^']*'\) (?:evicted other entries|could not be stored)/
--- grep_error_log_out eval
"shm 'small_shm' is full: storing the state of a target ('lua-resty-healthcheck:testing:state:added') evicted other entries
shm 'small_shm' is full: storing the counter of a target ('lua-resty-healthcheck:testing:counter:" . ("c" x 64) . "') evicted other entries
shm 'small_shm' is full: the state of a target ('lua-resty-healthcheck:testing:state:added') could not be stored
shm 'small_shm' is full: a key ('123') could not be stored
"



=== TEST 8: each shm has its own reports
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local c1 = new_checker("small_shm", "one")
            local c2 = new_checker("test_shm", "two")
            local too_large = string.rep("x", 9 * 1024 * 1024)
            c1.shm:set(c1.TARGET_STATE .. ":a", too_large)
            c2.shm:set(c2.TARGET_STATE .. ":a", too_large)
            ngx.say("done")
        }
    }
--- request
GET /t
--- response_body
done
--- grep_error_log eval
qr/shm '[a-z_]+' is full: the state of a target/
--- grep_error_log_out
shm 'small_shm' is full: the state of a target
shm 'test_shm' is full: the state of a target



=== TEST 9: get_target_list() of the module reports nothing for a list that is not there
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = new_checker("test_shm")
            ngx.say(#healthcheck.get_target_list("nosuch", "test_shm"))
            assert(checker:add_target(ip, 11111, nil, true))
            ngx.shared.test_shm:delete(checker.TARGET_LIST)
            ngx.say(#healthcheck.get_target_list("testing", "test_shm"))
        }
    }
--- request
GET /t
--- response_body
0
0
--- no_error_log eval
qr/\[healthcheck\] shm '/



=== TEST 10: a clock that is set back does not silence the reports
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            -- the library takes its reference to ngx.now when it is loaded
            local real_now, offset = ngx.now, 0
            ngx.now = function() return real_now() + offset end
            local checker = new_checker("small_shm")
            local key = checker.TARGET_STATE .. ":" .. ip .. ":11111:" .. ip
            local too_large = string.rep("x", 100000)
            checker.shm:set(key, too_large)   -- reported
            checker.shm:set(key, too_large)   -- inside the interval: skipped
            offset = -3600
            checker.shm:set(key, too_large)   -- an hour earlier: reported
            ngx.now = real_now
            ngx.say("done")
        }
    }
--- request
GET /t
--- response_body
done
--- grep_error_log eval
qr/shm 'small_shm' is full: the state of a target/
--- grep_error_log_out
shm 'small_shm' is full: the state of a target
shm 'small_shm' is full: the state of a target
