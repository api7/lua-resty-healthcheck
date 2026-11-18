use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(2);
master_on();

plan tests => repeat_each() * blocks() * 3;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict test_sync 1m;
    lua_shared_dict my_worker_events 8m;

    init_worker_by_lua_block {
        local we = require "resty.worker.events"
        assert(we.configure({ shm = "my_worker_events", interval = 0.1 }))
        local shm = ngx.shared.test_sync
        local my_id = ngx.worker.id()
        assert(ngx.worker.count() == 2)

        -- Record the receiver, not the sender: both workers must prove that
        -- the real event transport reaches them before any target is added.
        we.register(function()
            assert(shm:set("connected:" .. my_id, true))
        end, "membership-barrier", "ping")

        local function all_set(prefix)
            return shm:get(prefix .. 0) and shm:get(prefix .. 1)
        end

        local function wait_for(cond, what)
            local deadline = ngx.now() + 5
            while not cond() do
                assert(not shm:get("failure"), shm:get("failure"))
                ngx.update_time()
                assert(ngx.now() < deadline, "timed out waiting for " .. what)
                ngx.sleep(0.01)
            end
        end

        local function arrive(phase)
            assert(shm:set(phase .. my_id, true))
            wait_for(function() return all_set(phase) end, phase)
        end

        assert(ngx.timer.at(0, function()
            local ok, err = pcall(function()
                local checker = assert(require("resty.healthcheck").new({
                    name = "membership",
                    shm_name = "test_shm",

                    checks = {
                        active = {
                            healthy = { interval = 0 },
                            unhealthy = { interval = 0 },
                        },
                    },
                }))

                -- Fault injection is limited to one receiver losing one add
                -- event. Later events still pass through the real transport
                -- and the unmodified handler; no target or version is seeded.
                local dropped = false
                if my_id == 1 then
                    local handler = checker.event_handler
                    checker.event_handler = function(self, event, ip, port, hostname)
                        if not dropped and event == self.events.healthy and port == 11111 then
                            dropped = true
                            return
                        end
                        return handler(self, event, ip, port, hostname)
                    end
                end

                local clear_events = 0
                we.register(function(_, event)
                    if event == checker.events.clear then
                        clear_events = clear_events + 1
                    end
                end, checker.EVENT_SOURCE)

                local function status(port)
                    local value, status_err = checker:get_target_status("127.0.0.1", port)
                    if status_err then
                        assert(status_err == "target not found", status_err)
                        return "unknown"
                    end
                    return tostring(value)
                end

                local results = {}
                local function record(label, before, pair)
                    local states = status(11111)
                    if pair then
                        states = states .. "," .. status(11112)
                    end
                    results[#results + 1] = label .. "=" .. states .. ":" ..
                                           (checker.status_ver - before)
                end

                arrive("subscribed:")
                wait_for(function()
                    if my_id == 0 then
                        assert(we.post("membership-barrier", "ping", true))
                    end
                    return all_set("connected:")
                end, "both receivers to get the barrier event")

                local before = checker.status_ver
                arrive("ready-to-add:")
                if my_id == 0 then
                    assert(checker:add_target("127.0.0.1", 11111, nil, true))
                end
                wait_for(function()
                    return my_id == 0 and status(11111) == "true" or my_id == 1 and dropped
                end, "the add event to reach both receivers")
                record("initial", before)

                before = checker.status_ver
                arrive("added:")
                if my_id == 0 then
                    assert(checker:set_target_status("127.0.0.1", 11111, nil, false))
                end
                wait_for(function() return status(11111) == "false" end, "unhealthy")
                -- A consumer such as APISIX treats unknown as usable. It must
                -- invalidate its cached picker when this worker learns false.
                record("unhealthy", before)

                before = checker.status_ver
                arrive("unhealthy:")
                if my_id == 0 then
                    assert(checker:remove_target("127.0.0.1", 11111, "127.0.0.1"))
                end
                wait_for(function() return status(11111) == "unknown" end, "removal")
                record("removed", before)

                before = checker.status_ver
                arrive("removed:")
                if my_id == 0 then
                    assert(checker:add_target("127.0.0.1", 11111, nil, false))
                    assert(checker:add_target("127.0.0.1", 11112, nil, false))
                end
                wait_for(function()
                    return status(11111) == "false" and status(11112) == "false"
                end, "both unhealthy targets")
                record("two_added", before, true)

                before = checker.status_ver
                arrive("two-added:")
                if my_id == 0 then
                    assert(checker:clear())
                    record("caller_clear", before, true)
                end
                wait_for(function()
                    return status(11111) == "unknown" and status(11112) == "unknown"
                           and clear_events == 1
                end, "the non-empty clear event")
                record("cleared", before, true)

                before = checker.status_ver
                arrive("cleared:")
                if my_id == 0 then
                    assert(checker:clear())
                end
                -- Observe delivery, not a delay: an empty clear must not bump
                -- either the caller or the other worker when its event arrives.
                wait_for(function() return clear_events == 2 end, "the empty clear event")
                record("empty_clear", before, true)
                assert(shm:set("result:" .. my_id, table.concat(results, " | ")))
            end)
            if not ok then
                assert(shm:set("failure", tostring(err)))
                assert(shm:set("result:" .. my_id, "failed: " .. tostring(err)))
            end
        end))
    }

};

run_tests();

__DATA__

=== TEST 1: two workers version new unhealthy targets, removal, and non-empty clear after a lost add event
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local shm = ngx.shared.test_sync
            local deadline = ngx.now() + 40
            while not (shm:get("result:0") and shm:get("result:1")) do
                ngx.update_time()
                assert(ngx.now() < deadline, "workers did not finish")
                ngx.sleep(0.01)
            end
            for id = 0, 1 do
                ngx.say("worker ", id, ": ", shm:get("result:" .. id))
            end
        }
    }
--- request
GET /t
--- response_body
worker 0: initial=true:1 | unhealthy=false:1 | removed=unknown:1 | two_added=false,false:2 | caller_clear=unknown,unknown:1 | cleared=unknown,unknown:1 | empty_clear=unknown,unknown:0
worker 1: initial=unknown:0 | unhealthy=false:1 | removed=unknown:1 | two_added=false,false:2 | cleared=unknown,unknown:1 | empty_clear=unknown,unknown:0
--- timeout: 45
--- no_error_log
[error]
