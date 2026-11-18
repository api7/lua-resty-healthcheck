# lua-resty-healthcheck

![legacy version](https://img.shields.io/luarocks/v/kong/lua-resty-healthcheck/1.6.1-1?style=flat-square)
![Release 1.6.x](https://github.com/Kong/lua-resty-healthcheck/actions/workflows/build_and_test_with_resty_events.yml/badge.svg?branch=release/1.6.x)
![License](https://img.shields.io/badge/License-Apache%202.0-blue?style=flat-square)
![Twitter Follow](https://img.shields.io/twitter/follow/thekonginc?style=social)

A health check library for OpenResty.

## Synopsis

```nginx
http {
    lua_shared_dict test_shm 8m;
    lua_shared_dict my_worker_events 8m;
    init_worker_by_lua_block {

        local we = require "resty.worker.events"
        local ok, err = we.configure({
            shm = "my_worker_events",
            interval = 0.1
        })
        if not ok then
            ngx.log(ngx.ERR, "failed to configure worker events: ", err)
            return
        end

        local healthcheck = require("resty.healthcheck")
        local checker = healthcheck.new({
            name = "testing",
            shm_name = "test_shm",
            checks = {
                active = {
                    type = "https",
                    http_path = "/status",
                    healthy  = {
                        interval = 2,
                        successes = 1,
                    },
                    unhealthy  = {
                        interval = 1,
                        http_failures = 2,
                    }
                },
            }
        })

        local ok, err = checker:add_target("127.0.0.1", 8080, "example.com", false)

        local handler = function(target, eventname, sourcename, pid)
            ngx.log(ngx.DEBUG,"Event from: ", sourcename)
            if eventname == checker.events.remove
                -- a target was removed
                ngx.log(ngx.DEBUG,"Target removed: ",
                    target.ip, ":", target.port, " ", target.hostname)
            elseif eventname == checker.events.healthy
                -- target changed state, or was added
                ngx.log(ngx.DEBUG,"Target switched to healthy: ",
                    target.ip, ":", target.port, " ", target.hostname)
            elseif eventname ==  checker.events.unhealthy
                -- target changed state, or was added
                ngx.log(ngx.DEBUG,"Target switched to unhealthy: ",
                    target.ip, ":", target.port, " ", target.hostname)
            else
                -- unknown event
            end
        end
    }
}
```

## Description

This library supports performing active and passive health checks on arbitrary hosts.

Control of the library happens via its programmatic API. Consumption of its events
happens via the [lua-resty-worker-events](https://github.com/Kong/lua-resty-worker-events) library.

Targets are added using `checker:add_target(host, port)`.
Changes in status ("healthy" or "unhealthy") are broadcasted via worker-events.

Active checks are executed in the background based on the specified timer intervals.

For passive health checks, the library receives explicit notifications via its
programmatic API using functions such as `checker:report_http_status(host, port, status)`.

Each checker has a `status_ver` field: a number that increases whenever the
answer of `checker:get_target_status()` changes for one of its targets in the
current worker. That is when a target moves between the healthy and the
unhealthy side, when a target appears in or disappears from the worker's copy
of the targets, and when that copy is cleared. A caller that caches something
derived from the targets' statuses can use it as the version of that cache.

See the [online LDoc documentation](http://kong.github.io/lua-resty-healthcheck)
for the complete API.

## Keeping the workers in step

Each worker has its own copy of the targets of a checker and of their status,
which is what `checker:get_target_status()` reads. The copy is kept up to date
by the events this library raises for every change. An event that does not
reach a worker, because it was lost on the way or dispatched just before the
checker subscribed, leaves that copy wrong, so every worker also compares its
copies with the shm:

- Every change increments a version of its checker and a version of the shm,
  both kept in the shm, and its event carries the two numbers. A worker that
  got every event knows which versions the shm must have.
- A timer in each worker reads the version of each shm every 0.1 s. When it
  is the expected one there is nothing else to do, however many checkers and
  changes there are.
- When the shm is ahead, and still is 5 ms later (the events may be on their
  way), the worker reads the version of each of its checkers and compares the
  ones that are behind with the shm, target by target: statuses are taken
  from the shm, targets are added and removed to match the target list. An
  event that is later than that is handled like a lost one, and ignored when
  it comes. lua-resty-events pauses 50 ms after every 100 events a worker
  sends, so this happens regularly when changes are frequent: such a run of
  the timer costs one read per checker of the worker, and one comparison per
  checker that changed.
- In the background, every checker is also compared in turn whatever the
  versions say, which covers what versions cannot tell (a version key evicted
  from a full shm, a worker that still runs an older version of this library
  during a reload). A checker is compared at most once every 10 s, and each
  run of the timer spends a fixed amount of work on this, so with many
  targets a round takes longer: (targets + 2 x checkers) / 200 seconds.

So a copy is put right about 0.1 s after an event was lost. A comparison
yields every 1,000 targets or so, only one runs at a time in a worker, and
the events that arrive for a checker while it is being compared are kept and
applied afterwards. A comparison only reads the shm: it writes nothing and
raises no event. It logs `reconciled <n> target(s) with shm` at info level
when it had something to correct, and increments `status_ver` as an event
would.

A comparison can only take from the shm what is there. When the state of a
listed target, or the target list, was evicted from a shm that is full, the
worker keeps what it has for it. Until a comparison can read everything again,
it also applies the events of that checker that come late, unless it read a
newer state for their target, and compares the checker again after each. For a
missing state key that lasts until the target changes state again, which
writes the key. The events of one target are applied in the order of its
changes, so one that arrives after a later one changes nothing.

The data of an event has three more fields for this: `version`,
`shm_version` and `shm`. Events without them, from workers that still run an
older version of this library during a reload, are applied as before.

## Sizing the shm

All checkers that use the same `shm_name` keep their data in that
`lua_shared_dict`. Apache APISIX uses one dictionary for all its checkers:
`upstream-healthcheck`, 10m by default, set under
`nginx_config.meta.lua_shared_dict` in its `config.yaml` (APISIX 3.16 and
later; before that, `upstream-healthcheck` under
`nginx_config.http.lua_shared_dict` and `upstream-healthcheck-stream` under
`nginx_config.stream.lua_shared_dict`).

What is stored:

| Entry | How many | Size |
|---|---|---|
| state of a target | one per target | 256 bytes (*) |
| counters of a target | one per target, created by the first report or probe result that is counted for it | 256 bytes (*) |
| target list of a checker | one per checker, a single value | about 50 bytes per target, more with long hostnames or metadata; 256 bytes for one target, 1 KB for 10, whole 4 KB pages above 2 KB |
| version of a checker | one per checker | 256 bytes (*) |
| version of the shm | one | 128 bytes |

(*) An entry takes a slot of 128, 256, 512... bytes, depending mostly on the
length of its key, which contains the name of the checker and the ip, port and
hostname of the target. 256 bytes is what the names used in the measurements
below need.

A write to a shm that is full first evicts the entries that were used least
recently, up to 30 of them, which can be the state of another target or the
target list of another checker. If that does not free a large enough block,
the write fails with `no memory`, after those evictions and after the value
the key had before was removed: an `add_target()` that fails this way leaves
its checker without a target list in the shm. This library logs it when one
of its writes evicts entries (a warning) or fails (an error), both as `shm
'<name>' is full: ...`, and when a checker finds that its target list is gone
(an error, `shm '<name>' no longer has the target list of checker ...`): at
most one warning and one error a minute for each shm in each worker, so a
failed write and a lost target list share the error.

How many targets fit depends on how they are spread over the checkers,
because the target list of a checker is one value: it needs a run of
contiguous free pages, and it is written again, one entry longer, every time
a target is added. Measured in a 10m dictionary, with checkers named as APISIX
names them and targets added until the first write that evicted entries or
failed (which of the two comes first depends on the layout; in the fourth and
the fifth row it was a write of a target list that failed):

| Targets per checker | Counters | Bytes per target | Targets when the shm was full | Free pages left then |
|---|---|---|---|---|
| 1 | no | 768 | 13,600 | 0% |
| 10 | no | 384 | 27,100 | 0% |
| 100 | no | 341 | 27,600 | 10% |
| 1,000 | no | 306 | 19,000 | 45% |
| 10 | yes | 640 | 16,300 | 0% |
| 100, with 40-character hostnames | yes | 597 | 16,500 | 6% |

So, to size the dictionary:

- count 512 bytes per target for its state and its counters, 256 bytes per
  checker for its version, plus 50 to 250 bytes per target for the target
  lists (the fewer targets per checker, the more);
- then leave room for the target lists to be rewritten: with 100 targets per
  checker the shm was full with a tenth of its pages still free, with 1,000
  targets per checker with almost half of them free. The free space of the
  dictionary (`ngx.shared.DICT:free_space()`, exported by APISIX as
  `apisix_shared_dict_free_space_bytes`) therefore does not tell how many more
  targets fit when checkers are large;
- a single number of targets that fits a given size does not exist: 10m held
  between 13,600 and 27,600 targets in the cases above.

The numbers were measured with OpenResty 1.29.2.4 on a 64-bit Linux with 4 KB
pages; `t/shm-sizing/measure_shm.lua` reproduces them.

## History

Versioning is strictly based on [Semantic Versioning](https://semver.org/)

### 1.6.3 (06-Sep-2023)

* Feature: Added support for https_sni [#49](https://github.com/Kong/lua-resty-healthcheck/pull/49) (backport)
* Fix: Use OpenResty API for mTLS [#99](https://github.com/Kong/lua-resty-healthcheck/pull/99) (backport)

### 1.6.2 (17-Nov-2022)

* Fix: avoid raising worker events for new targets that were marked for delayed
  removal, i.e. targets that already exist in memory only need the removal flag
  cleared when added back. [#122](https://github.com/Kong/lua-resty-healthcheck/pull/122)

### 1.6.1 (25-Jul-2022)

* Fix: improvements to ensure the proper securing of shared resources to avoid
  race conditions and clearly report failure states.
  [#112](https://github.com/Kong/lua-resty-healthcheck/pull/112),
  [#113](https://github.com/Kong/lua-resty-healthcheck/pull/113),
  [#114](https://github.com/Kong/lua-resty-healthcheck/pull/114).
* Fix: reduce the frequency of checking for unused targets, reducing the number
  of locks created. [#116](https://github.com/Kong/lua-resty-healthcheck/pull/116)
* Fix accept any [lua-resty-events](https://github.com/Kong/lua-resty-events)
  `0.1.x` release. [#118](https://github.com/Kong/lua-resty-healthcheck/pull/118)

### 1.6.0 (27-Jun-2022)

* Feature: introduce support to [lua-resty-events](https://github.com/Kong/lua-resty-events)
  module in addition to [lua-resty-worker-events](https://github.com/Kong/lua-resty-worker-events)
  support. With this addition, the lua-resty-healthcheck luarocks package does
  not require a specific event-sharing module anymore, but you are still
  required to provide either lua-resty-worker-events or lua-resty-events.
  [#105](https://github.com/Kong/lua-resty-healthcheck/pull/105)
* Change: if available, lua-resty-healthcheck now uses `string.buffer`, the new LuaJIT's
  serialization API. If it is unavailable, lua-resty-healthcheck fallbacks to
  cjson.  [#109](https://github.com/Kong/lua-resty-healthcheck/pull/109)

### 1.5.1 (23-Mar-2022)

* Fix: avoid breaking active health checks when adding or removing targets.
  [#93](https://github.com/Kong/lua-resty-healthcheck/pull/93)

### 1.5.0 (09-Feb-2022)

* New option `checks.active.headers` supports one or more lists of values indexed by
  header name. [#87](https://github.com/Kong/lua-resty-healthcheck/pull/87)
* Introduce dealyed_clear() function, used to remove addresses after a time interval.
  This function may be used when an address is being removed but may be added again
  before the interval expires, keeping its health status.
  [#88](https://github.com/Kong/lua-resty-healthcheck/pull/88)

### 1.4.3 (31-Mar-2022)

* Fix: avoid breaking active health checks when adding or removing targets.
  [#100](https://github.com/Kong/lua-resty-healthcheck/pull/100)

### 1.4.2 (29-Jun-2021)

* Fix: prevent new active checks being scheduled while a health check is running.
  [#72](https://github.com/Kong/lua-resty-healthcheck/pull/72)
* Fix: remove event watcher when stopping an active health check.
  [#74](https://github.com/Kong/lua-resty-healthcheck/pull/74); fixes Kong issue
  [#7406](https://github.com/Kong/kong/issues/7406)

### 1.4.1 (17-Feb-2021)

* Fix: make sure that a single worker will actively check hosts' statuses.
  [#67](https://github.com/Kong/lua-resty-healthcheck/pull/67)

### 1.4.0 (07-Jan-2021)

* Use a single timer to actively health check targets. This reduces the number
  of timers used by health checkers, as they used to use two timers by each
  target. [#62](https://github.com/Kong/lua-resty-healthcheck/pull/62)

### 1.3.0 (17-Jun-2020)

* Adds support to mTLS to active healthchecks. This feature  can be used adding
  the fields `ssl_cert` and `ssl_key`, with certificate and key respectively,
  when creating a new healthcheck object.
  [#41](https://github.com/Kong/lua-resty-healthcheck/pull/41)

### 1.2.0 (13-Feb-2020)

 * Adds `set_all_target_statuses_for_hostname`, which sets the targets for
   all entries with a given hostname at once.

### 1.1.2 (19-Dec-2019)

 * Fix: when `ngx.sleep` API is not available (e.g. in the log phase) it is not
   possible to lock using lua-resty-lock and any function that needs exclusive
   access would fail. This fix adds a retry method that starts a new light
   thread, which has access to `ngx.sleep`, to lock the critical path.
   [#37](https://github.com/Kong/lua-resty-healthcheck/pull/37);

### 1.1.1 (14-Nov-2019)

 * Fix: fail when it is not possible to get exclusive access to the list of
   targets. This fix prevents that workers get to an inconsistent state.
   [#34](https://github.com/Kong/lua-resty-healthcheck/pull/34);

### 1.1.0 (30-Sep-2019)

 * Add support for setting the custom `Host` header to be used for active checks.
 * Fix: log error on SSL Handshake failure
   [#28](https://github.com/Kong/lua-resty-healthcheck/pull/28);

### 1.0.0 (05-Jul-2019)

 * BREAKING: all API functions related to hosts require a `hostname` argument
   now. This way different hostnames listening on the same IP and ports
   combination do not have an effect on each other.
 * Fix: fix reporting active TCP probe successes
   [#20](https://github.com/Kong/lua-resty-healthcheck/pull/20);
   fixes issue [#19](https://github.com/Kong/lua-resty-healthcheck/issues/19)

### 0.6.1 (04-Apr-2019)

 * Fix: set up event callback only after target list is loaded
   [#18](https://github.com/Kong/lua-resty-healthcheck/pull/18);
   fixes Kong issue [#4453](https://github.com/Kong/kong/issues/4453)

### 0.6.0 (26-Sep-2018)

 * Introduce `checks.active.https_verify_certificate` field.
   It is `true` by default; setting it to `false` disables certificate
   verification in active healthchecks over HTTPS.

### 0.5.0 (25-Jul-2018)

 * Add support for `https` -- thanks @gaetanfl for the PR!
 * Introduce separate `checks.active.type` and `checks.passive.type` fields;
   the top-level `type` field is still supported as a fallback but is now
   deprecated.

### 0.4.2 (23-May-2018)

 * Fix `Host` header in active healthchecks

### 0.4.1 (21-May-2018)

 * Fix internal management of healthcheck counters

### 0.4.0 (20-Mar-2018)

 * Correct setting of defaults in `http_statuses`
 * Type and bounds checking to `checks` table

### 0.3.0 (18-Dec-2017)

 * Disable individual checks by setting their counters to 0

### 0.2.0 (30-Nov-2017)

 * Adds `set_target_status`

### 0.1.0 (27-Nov-2017) Initial release

 * Initial upload

## Copyright and License

```
Copyright 2017-2022 Kong Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

[badge-travis-url]: https://travis-ci.org/Kong/lua-resty-healthcheck/branches
[badge-travis-image]: https://travis-ci.org/Kong/lua-resty-healthcheck.svg?branch=master
