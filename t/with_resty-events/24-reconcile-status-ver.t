use Test::Nginx::Socket::Lua 'no_plan';
use Cwd qw(cwd);

workers(1);

my $pwd = cwd();
$ENV{TEST_NGINX_SERVROOT} = server_root();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;

    init_worker_by_lua_block {
        _G.__TESTING_HEALTHCHECKER = true
        local we = require "resty.events.compat"
        assert(we.configure({
            unique_timeout = 5,
            broker_id = 0,
            listening = "unix:$ENV{TEST_NGINX_SERVROOT}/worker_events.sock"
        }))
        assert(we.configured())
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

=== TEST 1: backfilling a never-seen-locally healthy target bumps status_ver
# A target this worker's self.targets never held an entry for at all was not
# routable (get_target_status returns "target not found", never true). Once
# the reconcile sweep backfills it as healthy/mostly_healthy it becomes
# routable, which is exactly the kind of transition status_ver exists to
# signal to a consumer's routing cache -- so it must be bumped here the same
# way event_handler bumps it for a normal add.
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            healthcheck._set_reconcile_interval(0.3)

            local checker = healthcheck.new({
                name = "test-reconcile-status-ver-backfill",
                shm_name = "test_shm",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
                events_module = "resty.events",
            })
            if not checker then
                ngx.say("failed to create checker")
                return
            end

            -- Seed shm directly instead of add_target(): add_target() itself
            -- raises an event that would backfill self.targets, defeating the
            -- "never seen locally" scenario this test targets.
            local shm = ngx.shared["test_shm"]
            local ok, codec = pcall(require, "string.buffer")
            if not ok then
                codec = require("cjson.safe").new()
            end
            local target_list = { { ip = "127.0.0.1", port = 12349, hostname = "127.0.0.1" } }
            assert(shm:set(checker.TARGET_LIST, codec.encode(target_list)))
            assert(shm:set(checker.TARGET_STATE .. ":127.0.0.1:12349:127.0.0.1", 1)) -- "healthy"

            local before_status, before_err = checker:get_target_status("127.0.0.1", 12349)
            ngx.say("before reconcile: ", tostring(before_status), " err: ", tostring(before_err))
            local before_ver = checker.status_ver

            ngx.sleep(0.6) -- past the 0.3s test reconcile interval

            local after_status = checker:get_target_status("127.0.0.1", 12349)
            ngx.say("after reconcile: ", tostring(after_status))
            ngx.say("status_ver bumped: ", tostring(checker.status_ver > before_ver))

            checker:stop()
        }
    }
--- request
GET /t
--- response_body
before reconcile: nil err: target not found
after reconcile: true
status_ver bumped: true
--- no_error_log
[error]
--- timeout: 5

=== TEST 2: a stale local target removal bumps status_ver
# A target dropped by the reconcile sweep (missed remove event) was routable
# immediately beforehand (it was locally healthy); after the drop it is gone
# entirely (not routable). That is a routable -> not-routable transition and
# must bump status_ver the same way a genuine remove event does.
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            healthcheck._set_reconcile_interval(0.3)

            local checker = healthcheck.new({
                name = "test-reconcile-status-ver-remove",
                shm_name = "test_shm",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
                events_module = "resty.events",
            })
            if not checker then
                ngx.say("failed to create checker")
                return
            end

            local ok, err = checker:add_target("127.0.0.1", 12350, nil, true)
            if not ok then
                ngx.say("failed to add target: ", err)
                return
            end
            ngx.sleep(0.2) -- let add_target's own event settle locally

            local before_ver = checker.status_ver

            local ok, codec = pcall(require, "string.buffer")
            if not ok then
                codec = require("cjson.safe").new()
            end
            local shm = ngx.shared["test_shm"]
            local ok2, err2 = shm:set(checker.TARGET_LIST, codec.encode({}))
            if not ok2 then
                ngx.say("failed to poke shm: ", err2)
                return
            end

            ngx.sleep(0.6) -- past the 0.3s test reconcile interval

            local after_status, after_err = checker:get_target_status("127.0.0.1", 12350)
            ngx.say("after reconcile: ", tostring(after_status), " err: ", tostring(after_err))
            ngx.say("status_ver bumped: ", tostring(checker.status_ver > before_ver))

            checker:stop()
        }
    }
--- request
GET /t
--- response_body
after reconcile: nil err: target not found
status_ver bumped: true
--- no_error_log
[error]
--- timeout: 5
