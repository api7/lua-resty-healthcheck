use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * blocks() * 3;

my $pwd = cwd();
$ENV{TEST_NGINX_SERVROOT} = server_root();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;

    init_by_lua_block {
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
    }

    init_worker_by_lua_block {
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

=== TEST 1: a report for a target removed meanwhile does not bring it back
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))
            ngx.sleep(0.3)

            -- a busy worker: its events are dispatched late
            we.register(function() ngx.sleep(0.6) end, "filler", "slow")
            we.post("filler", "slow", 1)
            ngx.sleep(0.05)

            -- another worker removes the target, while this worker, whose
            -- copy still has it, reports a failed request to it
            assert(checker:remove_target("127.0.0.1", 11111, "127.0.0.1"))
            assert(checker:report_http_status("127.0.0.1", 11111, nil, 500))

            ngx.sleep(2)
            local list = healthcheck.get_target_list("testing", "test_shm")
            local ok, err = checker:get_target_status("127.0.0.1", 11111)
            local state = ngx.shared.test_shm:get(checker.TARGET_STATE .. ":127.0.0.1:11111:127.0.0.1")
            ngx.say("listed=", #list, " local=", tostring(ok), " ", tostring(err),
                    " state=", tostring(state))
        }
    }
--- request
GET /t
--- response_body
listed=0 local=nil target not found state=nil
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/
--- timeout: 6



=== TEST 2: an evicted target list does not drop the local copy
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            assert(checker:add_target("127.0.0.1", 11111, nil, false))
            assert(checker:add_target("127.0.0.1", 22222, nil, true))
            assert(wait_until(function()
                return checker:get_target_status("127.0.0.1", 11111) == false
                   and checker:get_target_status("127.0.0.1", 22222) == true
            end))
            ngx.sleep(0.3)

            -- the list key is evicted from a full shm, and a later change of
            -- this checker makes the timer resync it
            ngx.shared.test_shm:delete(checker.TARGET_LIST)
            assert(checker:set_target_status("127.0.0.1", 22222, nil, false))
            assert(wait_until(function()
                return checker:get_target_status("127.0.0.1", 22222) == false
            end))
            ngx.sleep(0.3)

            -- the unhealthy target must not turn into an unknown (usable) one
            local ok, err = checker:get_target_status("127.0.0.1", 11111)
            ngx.say(tostring(ok), " ", tostring(err))
        }
    }
--- request
GET /t
--- response_body
false nil
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 3: a target whose initial state cannot be written is not published
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            -- the write of the state fails, as in a full shm
            local real = checker.shm
            local state_key = checker.TARGET_STATE .. ":127.0.0.1:11111:127.0.0.1"
            checker.shm = setmetatable({
                set = function(_, key, ...)
                    if key == state_key then
                        return nil, "no memory"
                    end
                    return real:set(key, ...)
                end,
            }, {
                __index = function(_, name)
                    local method = real[name]
                    return function(_, ...)
                        return method(real, ...)
                    end
                end,
            })
            local ok, err = checker:add_target("127.0.0.1", 11111, nil, true)
            checker.shm = real

            ngx.say(tostring(ok), " ", tostring(err), " listed=",
                    #healthcheck.get_target_list("testing", "test_shm"))
        }
    }
--- request
GET /t
--- response_body
nil failed to set initial health status in shm: no memory listed=0
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 4: re-adding a target whose state was evicted fills it in and announces it
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            local shm = ngx.shared.test_shm
            local state_key = checker.TARGET_STATE .. ":127.0.0.1:11111:127.0.0.1"
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))

            -- inside the purge window, the state key is evicted
            assert(checker:delayed_clear(10))
            shm:delete(state_key)
            local version = shm:get(checker.TARGET_VERSION)

            assert(checker:add_target("127.0.0.1", 11111, nil, false))
            ngx.say("state=", tostring(shm:get(state_key) ~= nil),
                    " announced=", tostring(shm:get(checker.TARGET_VERSION) > version))
        }
    }
--- request
GET /t
--- response_body
state=true announced=true
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 5: a late event for a removed target whose state was left behind does not bring it back
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            local state_key = checker.TARGET_STATE .. ":127.0.0.1:11111:127.0.0.1"
            local target = { ip = "127.0.0.1", port = 11111, hostname = "127.0.0.1" }
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))
            assert(checker:remove_target("127.0.0.1", 11111, "127.0.0.1"))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) == nil end))

            -- a state left behind for the removed target (written, e.g., by a
            -- worker that still runs the previous version of this module
            -- during a reload), and an event for it delivered late
            assert(ngx.shared.test_shm:set(state_key, 2))
            checker.ev_callback(target, checker.events.unhealthy)
            local ok, err = checker:get_target_status("127.0.0.1", 11111)
            ngx.say(tostring(ok), " ", tostring(err))
        }
    }
--- request
GET /t
--- response_body
nil target not found
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 6: a late event for a listed target whose state key alone was evicted keeps it
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            local state_key = checker.TARGET_STATE .. ":127.0.0.1:11111:127.0.0.1"
            local target = { ip = "127.0.0.1", port = 11111, hostname = "127.0.0.1" }
            assert(checker:add_target("127.0.0.1", 11111, nil, false))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) == false end))

            -- the state key is evicted from a full shm, the target stays
            -- listed, and an event for it is delivered late
            ngx.shared.test_shm:delete(state_key)
            checker.ev_callback(target, checker.events.unhealthy)
            local ok, err = checker:get_target_status("127.0.0.1", 11111)
            ngx.say(tostring(ok), " ", tostring(err))
        }
    }
--- request
GET /t
--- response_body
false nil
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 7: set_target_status() announces the state change even if resetting the counter fails
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            local state_key = checker.TARGET_STATE .. ":127.0.0.1:11111:127.0.0.1"
            local target = { ip = "127.0.0.1", port = 11111, hostname = "127.0.0.1" }
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))

            -- the counter key has to be created, and the shm is full
            local real = checker.shm
            local counter_key = checker.TARGET_COUNTER .. ":127.0.0.1:11111:127.0.0.1"
            checker.shm = setmetatable({
                set = function(_, key, ...)
                    if key == counter_key then
                        return nil, "no memory"
                    end
                    return real:set(key, ...)
                end,
            }, {
                __index = function(_, name)
                    local method = real[name]
                    return function(_, ...)
                        return method(real, ...)
                    end
                end,
            })
            local version = real:get(checker.TARGET_VERSION)
            local ok, err = checker:set_target_status("127.0.0.1", 11111, nil, false)
            checker.shm = real

            ngx.say(tostring(ok), " ", tostring(err), " state=", real:get(state_key),
                    " announced=", tostring(real:get(checker.TARGET_VERSION) ~= version))
        }
    }
--- request
GET /t
--- response_body
nil no memory state=2 announced=true
--- grep_error_log eval
qr/unhealthy forced for \S+ [\d.]+:\d+|\[error\](?!.*lua tcp socket read timed out)/
--- grep_error_log_out
unhealthy forced for 127.0.0.1 127.0.0.1:11111



=== TEST 8: a state change writes the state key of a listed target again after it was evicted
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            local shm = ngx.shared.test_shm
            local state_key = checker.TARGET_STATE .. ":127.0.0.1:11111:127.0.0.1"
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))

            shm:delete(state_key)
            assert(checker:set_target_status("127.0.0.1", 11111, nil, false))
            ngx.say("state=", tostring(shm:get(state_key)))
        }
    }
--- request
GET /t
--- response_body
state=2
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 9: a state change still writes the state when the target list was evicted with the state key
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            local shm = ngx.shared.test_shm
            local state_key = checker.TARGET_STATE .. ":127.0.0.1:11111:127.0.0.1"
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))

            -- health changes keep working for the workers that have the
            -- target (TEST 11: such a state never adds a target elsewhere)
            shm:delete(state_key)
            shm:delete(checker.TARGET_LIST)
            assert(checker:set_target_status("127.0.0.1", 11111, nil, false))
            wait_until(function() return checker:get_target_status("127.0.0.1", 11111) == false end)
            ngx.say("state=", tostring(shm:get(state_key)), " local=",
                    tostring(checker:get_target_status("127.0.0.1", 11111)))
        }
    }
--- request
GET /t
--- response_body
state=2 local=false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 10: a new target whose list write fails leaves no state behind
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            local shm = ngx.shared.test_shm
            local state_key = checker.TARGET_STATE .. ":127.0.0.1:11111:127.0.0.1"
            local real = checker.shm
            checker.shm = setmetatable({
                set = function(_, key, ...)
                    if key == checker.TARGET_LIST then
                        return nil, "no memory"
                    end
                    return real:set(key, ...)
                end,
            }, {
                __index = function(_, name)
                    local method = real[name]
                    return function(_, ...)
                        return method(real, ...)
                    end
                end,
            })
            local ok, err = checker:add_target("127.0.0.1", 11111, nil, true)
            checker.shm = real
            ngx.say(tostring(ok), " ", tostring(err), " state=", tostring(shm:get(state_key)))
        }
    }
--- request
GET /t
--- response_body
nil failed to store target_list in shm: no memory state=nil
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 11: a late event for a removed target whose state was left behind does not bring it back when the list was evicted
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            local shm = ngx.shared.test_shm
            local state_key = checker.TARGET_STATE .. ":127.0.0.1:11111:127.0.0.1"
            local target = { ip = "127.0.0.1", port = 11111, hostname = "127.0.0.1" }
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))
            assert(checker:remove_target("127.0.0.1", 11111, "127.0.0.1"))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) == nil end))

            -- a state left behind, the list evicted, and a late event
            assert(shm:set(state_key, 1))
            shm:delete(checker.TARGET_LIST)
            checker.ev_callback(target, checker.events.healthy)
            local ok, err = checker:get_target_status("127.0.0.1", 11111)
            ngx.say(tostring(ok), " ", tostring(err))
        }
    }
--- request
GET /t
--- response_body
nil target not found
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 12: a remove event drops a target that is no longer listed, even if a state was left behind for it
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            local shm = ngx.shared.test_shm
            local state_key = checker.TARGET_STATE .. ":127.0.0.1:11111:127.0.0.1"
            local target = { ip = "127.0.0.1", port = 11111, hostname = "127.0.0.1" }
            local we = require "resty.events.compat"
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))

            -- another worker removes the target; a state is left behind for
            -- it, and this worker, whose copy still has it, gets the remove.
            -- Nothing below yields, so the timer cannot run meanwhile.
            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            assert(checker:remove_target("127.0.0.1", 11111, "127.0.0.1"))
            assert(shm:set(state_key, 1))
            local before = checker:get_target_status("127.0.0.1", 11111)
            checker.ev_callback(target, checker.events.remove)
            local ok, err = checker:get_target_status("127.0.0.1", 11111)
            ngx.say("before=", tostring(before), " after=", tostring(ok), " ", tostring(err))
        }
    }
--- request
GET /t
--- response_body
before=true after=nil target not found
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 13: a remove event with the target list evicted keeps a target this worker has, with its shm state
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            local shm = ngx.shared.test_shm
            local state_key = checker.TARGET_STATE .. ":127.0.0.1:11111:127.0.0.1"
            local target = { ip = "127.0.0.1", port = 11111, hostname = "127.0.0.1" }
            local we = require "resty.events.compat"
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))

            -- nothing tells whether the target is still listed: it is kept,
            -- and its current state applies. Nothing below yields.
            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            assert(shm:set(state_key, 2))
            shm:delete(checker.TARGET_LIST)
            checker.ev_callback(target, checker.events.remove)
            local ok, err = checker:get_target_status("127.0.0.1", 11111)
            ngx.say(tostring(ok), " ", tostring(err))
        }
    }
--- request
GET /t
--- response_body
false nil
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 14: set_target_status() for a target removed meanwhile writes nothing, raises no event and does not log "forced"
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            local shm = ngx.shared.test_shm
            local state_key = checker.TARGET_STATE .. ":127.0.0.1:11111:127.0.0.1"
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))

            -- another worker removes the target; this worker's copy still has
            -- it. Nothing below yields, so the timer cannot run meanwhile.
            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            assert(checker:remove_target("127.0.0.1", 11111, "127.0.0.1"))
            local version = shm:get(checker.TARGET_VERSION)
            local ok = checker:set_target_status("127.0.0.1", 11111, nil, false)
            ngx.say(tostring(ok), " state=", tostring(shm:get(state_key)),
                    " announced=", tostring(shm:get(checker.TARGET_VERSION) ~= version))
        }
    }
--- request
GET /t
--- response_body
true state=nil announced=false
--- no_error_log eval
qr/unhealthy forced for|\[error\](?!.*lua tcp socket read timed out)/



=== TEST 15: set_target_status() deferred to a timer logs "forced" when the state is written, not before
--- http_config eval: $::HttpConfig
--- config
    location = /locked {
        content_by_lua_block {
            -- the target lock is busy for 0.5 s
            local checker = package.loaded.test_checker
            local lock = assert(require("resty.lock"):new("test_shm", { exptime = 0.5, timeout = 0 }))
            assert(lock:lock(checker.TARGET_LOCK .. ":127.0.0.1:11111:127.0.0.1"))
            ngx.say("locked")
        }
        log_by_lua_block {
            -- not yieldable and the lock is busy: deferred to a timer
            local checker = package.loaded.test_checker
            local ok = checker:set_target_status("127.0.0.1", 11111, nil, false)
            ngx.log(ngx.WARN, "set_target_status returned ", tostring(ok))
        }
    }
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            package.loaded.test_checker = checker
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))

            local sock = ngx.socket.tcp()
            assert(sock:connect("127.0.0.1", ngx.var.server_port))
            assert(sock:send("GET /locked HTTP/1.0\r\nHost: localhost\r\n\r\n"))
            assert(sock:receive("*a"))
            sock:close()

            local done = wait_until(function()
                return checker:get_target_status("127.0.0.1", 11111) == false
            end, 3)
            ngx.log(ngx.WARN, "applied: ", tostring(done))
            ngx.say(tostring(done))
        }
    }
--- request
GET /t
--- response_body
true
--- grep_error_log eval
qr/set_target_status returned \w+|unhealthy forced for|applied: \w+/
--- grep_error_log_out
set_target_status returned scheduled
unhealthy forced for
applied: true
--- timeout: 6



=== TEST 16: a status event for a target this worker has, with no state and no longer listed, removes it
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            local target = { ip = "127.0.0.1", port = 11111, hostname = "127.0.0.1" }
            local we = require "resty.events.compat"
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))

            -- another worker removes the target, and an older status event
            -- reaches this worker before the remove. Nothing below yields.
            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            assert(checker:remove_target("127.0.0.1", 11111, "127.0.0.1"))
            local before = checker:get_target_status("127.0.0.1", 11111)
            checker.ev_callback(target, checker.events.unhealthy)
            local ok, err = checker:get_target_status("127.0.0.1", 11111)
            ngx.say("before=", tostring(before), " after=", tostring(ok), " ", tostring(err))
        }
    }
--- request
GET /t
--- response_body
before=true after=nil target not found
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 17: a remove event with both the target list and the state evicted keeps a target this worker has
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            })
            local shm = ngx.shared.test_shm
            local state_key = checker.TARGET_STATE .. ":127.0.0.1:11111:127.0.0.1"
            local target = { ip = "127.0.0.1", port = 11111, hostname = "127.0.0.1" }
            local we = require "resty.events.compat"
            assert(checker:add_target("127.0.0.1", 11111, nil, false))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) == false end))

            -- Nothing below yields.
            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            shm:delete(state_key)
            shm:delete(checker.TARGET_LIST)
            checker.ev_callback(target, checker.events.remove)
            local ok, err = checker:get_target_status("127.0.0.1", 11111)
            ngx.say(tostring(ok), " ", tostring(err))
        }
    }
--- request
GET /t
--- response_body
false nil
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/
