local helpers = require "spec.helpers"
local timestamp = require "kong.tools.timestamp"

local function wait()
  -- If the minute elapses in the middle of the test, then the test will
  -- fail. So we give it this test 30 seconds to execute, and if the second
  -- of the current minute is > 30, then we wait till the new minute kicks in
  local current_second = timestamp.get_timetable().sec
  if current_second > 30 then
    os.execute("sleep "..tostring(60 - current_second))
  end
end

wait() -- Wait before starting

for i, policy in ipairs({"local", "cluster", "redis"}) do
  describe("Plugin: rate-limiting (access) with policy: "..policy, function()
    setup(function()
      helpers.kill_all()
      helpers.dao:drop_schema()
      assert(helpers.dao:run_migrations())

      local consumer1 = assert(helpers.dao.consumers:insert {
        custom_id = "provider_123"
      })
      assert(helpers.dao.keyauth_credentials:insert {
        key = "apikey122",
        consumer_id = consumer1.id
      })

      local consumer2 = assert(helpers.dao.consumers:insert {
        custom_id = "provider_124"
      })
      assert(helpers.dao.keyauth_credentials:insert {
        key = "apikey123",
        consumer_id = consumer2.id
      })
      
      local api1 = assert(helpers.dao.apis:insert {
        request_host = "test1.com",
        upstream_url = "http://mockbin.com"
      })
      assert(helpers.dao.plugins:insert {
        name = "rate-limiting",
        api_id = api1.id,
        config = { policy = policy, minute = 6, cluster_fault_tolerant = false, redis_host = "127.0.0.1" }
      })

      local api2 = assert(helpers.dao.apis:insert {
        request_host = "test2.com",
        upstream_url = "http://mockbin.com"
      })
      assert(helpers.dao.plugins:insert {
        name = "rate-limiting",
        api_id = api2.id,
        config = { minute = 3, hour = 5, cluster_fault_tolerant = false, policy = policy, redis_host = "127.0.0.1" }
      })

      local api3 = assert(helpers.dao.apis:insert {
        request_host = "test3.com",
        upstream_url = "http://mockbin.com"
      })
      assert(helpers.dao.plugins:insert {
        name = "key-auth",
        api_id = api3.id
      })
      assert(helpers.dao.plugins:insert {
        name = "rate-limiting",
        api_id = api3.id,
        config = { minute = 6, cluster_fault_tolerant = false, policy = policy, redis_host = "127.0.0.1" }
      })
      assert(helpers.dao.plugins:insert {
        name = "rate-limiting",
        api_id = api3.id,
        consumer_id = consumer1.id,
        config = { minute = 8, cluster_fault_tolerant = false, policy = policy, redis_host = "127.0.0.1" }
      })

      local api4 = assert(helpers.dao.apis:insert {
        request_host = "test4.com",
        upstream_url = "http://mockbin.com"
      })
      assert(helpers.dao.plugins:insert {
        name = "key-auth",
        api_id = api4.id
      })
      assert(helpers.dao.plugins:insert {
        name = "rate-limiting",
        api_id = api4.id,
        consumer_id = consumer1.id,
        config = { minute = 6, cluster_fault_tolerant = true, policy = policy, redis_host = "127.0.0.1" }
      })

      assert(helpers.start_kong())
    end)

    teardown(function()
      helpers.stop_kong()
      --helpers.clean_prefix()
    end)

    describe("Without authentication (IP address)", function()
      it("blocks if exceeding limit", function()
        for i = 1, 6 do
          local res = assert(helpers.proxy_client():send {
            method = "GET",
            path = "/status/200/",
            headers = {
              ["Host"] = "test1.com"
            }
          })
          assert.res_status(200, res)
          assert.are.same(6, tonumber(res.headers["x-ratelimit-limit-minute"]))
          assert.are.same(6 - i, tonumber(res.headers["x-ratelimit-remaining-minute"]))
        end

        -- Additonal request, while limit is 6/minute
        local res = assert(helpers.proxy_client():send {
          method = "GET",
          path = "/status/200/",
          headers = {
            ["Host"] = "test1.com"
          }
        })
        local body = assert.res_status(429, res)
        assert.are.equal([[{"message":"API rate limit exceeded"}]], body)
      end)

      it("handles multiple limits", function()
        local limits = {
          minute = 3,
          hour = 5
        }

        for i = 1, 3 do
          local res = assert(helpers.proxy_client():send {
            method = "GET",
            path = "/status/200/",
            headers = {
              ["Host"] = "test2.com"
            }
          })
          assert.res_status(200, res)

          assert.are.same(limits.minute, tonumber(res.headers["x-ratelimit-limit-minute"]))
          assert.are.same(limits.minute - i, tonumber(res.headers["x-ratelimit-remaining-minute"]))
          assert.are.same(limits.hour, tonumber(res.headers["x-ratelimit-limit-hour"]))
          assert.are.same(limits.hour - i, tonumber(res.headers["x-ratelimit-remaining-hour"]))
        end

        local res = assert(helpers.proxy_client():send {
          method = "GET",
          path = "/status/200/",
          headers = {
            ["Host"] = "test2.com"
          }
        })
        local body = assert.res_status(429, res)
        assert.are.equal([[{"message":"API rate limit exceeded"}]], body)
        assert.are.equal(2, tonumber(res.headers["x-ratelimit-remaining-hour"]))
        assert.are.equal(0, tonumber(res.headers["x-ratelimit-remaining-minute"]))
      end)
    end)
    describe("With authentication", function()
      describe("API-specific plugin", function()
        it("blocks if exceeding limit", function()
          for i = 1, 6 do
            local res = assert(helpers.proxy_client():send {
              method = "GET",
              path = "/status/200/?apikey=apikey123",
              headers = {
                ["Host"] = "test3.com"
              }
            })
            assert.res_status(200, res)
            assert.are.same(6, tonumber(res.headers["x-ratelimit-limit-minute"]))
            assert.are.same(6 - i, tonumber(res.headers["x-ratelimit-remaining-minute"]))
          end

          -- Third query, while limit is 2/minute
          local res = assert(helpers.proxy_client():send {
            method = "GET",
            path = "/status/200/?apikey=apikey123",
            headers = {
              ["Host"] = "test3.com"
            }
          })
          local body = assert.res_status(429, res)
          assert.are.equal([[{"message":"API rate limit exceeded"}]], body)
        end)
      end)
      describe("Plugin customized for specific consumer", function()
        it("blocks if exceeding limit", function()
          for i = 1, 8 do
            local res = assert(helpers.proxy_client():send {
              method = "GET",
              path = "/status/200/?apikey=apikey122",
              headers = {
                ["Host"] = "test3.com"
              }
            })
            assert.res_status(200, res)
            assert.are.same(8, tonumber(res.headers["x-ratelimit-limit-minute"]))
            assert.are.same(8 - i, tonumber(res.headers["x-ratelimit-remaining-minute"]))
          end

          local res = assert(helpers.proxy_client():send {
            method = "GET",
            path = "/status/200/?apikey=apikey122",
            headers = {
              ["Host"] = "test3.com"
            }
          })
          local body = assert.res_status(429, res)
          assert.are.equal([[{"message":"API rate limit exceeded"}]], body)
        end)
        it("blocks if the only rate-limiting plugin existing is per consumer and not per API", function()
          for i = 1, 6 do
            local res = assert(helpers.proxy_client():send {
              method = "GET",
              path = "/status/200/?apikey=apikey122",
              headers = {
                ["Host"] = "test4.com"
              }
            })
            assert.res_status(200, res)
            assert.are.same(6, tonumber(res.headers["x-ratelimit-limit-minute"]))
            assert.are.same(6 - i, tonumber(res.headers["x-ratelimit-remaining-minute"]))
          end

          local res = assert(helpers.proxy_client():send {
            method = "GET",
            path = "/status/200/?apikey=apikey122",
            headers = {
              ["Host"] = "test4.com"
            }
          })
          local body = assert.res_status(429, res)
          assert.are.equal([[{"message":"API rate limit exceeded"}]], body)
        end)
      end)
    end)

    if policy == "cluster" then
      describe("Fault tolerancy", function()

        before_each(function()
          helpers.kill_all()
          helpers.dao:drop_schema()
          assert(helpers.dao:run_migrations())

          local api1 = assert(helpers.dao.apis:insert {
            request_host = "failtest1.com",
            upstream_url = "http://mockbin.com"
          })
          assert(helpers.dao.plugins:insert {
            name = "rate-limiting",
            api_id = api1.id,
            config = { minute = 6, cluster_fault_tolerant = false }
          })

          local api2 = assert(helpers.dao.apis:insert {
            request_host = "failtest2.com",
            upstream_url = "http://mockbin.com"
          })
          assert(helpers.dao.plugins:insert {
            name = "rate-limiting",
            api_id = api2.id,
            config = { minute = 6, cluster_fault_tolerant = true }
          })

          assert(helpers.start_kong())
        end)

        teardown(function()
          helpers.kill_all()
          helpers.dao:drop_schema()
          assert(helpers.dao:run_migrations())
        end)

        it("does not work if an error occurs", function()
          local res = assert(helpers.proxy_client():send {
            method = "GET",
            path = "/status/200/",
            headers = {
              ["Host"] = "failtest1.com"
            }
          })
          assert.res_status(200, res)
          assert.are.same(6, tonumber(res.headers["x-ratelimit-limit-minute"]))
          assert.are.same(5, tonumber(res.headers["x-ratelimit-remaining-minute"]))

          -- Simulate an error on the database
          local err = helpers.dao.ratelimiting_metrics:drop_table(helpers.dao.ratelimiting_metrics.table)
          assert.falsy(err)

          -- Make another request
          local res = assert(helpers.proxy_client():send {
            method = "GET",
            path = "/status/200/",
            headers = {
              ["Host"] = "failtest1.com"
            }
          })
          local body = assert.res_status(500, res)
          assert.are.equal([[{"message":"An unexpected error occurred"}]], body)
        end)
        it("keeps working if an error occurs", function()
          local res = assert(helpers.proxy_client():send {
            method = "GET",
            path = "/status/200/",
            headers = {
              ["Host"] = "failtest2.com"
            }
          })
          assert.res_status(200, res)
          assert.are.same(6, tonumber(res.headers["x-ratelimit-limit-minute"]))
          assert.are.same(5, tonumber(res.headers["x-ratelimit-remaining-minute"]))

          -- Simulate an error on the database
          local err = helpers.dao.ratelimiting_metrics:drop_table(helpers.dao.ratelimiting_metrics.table)
          assert.falsy(err)

          -- Make another request
          local res = assert(helpers.proxy_client():send {
            method = "GET",
            path = "/status/200/",
            headers = {
              ["Host"] = "failtest2.com"
            }
          })
          assert.res_status(200, res)
          assert.falsy(res.headers["x-ratelimit-limit-minute"])
          assert.falsy(res.headers["x-ratelimit-remaining-minute"])
        end)
      end)

    elseif policy == "local" then
      describe("Expirations", function()
        local api
        setup(function()
          helpers.kill_all()
          helpers.dao:drop_schema()
          assert(helpers.dao:run_migrations())

          api = assert(helpers.dao.apis:insert {
            request_host = "expire1.com",
            upstream_url = "http://mockbin.com"
          })
          assert(helpers.dao.plugins:insert {
            name = "rate-limiting",
            api_id = api.id,
            config = { minute = 6, cluster_fault_tolerant = false }
          })

          assert(helpers.start_kong())
        end)

        --[[
        it("expires a local cache key", function()
          local periods = timestamp.get_timestamps(current_timestamp)

          local res = assert(helpers.proxy_client():send {
            method = "GET",
            path = "/status/200/",
            headers = {
              ["Host"] = "expire1.com"
            }
          })
          assert.res_status(200, res)
          assert.are.same(6, tonumber(res.headers["x-ratelimit-limit-minute"]))
          assert.are.same(5, tonumber(res.headers["x-ratelimit-remaining-minute"]))

          print("/cache/"..string.format("ratelimit:%s:%s:%s:%s", api.id, "127.0.0.1", periods.minute, "minute"))

          local res = assert(helpers.admin_client():send {
            method = "GET",
            path = "/cache/"..string.format("ratelimit:%s:%s:%s:%s", api.id, "127.0.0.1", periods.minute, "minute")
          })
          local body = assert.res_status(200, res)
          print(body)
        end)
        --]]
      end)
    end

  end)
end