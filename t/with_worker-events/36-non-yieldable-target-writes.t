use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * blocks() * 3;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;

    init_worker_by_lua_block {
        local we = require "resty.worker.events"
        assert(we.configure{ shm = "my_worker_events", interval = 0.1 })

        _G.checker = assert(require("resty.healthcheck").new({
            name = "testing",
            shm_name = "test_shm",
            checks = {
                active = {
                    healthy = { interval = 0 },
                    unhealthy = { interval = 0 },
                },
            },
        }))
    }
};

run_tests();

__DATA__

=== TEST 1: a scheduled target write acquires both locks again
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        set_by_lua_block $test {
            local checker = _G.checker
            local lock = assert(require("resty.lock"):new(checker.shm_name))
            assert(lock:lock(checker.TARGET_LIST_LOCK))
            ngx.ctx.lock = lock

            local ok, err = checker:add_target("127.0.0.1", 11111, nil, false)
            assert(ok == "scheduled", tostring(ok) .. ": " .. tostring(err))
            ngx.ctx.ok = ok
        }

        content_by_lua_block {
            local checker = _G.checker
            local we = require "resty.worker.events"
            ngx.sleep(0.1)
            we.poll()
            assert(checker:get_target_status("127.0.0.1", 11111) == nil)
            assert(ngx.ctx.lock:unlock())

            local deadline = ngx.now() + 5
            local status
            repeat
                we.poll()
                status = checker:get_target_status("127.0.0.1", 11111)
                if status ~= nil then
                    break
                end
                ngx.update_time()
                assert(ngx.now() < deadline, "scheduled target write did not finish")
                ngx.sleep(0.01)
            until false
            ngx.say(ngx.ctx.ok)
            ngx.say(tostring(status))
            ngx.say(#require("resty.healthcheck").get_target_list("testing", "test_shm"))
        }
    }
--- request
GET /t
--- response_body
scheduled
false
1
--- no_error_log
[error]
--- timeout: 10




=== TEST 2: a target-lock contention also retries with both locks
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        set_by_lua_block $test {
            local checker = _G.checker
            local key = checker.TARGET_LOCK .. ":127.0.0.1:11111:127.0.0.1"
            local lock = assert(require("resty.lock"):new(checker.shm_name))
            assert(lock:lock(key))
            ngx.ctx.lock = lock

            local ok, err = checker:add_target("127.0.0.1", 11111, nil, false)
            assert(ok == "scheduled", tostring(ok) .. ": " .. tostring(err))
            ngx.ctx.ok = ok
        }

        content_by_lua_block {
            local checker = _G.checker
            local we = require "resty.worker.events"
            ngx.sleep(0.1)
            we.poll()
            assert(checker:get_target_status("127.0.0.1", 11111) == nil)
            assert(ngx.ctx.lock:unlock())

            local deadline = ngx.now() + 5
            local status
            repeat
                we.poll()
                status = checker:get_target_status("127.0.0.1", 11111)
                if status ~= nil then
                    break
                end
                ngx.update_time()
                assert(ngx.now() < deadline, "scheduled target write did not finish")
                ngx.sleep(0.01)
            until false
            ngx.say(ngx.ctx.ok)
            ngx.say(tostring(status))
            ngx.say(#require("resty.healthcheck").get_target_list("testing", "test_shm"))
        }
    }
--- request
GET /t
--- response_body
scheduled
false
1
--- no_error_log
[error]
--- timeout: 10
