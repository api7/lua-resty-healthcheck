use Test::Nginx::Socket::Lua 'no_plan';
use Cwd qw(cwd);

workers(2);
master_on();

my $pwd = cwd();
$ENV{TEST_NGINX_SERVROOT} = server_root();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;

    init_worker_by_lua_block {
        local we = require "resty.events.compat"
        assert(we.configure({
            unique_timeout = 5,
            broker_id = 0,
            listening = "unix:$ENV{TEST_NGINX_SERVROOT}/worker_events.sock"
        }))
        assert(we.configured())

        local shm = ngx.shared.test_shm
        local worker_count = ngx.worker.count()
        local my_id = ngx.worker.id()

        local function all_set(prefix)
            for i = 0, worker_count - 1 do
                if not shm:get(prefix .. i) then
                    return false
                end
            end
            return true
        end

        local function wait_for(cond, deadline, what)
            while not cond() do
                ngx.update_time()
                if ngx.now() >= deadline then
                    error("timed out waiting for " .. what)
                end
                ngx.sleep(0.02)
            end
        end

        we.register(function(data)
            shm:set("barrier:" .. tostring(data), true)
        end, "barrier", "ping")

        ngx.timer.at(0, function()
            local healthcheck = require("resty.healthcheck")
            -- active checks are enabled (but not due during the test), so one
            -- worker holds the periodic lock and the other one does not
            local checker = assert(healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 999 },
                        unhealthy = { interval = 999 },
                    },
                },
            }))

            local deadline = ngx.now() + 5

            -- broadcasts must reach every worker before the target is added
            -- (there is no replay for workers that connect later)
            wait_for(function()
                we.post("barrier", "ping", my_id)
                return all_set("barrier:")
            end, deadline, "the broadcast barrier")

            if my_id == 0 then
                assert(checker:add_target("127.0.0.1", 11111, nil, true))
            end

            wait_for(function()
                return checker:get_target_status("127.0.0.1", 11111) == true
            end, deadline, "the target to show up as healthy")

            -- from now on every worker misses the checker's events
            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            shm:set("unsub:" .. my_id, true)

            if my_id == 0 then
                wait_for(function() return all_set("unsub:") end, deadline,
                         "every worker to unsubscribe")
                ngx.update_time()
                shm:set("flipped_at", ngx.now())
                assert(checker:set_target_status("127.0.0.1", 11111, nil, false))
            end

            local converge_deadline = ngx.now() + 3
            while checker:get_target_status("127.0.0.1", 11111) ~= false do
                ngx.update_time()
                if ngx.now() >= converge_deadline then
                    shm:set("result:" .. my_id, "stuck")
                    return
                end
                ngx.sleep(0.01)
            end

            ngx.update_time()
            local elapsed = ngx.now() - (shm:get("flipped_at") or ngx.now())
            shm:set("result:" .. my_id, elapsed <= 0.5 and "converged"
                                        or ("slow: " .. elapsed))
        end)
    }

    server {
        server_name kong_worker_events;
        listen unix:$ENV{TEST_NGINX_SERVROOT}/worker_events.sock;
        access_log off;
        location / {
            content_by_lua_block {
                require("resty.events.compat").run()
            }
        }
    }
};

run_tests();

__DATA__

=== TEST 1: every worker reconciles a missed status event, lock holder or not
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local shm = ngx.shared.test_shm
            local deadline = ngx.now() + 8
            while true do
                local r0, r1 = shm:get("result:0"), shm:get("result:1")
                ngx.update_time()
                if (r0 and r1) or ngx.now() >= deadline then
                    ngx.say("worker 0: ", tostring(r0))
                    ngx.say("worker 1: ", tostring(r1))
                    return
                end
                ngx.sleep(0.05)
            end
        }
    }
--- request
GET /t
--- response_body
worker 0: converged
worker 1: converged
--- no_error_log
[error]
--- timeout: 10
