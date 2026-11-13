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
        -- creates checkers with the compat layer of lua-resty-events
        -- reporting `version`
        function new_checkers(version, count)
            local we = require "resty.events.compat"
            local orig_version = we._VERSION
            we._VERSION = version
            local results = {}
            for i = 1, count do
                local ok, checker, err = pcall(require("resty.healthcheck").new, {
                    name = "testing" .. i,
                    shm_name = "test_shm",
                    events_module = "resty.events",
                })
                if ok then
                    results[i] = tostring(checker ~= nil) .. " " .. tostring(err)
                else
                    -- new() threw: `checker` is the error
                    results[i] = "false " .. tostring(checker)
                end
            end
            we._VERSION = orig_version
            return table.concat(results, ", ")
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

=== TEST 1: lua-resty-events 0.3.x, whose compat layer reports the version of the library, is accepted
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            ngx.say(new_checkers("0.3.1", 1))
        }
    }
--- request
GET /t
--- response_body
true nil
--- no_error_log
untested lua-resty-events version



=== TEST 2: lua-resty-events up to 0.2.x, whose compat layer reports 0.1.0, is accepted as before
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            ngx.say(new_checkers("0.1.0", 1))
        }
    }
--- request
GET /t
--- response_body
true nil
--- no_error_log
untested lua-resty-events version



=== TEST 3: another version is used as well, with one warning for the worker
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            ngx.say(new_checkers("0.4.0", 3))
        }
    }
--- request
GET /t
--- response_body
true nil, true nil, true nil
--- grep_error_log eval
qr/\[warn\].*?untested lua-resty-events version: \S+?(?=,)/
--- grep_error_log_out eval
qr/\A[^\n]*untested lua-resty-events version: 0\.4\.0\n\z/
