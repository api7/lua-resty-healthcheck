use Test::Nginx::Socket::Lua 'no_plan';
use Cwd qw(cwd);

workers(1);

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

no_shuffle();
run_tests();

__DATA__



=== TEST 1: healthy
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2116;
        location = /status {
            return 200;
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local name = "testing"
            local shm_name = "test_shm"
            local checker = healthcheck.new({
                name = name,
                shm_name = shm_name,
                events_module = "resty.events",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1, -- we don't want active checks
                            successes = 1,
                        },
                        unhealthy  = {
                            interval = 0.1, -- we don't want active checks
                            tcp_failures = 3,
                            http_failures = 3,
                        }
                    }
                }
            })
            checker:add_target("127.0.0.1", 2116, nil, false)
            checker:add_target("127.0.0.2", 2116, nil, false)
            ngx.sleep(3)
            local nodes = healthcheck.get_target_list(name, shm_name)
            assert(#nodes == 2, "invalid number of nodes")
            for _, node in ipairs(nodes) do
                assert(node.ip == "127.0.0.1" or node.ip == "127.0.0.2", "invalid ip")
                assert(node.port == 2116, "invalid port")
                assert(node.status == "healthy", "invalid status")
                assert(node.counter.success == 1, "invalid success counter")
                assert(node.counter.tcp_failure == 0, "invalid tcp failure counter")
                assert(node.counter.http_failure == 0, "invalid http failure counter")
                assert(node.counter.timeout_failure == 0, "invalid timeout failure counter")
            end
        }
    }
--- request
GET /t
--- timeout: 5



=== TEST 2: healthcheck - add_target with meta
--- http_config eval
qq{
    $::HttpConfig

    # ignore lua tcp socket read timed out
    lua_socket_log_errors off;

    server {
        listen 2116;
        location = /status {
            return 200;
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local name = "testing"
            local shm_name = "test_shm"
            local checker = healthcheck.new({
                name = name,
                shm_name = shm_name,
                events_module = "resty.events",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1, -- we don't want active checks
                            successes = 1,
                        },
                        unhealthy  = {
                            interval = 0.1, -- we don't want active checks
                            tcp_failures = 3,
                            http_failures = 3,
                        }
                    }
                }
            })
            checker:add_target("127.0.0.1", 2116, nil, false, nil, { raw = "host_1" })
            checker:add_target("127.0.0.2", 2116, nil, false, nil, { raw = "host_2" })
            ngx.sleep(2)
            local nodes = healthcheck.get_target_list(name, shm_name)
            assert(#nodes == 2, "invalid number of nodes")
            for _, node in ipairs(nodes) do
                assert(node.ip == "127.0.0.1" or node.ip == "127.0.0.2", "invalid ip")
                assert(node.port == 2116, "invalid port")
                assert(node.status == "healthy", "invalid status")
                assert(node.counter.success == 1, "invalid success counter")
                assert(node.counter.tcp_failure == 0, "invalid tcp failure counter")
                assert(node.counter.http_failure == 0, "invalid http failure counter")
                assert(node.counter.timeout_failure == 0, "invalid timeout failure counter")
                assert(node.meta.raw == "host_1" or node.meta.raw == "host_2", "invalid node meta")
            end
        }
    }
--- request
GET /t
--- no_error_log
[error]
--- timeout: 5



=== TEST 3: passive healthcheck without hostname
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2119;
        location = /status {
            return 200;
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
events_module = "resty.events",
                type = "http",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 999, -- we don't want active checks
                            successes = 3,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 3,
                        },
                        unhealthy  = {
                            tcp_failures = 2,
                            http_failures = 3,
                        }
                    }
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2119, nil, true)
            ngx.sleep(0.01)
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "passive")
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "passive")
            checker:report_http_status("127.0.0.1", 2119, nil, 500, "passive")
            ngx.sleep(0.01)
            assert(checker:get_target_status("127.0.0.1", 2119), false)
            local nodes = healthcheck.get_target_list(name, shm_name)
            assert(#nodes == 1, "invalid number of nodes")
            assert(nodes[1].ip == "127.0.0.1", "invalid ip")
            assert(nodes[1].port == 2119, "invalid port")
            assert(nodes[1].status == "unhealthy", "invalid status")
            assert(nodes[1].counter.success == 0, "invalid success counter")
            assert(nodes[1].counter.tcp_failure == 0, "invalid tcp failure counter")
            assert(nodes[1].counter.http_failure == 3, "invalid http failure counter")
            assert(nodes[1].counter.timeout_failure == 0, "invalid timeout failure counter")
        }
    }
--- request
GET /t
--- error_log
unhealthy HTTP increment (1/3) for '(127.0.0.1:2119)'
unhealthy HTTP increment (2/3) for '(127.0.0.1:2119)'
unhealthy HTTP increment (3/3) for '(127.0.0.1:2119)'
event: target status '(127.0.0.1:2119)' from 'true' to 'falsedf'
