our $SkipReason;

BEGIN {
    if ($ENV{TEST_ENVIRONMENT} ne "apisix") {
        $SkipReason = "Only for apisix environment";
    }
}

use Test::Nginx::Socket::Lua $SkipReason ? (skip_all => $SkipReason) : ('no_plan');
use Cwd qw(cwd);

workers(1);

my $pwd = cwd();
$ENV{TEST_NGINX_SERVROOT} = server_root();

no_shuffle();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;/usr/local/lib/lua/?.lua;/usr/local/lib/lua/?/init.lua;;";# add lua-resty-events path
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

    server {
        listen 8765 ssl;
        ssl_certificate ../../apisix/certs/mtls_server.crt;
        ssl_certificate_key ../../apisix/certs/mtls_server.key;
        ssl_client_certificate ../../apisix/certs/mtls_ca.crt;
        ssl_verify_client on;

        location /healthz {
            return 200 'ok';
        }
    }
};

run_tests();

__DATA__

=== TEST 1: configure a MTLS probe
--- http_config eval
qq{
    $::HttpConfig
}
--- config
    location = /t {
        content_by_lua_block {

            local pl_file = require "pl.file"
            local cert = pl_file.read("t/apisix/certs/mtls_client.crt", true)
            local key = pl_file.read("t/apisix/certs/mtls_client.key", true)

            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing_mtls",
                shm_name = "test_shm",
                events_module = "resty.events",
                type = "http",
                ssl_cert = cert,
                ssl_key = key,
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 999, -- we don't want active checks
                            successes = 3,
                        },
                        unhealthy  = {
                            interval = 999, -- we don't want active checks
                            tcp_failures = 3,
                            http_failures = 3,
                        }
                    },
                    passive = {
                        healthy  = {
                            successes = 3,
                        },
                        unhealthy  = {
                            tcp_failures = 3,
                            http_failures = 3,
                        }
                    }
                }
            })
            ngx.say(checker ~= nil)  -- true
        }
    }
--- request
GET /t
--- response_body
true


=== TEST 2: mtls check with cert/key
--- http_config eval
qq{
    $::HttpConfig
}
--- config
    location /t {
        content_by_lua_block {
            local pl_file = require "pl.file"
            local cert = pl_file.read("t/apisix/certs/mtls_client.crt", true)
            local key = pl_file.read("t/apisix/certs/mtls_client.key", true)

            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                ssl_cert = cert,
                ssl_key = key,
                checks = {
                active = {
                        type = "https",
                        https_verify_certificate = false,
                        http_path = "/healthz",
                        healthy  = {
                            interval = 999,  -- we don't want  check healthy node
                            successes = 1
                        },
                        unhealthy  = {
                            interval = 0.1,
                            http_failures = 1,
                        }
                    },
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 8765, "127.0.0.1", false) -- init unhealthy node
            ngx.sleep(0.5) -- wait for check
            ngx.status = 200
            ngx.say(checker:get_target_status("127.0.0.1", 8765))  -- true
        }
    }

--- request
GET /t
--- response_body
true
--- error_log
using tlshandshake


=== TEST 3: mtls check with unsupport parsed cert/key
--- http_config eval
qq{
    $::HttpConfig
}
--- config
    location /t {
        content_by_lua_block {

            local pl_file = require "pl.file"
            local ssl = require "ngx.ssl"
            local cert = ssl.parse_pem_cert(pl_file.read("t/apisix/certs/mtls_client.crt", true))
            local key = ssl.parse_pem_priv_key(pl_file.read("t/apisix/certs/mtls_client.key", true))

            local healthcheck = require("resty.healthcheck")
            local ok, err = pcall(healthcheck.new,{
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                ssl_cert = cert,
                ssl_key = key
            })
            ngx.log(ngx.ERR, err)
        }
    }

--- request
GET /t
--- error_log
ssl_cert and ssl_key must be pem strings when using tlshandshake


=== TEST 4: mtls check without cert/key
--- http_config eval
qq{
    $::HttpConfig
}
--- config
    location /t {
        content_by_lua_block {

            local cert
            local key

            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                events_module = "resty.events",
                ssl_cert = cert,
                ssl_key = key,
                checks = {
                active = {
                        type = "https",
                        https_verify_certificate = false,
                        http_path = "/healthz",
                        healthy  = {
                            interval = 0.1,  -- we don't want  check healthy node
                            successes = 1
                        },
                        unhealthy  = {
                            interval = 999,
                            http_failures = 1,
                            http_statuses = { 400 }
                        }
                    },
                }
            })
            local ok, err = checker:add_target("127.0.0.1", 8765, "127.0.0.1", true) -- init healthy node
            ngx.sleep(0.5) -- wait for check
            ngx.status = 200
            ngx.say(checker:get_target_status("127.0.0.1", 8765))  -- true
        }
    }

--- request
GET /t
--- response_body
false
--- error_log
client sent no required SSL certificate
