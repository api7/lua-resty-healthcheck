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

        -- While the request holds the list lock, the retry should hold the
        -- target lock. Probe with a zero timeout so a miss is observable.
        function wait_for_target_lock(checker)
            local key = checker.TARGET_LOCK .. ":127.0.0.1:11111:127.0.0.1"
            local probe = assert(require("resty.lock"):new(checker.shm_name, { timeout = 0 }))
            local deadline = ngx.now() + 2
            repeat
                local elapsed, err = probe:lock(key)
                if not elapsed then
                    assert(err == "timeout", err)
                    return
                end
                assert(probe:unlock())
                assert(ngx.now() < deadline, "retry did not acquire the target lock")
                ngx.sleep(0.01)
            until false
        end

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

our $WriteConfig = <<'NGINX';
    location ~ ^/(list-add|target-add|target-remove)$ {
        set_by_lua_block $test {
            local checker = _G.checker
            local removing = ngx.var.uri == "/target-remove"
            if removing then
                assert(checker:add_target("127.0.0.1", 11111, nil, false) == true)
            end
            local key = checker.TARGET_LIST_LOCK
            if ngx.var.uri ~= "/list-add" then
                key = checker.TARGET_LOCK .. ":127.0.0.1:11111:127.0.0.1"
            end
            ngx.ctx.list_before = checker.shm:get(checker.TARGET_LIST)
            local lock = assert(require("resty.lock"):new(checker.shm_name))
            assert(lock:lock(key))
            ngx.ctx.lock = lock

            local ok, err
            if removing then
                ok, err = checker:remove_target("127.0.0.1", 11111)
            else
                ok, err = checker:add_target("127.0.0.1", 11111, nil, false)
            end
            assert(ok == "scheduled", tostring(ok) .. ": " .. tostring(err))
            ngx.ctx.ok = ok
        }

        content_by_lua_block {
            local checker = _G.checker
            local we = require "resty.worker.events"
            local removing = ngx.var.uri == "/target-remove"
            local list_lock = ngx.ctx.lock
            if ngx.var.uri ~= "/list-add" then
                list_lock = assert(require("resty.lock"):new(checker.shm_name))
                assert(list_lock:lock(checker.TARGET_LIST_LOCK))
                assert(ngx.ctx.lock:unlock())
            end
            wait_for_target_lock(checker)
            assert(checker.shm:get(checker.TARGET_LIST) == ngx.ctx.list_before)
            assert(list_lock:unlock())

            local deadline = ngx.now() + 5
            local healthcheck = require "resty.healthcheck"
            local expected_status
            if not removing then
                expected_status = false
            end
            local status, listed
            repeat
                we.poll()
                status = checker:get_target_status("127.0.0.1", 11111)
                listed = #healthcheck.get_target_list("testing", "test_shm")
                if status == expected_status and listed == (removing and 0 or 1) then
                    break
                end
                ngx.update_time()
                assert(ngx.now() < deadline, "scheduled target write did not finish")
                ngx.sleep(0.01)
            until false
            ngx.say(ngx.ctx.ok)
            ngx.say(tostring(status))
            ngx.say(listed)
        }
    }
NGINX

run_tests();

__DATA__

=== TEST 1: a retry caused by list-lock contention reacquires the target lock
--- http_config eval: $::HttpConfig
--- config eval: $::WriteConfig
--- request
GET /list-add
--- response_body
scheduled
false
1
--- no_error_log
[error]
--- timeout: 10




=== TEST 2: a deferred addition waits for both the target and list locks
--- http_config eval: $::HttpConfig
--- config eval: $::WriteConfig
--- request
GET /target-add
--- response_body
scheduled
false
1
--- no_error_log
[error]
--- timeout: 10



=== TEST 3: a deferred removal waits for both the target and list locks
--- http_config eval: $::HttpConfig
--- config eval: $::WriteConfig
--- request
GET /target-remove
--- response_body
scheduled
nil
0
--- no_error_log
[error]
--- timeout: 10
