use Test::Nginx::Socket::Lua 'no_plan';
use Cwd qw(cwd);

workers(1);

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

=== TEST 1: a stale local target is dropped when shm no longer has it (missed remove event)
# remove_target() mutates the TARGET_LIST (and TARGET_STATE) shm keys directly
# and then raises a single `remove` broadcast -- the same single-shot,
# no-resend mechanism incr_counter uses for health-state changes. A worker
# that misses that one broadcast keeps a target in its local self.targets
# cache that shm has already forgotten, so get_target_status() keeps
# reporting the last-known (here: healthy) status for a target that no
# longer exists at all, indefinitely.
#
# Simulate the drop by directly rewriting TARGET_LIST in shm to omit the
# target, exactly what remove_target() itself does, without calling
# remove_target() (so no `remove` event is ever posted). Before the reconcile
# sweep, the local cache must still report the stale "true". After one sweep
# interval, the target must be gone entirely (get_target_status errors with
# "target not found", matching what a real removal looks like locally).
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })

            local healthcheck = require("resty.healthcheck")
            healthcheck._set_reconcile_interval(0.3)

            local checker = healthcheck.new({
                name = "test-missed-remove-reconcile",
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

            -- keep a second, unrelated target so the sweep has to distinguish
            -- "still present" from "gone" rather than just seeing an empty list
            local ok, err = checker:add_target("127.0.0.1", 12347, nil, true)
            if not ok then
                ngx.say("failed to add target 12347: ", err)
                return
            end
            local ok, err = checker:add_target("127.0.0.1", 12348, nil, true)
            if not ok then
                ngx.say("failed to add target 12348: ", err)
                return
            end
            ngx.sleep(0.2) -- let both add_target events settle locally

            local before = checker:get_target_status("127.0.0.1", 12347)
            ngx.say("before shm removal: ", tostring(before))

            -- Simulate a dropped `remove` broadcast: rewrite TARGET_LIST in
            -- shm to omit the target, the same shm mutation remove_target()
            -- itself performs, but skip its raise_event call entirely.
            local ok, codec = pcall(require, "string.buffer")
            if not ok then
                codec = require("cjson.safe").new()
            end
            local shm = ngx.shared["test_shm"]
            local raw = shm:get(checker.TARGET_LIST)
            local target_list = codec.decode(raw)
            local new_list = {}
            for _, t in ipairs(target_list) do
                if not (t.ip == "127.0.0.1" and t.port == 12347) then
                    new_list[#new_list + 1] = t
                end
            end
            local ok, err = shm:set(checker.TARGET_LIST, codec.encode(new_list))
            if not ok then
                ngx.say("failed to poke shm: ", err)
                return
            end

            -- immediately after the shm write: the local cache has NOT been
            -- told anything, so it must still report the pre-existing value
            local immediately_after = checker:get_target_status("127.0.0.1", 12347)
            ngx.say("immediately after shm removal: ", tostring(immediately_after))

            ngx.sleep(0.6) -- past the 0.3s test reconcile interval

            local after_reconcile, after_err = checker:get_target_status("127.0.0.1", 12347)
            ngx.say("after reconcile: ", tostring(after_reconcile), " err: ", tostring(after_err))

            -- the untouched target must still be there and unaffected
            local other_status = checker:get_target_status("127.0.0.1", 12348)
            ngx.say("untouched target still healthy: ", tostring(other_status))

            checker:stop()
        }
    }
--- request
GET /t
--- response_body
before shm removal: true
immediately after shm removal: true
after reconcile: nil err: target not found
untouched target still healthy: true
--- grep_error_log eval
qr/reconciled stale local target no longer in shm \(missed remove event\)/
--- grep_error_log_out
reconciled stale local target no longer in shm (missed remove event)
--- no_error_log
[error]
--- timeout: 5
