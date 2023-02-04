-- mod-version:3 --lite-xl 2.1 --priority:5

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local json = require "libraries.json"


local PluginManager = {
  last_refresh = nil,
  requires_restart = false
}
local binary_extension = (PLATFORM == "Windows" and ".exe" or "")
config.plugins.plugin_manager = common.merge({
  lpm_binary_name = "lpm." .. ARCH .. binary_extension,
  lpm_binary_path = nil,
  -- Restarts the plugin manager on changes.
  restart_on_change = true,
  -- Path to a local copy of all repositories.
  cachdir = USERDIR  .. PATHSEP .. "lpm",
  -- Path to the folder that holds user-specified plugins.
  userdir = USERDIR,
  -- Path to ssl certificate directory or bunde. Nil will auto-detect.
  ssl_certs = nil,
  -- Whether or not to force install things.
  force = false,
  -- Dumps commands that run to stdout, as well as responses from lpm.
  debug = false
}, config.plugins.plugin_manager)

package.path = package.path .. ";" .. USERDIR .. "/libraries/?.lua" .. ";" .. USERDIR .. "/libraries/?/init.lua" .. ";" .. DATADIR .. "/libraries/?.lua" .. ";" .. DATADIR .. "/libraries/?/init.lua"

if not config.plugins.plugin_manager.lpm_binary_path then
  local paths = {
    DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "plugin_manager" .. PATHSEP .. config.plugins.plugin_manager.lpm_binary_name,
    USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. "plugin_manager" .. PATHSEP .. config.plugins.plugin_manager.lpm_binary_name,
    DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "plugin_manager" .. PATHSEP .. "lpm" .. binary_extension,
    USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. "plugin_manager" .. PATHSEP .. "lpm" .. binary_extension,
  }
  local path, s = os.getenv("PATH"), 1
  while true do
    local _, e = path:find(":", s)
    table.insert(paths, path:sub(s, e and (e-1) or #path) .. PATHSEP .. "lpm" .. binary_extension)
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

local function join(joiner, t) local s = "" for i,v in ipairs(t) do if i > 1 then s = s .. joiner end s = s .. v end return s end

local running_processes = {}

local function extract_progress(chunk)
  local newline = chunk:find("\n")
  if not newline then return nil, chunk end
  if #chunk == newline then
    if chunk:find("^{\"progress\"") then return chunk, "" end
    return nil, chunk
  end
  return chunk:sub(1, newline - 1), chunk:sub(newline + 1)
end

local function run(cmd, progress)
  table.insert(cmd, 1, config.plugins.plugin_manager.lpm_binary_path)
  table.insert(cmd, "--json")
  table.insert(cmd, "--mod-version=" .. (rawget(_G, "MOD_VERSION") or MOD_VERSION_STRING)) -- #workaround hack for new system.
  table.insert(cmd, "--quiet")
  table.insert(cmd, "--progress")
  table.insert(cmd, "--userdir=" .. USERDIR)
  table.insert(cmd, "--datadir=" .. DATADIR)
  table.insert(cmd, "--binary=" .. EXEFILE)
  table.insert(cmd, "--assume-yes")
  if config.plugins.plugin_manager.ssl_certs then table.insert(cmd, "--ssl_certs") table.insert(cmd, config.plugins.plugin_manager.ssl_certs) end
  if config.plugins.plugin_manager.force then table.insert(cmd, "--force") end
  local proc = process.start(cmd)
  if config.plugins.plugin_manager.debug then for i, v in ipairs(cmd) do io.stdout:write((i > 1 and " " or "") .. v) end io.stdout:write("\n") io.stdout:flush() end
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
            if config.plugins.plugin_manager.debug and chunk ~= nil then io.stdout:write(chunk) io.stdout:flush() end
            if chunk and v[1]:running() and #chunk == 0 then break end
            if chunk ~= nil and #chunk > 0 then
              v[3] = v[3] .. chunk
              local progress_line
              progress_line, v[3] = extract_progress(v[3])
              if progress and progress_line then
                progress_line = json.decode(progress_line)
                progress(progress_line.progress)
              end
              has_chunk = true
            else
              still_running = false
              if v[1]:returncode() == 0 then
                v[2]:resolve(v[3])
              else
                local err = v[1]:read_stderr(2048)
                core.error("error running " .. join(" ", cmd) .. ": " .. (err or "?"))
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
        coroutine.yield(has_chunk and 0.001 or 0.05)
      end
    end)
  end
  return promise
end


function PluginManager:refresh(progress)
  local prom = Promise.new()
  run({ "list" }, progress):done(function(addons)
    self.addons = json.decode(addons)["addons"]
    table.sort(self.addons, function(a,b) return a.id < b.id end)
    self.valid_addons = {}
    for i, addon in ipairs(self.addons) do
      if addon.status ~= "incompatible" then
        table.insert(self.valid_addons, addon)
        if addon.id == "plugin_manager" and addon.status == "installed" then
          addon.status = "special"
        end
      end
    end
    self.last_refresh = os.time()
    prom:resolve(addons)
    run({ "repo", "list" }):done(function(repositories)
      self.repositories = json.decode(repositories)["repositories"]
    end)
  end)
  return prom
end


function PluginManager:upgrade(progress)
  local prom = Promise.new()
  run({ "update" }, progress):done(function()
    run({ "upgrade" }, progress):done(function()
      prom:resolve()
    end)
  end)
  return prom
end


function PluginManager:get_addons()
  local prom = Promise.new()
  if self.addons then
    prom:resolve(self.addons)
  else
    self:refresh():done(function()
      prom:resolve(self.addons)
    end)
  end
  return prom
end

local function run_stateful_plugin_command(plugin_manager, cmd, arg, progress)
  local promise = Promise.new()
  run({ cmd, arg }, progress):done(function(result)
    if config.plugins.plugin_manager.restart_on_change then
      command.perform("core:restart")
    else
      plugin_manager:refresh(progress):forward(promise)
    end
  end)
  return promise
end


function PluginManager:install(addon, progress) return run_stateful_plugin_command(self, "install", addon.id .. (addon.version and (":" .. addon.version) or ""), progress) end
function PluginManager:uninstall(addon, progress) return run_stateful_plugin_command(self, "uninstall", addon.id, progress) end
function PluginManager:reinstall(addon, progress) return run_stateful_plugin_command(self, "reinstall", addon.id, progress) end


function PluginManager:get_addon(name_and_version)
  local promise = Promise.new()
  PluginManager:get_addons():done(function()
    local s = name_and_version:find(":")
    local name, version = name_and_version, nil
    if s then
      name = name_and_version:sub(1, s-1)
      version = name_and_version:sub(s+1)
    end
    local match = false
    for i, addon in ipairs(PluginManager.addons) do
      if not addon.mod_version or tostring(addon.mod_version) == tostring(MOD_VERSION_MAJOR) and (addon.version == version or version == nil) then
        promise:resolve(addon)
        match = true
        break
      end
    end
    if not match then promise:reject() end
  end)
  return promise
end

PluginManager.promise = Promise
PluginManager.view = require "plugins.plugin_manager.plugin_view"

command.add(nil, {
  ["plugin-manager:install"] = function()
    PluginManager:get_addons()
    core.command_view:enter("Enter plugin name",
      function(name)
        PluginManager:get_addon(name):done(function(addon)
          core.log("Attempting to install plugin " .. name .. "...")
          PluginManager:install(addon, PluginManager.view.progress_callback):done(function()
            core.log("Successfully installed plugin " .. addon.id .. ".")
          end)
        end):fail(function()
          core.error("Unknown plugin " .. name .. ".")
        end)
      end,
      function(text)
        local items = {}
        if not PluginManager.addons then return end
        for i, addon in ipairs(PluginManager.addons) do
          if not addon.mod_version or tostring(addon.mod_version) == tostring(MOD_VERSION) and addon.status == "available" then
            table.insert(items, addon.id .. ":" .. addon.version)
          end
        end
        return common.fuzzy_match(items, text)
      end
    )
  end,
  ["plugin-manager:uninstall"] = function()
    PluginManager:get_addons()
    core.command_view:enter("Enter plugin name",
      function(name)
        PluginManager:get_addon(name):done(function(addon)
          core.log("Attempting to uninstall plugin " .. addon.id .. "...")
          PluginManager:uninstall(addon, PluginManager.view.progress_callback):done(function()
            core.log("Successfully uninstalled plugin " .. addon.id .. ".")
          end)
        end):fail(function()
          core.error("Unknown plugin " .. name .. ".")
        end)
      end,
      function(text)
        local items = {}
        if not PluginManager.addons then return end
        for i, addon in ipairs(PluginManager.addons) do
          if addon.status == "installed" then
            table.insert(items, addon.id .. ":" .. addon.version)
          end
        end
        return common.fuzzy_match(items, text)
      end
    )
  end,
  ["plugin-manager:add-repository"] = function()
    core.command_view:enter("Enter repository url",
      function(url)
        PluginManager:add(url):done(function()
          core.log("Successfully added repository " .. url .. ".")
        end)
      end
    )
  end,
  ["plugin-manager:remove-repository"] = function()
    PluginManager:get_plugins()
    core.command_view:enter("Enter repository url",
      function(url)
        PluginManager:remove(url):done(function()
          core.log("Successfully removed repository " .. url .. ".")
        end)
      end,
      function(text)
        local items = {}
        if PluginManager.repositories then
          for i,v in ipairs(PluginManager.repositories) do
            table.insert(items, v.remote .. ":" .. (v.commit or v.branch))
          end
        end
        return common.fuzzy_match(items, text)
      end
    )
  end,
  ["plugin-manager:refresh"] = function() PluginManager:refresh(PluginManager.view.progress_callback):done(function() core.log("Successfully refreshed plugin listing.") end) end,
  ["plugin-manager:upgrade"] = function() PluginManager:upgrade(PluginManager.view.progress_callback):done(function() core.log("Successfully upgraded installed plugins.") end) end,
  ["plugin-manager:show"] = function()
    local node = core.root_view:get_active_node_default()
    node:add_view(PluginManager.view(PluginManager))
  end
})

return PluginManager
