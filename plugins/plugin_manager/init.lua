-- mod-version:3 --lite-xl 2.1

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local json = require "libraries.json"


local PluginManager = {
  last_refresh = nil,
  requires_restart = false
}
config.plugins.plugin_manager = common.merge({
  lpm_binary_name = "lpm." .. ARCH .. (PLATFORM == "Windows" and ".exe" or ""),
  lpm_binary_path = nil,
  -- Restarts the plugin manager on changes.
  restart_on_change = true,
  -- Path to a local copy of all repositories.
  cachdir = USERDIR  .. PATHSEP .. "lpm",
  -- Path to the folder that holds user-specified plugins.
  userdir = USERDIR,
  -- Path to ssl certificate directory.
  ssl_certs = nil,
  -- Whether or not to force install things.
  force = false,
  -- Dumps commands that run to stdout, as well as responses from lpm.
  debug = true
}, config.plugins.plugin_manager)

if not config.plugins.plugin_manager.lpm_binary_path then
  local paths = { 
    DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "plugin_manager" .. PATHSEP .. config.plugins.plugin_manager.lpm_binary_name,
    DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "plugin_manager" .. PATHSEP .. config.plugins.plugin_manager.lpm_binary_name,
    USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. "plugin_manager" .. PATHSEP .. "lpm",
    USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. "plugin_manager" .. PATHSEP .. "lpm",
  }
  local path, s = os.getenv("PATH"), 1
  while true do
    local _, e = path:find(":", s)
    table.insert(paths, path:sub(s, e and (e-1) or #path) .. PATHSEP .. "lpm")
    if not e then break end
    s = e + 1
  end
  for i, path in ipairs(paths) do
    if system.get_file_info(path) then 
      config.plugins.plugin_manager.lpm_binary_path = path 
      break 
    end
  end
end
if not config.plugins.plugin_manager.lpm_binary_path then error("can't find lpm binary, please supply one with config.plugins.plugin_manager.lpm_binary_path") end

local Promise = { }
function Promise:__index(idx) return rawget(self, idx) or Promise[idx] end
function Promise.new(result) return setmetatable({ result = result, success = nil, _done = { }, _fail = { } }, Promise) end
function Promise:done(done) if self.success == true then done(self.result) else table.insert(self._done, done) end return self end
function Promise:fail(fail) if self.success == false then fail(self.result) else table.insert(self._fail, fail) end return self end
function Promise:resolve(result) self.result = result self.success = true for i,v in ipairs(self._done) do v(result) end return self end
function Promise:reject(result) self.result = result self.success = false for i,v in ipairs(self._fail) do v(result) end return self end
function Promise:forward(promise) self:done(function(data) promise:resolve(data) end) self:fail(function(data) promise:reject(data) end) return self end

local running_processes = {}

local function run(cmd)
  local t = { config.plugins.plugin_manager.lpm, table.unpack(cmd), "--json", "--mod-version", MOD_VERSION }
  if config.plugins.plugin_manager.ssl_certs then table.insert(t, "--ssl_certs") table.insert(t, config.plugins.plugin_manager.ssl_certs) end 
  table.insert(cmd, 1, config.plugins.plugin_manager.lpm_binary_path)
  table.insert(cmd, "--json")
  table.insert(cmd, "--mod-version=" .. MOD_VERSION)
  table.insert(cmd, "--quiet")
  table.insert(cmd, "--userdir=" .. USERDIR)
  table.insert(cmd, "--assume-yes")
  if config.plugins.plugin_manager.force then table.insert(cmd, "--force") end
  local proc = process.start(cmd)
  if config.plugins.plugin_manager.debug then for i, v in ipairs(cmd) do print((i > 1 and " " or "") .. v) end end
  local promise = Promise.new()
  table.insert(running_processes, { proc, promise, "" })
  if #running_processes == 1 then
    core.add_thread(function()
      while #running_processes > 0 do 
        local still_running_processes = {}
        local has_chunk = false
        local i = 1
        while i < #running_processes + 1 do
          local v = running_processes[i]
          local still_running = true
          while true do
            local chunk = v[1]:read_stdout(2048)
            if config.plugins.plugin_manager.debug then print(chunk) end
            if chunk and #chunk == 0 then break end
            if chunk ~= nil then 
              v[3] = v[3] .. chunk 
              has_chunk = true
            else
              still_running = false
              if v[1]:returncode() == 0 then
                v[2]:resolve(v[3])
              else
                local err = v[1]:read_stderr(2048)
                core.error("error running lpm: " .. err)
                v[2]:reject(v[3])
              end
              break
            end
          end
          if still_running then
            table.insert(still_running_processes, v)
          end
          i = i + 1
        end
        running_processes = still_running_processes
        coroutine.yield(has_chunk and 0.001 or 0.1)
      end
    end)
  end
  return promise
end


function PluginManager:refresh()
  return run({ "plugin", "list" }):done(function(plugins)
    self.plugins = json.decode(plugins)["plugins"]
    table.sort(self.plugins, function(a,b) return a.name < b.name end)
    self.valid_plugins = {}
    for i, plugin in ipairs(self.plugins) do
      if plugin.status ~= "incompatible" then
        table.insert(self.valid_plugins, plugin)
      end
    end
    self.last_refresh = os.time()
  end)
end


function PluginManager:get_plugins()
  local prom = Promise.new()
  if self.plugins then 
    prom:resolve(self.plugins) 
  else
    self:refresh():done(function()
      prom:resolve(self.plugins)
    end)
  end
  return prom
end


function PluginManager:install(plugin)
  local promise = Promise.new()
  run({ "plugin", "install", plugin.name .. (plugin.version and (":" .. plugin.version) or "") }):done(function(result)
    if config.plugins.plugin_manager.restart_on_change then
      command.perform("core:restart")
    else
      self:refresh():forward(promise)
    end
  end)
  return promise
end


function PluginManager:uninstall(plugin)
  local promise = Promise.new()
  run({ "plugin", "uninstall", plugin.name }):done(function(result)
    if config.plugins.plugin_manager.restart_on_change then
      command.perform("core:restart")
    else
      self:refresh():forward(promise)
    end
  end)
  return promise
end


local function get_suggestions(text)
  local items = {}
  if not PluginManager.plugins then return end
  for i, plugin in ipairs(PluginManager.plugins) do
    if not plugin.mod_version or tostring(plugin.mod_version) == tostring(MOD_VERSION) then
      table.insert(items, plugin.name .. ":" .. plugin.version)
    end
  end
  return common.fuzzy_match(items, text)
end

command.add(nil, {
  ["plugin-manager:show"] = function()
    local node = core.root_view:get_active_node_default()
    node:add_view(PluginView())
  end,
  ["plugin-manager:install"] = function() 
    core.command_view:enter("Enter plugin name", 
      function(name)  
        core.log("Attempting to install plugin " .. name .. "...")
        PluginManager:install(name, nil):done(function()
          core.log("Successfully installed plugin " .. name .. ".")
        end) 
      end, 
      function(text) return get_suggestions(text) end
    )
  end,
  ["plugin-manager:remove"] = function() 
    core.command_view:enter("Enter plugin name",
      function(name)  
        core.log("Attempting to remove plugin " .. name .. "...")
        PluginManager:uninstall(name):done(function()
          core.log("Successfully removed plugin " .. name .. ".")
        end)
      end, 
      function(text)  return get_suggestions(PluginManager.local_plugins, text) end
    )
  end,
  ["plugin-manager:refresh"] = function() PluginManager:refresh():done(function() core.log("Successfully refreshed plugin listing.") end) end,
})

PluginManager.promise = Promise
PluginManager.initialized = Promise.new()
PluginManager:refresh():done(function()
  PluginManager.initialized:resolve()
end)


return PluginManager
