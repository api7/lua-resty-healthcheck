#!/usr/bin/env python3
# gen_conf.py <upstreams> <nodes per upstream> <flapping upstreams> > apisix.yaml
import sys
K, M, F = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
INTERVAL = int(sys.argv[4]) if len(sys.argv) > 4 else 1
out = ["routes:"]
def fn_route(rid, uri, code):
    out.extend([f"  - id: {rid}", f"    uri: {uri}", "    plugins:", "      serverless-pre-function:", "        phase: access", "        functions:", f'          - "{code}"'])
fn_route("up", "/up", "return function() ngx.header['Content-Length'] = 3; ngx.print('up\\\\n'); ngx.exit(200) end")
# healthy and unhealthy in turn, two seconds each
fn_route("flap", "/flap", "return function() if math.floor(ngx.now() / 2) % 2 == 0 then ngx.header['Content-Length'] = 3; ngx.print('up\\\\n'); ngx.exit(200) end ngx.exit(500) end")
fn_route("whoami", "/whoami", "return function() local b = tostring(ngx.worker.id()); ngx.header['Content-Length'] = #b; ngx.print(b); ngx.exit(200) end")
fn_route("hookstats", "/hookstats", "return function() local b = require('bench_hook').stats(); ngx.header['Content-Length'] = #b; ngx.print(b); ngx.exit(200) end")
for i in range(1, K + 1):
    out.extend([f"  - id: r{i}", f"    uri: /hello/{i}", "    plugins:", "      proxy-rewrite:", "        uri: /up", f"    upstream_id: {i}"])
out.append("upstreams:")
for i in range(1, K + 1):
    path = "/flap" if i <= F else "/up"
    out.extend([f"  - id: {i}", "    type: roundrobin", "    retries: 0", "    nodes:"])
    for n in range(M):
        out.append(f'      "127.{1 + n}.{i >> 8}.{i & 255}:9080": 1')
    out.extend(["    checks:", "      active:", "        type: http", f"        http_path: {path}", "        concurrency: 20",
                "        healthy:", f"          interval: {INTERVAL}", "          successes: 1",
                "        unhealthy:", f"          interval: {INTERVAL}", "          http_failures: 1", "          tcp_failures: 1"])
out.append("#END")
print("\n".join(out))
