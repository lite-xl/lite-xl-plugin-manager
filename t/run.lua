local json = require "plugins.json"

setmetatable(_G, { __index = function(t, k) if not rawget(t, k) then error("cannot get undefined global variable: " .. k, 2) end end, __newindex = function(t, k) error("cannot set global variable: " .. k, 2) end  })

local tmpdir = os.getenv("TMPDIR") or "/tmp"
local fast = os.getenv("FAST")
local last_command_result, last_command
local userdir = tmpdir .. "/lpmtest"
local function lpm(cmd)
  last_command = "./lpm --quiet --json --userdir=" .. userdir .. " " .. cmd
  local pipe = io.popen(last_command, "r")
  last_command_result = json.decode(pipe:read("*all"))
  local success = pipe:close()
  if not success then error("error calling lpm", 2) end
  return last_command_result
end

local function assert_exists(path)
  if not io.open(path, "rb")  then error("assertion failed: file " .. path .. " does not exist", 2) end
end
local function assert_not_exists(path)
  if io.open(path, "rb") then error("assertion failed: file " .. path .. " exists", 2) end
end

local function run_tests(tests, arg)
  local fail_count = 0
  local names = {}
  if #arg == 0 then
    for k,v in pairs(tests) do table.insert(names, k) end  
  else
    names = arg
  end
  table.sort(names)
  local max_name = 0
  for i,k in ipairs(names) do max_name = math.max(max_name, #k) end  
  for i,k in ipairs(names) do
    local v = tests[k]
    if fast then
      os.execute("rm -rf " .. tmpdir .. "/lpmtest/plugins && mkdir -p " .. tmpdir .. "/lpmtest");
    else
      os.execute("rm -rf " .. tmpdir .. "/lpmtest && mkdir -p " .. tmpdir .. "/lpmtest");
    end
    io.stdout:write(string.format("test %-" .. (max_name + 1) .. "s: ", k))
    local failed = false
    xpcall(v, function(err)
      print("[FAIL]: " .. err)
      print(debug.traceback())
      print()
      print()
      print("Last Command: " .. last_command)
      print(json.encode(last_command_result)) 
      fail_count = fail_count + 1
      failed = true
    end)
    if not failed then
      print("[PASSED]")
    end
  end
  os.exit(fail_count)
end

local tests = {
  ["00_install_singleton"] = function()
    local plugins = lpm("list bracketmatch")["plugins"]
    assert(#plugins == 1)
    assert(plugins[1].organization == "singleton")
    assert(plugins[1].status == "available")
    local actions = lpm("install bracketmatch")["actions"]
    assert(actions[1]:find("Installing singleton"))
    assert_exists(userdir .. "/plugins/bracketmatch.lua")
    actions = lpm("uninstall bracketmatch")["actions"]
    assert_not_exists(userdir .. "/plugins/bracketmatch.lua")
  end,
  ["01_upgrade_singleton"] = function()
    lpm("install bracketmatch")
    local plugins = lpm("list bracketmatch")["plugins"]
    assert(#plugins == 1)
    assert(plugins[1].status == "installed")
    assert_exists(plugins[1].path)
    io.open(plugins[1].path, "ab"):write("-- this is a test comment to modify the checksum"):close()
    plugins = lpm("list bracketmatch")["plugins"]
    assert(#plugins == 2)
    lpm("install bracketmatch")
    plugins = lpm("list bracketmatch")["plugins"]
    assert(#plugins == 1)
  end,
  ["02_install_complex"] = function()
    local plugins = lpm("list plugin_manager")["plugins"]
    assert(#plugins == 1)
    assert(plugins[1].organization == "complex")
    assert(plugins[1].status == "available")
    assert(plugins[1].dependencies.json)
    local actions = lpm("install plugin_manager")["actions"]
    assert_exists(userdir .. "/libraries/json.lua")
    assert_exists(userdir .. "/plugins/plugin_manager")
    assert_exists(userdir .. "/plugins/plugin_manager/init.lua")
    actions = lpm("uninstall plugin_manager")["actions"]
    assert_not_exists(userdir .. "/plugins/plugin_manager")
  end,
  ["03_upgrade_complex"] = function()
    local actions = lpm("install plugin_manager")
    local plugins = lpm("list plugin_manager")["plugins"]
    assert(#plugins == 1)
    assert(plugins[1].organization == "complex")
    assert(plugins[1].status == "installed")
  end,
  ["04_list_plugins"] = function()
    local plugins = lpm("list")["plugins"]
    assert(#plugins > 20)
  end
}


run_tests(tests, arg)
