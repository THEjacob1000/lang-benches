local thread_id = 0
local scenario = os.getenv("SCENARIO") or "health"
local title = string.rep("test ", 8)
local body = string.rep("benchmark ", 50)

function setup(thread)
  thread_id = thread_id + 1
  thread:set("seed", 1729 + thread_id * 104729)
end

function init(args)
  math.randomseed(seed)
  if scenario ~= "health" and scenario ~= "user" and scenario ~= "posts" and scenario ~= "write" and scenario ~= "mixed" then
    error("unknown SCENARIO: " .. scenario)
  end
end

function request()
  local selected, user = scenario, math.random(10000)
  if selected == "mixed" then
    -- Reads and writes hit disjoint users so a faster writer doesn't change the size of its own posts reads.
    local roll = math.random(100)
    if roll <= 60 then selected, user = "user", math.random(5000)
    elseif roll <= 80 then selected, user = "posts", math.random(5000)
    else selected, user = "write", 5000 + math.random(5000) end
  end
  if selected == "user" then return wrk.format("GET", "/users/" .. user) end
  if selected == "posts" then return wrk.format("GET", "/users/" .. user .. "/posts") end
  local payload = string.format('{"userId":%d,"title":"%s","body":"%s"}', user, title, body)
  return wrk.format("POST", "/posts", { ["Content-Type"] = "application/json" }, payload)
end

-- wrk only sends its prebuilt static request (with the Host header) when no request() exists.
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
