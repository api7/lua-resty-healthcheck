use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(2);
master_on();
plan tests => repeat_each() * blocks() * 3;

my $pwd = cwd();
our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 128k;
    lua_shared_dict test_sync 64k;
    lua_shared_dict my_worker_events 1m;

    init_worker_by_lua_block {
        local we = require "resty.worker.events"
        assert(we.configure({ shm = "my_worker_events", interval = 0.1 }))
        local hc = require "resty.healthcheck"
        local dict, sync = ngx.shared.test_shm, ngx.shared.test_sync
        local ip, a, b = "127.0.0.1", "edge", "edge:target_list"
        local worker = ngx.worker.id()

        local function checker(name)
            return assert(hc.new({ name = name, shm_name = "test_shm" }))
        end

        local function wait_for(key)
            local deadline = ngx.now() + 5
            while not sync:get(key) do
                assert(not sync:get("error"), sync:get("error"))
                assert(ngx.now() < deadline, "timed out waiting for " .. key)
                ngx.sleep(0.01)
            end
        end

        local function leave_on_stage(c, port)
            assert(c:add_target(ip, port, nil, false))
            local main, stage = c.TARGET_LIST, assert(c.TARGET_LIST_STAGING)
            local before = assert(dict:get(main))

            -- The proposed value cannot fit even as a single entry.
            local ok, err = c:add_target(ip, port + 9, nil, true, nil,
                                         { blob = string.rep("x", dict:capacity() + 1) })
            assert(not ok and err:find("no memory", 1, true), err)
            assert(dict:get(main) == before and not dict:get(stage))
            assert(not dict:get(c.TARGET_STATE .. ":" .. ip .. ":" .. (port + 9) .. ":" .. ip))

            local shm, fillers, staged, retries = c.shm, {}, nil, 0
            c.shm = setmetatable({
                safe_set = function(_, key, value)
                    if key ~= main then
                        return shm:safe_set(key, value)
                    end
                    assert(dict:get(main) == before and dict:get(stage) == value)
                    staged = value
                    -- Occupy the remaining blocks of the size the new primary
                    -- needs, after its staging write has succeeded.
                    while true do
                        local label = string.rep("p", #key - 4) .. string.format("%04d", #fillers)
                        local added, why = dict:safe_add(label, value)
                        if not added then
                            assert(why == "no memory", why)
                            break
                        end
                        fillers[#fillers + 1] = label
                    end
                    local written, why = shm:safe_set(key, value)
                    assert(not written and why == "no memory" and not dict:get(main))
                    return written, why
                end,
                safe_add = function(_, key, value)
                    local added, why = shm:safe_add(key, value)
                    if key == main then
                        retries = retries + 1
                        assert(value == staged and not added and why == "no memory")
                    end
                    return added, why
                end,
            }, { __index = shm })

            ok, err = c:add_target(ip, port + 1, nil, true, nil,
                                   { blob = string.rep("z", 12000) })
            c.shm = shm
            assert(ok, err)
            assert(staged and staged ~= before and retries == 1)
            assert(not dict:get(main) and dict:get(stage) == staged)
            return function()
                for _, label in ipairs(fillers) do dict:delete(label) end
            end
        end

        local function check_list(name, port, recovered)
            local list = assert(hc.get_target_list(name, "test_shm"))
            assert(#list == (recovered and 1 or 2), name .. " member count")
            if not recovered then
                assert(list[1].port == port and list[1].status == "unhealthy", name)
            end
            local added = list[#list]
            assert(added.port == port + 1 and added.status == "healthy", name)
            assert(added.meta.blob == string.rep("z", 12000))
        end

        local function check_stale_reporter(c)
            -- The local worker missed a removal event. The authoritative list
            -- excludes this target throughout both concurrent publications.
            local port = 11999
            c:event_handler(c.events.healthy, ip, port, ip)
            assert(c:get_target_status(ip, port) == true)
            local shm, step = c.shm, 0
            local main, stage = c.TARGET_LIST, c.TARGET_LIST_STAGING
            local members = assert(dict:get(main))
            assert(dict:safe_add(stage, members))
            dict:delete(main)
            c.shm = setmetatable({ get = function(_, key)
                local value = shm:get(key)
                if step == 0 and key == main then
                    assert(not value)
                    assert(dict:safe_add(main, members))
                    dict:delete(stage)
                    step = 1
                elseif step == 1 and key == stage then
                    -- An unlocked second lookup can miss the retired stage;
                    -- the next publication then drops the primary before lookup three.
                    assert(not value)
                    assert(dict:safe_add(stage, members))
                    local ok, err = dict:safe_set(main, string.rep("x", dict:capacity() + 1))
                    assert(not ok and err == "no memory" and not dict:get(main))
                    step = 2
                end
                return value
            end }, { __index = shm })
            assert(c:set_target_status(ip, port, ip, true))
            c.shm = shm
            assert(step > 0, "stale reporter did not consult membership")
            assert(not dict:get(c.TARGET_STATE .. ":" .. ip .. ":" .. port .. ":" .. ip),
                   "stale reporter resurrected a removed target")
        end

        assert(ngx.timer.at(0, function()
            local ok, err = pcall(function()
                assert(ngx.worker.count() == 2)
                assert(sync:set("pid:" .. worker, ngx.worker.pid()))
                if worker == 0 then
                    local first, second = checker(a), checker(b)
                    assert(sync:set("source", first.EVENT_SOURCE))
                    wait_for("subscribed")
                    local release_first = leave_on_stage(first, 11000)
                    release_first()
                    local release_second = leave_on_stage(second, 22000)
                    assert(sync:set("ready", true))
                    wait_for("observed")
                    assert(not dict:get(first.TARGET_LIST) and dict:get(first.TARGET_LIST_STAGING))
                    assert(not dict:get(second.TARGET_LIST) and dict:get(second.TARGET_LIST_STAGING))
                    release_second()
                    assert(sync:set("space", true))
                    wait_for("retried")
                    check_list(a, 11000, true)
                    check_list(b, 22000, false)
                else
                    wait_for("source")
                    local missed = checker(a)
                    assert(missed:stop())
                    we.register(function(data)
                        if data.port == 11001 then sync:set("event", true) end
                    end, sync:get("source"), "healthy")
                    assert(sync:set("subscribed", true))
                    wait_for("ready")
                    wait_for("event")
                    -- Both additions were delivered while this checker was stopped.
                    -- Its existing local copy must catch up from the staged list.
                    assert(missed:get_target_status(ip, 11000) == nil)
                    assert(missed:get_target_status(ip, 11001) == nil)
                    assert(missed:start())
                    local deadline = ngx.now() + 3
                    while missed:get_target_status(ip, 11000) ~= false or
                          missed:get_target_status(ip, 11001) ~= true do
                        assert(ngx.now() < deadline, "existing checker did not reconcile from staging")
                        ngx.sleep(0.01)
                    end
                    assert(not dict:get(missed.TARGET_LIST) and dict:get(missed.TARGET_LIST_STAGING))
                    check_list(a, 11000, false)
                    check_list(b, 22000, false)
                    local fresh = checker(a)
                    assert(fresh:get_target_status(ip, 11000) == false)
                    assert(fresh:get_target_status(ip, 11001) == true)
                    assert(sync:set("observed", true))
                    wait_for("space")
                    -- A read after capacity returns heals the legacy key.
                    -- No checker mutation or configuration change drives recovery.
                    check_list(a, 11000, false)
                    assert(dict:get(fresh.TARGET_LIST) and not dict:get(fresh.TARGET_LIST_STAGING))
                    check_stale_reporter(fresh)
                    assert(fresh:remove_target(ip, 11000, ip))
                    assert(sync:set("retried", true))
                end
                assert(sync:set("done:" .. worker, true))
            end)
            if not ok then
                sync:set("error", err)
            end
        end))
    }
};

run_tests();

__DATA__

=== TEST 1: two workers read committed staged lists and republish one checker independently
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local sync = ngx.shared.test_sync
            local deadline = ngx.now() + 8
            while not (sync:get("done:0") and sync:get("done:1")) do
                assert(not sync:get("error"), sync:get("error"))
                assert(ngx.now() < deadline, "workers did not finish")
                ngx.sleep(0.01)
            end
            assert(assert(sync:get("pid:0")) ~= assert(sync:get("pid:1")))
            ngx.say("both workers observed recovery and checker isolation")
        }
    }
--- request
GET /t
--- response_body
both workers observed recovery and checker isolation
--- timeout: 10
--- no_error_log
lua entry thread aborted
