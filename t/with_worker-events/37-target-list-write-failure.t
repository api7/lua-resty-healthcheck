use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * blocks() * 3;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;$pwd/?.lua;;";
    lua_shared_dict test_shm 512k;
    lua_shared_dict my_worker_events 8m;

    init_by_lua_block {
        _G.__TESTING_HEALTHCHECKER = true

        function new_checker()
            if not worker_events_configured then
                local we = require "resty.worker.events"
                assert(we.configure{ shm = "my_worker_events", interval = 0.1 })
                worker_events_configured = true
            end
            return assert(require("resty.healthcheck").new({
                name = "testing",
                shm_name = "test_shm",
                checks = {
                    active = {
                        healthy = { interval = 0 },
                        unhealthy = { interval = 0 },
                    },
                },
            }))
        end
    }
};

our $Config = q{
    location ~ ^/test/(.*)$ {
        content_by_lua_block {
            if ngx.var.uri == "/test/encoding_cjson" then
                -- Exercise the cjson.safe fallback, which returns nil and an error.
                package.loaded["string.buffer"] = nil
                package.preload["string.buffer"] = function() error("string.buffer unavailable") end
            end
            require("t.target-list-replacement").run(new_checker, ngx.var.uri:sub(7))
        }
    }
};

run_tests();

__DATA__


=== TEST 1: oversized public target metadata leaves the old list intact
--- http_config eval: $::HttpConfig
--- config eval: $::Config
--- request
GET /test/add
--- response_body
nil failed to store target_list in shm: no memory
retained=true a=false b=true staged=nil
--- no_error_log
lua entry thread aborted


=== TEST 2: failed removal leaves the prior serialized list
--- http_config eval: $::HttpConfig
--- config eval: $::Config
--- request
GET /test/remove
--- response_body
nil failed to store target_list in shm: no memory
retained=true a=false b=true staged=nil
--- no_error_log
lua entry thread aborted


=== TEST 3: failed clear leaves the prior serialized list
--- http_config eval: $::HttpConfig
--- config eval: $::Config
--- request
GET /test/clear
--- response_body
nil failed to store target_list in shm: no memory
retained=true a=false b=true staged=nil
--- no_error_log
lua entry thread aborted


=== TEST 4: failed delayed clear retains the original purge markers
--- http_config eval: $::HttpConfig
--- config eval: $::Config
--- request
GET /test/delayed
--- response_body
nil failed to store target_list in shm: no memory
retained=true a=false b=true staged=nil
--- no_error_log
lua entry thread aborted


=== TEST 5: periodic purge retries after a failed staging write
--- http_config eval: $::HttpConfig
--- config eval: $::Config
--- request
GET /test/timer
--- response_body
retained=true writes=0
purged
--- no_error_log
lua entry thread aborted
--- timeout: 10


=== TEST 6: a different value that won the primary is preserved
--- http_config eval: $::HttpConfig
--- config eval: $::Config
--- request
GET /test/occupied
--- response_body
nil failed to store target_list in shm: no memory
untouched=true staged=nil
--- no_error_log
lua entry thread aborted


=== TEST 7: failed first creation leaves both keys absent
--- http_config eval: $::HttpConfig
--- config eval: $::Config
--- request
GET /test/initial
--- response_body
nil failed to store target_list in shm: no memory
absent=true staged=nil
--- no_error_log
lua entry thread aborted


=== TEST 8: destructive primary failure commits the complete stage
--- http_config eval: $::HttpConfig
--- config eval: $::Config
--- request
GET /test/fallback
--- response_body
true nil
a=nil b=true
retry cleared
--- no_error_log
lua entry thread aborted


=== TEST 9: normal changes read the primary once and write the new list to two keys
--- http_config eval: $::HttpConfig
--- config eval: $::Config
--- request
GET /test/fast
--- response_body
reads=4 writes=4 staged=4
--- no_error_log
lua entry thread aborted


=== TEST 10: cjson.safe encoding failure does not publish or leave a new target state
--- http_config eval: $::HttpConfig
--- config eval: $::Config
--- request
GET /test/encoding_cjson
--- response_body
retained=true writes=0 staged=0
--- no_error_log
lua entry thread aborted


=== TEST 11: a near-full zone can shrink when two copies of the old list would not fit
--- http_config eval: $::HttpConfig
--- config eval: $::Config
--- request
GET /test/full_shrink
--- response_body
cleared
--- no_error_log
lua entry thread aborted


=== TEST 12: a stale stage alongside the primary is overwritten before the next update
--- http_config eval: $::HttpConfig
--- config eval: $::Config
--- request
GET /test/stale_stage
--- response_body
true nil
a=nil b=true
retry cleared
--- no_error_log
lua entry thread aborted


=== TEST 13: new target state allocation cannot evict this checker's current list
--- http_config eval: $::HttpConfig
--- config eval: $::Config
--- request
GET /test/state
--- response_body
nil failed to set initial health status in shm: no memory
retained=true a=false b=true staged=nil
--- no_error_log
lua entry thread aborted


=== TEST 14: the default encoder rejects invalid metadata and rolls back the new target
--- http_config eval: $::HttpConfig
--- config eval: $::Config
--- request
GET /test/encoding
--- response_body
retained=true writes=0 staged=0
--- no_error_log
lua entry thread aborted
