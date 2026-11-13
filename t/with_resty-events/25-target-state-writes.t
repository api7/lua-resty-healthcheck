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

        -- two checkers with the same name stand for the checkers of two
        -- workers: each has its own copy of the targets
        function new_checker()
            return assert(require("resty.healthcheck").new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                    passive = {
                        unhealthy = { http_failures = 1 },
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

        -- a shm whose set() fails for one key, as when the shm is full
        function failing_shm(real, failing_key)
            return setmetatable({
                set = function(_, key, ...)
                    if key == failing_key then
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

=== TEST 1: a failed request reported for a target that another worker removed does not bring it back
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            -- `b` does not get the removal: its copy still has the target
            we.unregister(b.ev_callback, b.EVENT_SOURCE)
            assert(a:remove_target(ip, 11111, ip))
            assert(wait_until(function() return status(a, 11111) == "nil/target not found" end))

            -- one failed request is enough to mark it unhealthy
            assert(b:report_http_status(ip, 11111, nil, 500, "passive"))
            ngx.sleep(0.3)
            ngx.say("listed=", #healthcheck.get_target_list("testing", "test_shm"),
                    " a=", status(a, 11111), " state=", tostring(shm:get(state_key)))
        }
    }
--- request
GET /t
--- response_body
listed=0 a=nil/target not found state=nil
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 2: set_target_status() for a target that another worker removed writes nothing, raises no event and does not log "forced"
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            we.unregister(b.ev_callback, b.EVENT_SOURCE)
            assert(a:remove_target(ip, 11111, ip))
            assert(wait_until(function() return status(a, 11111) == "nil/target not found" end))

            local events = 0
            local count = function() events = events + 1 end
            we.register(count, a.EVENT_SOURCE)
            local ok = b:set_target_status(ip, 11111, nil, false)
            ngx.sleep(0.3)
            ngx.say(tostring(ok), " state=", tostring(shm:get(state_key)), " events=", events)
        }
    }
--- request
GET /t
--- response_body
true state=nil events=0
--- no_error_log eval
qr/unhealthy forced for|\[error\](?!.*lua tcp socket read timed out)/



=== TEST 3: a state change writes the state key of a listed target again after it was evicted
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            shm:delete(state_key)
            assert(a:set_target_status(ip, 11111, nil, false))
            wait_until(function() return status(b, 11111) == "false" end)
            ngx.say("state=", tostring(shm:get(state_key)), " b=", status(b, 11111))
        }
    }
--- request
GET /t
--- response_body
state=2 b=false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 4: it is written again as well when the target list was evicted with it
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            shm:delete(state_key)
            shm:delete(a.TARGET_LIST)
            assert(a:set_target_status(ip, 11111, nil, false))
            wait_until(function() return status(b, 11111) == "false" end)
            ngx.say("state=", tostring(shm:get(state_key)), " b=", status(b, 11111))
        }
    }
--- request
GET /t
--- response_body
state=2 b=false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 5: re-adding a target inside the purge window keeps the state it has in shm
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            -- another worker marks it unhealthy, and `a` misses that event
            we.unregister(a.ev_callback, a.EVENT_SOURCE)
            assert(b:set_target_status(ip, 11111, nil, false))
            assert(wait_until(function() return status(b, 11111) == "false" end))

            assert(a:delayed_clear(10))
            assert(a:add_target(ip, 11111, nil, true))
            ngx.say("a=", status(a, 11111), " state=", tostring(shm:get(state_key)))
        }
    }
--- request
GET /t
--- response_body
a=true state=2
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 6: re-adding a target whose state key was evicted fills it in and raises an event
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            assert(a:delayed_clear(10))
            shm:delete(state_key)
            assert(a:add_target(ip, 11111, nil, false))
            wait_until(function() return status(b, 11111) == "false" end)
            ngx.say("state=", tostring(shm:get(state_key)), " b=", status(b, 11111))
        }
    }
--- request
GET /t
--- response_body
state=2 b=false
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 7: a target whose initial state cannot be written is not published
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a = new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            local real = a.shm
            a.shm = failing_shm(real, state_key)
            local ok, err = a:add_target(ip, 11111, nil, true)
            a.shm = real
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



=== TEST 8: a new target whose list write fails leaves no state behind
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a = new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            local real = a.shm
            a.shm = failing_shm(real, a.TARGET_LIST)
            local ok, err = a:add_target(ip, 11111, nil, true)
            a.shm = real
            ngx.say(tostring(ok), " ", tostring(err), " state=", tostring(shm:get(state_key)))
        }
    }
--- request
GET /t
--- response_body
nil failed to store target_list in shm: no memory state=nil
--- no_error_log eval
qr/\[error\](?!.*lua tcp socket read timed out)/



=== TEST 9: set_target_status() announces the state it wrote, and logs "forced", even if resetting the counter fails
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a, b = new_checker(), new_checker()
            local state_key = key_of(a.TARGET_STATE, 11111)
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function()
                return status(a, 11111) == "true" and status(b, 11111) == "true"
            end))
            local real = a.shm
            a.shm = failing_shm(real, key_of(a.TARGET_COUNTER, 11111))
            local ok, err = a:set_target_status(ip, 11111, nil, false)
            a.shm = real
            wait_until(function() return status(b, 11111) == "false" end)
            ngx.say(tostring(ok), " ", tostring(err), " state=", tostring(shm:get(state_key)),
                    " b=", status(b, 11111))
        }
    }
--- request
GET /t
--- response_body
nil no memory state=2 b=false
--- grep_error_log eval
qr/unhealthy forced for \S+ [\d.]+:\d+|\[error\](?!.*lua tcp socket read timed out)/
--- grep_error_log_out
unhealthy forced for 127.0.0.1 127.0.0.1:11111



=== TEST 10: set_target_status() deferred to a timer logs "forced" when the state is written, not before
--- http_config eval: $::HttpConfig
--- config
    location = /locked {
        content_by_lua_block {
            -- the target lock is busy for 0.5 s
            local checker = package.loaded.test_checker
            local lock = assert(require("resty.lock"):new("test_shm", { exptime = 0.5, timeout = 0 }))
            assert(lock:lock(key_of(checker.TARGET_LOCK, 11111)))
            ngx.say("locked")
        }
        log_by_lua_block {
            -- this phase cannot yield and the lock is busy: deferred to a timer
            local checker = package.loaded.test_checker
            local ok = checker:set_target_status(ip, 11111, nil, false)
            ngx.log(ngx.WARN, "set_target_status returned ", tostring(ok))
        }
    }
    location = /t {
        content_by_lua_block {
            local we = require "resty.events.compat"
            local healthcheck = require("resty.healthcheck")
            local shm = ngx.shared.test_shm
            local a = new_checker()
            package.loaded.test_checker = a
            assert(a:add_target(ip, 11111, nil, true))
            assert(wait_until(function() return status(a, 11111) == "true" end))

            local sock = ngx.socket.tcp()
            assert(sock:connect("127.0.0.1", ngx.var.server_port))
            assert(sock:send("GET /locked HTTP/1.0\r\nHost: localhost\r\n\r\n"))
            assert(sock:receive("*a"))
            sock:close()

            local done = wait_until(function() return status(a, 11111) == "false" end, 3)
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
