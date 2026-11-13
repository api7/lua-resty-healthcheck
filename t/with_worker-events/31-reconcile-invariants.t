use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * blocks() * 3;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict other_shm 8m;
    lua_shared_dict my_worker_events 8m;

    init_by_lua_block {
        _G.__TESTING_HEALTHCHECKER = true
        ip = "127.0.0.1"

        -- polls cond() until it returns true or the timeout (2 s) expires
        function wait_until(cond, timeout)
            local deadline = ngx.now() + (timeout or 2)
            while not cond() do
                ngx.update_time()
                if ngx.now() >= deadline then
                    return false
                end
                ngx.sleep(0.01)
            end
            return true
        end

        -- The library takes its references to ngx.sleep and ngx.timer.every
        -- when it is loaded, which is in the first new_checker() of a test.
        -- `yield_hook = { cond = f, fn = g }` calls g() the next time the
        -- library yields (ngx.sleep(0)) while f() holds.
        local real_sleep = ngx.sleep
        ngx.sleep = function(seconds)
            local hook = yield_hook
            if hook and seconds == 0 and hook.cond() then
                yield_hook = nil
                hook.fn()
            end
            return real_sleep(seconds)
        end

        -- the reconcile timer is not started: the test makes each of its runs
        -- with _reconcile(). To be called before the first new_checker().
        function no_reconcile_timer()
            ngx.timer.every = function() return true end
        end

        function events()
            local we = require "resty.worker.events"
            if not worker_events_configured then
                assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
                worker_events_configured = true
            end
            return we
        end

        -- two checkers with the same name stand for the checkers of two
        -- workers: each has its own copy of the targets
        function new_checker(name, shm_name)
            events()
            return assert(require("resty.healthcheck").new({
                name = name or "testing",
                shm_name = shm_name or "test_shm",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            }))
        end

        function status(checker, port)
            local ok, err = checker:get_target_status(ip, port)
            return tostring(ok) .. (err and ("/" .. err) or "")
        end

        function key_of(prefix, port)
            return prefix .. ":" .. ip .. ":" .. port .. ":" .. ip
        end

        -- runs fn() with the events it raises lost: no worker gets them
        function lose_events(fn)
            local we = events()
            local post = we.post
            we.post = function() return true end
            local ok, err = pcall(fn)
            we.post = post
            assert(ok, err)
        end

        -- runs fn() with the events it raises held back; returns a function
        -- that sends them, and the events
        function hold_events(fn)
            local we = events()
            local post = we.post
            local held = {}
            we.post = function(source, event, data)
                held[#held + 1] = { source, event, data }
                return true
            end
            local ok, err = pcall(fn)
            we.post = post
            assert(ok, err)
            return function()
                for _, e in ipairs(held) do
                    post(e[1], e[2], e[3])
                end
            end, held
        end

        -- returns when the events posted so far have been dispatched
        local flush_seq = 0
        function flush_events()
            local we = events()
            flush_seq = flush_seq + 1
            local seq, seen = flush_seq, false
            local callback = function(data)
                if data == seq then
                    seen = true
                end
            end
            we.register(callback, "test-flush", "marker")
            we.post("test-flush", "marker", seq)
            local ok = wait_until(function()
                we.poll()
                return seen
            end)
            we.unregister(callback, "test-flush", "marker")
            assert(ok, "the events were not dispatched")
        end

        -- the counters of the reconciliation: a copy, and what was added to
        -- one of them since that copy
        function stats()
            local copy = {}
            for k, v in pairs(require("resty.healthcheck")._reconcile_stats()) do
                copy[k] = v
            end
            return copy
        end

        function since(before, key)
            return require("resty.healthcheck")._reconcile_stats()[key] - before[key]
        end
    }
};

run_tests();

__DATA__

=== TEST 1: a change made to a target after it was compared, during the same comparison, with its event lost, is corrected on the next run
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            healthcheck._set_sync_batch(1)   -- yield after every unit of work
            lose_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            -- the third yield of the comparison of `b`: the list is decoded,
            -- and 11111 and 22222 are compared
            local yields, during = 0
            yield_hook = {
                cond = function()
                    if b.syncing then
                        yields = yields + 1
                    end
                    return yields == 3
                end,
                fn = function()
                    during = status(b, 11111)
                    lose_events(function()
                        assert(a:set_target_status(ip, 11111, nil, true))
                    end)
                end,
            }
            healthcheck._reconcile()
            local first = status(b, 11111)
            healthcheck._reconcile()
            ngx.say("during=", tostring(during), " first=", first, " then b=", status(b, 11111),
                    " a=", status(a, 11111))
        }
    }
--- request
GET /t
--- response_body
during=false first=false then b=true a=true
--- no_error_log
[error]



=== TEST 2: a change made while new() loads the targets, after its target was loaded, with the event lost, is compared on the next run
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a = new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            flush_events()
            healthcheck._reconcile()

            -- when new() reads the state of the last target, the first one,
            -- which it has loaded already, changes, and the event is lost
            local methods = getmetatable(shm).__index
            local get = methods.get
            local last_state = key_of(a.TARGET_STATE, 22222)
            local armed = true
            methods.get = function(dict, key, ...)
                if armed and key == last_state then
                    armed = false
                    lose_events(function()
                        assert(a:set_target_status(ip, 11111, nil, false))
                    end)
                end
                return get(dict, key, ...)
            end
            local b = new_checker()
            methods.get = get
            local loaded = status(b, 11111)
            healthcheck._reconcile()
            ngx.say("armed=", tostring(armed), " loaded=", loaded, " after a run: b=", status(b, 11111),
                    " a=", status(a, 11111))
        }
    }
--- request
GET /t
--- response_body
armed=false loaded=true after a run: b=false a=false
--- no_error_log
[error]



=== TEST 3: a run of the timer between the two version increments of a change does not hide the change
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            flush_events()
            healthcheck._reconcile()

            -- another worker's timer runs after the first of the two
            -- increments of a change whose event is lost
            local methods = getmetatable(shm).__index
            local incr = methods.incr
            local armed = true
            methods.incr = function(dict, key, ...)
                local res, err, forcible = incr(dict, key, ...)
                if armed and (key == a.TARGET_VERSION or key == "lua-resty-healthcheck::shm_version") then
                    armed = false
                    healthcheck._reconcile()
                end
                return res, err, forcible
            end
            lose_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            methods.incr = incr
            healthcheck._reconcile()
            ngx.say("armed=", tostring(armed), " b=", status(b, 11111), " a=", status(a, 11111))
        }
    }
--- request
GET /t
--- response_body
armed=false b=false a=false
--- no_error_log
[error]



=== TEST 4: a worker that clears a checker and adds the same targets again, with its events lost, gets its copy back
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            healthcheck._set_sweep(1000, 1)   -- every checker, on every run
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            healthcheck._reconcile()   -- the members are compared, the list is remembered
            local list = shm:get(a.TARGET_LIST)
            lose_events(function()
                assert(b:clear())
                assert(b:add_target(ip, 11111, nil, true))
                assert(b:add_target(ip, 22222, nil, true))
                assert(b:add_target(ip, 33333, nil, true))
            end)
            local same = shm:get(a.TARGET_LIST) == list
            for _ = 1, 5 do
                healthcheck._reconcile()
            end
            ngx.say("same list=", tostring(same), " listed=",
                    #healthcheck.get_target_list("testing", "test_shm"),
                    " a=", #a.targets, " b=", #b.targets, " b:11111=", status(b, 11111))
        }
    }
--- request
GET /t
--- response_body
same list=true listed=3 a=3 b=3 b:11111=true
--- no_error_log
[error]



=== TEST 5: a checker cleared by an event and filled again with the same targets, the events of which are lost, gets them back
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            flush_events()
            healthcheck._reconcile()
            healthcheck._set_sweep(1000, 1)   -- every checker, on every run
            healthcheck._reconcile()   -- the members are compared, the list is remembered
            local list = shm:get(a.TARGET_LIST)
            assert(a:clear())
            flush_events()
            local cleared = #b.targets
            lose_events(function()
                assert(a:add_target(ip, 11111, nil, true))
                assert(a:add_target(ip, 22222, nil, true))
            end)
            healthcheck._reconcile()
            ngx.say("same list=", tostring(shm:get(a.TARGET_LIST) == list), " cleared=", cleared,
                    " a=", #a.targets, " b=", #b.targets)
        }
    }
--- request
GET /t
--- response_body
same list=true cleared=0 a=2 b=2
--- no_error_log
[error]



=== TEST 6: the removal of the last listed target arrives after the event that added it again: the target is back after the next run
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            healthcheck._set_sweep(1000, 1)   -- every checker, on every run
            healthcheck._reconcile()          -- the members are compared, the list is remembered
            healthcheck._set_sweep(20, 100)
            local list = shm:get(a.TARGET_LIST)
            local send = hold_events(function()
                assert(a:remove_target(ip, 33333, ip))
            end)
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            send()
            flush_events()
            local late = status(b, 33333)
            healthcheck._reconcile()
            ngx.say("same list=", tostring(shm:get(a.TARGET_LIST) == list), " after the late removal: ", late,
                    " after a run: b=", status(b, 33333), " a=", status(a, 33333))
        }
    }
--- request
GET /t
--- response_body
same list=true after the late removal: nil/target not found after a run: b=true a=true
--- no_error_log
[error]



=== TEST 7: a target whose state key was evicted keeps the status the copy has, whether the members are compared or not
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, false))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            healthcheck._set_sweep(1000, 1)   -- every checker, on every run
            healthcheck._reconcile()          -- the members are compared, the list is remembered
            local ver = b.status_ver

            -- only the statuses are compared
            shm:delete(key_of(a.TARGET_STATE, 11111))
            assert(shm:set(key_of(a.TARGET_STATE, 22222), 2))
            local before = stats()
            healthcheck._reconcile()
            ngx.say("statuses: members=", since(before, "members"), " ", status(b, 11111), ",",
                    status(b, 22222), " targets=", #b.targets, " status_ver+", b.status_ver - ver)

            -- the members are compared: the list changed
            ver = b.status_ver
            lose_events(function()
                assert(a:add_target(ip, 44444, nil, true))
            end)
            before = stats()
            healthcheck._reconcile()
            ngx.say("members: members=", since(before, "members"), " ", status(b, 11111), ",",
                    status(b, 44444), " targets=", #b.targets, " status_ver+", b.status_ver - ver)
        }
    }
--- request
GET /t
--- response_body
statuses: members=0 false,false targets=3 status_ver+1
members: members=2 false,true targets=4 status_ver+1
--- no_error_log
[error]



=== TEST 8: checkers that were collected leave the others compared, by scans and in the background
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            healthcheck._set_sweep(1000, 1)   -- every checker, on every run
            local keep_a, keep_b = new_checker("kept"), new_checker("kept")
            assert(keep_a:add_target(ip, 11111, nil, true))
            do
                local gone = {}
                for i = 1, 12 do
                    gone[i] = new_checker("gone-" .. i)
                    assert(gone[i]:add_target(ip, 11111, nil, true))
                end
                flush_events()
                for i = 1, 12 do
                    gone[i]:stop()
                end
            end
            local last = new_checker("last")
            assert(last:add_target(ip, 11111, nil, true))
            flush_events()
            collectgarbage()
            collectgarbage()
            -- rounds of the background comparison: the holes are counted,
            -- then closed
            for _ = 1, 4 do
                healthcheck._reconcile()
            end
            local before = stats()
            -- a lost event: found by a scan
            lose_events(function()
                assert(keep_a:set_target_status(ip, 11111, nil, false))
            end)
            healthcheck._reconcile()
            local scanned = status(keep_b, 11111)
            -- a change no version announces: found in the background
            assert(shm:set(key_of(last.TARGET_STATE, 11111), 2))
            healthcheck._reconcile()
            healthcheck._reconcile()
            ngx.say("scan: ", scanned, " background: ", status(last, 11111),
                    " scans=", since(before, "scans"))
        }
    }
--- request
GET /t
--- response_body
scan: false background: false scans=1
--- no_error_log
[error]



=== TEST 9: looking at the version of every checker yields after every batch
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local checkers = {}
            for i = 1, 40 do
                checkers[i] = new_checker("checker-" .. i)
            end
            local a = new_checker("changing")
            assert(a:add_target(ip, 11111, nil, true))
            flush_events()
            healthcheck._reconcile()
            healthcheck._set_sync_batch(10)
            lose_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            local before = stats()
            healthcheck._reconcile()
            ngx.say("scans=", since(before, "scans"), " compared=", since(before, "compared"),
                    " yields=", since(before, "yields"), " ", status(a, 11111))
        }
    }
--- request
GET /t
--- response_body
scans=1 compared=1 yields=4 false
--- no_error_log
[error]



=== TEST 10: a comparison that corrects statuses and members writes nothing to the shm
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            healthcheck._set_sweep(1000, 1)   -- every checker, on every run
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            lose_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
                assert(a:add_target(ip, 44444, nil, false))
                assert(a:remove_target(ip, 22222, ip))
            end)
            local methods = getmetatable(shm).__index
            local writes, saved = {}, {}
            for _, name in ipairs({ "set", "safe_set", "add", "safe_add", "replace", "incr", "delete",
                                    "flush_all", "flush_expired", "lpush", "rpush", "lpop", "rpop",
                                    "expire" }) do
                local method = methods[name]
                if method then
                    saved[name] = method
                    methods[name] = function(dict, key, ...)
                        writes[#writes + 1] = name .. " " .. tostring(key)
                        return method(dict, key, ...)
                    end
                end
            end
            local before = stats()
            healthcheck._reconcile()
            healthcheck._reconcile()
            for name, method in pairs(saved) do
                methods[name] = method
            end
            ngx.say("corrected=", since(before, "corrected"), " b=", status(b, 11111), ",",
                    status(b, 22222), ",", status(b, 44444), " writes=", #writes, " ",
                    table.concat(writes, "; "))
        }
    }
--- request
GET /t
--- response_body
corrected=6 b=false,nil/target not found,false writes=0 
--- no_error_log
[error]



=== TEST 11: a checker version that went back has the checker compared instead of its events ignored
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            healthcheck._reconcile()
            -- as when the key was evicted and made again after the clock was set back
            assert(shm:set(a.TARGET_VERSION, 5))
            assert(a:set_target_status(ip, 11111, nil, false))
            flush_events()
            local ignored = status(b, 11111)
            local before = stats()
            healthcheck._reconcile()
            ngx.say(ignored, " b=", status(b, 11111), " a=", status(a, 11111),
                    " scans=", since(before, "scans"), " compared=", since(before, "compared"))
        }
    }
--- request
GET /t
--- response_body
true b=false a=false scans=0 compared=2
--- no_error_log
[error]



=== TEST 12: a comparison that throws does not end the run for good: it is logged and tried again
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            healthcheck._reconcile()
            lose_events(function()
                assert(a:set_target_status(ip, 11111, nil, false))
            end)
            -- the version of `b` is read once when every checker is looked
            -- at; the read after that, by its comparison, throws
            local real, reads = b.shm, 0
            b.shm = setmetatable({}, {
                __index = function(_, name)
                    local method = real[name]
                    return function(_, key, ...)
                        if name == "get" and key == b.TARGET_VERSION then
                            reads = reads + 1
                            if reads == 2 then
                                error("boom")
                            end
                        end
                        return method(real, key, ...)
                    end
                end,
            })
            healthcheck._reconcile()
            local first = status(b, 11111)
            healthcheck._reconcile()
            ngx.say(first, " ", status(b, 11111), " a=", status(a, 11111), " reads=", reads)
        }
    }
--- request
GET /t
--- response_body
true false a=false reads=3
--- grep_error_log eval
qr/failed to reconcile targets with shm \([^)]*\): .*boom/
--- grep_error_log_out eval
qr/\Afailed to reconcile targets with shm \(it is tried again on every run of the timer\): [^\n]*boom\n\z/



=== TEST 13: comparing many small checkers yields as well
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local checkers = {}
            for i = 1, 12 do
                checkers[i] = new_checker("checker-" .. i)
                assert(checkers[i]:add_target(ip, 11111, nil, true))
            end
            flush_events()
            healthcheck._set_sweep(1000, 1)   -- every checker, on every run
            healthcheck._reconcile()          -- the members are compared, the lists are remembered
            healthcheck._set_sync_batch(10)
            local before = stats()
            healthcheck._reconcile()
            -- 1 for the status and 2 for the checker, 12 times
            ngx.say("compared=", since(before, "compared"), " members=", since(before, "members"),
                    " yields=", since(before, "yields"))
        }
    }
--- request
GET /t
--- response_body
compared=12 members=0 yields=3
--- no_error_log
[error]



=== TEST 14: a copy whose version is not known is compared when an event arrives
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            -- the version key is gone from a full shm when the copies are compared
            healthcheck._set_sweep(1000, 1)
            healthcheck._reconcile()
            shm:delete(a.TARGET_VERSION)
            healthcheck._reconcile()
            healthcheck._set_sweep(20, 1000000)
            assert(a:set_target_status(ip, 11111, nil, false))
            flush_events()
            local before = stats()
            healthcheck._reconcile()
            assert(a:set_target_status(ip, 11111, nil, true))
            flush_events()
            healthcheck._reconcile()
            -- compared once, after the first event; the second one is in order
            ngx.say("b=", status(b, 11111), " scans=", since(before, "scans"),
                    " compared=", since(before, "compared"))
        }
    }
--- request
GET /t
--- response_body
b=true scans=0 compared=2
--- no_error_log
[error]



=== TEST 15: with lua-resty-worker-events, events that wait to be polled are dispatched before the shm being ahead is taken for a loss
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            no_reconcile_timer()
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            assert(a:add_target(ip, 11111, nil, true))
            assert(a:add_target(ip, 22222, nil, true))
            assert(a:add_target(ip, 33333, nil, true))
            flush_events()
            assert(#a.targets == 3 and #b.targets == 3)
            healthcheck._reconcile()
            -- posted and not dispatched, as when another worker posts it:
            -- post() polls, which is turned off for this one
            local we = events()
            local poll = we.poll
            we.poll = function() return true end
            assert(a:set_target_status(ip, 11111, nil, false))
            we.poll = poll
            local waiting = status(b, 11111)
            local before = stats()
            healthcheck._reconcile()
            ngx.say(waiting, " b=", status(b, 11111), " scans=", since(before, "scans"),
                    " compared=", since(before, "compared"))
        }
    }
--- request
GET /t
--- response_body
true b=false scans=0 compared=0
--- no_error_log
[error]
