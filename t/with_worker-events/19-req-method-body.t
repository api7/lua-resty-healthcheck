use Test::Nginx::Socket::Lua 'no_plan';
use Cwd qw(cwd);

workers(1);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
};

run_tests();

__DATA__

=== TEST 1: http_method and http_req_body send a POST probe with a body
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2112;
        location = /status {
            content_by_lua_block {
                ngx.req.read_body()
                ngx.log(ngx.WARN, "probe received method=", ngx.req.get_method(),
                        " body=", ngx.req.get_body_data() or "")
                ngx.exit(200)
            }
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                checks = {
                    active = {
                        http_path = "/status",
                        http_method = "POST",
                        http_req_body = '{"ping":true}',
                        healthy  = {
                            interval = 0.1
                        },
                    }
                }
            })
            ngx.sleep(0.2) -- wait twice the interval
            local ok, err = checker:add_target("127.0.0.1", 2112, nil, true)
            ngx.say(ok)
            ngx.sleep(0.2) -- wait twice the interval
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
POST /status HTTP/1.1
Content-Length: 13
probe received method=POST body={"ping":true}


=== TEST 2: default method is GET with no body and no Content-Length
--- http_config eval
qq{
    $::HttpConfig

    server {
        listen 2112;
        location = /status {
            content_by_lua_block {
                ngx.req.read_body()
                ngx.log(ngx.WARN, "probe received method=", ngx.req.get_method(),
                        " body=", ngx.req.get_body_data() or "")
                ngx.exit(200)
            }
        }
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local checker = healthcheck.new({
                name = "testing",
                shm_name = "test_shm",
                checks = {
                    active = {
                        http_path = "/status",
                        healthy  = {
                            interval = 0.1
                        },
                    }
                }
            })
            ngx.sleep(0.2) -- wait twice the interval
            local ok, err = checker:add_target("127.0.0.1", 2112, nil, true)
            ngx.say(ok)
            ngx.sleep(0.2) -- wait twice the interval
        }
    }
--- request
GET /t
--- response_body
true
--- error_log
GET /status HTTP/1.1
probe received method=GET body=
--- no_error_log
Content-Length:
