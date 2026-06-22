use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => blocks() * 2;

my $pwd = cwd();

# A local self-signed TLS server is used instead of an external host so that
# the active TLS probe tests are deterministic and do not depend on network
# access. The certificate has CN/SAN "example.test"; probing with that
# hostname (SNI) and certificate verification enabled succeeds, while probing
# with a mismatching hostname and verification enabled fails.
$ENV{TEST_NGINX_TLS_CERT} = "$pwd/t/with_worker-events/util/tls_probe_cert.pem";
$ENV{TEST_NGINX_TLS_KEY} = "$pwd/t/with_worker-events/util/tls_probe_key.pem";

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;

    server {
        listen 2115 ssl;
        ssl_certificate $ENV{TEST_NGINX_TLS_CERT};
        ssl_certificate_key $ENV{TEST_NGINX_TLS_KEY};
        server_name example.test;
        location / {
            return 200 'ok';
        }
    }
};

run_tests();

__DATA__



=== TEST 1: active probes, valid https
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        lua_ssl_trusted_certificate $TEST_NGINX_TLS_CERT;
        lua_ssl_verify_depth 2;
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                checks = {
                    active = {
                        type = "https",
                        http_path = "/",
                        healthy  = {
                            interval = 2,
                            successes = 2,
                        },
                        unhealthy  = {
                            interval = 2,
                            tcp_failures = 2,
                        }
                    },
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2115, "example.test", false)
            ngx.sleep(8) -- wait for 4x the check interval
            ngx.say(checker:get_target_status("127.0.0.1", 2115, "example.test"))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- timeout
15

=== TEST 2: active probes, invalid cert
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        lua_ssl_trusted_certificate $TEST_NGINX_TLS_CERT;
        lua_ssl_verify_depth 2;
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                checks = {
                    active = {
                        type = "https",
                        http_path = "/",
                        healthy  = {
                            interval = 2,
                            successes = 2,
                        },
                        unhealthy  = {
                            interval = 2,
                            tcp_failures = 2,
                        }
                    },
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2115, "wrong.host.test", true)
            ngx.sleep(8) -- wait for 4x the check interval
            ngx.say(checker:get_target_status("127.0.0.1", 2115, "wrong.host.test"))  -- false
        }
    }
--- request
GET /t
--- response_body
false
--- timeout
15

=== TEST 3: active probes, accept invalid cert when disabling check
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        lua_ssl_trusted_certificate $TEST_NGINX_TLS_CERT;
        lua_ssl_verify_depth 2;
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                checks = {
                    active = {
                        type = "https",
                        https_verify_certificate = false,
                        http_path = "/",
                        healthy  = {
                            interval = 2,
                            successes = 2,
                        },
                        unhealthy  = {
                            interval = 2,
                            tcp_failures = 2,
                        }
                    },
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 2115, "wrong.host.test", false)
            ngx.sleep(8) -- wait for 4x the check interval
            ngx.say(checker:get_target_status("127.0.0.1", 2115, "wrong.host.test"))  -- true
        }
    }
--- request
GET /t
--- response_body
true
--- timeout
15
