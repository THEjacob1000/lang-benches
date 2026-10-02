local thread_id = 0
local scenario = os.getenv("SCENARIO") or "health"
local tokens = {}
local payload = '{"body":"' .. string.rep("benchmark ", 15) .. '"}'

function setup(thread)
  thread_id = thread_id + 1
  thread:set("seed", 1729 + thread_id * 104729)
end

function init(args)
  math.randomseed(seed)
  if scenario ~= "health" and scenario ~= "feed" and scenario ~= "post" and scenario ~= "mixed" then
    error("unknown SCENARIO: " .. scenario)
  end
  for token in assert(io.open("data/tokens.txt", "r")):lines() do tokens[#tokens + 1] = token end
  assert(#tokens == 10000, "expected 10000 user tokens")
end

function request()
  local selected = scenario
  if selected == "mixed" then
    local roll = math.random(100)
    if roll <= 70 then selected = "feed"
    elseif roll <= 90 then selected = "post"
    else selected = "comment" end
  end
  local headers = { ["Authorization"] = "Bearer " .. tokens[math.random(#tokens)] }
  if selected == "feed" then return wrk.format("GET", "/feed", headers) end
  local path = "/posts/" .. math.random(100000)
  if selected == "post" then return wrk.format("GET", path, headers) end
  headers["Content-Type"] = "application/json"
  return wrk.format("POST", path .. "/comments", headers, payload)
end

-- wrk's static request avoids Lua work in the health baseline.
if scenario == "health" then
  wrk.path = "/health"
  request = nil
end

function done(summary, latency, requests)
  local file = assert(io.open(assert(os.getenv("WRK_JSON"), "WRK_JSON is required"), "w"))
  file:write(string.format('{"requests":%d,"duration_us":%d,"bytes":%d,"errors":{"connect":%d,"read":%d,"write":%d,"status":%d,"timeout":%d},"rps":%.6f,"latency_us":{"mean":%.6f,"stdev":%.6f,"max":%.6f,"p50":%.6f,"p90":%.6f,"p99":%.6f,"p999":%.6f}}\n',
    summary.requests, summary.duration, summary.bytes, summary.errors.connect, summary.errors.read,
    summary.errors.write, summary.errors.status, summary.errors.timeout,
    summary.requests / (summary.duration / 1000000), latency.mean, latency.stdev, latency.max,
    latency:percentile(50), latency:percentile(90), latency:percentile(99), latency:percentile(99.9)))
  file:close()
end
