#!/usr/bin/env bash
# Runs Apache APISIX with a given copy of this library, with health checks on
# every upstream, and measures requests through it: throughput, latency, and
# the CPU time of the workers. Not a test.
#
#   run.sh <healthcheck.lua> <upstreams> <nodes each> <flapping upstreams> \
#          <lost events, percent> <check interval, s> [duration, s] [connections]
#
# - every upstream has <nodes each> nodes, all of them this APISIX itself, and
#   an active check every <check interval> seconds;
# - the first <flapping upstreams> are probed on a path that answers 200 and
#   500 in turn, two seconds each, so each of their nodes changes state every
#   two seconds;
# - <lost events> percent of the health check events reach no callback in the
#   worker that should get them (hook/bench_hook.lua).
#
# Needs docker and the image named by IMAGE (default apache/apisix:3.19.0-debian).
# Prints one line of JSON, see load.lua.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
image="${IMAGE:-apache/apisix:3.19.0-debian}"
lib="$1"; K="$2"; M="$3"; F="$4"; LOSE="$5"; INT="$6"; DUR="${7:-15}"; CONNS="${8:-16}"
work="$(mktemp -d "${TMPDIR:-/tmp}/hc-bench.XXXXXX")"; chmod 0755 "$work"
python3 "$here/gen_conf.py" "$K" "$M" "$F" "$INT" > "$work/apisix.yaml"
cp "$here/config.yaml" "$work/config.yaml"
name="hc-bench-$$"
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
docker run -d --rm --network none --user root --name "$name" -e "LOSE_PERCENT=$LOSE" \
  --mount "type=bind,src=$work,dst=/bench/conf,readonly" \
  --mount "type=bind,src=$here/hook,dst=/bench/hook,readonly" \
  --mount "type=bind,src=$here/load.lua,dst=/bench/load.lua,readonly" \
  --mount "type=bind,src=$lib,dst=/usr/local/apisix/deps/share/lua/5.1/resty/healthcheck.lua,readonly" \
  --entrypoint sh "$image" -c 'cp /bench/conf/config.yaml /bench/conf/apisix.yaml /usr/local/apisix/conf/ && cd /usr/local/apisix && apisix init >/tmp/init.log 2>&1 || { cat /tmp/init.log; exit 1; }; exec /usr/local/openresty/bin/openresty -p /usr/local/apisix -g "daemon off;"' >/dev/null
sleep 5
docker exec -e "UPSTREAMS=$K" -e "DURATION=$DUR" -e "CONNS=$CONNS" "$name" \
  timeout 600 /usr/local/openresty/bin/resty \
  --main-conf "env UPSTREAMS; env DURATION; env CONNS; env HOT; env SETTLE; env WORKERS;" \
  -I /usr/local/apisix/deps/share/lua/5.1 /bench/load.lua 2>&1 | tail -1
