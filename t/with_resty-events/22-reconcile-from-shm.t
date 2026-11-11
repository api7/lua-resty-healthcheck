use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

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
            ngx.sleep(0.2)

            -- new() reads the initial state from shm and then calls poll().
            -- Flip the target at that moment and let the event be dispatched
            -- before the second checker has subscribed.
            local orig_poll = we.poll
            we.poll = function(...)
                we.poll = orig_poll
                assert(a:set_target_status("127.0.0.1", 11111, nil, false))
                ngx.sleep(0.05)
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
--- no_error_log
[error]



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
            ngx.sleep(0.2)
            local ver = checker.status_ver

            -- from now on this worker misses the checker's events
            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            assert(checker:set_target_status("127.0.0.1", 11111, nil, false))

            ngx.sleep(0.3)
            ngx.say(checker:get_target_status("127.0.0.1", 11111), " ",
                    checker.status_ver > ver)
        }
    }
--- request
GET /t
--- response_body
false true
--- no_error_log
[error]



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
            ngx.sleep(0.2)

            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            -- remove_target() does not default the hostname to the ip
            assert(checker:remove_target("127.0.0.1", 11111, "127.0.0.1"))

            ngx.sleep(0.3)
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
--- no_error_log
[error]



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

            ngx.sleep(0.3)
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
--- no_error_log
[error]



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
            ngx.sleep(0.2)

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
--- no_error_log
[error]



=== TEST 6: a lost version key still triggers one resync
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
            ngx.sleep(0.2)

            -- a state change whose version bump is gone, e.g. the version
            -- keys were evicted from a full shm
            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            local shm = ngx.shared.test_shm
            assert(shm:set(checker.TARGET_STATE .. ":127.0.0.1:11111:127.0.0.1", 2))
            shm:delete(checker.TARGET_VERSION)
            shm:delete(checker.GLOBAL_TARGET_VERSION)

            ngx.sleep(0.3)
            ngx.say(checker:get_target_status("127.0.0.1", 11111))
        }
    }
--- request
GET /t
--- response_body
false
--- no_error_log
[error]



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
            ngx.sleep(0.3)
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
--- no_error_log
[error]



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
            ngx.sleep(0.3)

            -- the only worker, which also runs the probes, misses the event:
            -- its copy says healthy while shm says unhealthy. Probes succeed,
            -- so the target must come back to healthy in shm.
            we.unregister(checker.ev_callback, checker.EVENT_SOURCE)
            assert(checker:set_target_status("127.0.0.1", 2117, nil, false))

            ngx.sleep(1)
            local list = healthcheck.get_target_list("testing", "test_shm")
            ngx.say(list[1].status, " ", checker:get_target_status("127.0.0.1", 2117))
        }
    }
--- request
GET /t
--- response_body
healthy true
--- no_error_log
[error]
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
