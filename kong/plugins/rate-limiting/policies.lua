local singletons = require "kong.singletons"
local timestamp = require "kong.tools.timestamp"
local cache = require "kong.tools.database_cache"
local ngx_log = ngx.log
local ngx_timer_at = ngx.timer.at

local get_local_key = function(api_id, identifier, period_date, period)
  return string.format("ratelimit:%s:%s:%s:%s", api_id, identifier, period_date, period)
end

--TODO: Check that it really expires 
local EXPIRATIONS = {
  second = 1,
  minute = 60,
  hour = 3600,
  day = 86400,
  month = 2592000,
  year = 31104000
}

return {
  ["local"] = {
    increment = function(api_id, identifier, current_timestamp, value)
      local periods = timestamp.get_timestamps(current_timestamp)
      local ok = true
      for period, period_date in pairs(periods) do
        local cache_key = get_local_key(api_id, identifier, period_date, period)
        if not cache.rawget(cache_key) then
          cache.rawset(cache_key, 0, EXPIRATIONS[period])
        end

        local _, err = cache.incr(cache_key, value)
        if err then
          ok = false
          ngx_log("[rate-limiting] could not increment counter for period '"..period.."': "..tostring(err))
        end
      end

      return ok
    end,
    usage = function(api_id, identifier, current_timestamp, name)
      local periods = timestamp.get_timestamps(current_timestamp)
      local cache_key = get_local_key(api_id, identifier, periods[name], name)
      local current_metric, err = cache.rawget(cache_key)
      if err then
        return nil, err
      end
      return current_metric and current_metric or 0
    end
  },
  ["cluster"] = {
    increment = function(api_id, identifier, current_timestamp, value)
      local incr = function(premature, api_id, identifier, current_timestamp, value)
        if premature then return end
        local _, stmt_err = singletons.dao.ratelimiting_metrics:increment(api_id, identifier, current_timestamp, value)
        if stmt_err then
          ngx_log(ngx.ERR, "failed to increment: ", tostring(stmt_err))
        end
      end

      local ok, err = ngx_timer_at(0, incr, api_id, identifier, current_timestamp, 1)
      if not ok then
        ngx_log(ngx.ERR, "failed to create timer: ", err)
      end
    end,
    usage = function(api_id, identifier, current_timestamp, name)
      local current_metric, err = singletons.dao.ratelimiting_metrics:find(api_id, identifier, current_timestamp, name)
      if err then
        return nil, err
      end
      return current_metric and current_metric.value or 0
    end
  }
}