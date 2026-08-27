use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * (blocks() * 3) - 2;

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

=== TEST 1: a target's local health cache self-heals from shm after a missed event
# A worker's local self.targets cache is updated in two ways: (1) the
# worker_events broadcast raised once per state transition by incr_counter,
# or (2) nothing else -- get_target_status() only ever reads the local
# cache, never shm. If a worker misses that one broadcast (a worker_events
# delivery drop, or losing the add_target() "already exists in shm" race so
# no event is raised for it in the first place), its view of that target's
# health is permanently wrong: incr_counter never raises the same-state
# transition again, so there is no second chance to receive it.
#
# This writes directly to the shared dict, bypassing incr_counter/raise_event
# entirely, to simulate exactly that: shm updated, no event delivered. Before
# the reconcile sweep runs, get_target_status() must still report the stale
# ("healthy") value. After one sweep interval, it must have converged to the
# shm value ("unhealthy") on its own, with no event ever posted for it.
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })

            local healthcheck = require("resty.healthcheck")
            healthcheck._set_reconcile_interval(0.3)

            local checker = healthcheck.new({
                name = "test-missed-event-reconcile",
                shm_name = "test_shm",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            if not checker then
                ngx.say("failed to create checker")
                return
            end

            local ok, err = checker:add_target("127.0.0.1", 12345)
            if not ok then
                ngx.say("failed to add target: ", err)
                return
            end
            ngx.sleep(0.2) -- let add_target's own event settle locally

            local before = checker:get_target_status("127.0.0.1", 12345)
            ngx.say("before shm write: ", tostring(before))

            -- Simulate a dropped worker_events broadcast: mutate the
            -- authoritative shm state directly, without incr_counter/raise_event.
            local shm = ngx.shared["test_shm"]
            local state_key = checker.TARGET_STATE .. ":127.0.0.1:12345:127.0.0.1"
            local ok, err = shm:set(state_key, 2) -- INTERNAL_STATES[2] == "unhealthy"
            if not ok then
                ngx.say("failed to poke shm: ", err)
                return
            end

            -- immediately after the shm write: the local cache has NOT been
            -- told anything, so it must still read the pre-existing value
            local immediately_after = checker:get_target_status("127.0.0.1", 12345)
            ngx.say("immediately after shm write: ", tostring(immediately_after))

            ngx.sleep(0.6) -- past the 0.3s test reconcile interval

            local after_reconcile = checker:get_target_status("127.0.0.1", 12345)
            ngx.say("after reconcile: ", tostring(after_reconcile))

            checker:stop()
        }
    }
--- request
GET /t
--- response_body
before shm write: true
immediately after shm write: true
after reconcile: false
--- grep_error_log eval
qr/reconciled target status from shm/
--- grep_error_log_out
reconciled target status from shm
--- no_error_log
[error]
--- timeout: 5
