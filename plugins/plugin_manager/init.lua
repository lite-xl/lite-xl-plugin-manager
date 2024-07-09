-- mod-version:4 --lite-xl 3.0 --priority:5

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local json = require "libraries.json"
local keymap = require "core.keymap"


local PluginManager = {
  last_refresh = nil,
  requires_restart = false
}
local binary_extension = (PLATFORM == "Windows" and ".exe" or (PLATFORM == "Android" and ".so" or ""))
config.plugins.plugin_manager = common.merge({
  lpm_binary_name = "lpm." .. ARCH .. binary_extension,
  lpm_binary_path = nil,
  show_libraries = false,
  -- Restarts the plugin manager on changes.
  restart_on_change = true,
  -- Path to a local copy of all repositories.
  cachdir = nil,
  -- Path to the folder that holds user-specified plugins.
  userdir = USERDIR,
  -- Path to ssl certificate directory or bunde. Nil will auto-detect.
  ssl_certs = nil,
  -- Whether or not to force install things.
  force = false,
  -- Dumps commands that run to stdout, as well as responses from lpm.
  debug = false,
  -- A list of addons to apply to the system bottle.
  addons = nil
}, config.plugins.plugin_manager)

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
    table.insert(paths, path:sub(s, e and (e-1) or #path) .. PATHSEP .. config.plugins.plugin_manager.lpm_binary_name)
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
local default_arguments = {
  "--mod-version=" .. (rawget(_G, "MOD_VERSION") or MOD_VERSION_STRING), -- #workaround hack for new system.
  "--datadir=" .. DATADIR,
  "--binary=" .. EXEFILE,
  "--assume-yes"
}
if config.plugins.plugin_manager.ssl_certs then table.insert(default_arguments, "--ssl_certs") table.insert(cmd, config.plugins.plugin_manager.ssl_certs) end
if config.plugins.plugin_manager.force then table.insert(default_arguments, "--force") end

local function extract_progress(chunk)
  local newline = chunk:find("\n")
  if not newline then return nil, chunk end
  if #chunk == newline then
    if chunk:find("^{\"progress\"") then return chunk, "" end
    return nil, chunk
  end
  return chunk:sub(1, newline - 1), chunk:sub(newline + 1)
end

local function run(cmd, options)
  options = options or {}
  table.insert(cmd, 1, config.plugins.plugin_manager.lpm_binary_path)
  table.insert(cmd, "--json")
  table.insert(cmd, "--quiet")
  table.insert(cmd, "--progress")
  if options.cachedir then table.insert(cmd, "--cachedir=" .. options.cachedir) end
  table.insert(cmd, "--userdir=" .. (options.userdir or USERDIR))
  for i,v in ipairs(default_arguments) do table.insert(cmd, v) end
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
          local progress_line
          while true do
            local chunk = v[1]:read_stdout(2048)
            if config.plugins.plugin_manager.debug and chunk ~= nil then io.stdout:write(chunk) io.stdout:flush() end
            if chunk and #chunk == 0 then break end
            if chunk ~= nil and #chunk > 0 then
              v[3] = v[3] .. chunk
              progress_line, v[3] = extract_progress(v[3])
              if options.progress and progress_line then
                progress_line = json.decode(progress_line)
                options.progress(progress_line.progress)
              end
              has_chunk = true
            else
              still_running = false
              if v[1]:returncode() == 0 then
                progress_line, v[3] = extract_progress(v[3])
                v[2]:resolve(v[3])
              else
                local err = v[1]:read_stderr(2048)
                core.error("error running " .. join(" ", cmd) .. ": " .. (err or "?"))
                progress_line, v[3] = extract_progress(v[3])
                if err then
                  v[2]:reject(json.decode(err).error)
                else
                  v[2]:reject(err)
                end
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


function PluginManager:refresh(options)
  local prom = Promise.new()
  local cmd = { "list" }
  if not config.plugins.plugin_manager.show_libraries then
    table.insert(cmd, "--type")
    table.insert(cmd, "!library")
  end
  run(cmd, options):done(function(addons)
    self.addons = json.decode(addons)["addons"]
    table.sort(self.addons, function(a,b) return a.id < b.id end)
    self.valid_addons = {}
    for i, addon in ipairs(self.addons) do
      if addon.status ~= "incompatible" then
        table.insert(self.valid_addons, addon)
        if (addon.id == "plugin_manager" or addon.id == "json") and (addon.status == "installed" or addon.status == "orphan") then
          addon.status = "special"
        end
      end
    end
    self.last_refresh = os.time()
    core.redraw = true
    prom:resolve(addons)
    run({ "repo", "list" }, options):done(function(repositories)
      self.repositories = json.decode(repositories)["repositories"]
    end)
  end)
  return prom
end


function PluginManager:upgrade(options)
  local prom = Promise.new()
  run({ "update" }, options):done(function()
    run({ "upgrade" }, options):done(function()
      prom:resolve()
    end)
  end)
  return prom
end



function PluginManager:purge(options)
  return run({ "purge" }, options)
end


function PluginManager:get_addons(options)
  local prom = Promise.new()
  if self.addons then
    prom:resolve(self.addons)
  else
    self:refresh(options):done(function()
      prom:resolve(self.addons)
    end):fail(function(arg) promise:reject(arg) end)
  end
  return prom
end

local function run_stateful_plugin_command(plugin_manager, cmd, args, options)
  local promise = Promise.new()
  run({ cmd, table.unpack(args) }, options):done(function(result)
    if (options.restart == nil and config.plugins.plugin_manager.restart_on_change) or options.restart then
      command.perform("core:restart")
    else
      plugin_manager:refresh(options):forward(promise)
    end
  end):fail(function(arg)
    promise:reject(arg)
  end)
  return promise
end


function PluginManager:install(addon, options) return run_stateful_plugin_command(self, "install", { addon.id .. (addon.version and (":" .. addon.version) or "") }, options) end
function PluginManager:reinstall(addon, options) return run_stateful_plugin_command(self, "install", { addon.id .. (addon.version and (":" .. addon.version) or ""), "--reinstall" }, options) end
function PluginManager:uninstall(addon, options) return run_stateful_plugin_command(self, "uninstall", { addon.id }, options) end
function PluginManager:unstub(addon, options)
  local promise = Promise.new()
  if addon.path and system.get_file_info(addon.path) then
    promise:resolve(addon)
  else
    run({ "unstub", addon.id }, options):done(function(result)
      local unstubbed_addon = json.decode(result).addons[1]
      for k,v in pairs(unstubbed_addon) do addon[k] = v end
      promise:resolve(addon)
    end):fail(function(arg) promise:reject(arg) end)
  end
  return promise
end


function PluginManager:get_addon(name_and_version, options)
  local promise = Promise.new()
  PluginManager:get_addons(options):done(function()
    local s = name_and_version:find(":")
    local name, version = name_and_version, nil
    if s then
      name = name_and_version:sub(1, s-1)
      version = name_and_version:sub(s+1)
    end
    local match = false
    for i, addon in ipairs(PluginManager.addons) do
      if not addon.mod_version or tostring(addon.mod_version) == tostring(rawget(_G, "MOD_VERSION_MAJOR") or rawget(_G, "MOD_VERSION")) and (addon.version == version or version == nil) then
        promise:resolve(addon)
        match = true
        break
      end
    end
    if not match then promise:reject() end
  end):fail(function(arg) promise:reject(arg) end)
  return promise
end

PluginManager.promise = Promise
PluginManager.view = require "plugins.plugin_manager.plugin_view"

-- This will be significantly simplified when the plugin loading monolith is broken up a bit.
if config.plugins.plugin_manager.addons then
  local target_plugin_directory = config.plugins.plugin_manger.adddon_directory or (USERDIR .. PATHSEP .. "projects" .. PATHSEP .. common.basename(system.absolute_path(".")))

  local mod_version_regex =
    regex.compile([[--.*mod-version:(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:$|\s)]])
  local function get_plugin_details(filename)
    local info = system.get_file_info(filename)
    if info ~= nil and info.type == "dir" then
      filename = filename .. PATHSEP .. "init.lua"
      info = system.get_file_info(filename)
    end
    if not info or not filename:match("%.lua$") then return false end
    local f = io.open(filename, "r")
    if not f then return false end
    local priority = false
    local version_match = false
    local major, minor, patch

    for line in f:lines() do
      if not version_match then
        local _major, _minor, _patch = mod_version_regex:match(line)
        if _major then
          _major = tonumber(_major) or 0
          _minor = tonumber(_minor) or 0
          _patch = tonumber(_patch) or 0
          major, minor, patch = _major, _minor, _patch

          version_match = major == MOD_VERSION_MAJOR
          if version_match then
            version_match = minor <= MOD_VERSION_MINOR
          end
          if version_match then
            version_match = patch <= MOD_VERSION_PATCH
          end
        end
      end

      if not priority then
        priority = line:match('%-%-.*%f[%a]priority%s*:%s*(%d+)')
        if priority then priority = tonumber(priority) end
      end

      if version_match then
        break
      end
    end
    f:close()
    return true, {
      version_match = version_match,
      version = major and {major, minor, patch} or {},
      priority = priority or 100
    }
  end

  local function replace_string(str, text, replace)
    local offset = 1
    local result = ""
    while true do
      local s,e = str:find(text, offset, true)
      if s then
        result = result .. str:sub(offset, s - 1) .. replace
        offset = e + 1
      else
        result = result .. str:sub(offset)
        break
      end
    end
    return result
  end

  local function lpm_load_plugins()
    package.cpath = replace_string(package.cpath, USERDIR, target_plugin_directory)
    package.path = replace_string(package.path, USERDIR, target_plugin_directory)

    local no_errors = true
    local refused_list = {
      userdir = {dir = target_plugin_directory, plugins = {}}
    }
    local files, ordered = {}, {}
    for _, root_dir in ipairs {target_plugin_directory} do
      local plugin_dir = root_dir .. PATHSEP .. "plugins"
      for _, filename in ipairs(system.list_dir(plugin_dir) or {}) do
        if not files[filename] then
          table.insert(
            ordered, {file = filename}
          )
        end
        -- user plugins will always replace system plugins
        files[filename] = plugin_dir
      end
    end

    for _, plugin in ipairs(ordered) do
      local dir = files[plugin.file]
      local name = plugin.file:match("(.-)%.lua$") or plugin.file
      local is_lua_file, details = get_plugin_details(dir .. PATHSEP .. plugin.file)

      plugin.valid = is_lua_file
      plugin.name = name
      plugin.dir = dir
      plugin.priority = details and details.priority or 100
      plugin.version_match = details and details.version_match or false
      plugin.version = details and details.version or {}
      plugin.version_string = #plugin.version > 0 and table.concat(plugin.version, ".") or "unknown"
    end

    -- sort by priority or name for plugins that have same priority
    table.sort(ordered, function(a, b)
      if a.priority ~= b.priority then
        return a.priority < b.priority
      end
      return a.name < b.name
    end)

    local load_start = system.get_time()
    for _, plugin in ipairs(ordered) do
      if plugin.valid then
        if not config.skip_plugins_version and not plugin.version_match then
          core.log_quiet(
            "Version mismatch for plugin %q[%s] from %s",
            plugin.name,
            plugin.version_string,
            plugin.dir
          )
          local rlist = plugin.dir:find(USERDIR, 1, true) == 1
            and 'userdir' or 'datadir'
          local list = refused_list[rlist].plugins
          table.insert(list, plugin)
        elseif config.plugins[plugin.name] ~= false then
          local start = system.get_time()
          local ok, loaded_plugin = core.try(require, "plugins." .. plugin.name)
          if ok then
            local plugin_version = ""
            if plugin.version_string ~= MOD_VERSION_STRING then
              plugin_version = "["..plugin.version_string.."]"
            end
            core.log_quiet(
              "Loaded plugin %q%s from %s in %.1fms",
              plugin.name,
              plugin_version,
              plugin.dir,
              (system.get_time() - start) * 1000
            )
          end
          if not ok then
            no_errors = false
          elseif config.plugins[plugin.name].onload then
            core.try(config.plugins[plugin.name].onload, loaded_plugin)
          end
        end
      end
    end
    core.log_quiet(
      "Loaded all managed plugins in %.1fms",
      (system.get_time() - load_start) * 1000
    )
    return no_errors, refused_list
  end

  local addons = {}
  local added_addons = {}
  for i,v in ipairs(config.plugins.plugin_manager.addons) do
    if type(v) == 'table' then
      local string = ""
      if v.remote then
        string = v.remote
        if v.commit or v.branch then
          string = string .. ":" .. (v.commit or v.branch)
        end
        string = string .. "@"
      end
      if not v.id then error("requires config.plugin_manager.addons entries to have an id") end
      string = string .. v.id
      if v.version then string = string .. ":" .. v.version end
      table.insert(addons, string)
      added_addons[v.id] = true
    else
      table.insert(addons, v)
      added_addons[v] = true
    end
  end
  local plugins = system.list_dir(USERDIR .. PATHSEP .. "plugins")
  run({ "apply", table.unpack(addons), }, { userdir = target_plugin_directory }):done(function(status)
    if json.decode(status)["changed"] then command.perform("core:restart") end 
  end)
  lpm_load_plugins()
  local old_configs = {}
  for i,v in ipairs(plugins or {}) do
    local id = v:gsub("%.lua$", "")
    if config.plugins[id] ~= false and id ~= "plugin_manager" and not added_addons[id] then
      old_configs[id] = config.plugins[id]
      config.plugins[id] = false
    end
  end
end


command.add(nil, {
  ["plugin-manager:install"] = function()
    PluginManager:get_addons({ progress = PluginManager.view.progress_callback })
    core.command_view:enter("Enter plugin name",
      function(name)
        PluginManager:get_addon(name, { progress = PluginManager.view.progress_callback }):done(function(addon)
          core.log("Attempting to install plugin " .. name .. "...")
          PluginManager:install(addon, { progress = PluginManager.view.progress_callback }):done(function()
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
    PluginManager:get_addons({ progress = PluginManager.view.progress_callback })
    core.command_view:enter("Enter plugin name",
      function(name)
        PluginManager:get_addon(name, { progress = PluginManager.view.progress_callback }):done(function(addon)
          core.log("Attempting to uninstall plugin " .. addon.id .. "...")
          PluginManager:uninstall(addon, { progress = PluginManager.view.progress_callback }):done(function()
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
    PluginManager:get_addons({ progress = PluginManager.view.progress_callback })
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
  ["plugin-manager:refresh"] = function() PluginManager:refresh({ progress = PluginManager.view.progress_callback }):done(function() core.log("Successfully refreshed plugin listing.") end) end,
  ["plugin-manager:upgrade"] = function() PluginManager:upgrade({ progress = PluginManager.view.progress_callback }):done(function() core.log("Successfully upgraded installed plugins.") end) end,
  ["plugin-manager:purge"] = function() PluginManager:purge({ progress = PluginManager.view.progress_callback }):done(function() core.log("Successfully purged lpm directory.") end) end,
  ["plugin-manager:show"] = function()
    local node = core.root_view:get_active_node_default()
    node:add_view(PluginManager.view(PluginManager))
  end,
})

if pcall(require, "plugins.terminal") then
  local terminal = require "plugins.terminal"
  command.add(nil, {
    ["plugin-manager:open-session"] = function()
      local arguments = { "-", "--userdir=" .. USERDIR }
      for i,v in ipairs(default_arguments) do table.insert(arguments, v) end
      local tv = terminal.class(common.merge(config.plugins.terminal, {
        shell = config.plugins.plugin_manager.lpm_binary_path,
        arguments = arguments
      }))
      core.root_view:get_active_node_default():add_view(tv)
    end
  })
end

return PluginManager
