use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(4);
master_on();

plan tests => repeat_each() * blocks() * 3;

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
                    shm:set("result:" .. my_id, "timed out waiting for " .. what)
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
            -- worker holds the periodic lock and the others do not
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

            -- events must reach every worker before the target is added
            wait_for(function()
                we.post("barrier", "ping", my_id)
                return all_set("barrier:")
            end, deadline, "the events to reach every worker")

            if my_id == 0 then
                assert(checker:add_target("127.0.0.1", 11111, nil, true))
            end

            wait_for(function()
                return checker:get_target_status("127.0.0.1", 11111) == true
            end, deadline, "the target to show up as healthy")
            shm:set("ready:" .. my_id, true)

            if my_id == 0 then
                wait_for(function() return all_set("ready:") end, deadline,
                         "every worker to have the target")
                -- the event of this change is lost: no worker gets it
                local post = we.post
                we.post = function() return true end
                assert(checker:set_target_status("127.0.0.1", 11111, nil, false))
                we.post = post
                ngx.update_time()
                shm:set("changed_at", ngx.now())
            end

            wait_for(function() return shm:get("changed_at") end, deadline, "the change")
            local converge_deadline = ngx.now() + 3
            while checker:get_target_status("127.0.0.1", 11111) ~= false do
                ngx.update_time()
                if ngx.now() >= converge_deadline then
                    shm:set("result:" .. my_id, "not corrected")
                    return
                end
                ngx.sleep(0.01)
            end

            ngx.update_time()
            local elapsed = ngx.now() - shm:get("changed_at")
            shm:set("result:" .. my_id, elapsed <= 1 and "corrected"
                                        or ("corrected late: " .. elapsed))
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

=== TEST 1: every worker corrects its copy when the event of a change is lost for all of them
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local shm = ngx.shared.test_shm
            local deadline = ngx.now() + 10
            local results
            repeat
                results = {}
                for i = 0, ngx.worker.count() - 1 do
                    results[#results + 1] = shm:get("result:" .. i)
                end
                ngx.sleep(0.05)
                ngx.update_time()
            until #results == ngx.worker.count() or ngx.now() >= deadline
            for i = 0, ngx.worker.count() - 1 do
                ngx.say("worker ", i, ": ", tostring(shm:get("result:" .. i)))
            end
        }
    }
--- request
GET /t
--- response_body
worker 0: corrected
worker 1: corrected
worker 2: corrected
worker 3: corrected
--- timeout: 15
--- no_error_log eval
qr/\[error\](?!.*(?:lua tcp socket read timed out|failed to communicate with broker|event worker failed))/
