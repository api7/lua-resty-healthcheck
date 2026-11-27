local healthcheck = require "resty.healthcheck"
local lock = require "resty.lock"
local ip = "127.0.0.1"

local function wait_until(predicate)
  local deadline = ngx.now() + 5
  while not predicate() do
    assert(ngx.now() < deadline, "timed out waiting for purge")
    ngx.sleep(0.01)
  end
end

local function observe(checker, fault, alternate)
  local real = checker.shm
  local primary, staged = checker.TARGET_LIST, checker.TARGET_LIST_STAGING
  local huge = string.rep("x", ngx.shared.test_shm:capacity() + 1)
  local stats = { reads = 0, main_writes = 0, stage_writes = 0, attempts = 0 }
  checker.shm = setmetatable({}, {
    __index = function(_, method)
      return function(_, key, ...)
        if key == primary and method == "get" then
          stats.reads = stats.reads + 1
        elseif key == staged and method == "safe_set" then
          stats.stage_writes = stats.stage_writes + 1
          local probe = assert(lock:new(checker.shm_name, { timeout = 0 }))
          local elapsed, err = probe:lock(checker.TARGET_LIST_LOCK)
          assert(not elapsed and err == "timeout", "staged outside the list lock")
          if fault == "stage" then
            fault = nil
            return real:safe_set(staged, huge)
          end
        elseif key == primary and (method == "safe_set" or method == "safe_add" or method == "set") then
          stats.main_writes = stats.main_writes + 1
          if fault == "primary" or fault == "winner" then
            local ok, err = real[method](real, key, huge)
            assert(not ok and err == "no memory" and real:get(key) == nil)
            if fault == "winner" then
              assert(real:safe_add(primary, alternate))
              fault = nil
            else
              fault = "restore"
            end
            return ok, err
          elseif fault == "restore" and method == "safe_add" then
            fault = nil
            stats.attempts = stats.attempts + 1
            return real:safe_add(primary, huge)
          elseif fault == "fallback_only" then
            assert(method == "safe_add")
            return real:safe_add(primary, huge)
          end
        elseif fault == "state" and key == checker.TARGET_STATE .. ":" .. ip .. ":33333:" .. ip then
          assert(method == "safe_set", "a state write could evict the current list")
          return real:safe_set(key, huge)
        end
        return real[method](real, key, ...)
      end
    end,
  })
  return stats
end

local function run(new_checker, op)
  local checker = new_checker()
  local raw = ngx.shared.test_shm
  local primary, staged = checker.TARGET_LIST, checker.TARGET_LIST_STAGING
  if op == "full_shrink" then
    -- A second copy of this list cannot fit. Clearing only needs to stage
    -- the new empty list. A later growth that cannot fit must keep it.
    assert(checker:add_target(ip, 11111, "a.local", false, nil,
                              { blob = string.rep("x", 320 * 1024) }))
    local large = assert(raw:get(primary))
    local reserved, err = raw:safe_add("old-copy-control", large)
    assert(not reserved and err == "no memory")
    assert(checker:clear())
    assert(raw:get(primary) and raw:get(staged) == nil)
    assert(new_checker():get_target_status(ip, 11111, "a.local") == nil)
    ngx.say("cleared")
    return
  end
  local alternate
  if op == "occupied" or op == "stale_stage" then
    assert(checker:clear())
    alternate = assert(raw:get(primary))
  end
  if op ~= "initial" then
    assert(checker:add_target(ip, 11111, "a.local", false, "probe.local", { rack = 7 }))
    assert(checker:add_target(ip, 22222, "b.local", true))
  end
  if op == "timer" then
    assert(checker:delayed_clear(0))
    healthcheck._set_cleanup_interval(0.1)
  end
  local before = raw:get(primary)
  if op == "stale_stage" then
    -- A worker exited after the previous primary was published.
    assert(raw:safe_add(staged, alternate))
  end
  local mode = ({ remove = "stage", clear = "stage", delayed = "stage", timer = "stage",
                  occupied = "winner", fallback = "primary", stale_stage = "primary",
                  state = "state" })[op]
  local count = observe(checker, mode, alternate)
  local ok, err
  if op == "add" or op == "initial" or op == "state" then
    -- Public metadata, without replacing any dict argument, triggers real
    -- allocation failure on the first primary write or on the staged write.
    local meta = op ~= "state" and { blob = string.rep("x", raw:capacity() + 1) } or nil
    ok, err = checker:add_target(ip, 33333, nil, true, nil, meta)
  elseif op == "remove" or op == "occupied" or op == "fallback" or op == "stale_stage" then
    ok, err = checker:remove_target(ip, 11111, "a.local")
  elseif op == "clear" then
    ok, err = checker:clear()
  elseif op == "delayed" then
    ok, err = checker:delayed_clear(60)
  elseif op == "timer" then
    wait_until(function() return count.stage_writes > 0 or count.main_writes > 0 end)
    ngx.say("retained=", raw:get(primary) == before, " writes=", count.main_writes)
    wait_until(function()
      return raw:get(primary) ~= before and #healthcheck.get_target_list("testing", "test_shm") == 0
    end)
    ngx.say("purged")
    return
  elseif op == "encoding" or op == "encoding_cjson" then
    ok, err = checker:add_target(ip, 33333, nil, true, nil, { invalid = function() end })
    assert(ok == nil and err:find("failed to store target_list in shm: ", 1, true) == 1,
           tostring(err))
    assert(err:find("seriali", 1, true), err)
    assert(raw:get(checker.TARGET_STATE .. ":" .. ip .. ":33333:" .. ip) == nil)
    ngx.say("retained=", raw:get(primary) == before, " writes=", count.main_writes,
            " staged=", count.stage_writes)
    return
  elseif op == "fast" then
    assert(checker:add_target(ip, 33333, nil, true))
    assert(checker:remove_target(ip, 11111, "a.local"))
    assert(checker:delayed_clear(60))
    assert(checker:clear())
    ngx.say("reads=", count.reads, " writes=", count.main_writes, " staged=", count.stage_writes)
    return
  end

  ngx.say(tostring(ok), " ", tostring(err))
  if op == "initial" then
    ngx.say("absent=", raw:get(primary) == nil, " staged=", tostring(raw:get(staged)))
  elseif op == "occupied" then
    ngx.say("untouched=", raw:get(primary) == alternate, " staged=", tostring(raw:get(staged)))
  elseif op == "fallback" or op == "stale_stage" then
    local saved = assert(raw:get(staged))
    assert(raw:get(primary) == nil and saved ~= before and saved ~= alternate)
    observe(checker, "fallback_only")
    local retry, retry_err = checker:clear()
    assert(not retry and retry_err == "failed to store target_list in shm: no memory")
    assert(raw:get(staged) == saved and raw:get(primary) == nil)
    -- The fresh checker can repair the legacy key once capacity allows it.
    local fresh = new_checker()
    ngx.say("a=", tostring(fresh:get_target_status(ip, 11111, "a.local")),
            " b=", tostring(fresh:get_target_status(ip, 22222, "b.local")))
    assert(raw:get(primary) == saved and raw:get(staged) == nil)
    assert(fresh:clear())
    ngx.say("retry cleared")
  else
    local fresh = new_checker()
    ngx.say("retained=", before == raw:get(primary), " a=",
            tostring(fresh:get_target_status(ip, 11111, "a.local")),
            " b=", tostring(fresh:get_target_status(ip, 22222, "b.local")),
            " staged=", tostring(raw:get(staged)))
  end
end

return { run = run }
