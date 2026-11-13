use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * blocks() * 3;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
};

run_tests();

__DATA__

=== TEST 1: an event dispatched while new() polls, after it loaded the targets, reaches the new checker
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local we = require "resty.worker.events"
            assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
            local healthcheck = require("resty.healthcheck")
            local opts = {
                name = "testing",
                shm_name = "test_shm",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            }

            local a = healthcheck.new(opts)
            assert(a:add_target("127.0.0.1", 11111, nil, true))

            -- new() loads the targets from shm and then calls poll(), which
            -- dispatches the event of a change made in between
            local orig_poll = we.poll
            we.poll = function(...)
                we.poll = orig_poll
                assert(a:set_target_status("127.0.0.1", 11111, nil, false))
                return orig_poll(...)
            end
            local b = healthcheck.new(opts)
            we.poll = orig_poll

            -- nothing changes any more: `b` only gets this from that event
            ngx.sleep(0.3)
            ngx.say(a:get_target_status("127.0.0.1", 11111), " ",
                    b:get_target_status("127.0.0.1", 11111))
        }
    }
--- request
GET /t
--- response_body
false false
--- no_error_log
[error]
