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

=== TEST 1: an event raised while new() is between its shm read and its subscription is not lost
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local healthcheck = require("resty.healthcheck")
            local opts = {
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            }

            local a = healthcheck.new(opts)
            assert(a:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return a:get_target_status("127.0.0.1", 11111) end))

            -- new() reads the initial state from shm and then calls poll().
            -- Flip the target at that moment and let the event be dispatched
            -- before the second checker has subscribed.
            local orig_poll = we.poll
            we.poll = function(...)
                we.poll = orig_poll
                assert(a:set_target_status("127.0.0.1", 11111, nil, false))
                -- `a` got the event: it has been dispatched, before `b` subscribed
                assert(wait_until(function()
                    return a:get_target_status("127.0.0.1", 11111) == false
                end))
                return orig_poll(...)
            end
            local b = healthcheck.new(opts)
            we.poll = orig_poll

            -- no sleep: the state must be right as soon as new() returns
            ngx.say(b:get_target_status("127.0.0.1", 11111))
        }
    }
--- request
GET /t
--- response_body
false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 2: a missed status event is reconciled from shm within a tick
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local healthcheck = require("resty.healthcheck")
            -- active checks disabled: reconciliation must not depend on them
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
            local ver = checker.status_ver

            -- from now on this worker misses the checker's events
            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            assert(checker:set_target_status("127.0.0.1", 11111, nil, false))

            wait_until(function() return checker:get_target_status("127.0.0.1", 11111) == false end)
            ngx.say(checker:get_target_status("127.0.0.1", 11111), " ",
                    checker.status_ver > ver)
        }
    }
--- request
GET /t
--- response_body
false true
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 3: a missed remove event drops the local target
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
            assert(checker:add_target("127.0.0.1", 22222, nil, true))
            assert(wait_until(function()
                return checker:get_target_status("127.0.0.1", 11111)
                       and checker:get_target_status("127.0.0.1", 22222)
            end))

            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            -- remove_target() does not default the hostname to the ip
            assert(checker:remove_target("127.0.0.1", 11111, "127.0.0.1"))

            wait_until(function() return select(2, checker:get_target_status("127.0.0.1", 11111)) == "target not found" end)
            local ok, err = checker:get_target_status("127.0.0.1", 11111)
            ngx.say(tostring(ok), " ", tostring(err))
            ngx.say(checker:get_target_status("127.0.0.1", 22222))
        }
    }
--- request
GET /t
--- response_body
nil target not found
true
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 4: a target whose add event was missed shows up with its shm state
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
            ngx.sleep(0.2)
            local ver = checker.status_ver

            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            assert(checker:add_target("127.0.0.1", 11111, nil, false))

            wait_until(function() return checker:get_target_status("127.0.0.1", 11111) == false end)
            -- the routing view changed (unknown -> unhealthy), so consumers
            -- caching on status_ver must see a new version
            ngx.say(tostring(checker:get_target_status("127.0.0.1", 11111)), " ",
                    checker.status_ver > ver)
        }
    }
--- request
GET /t
--- response_body
false true
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 5: re-adding a target inside the purge window keeps the shm state
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

            -- this worker's copy goes stale: shm says unhealthy, the local
            -- copy still says healthy (no yield until the re-add below)
            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            assert(checker:set_target_status("127.0.0.1", 11111, nil, false))

            assert(checker:delayed_clear(10))
            assert(checker:add_target("127.0.0.1", 11111, nil, true))

            local list = healthcheck.get_target_list("testing", "test_shm")
            ngx.say(list[1].status)
        }
    }
--- request
GET /t
--- response_body
unhealthy
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 6: a change whose version keys were lost is still reconciled
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

            -- let the ticks record the versions
            ngx.sleep(0.3)

            -- a state change whose version bump is gone, e.g. the version
            -- keys were evicted from a full shm
            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            local shm = ngx.shared.test_shm
            assert(shm:set(checker.TARGET_STATE .. ":127.0.0.1:11111:127.0.0.1", 2))
            shm:delete(checker.TARGET_VERSION)
            shm:delete(checker.GLOBAL_TARGET_VERSION)

            wait_until(function() return checker:get_target_status("127.0.0.1", 11111) == false end)
            ngx.say(checker:get_target_status("127.0.0.1", 11111))
        }
    }
--- request
GET /t
--- response_body
false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 7: nothing changed, nothing is resynced
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
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))
            -- let the first ticks (and the first full resync) pass
            ngx.sleep(0.3)

            local syncs = 0
            local orig_sync = checker.sync_from_shm
            checker.sync_from_shm = function(...)
                syncs = syncs + 1
                return orig_sync(...)
            end

            -- while nothing changes, only the shared version is read: the
            -- per-checker version is not read and nothing is resynced
            local shdict_methods = getmetatable(ngx.shared.test_shm).__index
            local orig_get = shdict_methods.get
            local version_reads = 0
            shdict_methods.get = function(dict, key, ...)
                if key == checker.TARGET_VERSION then
                    version_reads = version_reads + 1
                end
                return orig_get(dict, key, ...)
            end

            ngx.sleep(1)
            shdict_methods.get = orig_get
            local idle = syncs

            assert(checker:set_target_status("127.0.0.1", 11111, nil, false))
            wait_until(function() return syncs >= 1 end)
            local after_change = syncs

            ngx.sleep(1)
            ngx.say(idle, " ", version_reads, " ", after_change >= 1, " ",
                    syncs == after_change)
        }
    }
--- request
GET /t
--- response_body
0 0 true true
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 8: the probing worker recovers a target even if it missed the unhealthy event
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2117;
        location = /status {
            return 200;
        }
    }
}
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
                        http_path = "/status",
                        healthy = {
                            interval = 0.1,
                            successes = 1,
                        },
                        unhealthy = {
                            interval = 0.1,
                            http_failures = 1,
                        },
                    },
                },
            })
            assert(checker:add_target("127.0.0.1", 2117, nil, true))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 2117) end))

            -- the only worker, which also runs the probes, misses the event:
            -- its copy says healthy while shm says unhealthy. Probes succeed,
            -- so the target must come back to healthy in shm.
            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            assert(checker:set_target_status("127.0.0.1", 2117, nil, false))

            -- wait for the recovery, bounded so that a stuck target fails
            local list
            local deadline = ngx.now() + 3
            repeat
                ngx.sleep(0.1)
                list = healthcheck.get_target_list("testing", "test_shm")
            until (list[1].status == "healthy"
                   and checker:get_target_status("127.0.0.1", 2117))
                  or ngx.now() >= deadline
            ngx.say(list[1].status, " ", checker:get_target_status("127.0.0.1", 2117))
        }
    }
--- request
GET /t
--- response_body
healthy true
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/
--- timeout: 5



=== TEST 9: lua-resty-events 0.3.x, whose compat layer reports the library version, is accepted
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local orig_version = we._VERSION
            we._VERSION = "0.3.1"
            local healthcheck = require("resty.healthcheck")
            local checker, err = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
            })
            we._VERSION = orig_version
            ngx.say(checker ~= nil, " ", tostring(err))
        }
    }
--- request
GET /t
--- response_body
true nil
--- no_error_log
untested lua-resty-events version



=== TEST 10: an untested lua-resty-events version still loads, with a warning
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local orig_version = we._VERSION
            we._VERSION = "9.9.9"
            local healthcheck = require("resty.healthcheck")
            local checker, err = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
            })
            we._VERSION = orig_version
            ngx.say(checker ~= nil, " ", tostring(err))
        }
    }
--- request
GET /t
--- response_body
true nil
--- error_log
untested lua-resty-events version: 9.9.9



=== TEST 11: a change made while a checker is stopped is applied when it starts again
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local function new_checker(name)
                return assert(healthcheck.new({
                    name = name,
                    shm_name = "test_shm",
                    events_module = "resty.events",
                    checks = {
                        active = {
                            healthy = { interval = 0 },
                            unhealthy = { interval = 0 },
                        },
                    },
                }))
            end
            local a = new_checker("a")
            -- another live checker in the same shm keeps the shared version
            -- moving while `a` is stopped
            local other = new_checker("other")
            assert(other:add_target("127.0.0.1", 22222, nil, true))
            assert(a:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return a:get_target_status("127.0.0.1", 11111) end))
            -- let the other checker's ticks record the shared version
            ngx.sleep(0.3)

            a:stop()
            -- e.g. made by another worker; `a` does not receive the event
            assert(a:set_target_status("127.0.0.1", 11111, nil, false))
            ngx.sleep(0.3)

            assert(a:start())
            -- no sleep: start() resyncs
            ngx.say(a:get_target_status("127.0.0.1", 11111))
        }
    }
--- request
GET /t
--- response_body
false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 12: a target added as unhealthy bumps status_ver on the normal event path
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
            ngx.sleep(0.3)
            local ver = checker.status_ver

            -- unknown (treated as usable by callers) -> unhealthy
            assert(checker:add_target("127.0.0.1", 11111, nil, false))
            wait_until(function() return checker:get_target_status("127.0.0.1", 11111) == false end)
            ngx.say(tostring(checker:get_target_status("127.0.0.1", 11111)), " ",
                    checker.status_ver > ver)
        }
    }
--- request
GET /t
--- response_body
false true
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 13: removing an unhealthy target bumps status_ver
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
            assert(checker:add_target("127.0.0.1", 11111, nil, true))
            -- set_target_status() needs the target in the local copy
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) end))
            assert(checker:set_target_status("127.0.0.1", 11111, nil, false))
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) == false end))
            local ver = checker.status_ver

            -- unhealthy -> unknown (treated as usable by callers)
            assert(checker:remove_target("127.0.0.1", 11111, "127.0.0.1"))
            wait_until(function() return select(2, checker:get_target_status("127.0.0.1", 11111)) == "target not found" end)
            local ok, err = checker:get_target_status("127.0.0.1", 11111)
            ngx.say(tostring(ok), " ", tostring(err), " ", checker.status_ver > ver)
        }
    }
--- request
GET /t
--- response_body
nil target not found true
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 14: clear() bumps status_ver in the calling worker
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
            assert(wait_until(function() return checker:get_target_status("127.0.0.1", 11111) == false end))
            local ver = checker.status_ver

            assert(checker:clear())
            ngx.sleep(0.3)
            local ok, err = checker:get_target_status("127.0.0.1", 11111)
            ngx.say(tostring(ok), " ", tostring(err), " ", checker.status_ver > ver)
        }
    }
--- request
GET /t
--- response_body
nil target not found true
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 15: a change to one checker does not resync the others
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local function new_checker(name)
                return assert(healthcheck.new({
                    name = name,
                    shm_name = "test_shm",
                    events_module = "resty.events",
                    checks = {
                        active = {
                            healthy = { interval = 0 },
                            unhealthy = { interval = 0 },
                        },
                    },
                }))
            end
            local a = new_checker("a")
            local b = new_checker("b")
            assert(a:add_target("127.0.0.1", 11111, nil, true))
            assert(b:add_target("127.0.0.1", 22222, nil, true))
            assert(wait_until(function()
                return a:get_target_status("127.0.0.1", 11111)
                       and b:get_target_status("127.0.0.1", 22222)
            end))
            ngx.sleep(0.3)

            local b_syncs = 0
            local orig_sync = b.sync_from_shm
            b.sync_from_shm = function(...)
                b_syncs = b_syncs + 1
                return orig_sync(...)
            end

            assert(a:set_target_status("127.0.0.1", 11111, nil, false))
            wait_until(function() return a:get_target_status("127.0.0.1", 11111) == false end)
            -- give the timer a few ticks to (wrongly) resync `b`
            ngx.sleep(0.3)
            ngx.say(b_syncs, " ", a:get_target_status("127.0.0.1", 11111))
        }
    }
--- request
GET /t
--- response_body
0 false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 16: a stopped checker is not resynced
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local opts = {
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            }
            -- a checker being replaced by a new one with the same name
            local old = healthcheck.new(opts)
            local new = healthcheck.new(opts)
            assert(new:add_target("127.0.0.1", 11111, nil, true))
            assert(wait_until(function() return new:get_target_status("127.0.0.1", 11111) end))
            old:stop()

            local old_syncs = 0
            local orig_sync = old.sync_from_shm
            old.sync_from_shm = function(...)
                old_syncs = old_syncs + 1
                return orig_sync(...)
            end

            assert(new:set_target_status("127.0.0.1", 11111, nil, false))
            wait_until(function() return new:get_target_status("127.0.0.1", 11111) == false end)
            -- give the timer a few ticks to (wrongly) resync `old`
            ngx.sleep(0.3)
            ngx.say(old_syncs, " ", new:get_target_status("127.0.0.1", 11111))
        }
    }
--- request
GET /t
--- response_body
0 false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 17: version keys recreated after eviction do not come back to a value already seen
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
            -- let the ticks record the versions
            ngx.sleep(0.3)

            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            -- both keys are evicted and recreated by the next change before
            -- any timer tick runs (no yield in between)
            local shm = ngx.shared.test_shm
            shm:delete(checker.TARGET_VERSION)
            shm:delete(checker.GLOBAL_TARGET_VERSION)
            assert(checker:set_target_status("127.0.0.1", 11111, nil, false))

            wait_until(function() return checker:get_target_status("127.0.0.1", 11111) == false end)
            ngx.say(checker:get_target_status("127.0.0.1", 11111))
        }
    }
--- request
GET /t
--- response_body
false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/
