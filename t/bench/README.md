# Benchmarks

Not tests: nothing here is run by `prove`. They produce the figures quoted in
the pull request that added the reconciliation of the workers' copies with shm
(see "Keeping the workers in step" in the readme), and can be run against any
version of `lib/resty/healthcheck.lua` to compare.

## Callbacks, one at a time

`callbacks.lua` times the event callback of a checker and the timer callbacks
of a worker, with a real shm and nothing else running: the timers and the
event transport are replaced, so the script calls each callback itself. It
also reports the longest stretch a callback ran without yielding.

    SCENARIO=missed TARGETS=10000 CHECKERS=1 ROUNDS=30 \
      resty --shdict "hc 512m" \
            --main-conf "env SCENARIO; env TARGETS; env CHECKERS; env ROUNDS;" \
            -I lib t/bench/callbacks.lua

The scenarios are listed at the top of the script. `resty` and
lua-resty-timer have to be installed; the events library is not needed.

`idle`, `status`, `missed` and `late` first run the timers until every checker
was compared with shm once (110 passes with a version of the library that does
not compare), so the first comparison of a checker, which also decodes its
list, is not in the figures. The background comparison goes on after that, a
few checkers in each pass: with many checkers or targets the passes of `idle`
cover a part of a round of it, and the `compared=` counter in the last line of
the output tells how many checkers that was.

`status`, `missed` and `late` create two checkers for each name (the one that
makes the change and the one that is measured), so `CHECKERS=10000` there is
20,000 checkers in the worker. `clear` and `remove-missed` create two as well,
whatever `CHECKERS` is. The settings behind the figures quoted in the pull
request, as `SCENARIO TARGETS CHECKERS ROUNDS`:

    clear          10000 1     21        clear          18000 1     21
    remove         2000  1     5
    idle           2     10000 200       idle           10    1000  200
    idle           10000 1     200
    status         2     10000 100       status         10000 1     100
    missed         2     10000 30        missed         10000 1     30
    late           2     10000 30        late           10000 1     30
    remove-missed  10000 1     21        remove-missed  18000 1     21

## Requests through Apache APISIX

`apisix/run.sh` starts Apache APISIX in a container with a given copy of the
library, with an active health check on every upstream, and sends requests
through it: throughput, latency, the CPU time of the workers. Targets can be
made to change state all the time, and a share of the events can be lost.

    t/bench/apisix/run.sh "$PWD/lib/resty/healthcheck.lua" 200 5 40 5 1

That is 200 upstreams of 5 nodes each, 40 of them changing state every two
seconds, 5% of the events lost, a check every second. Needs docker and the
`apache/apisix:3.19.0-debian` image (or `IMAGE=...`).
