setmetatable(_G, { __newindex = function(t, k) error("cannot set global variable: " .. k, 2) end  })

-- Begin rxi JSON library.
local json = { _version = "0.1.2" }
local encode
local escape_char_map = {
  [ "\\" ] = "\\",
  [ "\"" ] = "\"",
  [ "\b" ] = "b",
  [ "\f" ] = "f",
  [ "\n" ] = "n",
  [ "\r" ] = "r",
  [ "\t" ] = "t",
}

local escape_char_map_inv = { [ "/" ] = "/" }
for k, v in pairs(escape_char_map) do
  escape_char_map_inv[v] = k
end


local function escape_char(c)
  return "\\" .. (escape_char_map[c] or string.format("u%04x", c:byte()))
end


local function encode_nil(val)
  return "null"
end


local function encode_table(val, stack)
  local res = {}
  stack = stack or {}

  -- Circular reference?
  if stack[val] then error("circular reference") end

  stack[val] = true

  if rawget(val, 1) ~= nil or next(val) == nil then
    -- Treat as array -- check keys are valid and it is not sparse
    local n = 0
    for k in pairs(val) do
      if type(k) ~= "number" then
        error("invalid table: mixed or invalid key types")
      end
      n = n + 1
    end
    if n ~= #val then
      error("invalid table: sparse array")
    end
    -- Encode
    for i, v in ipairs(val) do
      table.insert(res, encode(v, stack))
    end
    stack[val] = nil
    return "[" .. table.concat(res, ",") .. "]"

  else
    -- Treat as an object
    for k, v in pairs(val) do
      if type(k) ~= "string" then
        error("invalid table: mixed or invalid key types")
      end
      table.insert(res, encode(k, stack) .. ":" .. encode(v, stack))
    end
    stack[val] = nil
    return "{" .. table.concat(res, ",") .. "}"
  end
end


local function encode_string(val)
  return '"' .. val:gsub('[%z\1-\31\\"]', escape_char) .. '"'
end


local function encode_number(val)
  -- Check for NaN, -inf and inf
  if val ~= val or val <= -math.huge or val >= math.huge then
    error("unexpected number value '" .. tostring(val) .. "'")
  end
  return string.format("%.14g", val)
end


local type_func_map = {
  [ "nil"     ] = encode_nil,
  [ "table"   ] = encode_table,
  [ "string"  ] = encode_string,
  [ "number"  ] = encode_number,
  [ "boolean" ] = tostring,
}


encode = function(val, stack)
  local t = type(val)
  local f = type_func_map[t]
  if f then
    return f(val, stack)
  end
  error("unexpected type '" .. t .. "'")
end


function json.encode(val)
  return ( encode(val) )
end

local parse

local function create_set(...)
  local res = {}
  for i = 1, select("#", ...) do
    res[ select(i, ...) ] = true
  end
  return res
end

local space_chars   = create_set(" ", "\t", "\r", "\n")
local delim_chars   = create_set(" ", "\t", "\r", "\n", "]", "}", ",")
local escape_chars  = create_set("\\", "/", '"', "b", "f", "n", "r", "t", "u")
local literals      = create_set("true", "false", "null")

local literal_map = {
  [ "true"  ] = true,
  [ "false" ] = false,
  [ "null"  ] = nil,
}


local function next_char(str, idx, set, negate)
  for i = idx, #str do
    if set[str:sub(i, i)] ~= negate then
      return i
    end
  end
  return #str + 1
end


local function decode_error(str, idx, msg)
  local line_count = 1
  local col_count = 1
  for i = 1, idx - 1 do
    col_count = col_count + 1
    if str:sub(i, i) == "\n" then
      line_count = line_count + 1
      col_count = 1
    end
  end
  error( string.format("%s at line %d col %d", msg, line_count, col_count) )
end


local function codepoint_to_utf8(n)
  -- http://scripts.sil.org/cms/scripts/page.php?site_id=nrsi&id=iws-appendixa
  local f = math.floor
  if n <= 0x7f then
    return string.char(n)
  elseif n <= 0x7ff then
    return string.char(f(n / 64) + 192, n % 64 + 128)
  elseif n <= 0xffff then
    return string.char(f(n / 4096) + 224, f(n % 4096 / 64) + 128, n % 64 + 128)
  elseif n <= 0x10ffff then
    return string.char(f(n / 262144) + 240, f(n % 262144 / 4096) + 128,
                       f(n % 4096 / 64) + 128, n % 64 + 128)
  end
  error( string.format("invalid unicode codepoint '%x'", n) )
end


local function parse_unicode_escape(s)
  local n1 = tonumber( s:sub(1, 4),  16 )
  local n2 = tonumber( s:sub(7, 10), 16 )
   -- Surrogate pair?
  if n2 then
    return codepoint_to_utf8((n1 - 0xd800) * 0x400 + (n2 - 0xdc00) + 0x10000)
  else
    return codepoint_to_utf8(n1)
  end
end


local function parse_string(str, i)
  local res = ""
  local j = i + 1
  local k = j

  while j <= #str do
    local x = str:byte(j)

    if x < 32 then
      decode_error(str, j, "control character in string")

    elseif x == 92 then -- `\`: Escape
      res = res .. str:sub(k, j - 1)
      j = j + 1
      local c = str:sub(j, j)
      if c == "u" then
        local hex = str:match("^[dD][89aAbB]%x%x\\u%x%x%x%x", j + 1)
                 or str:match("^%x%x%x%x", j + 1)
                 or decode_error(str, j - 1, "invalid unicode escape in string")
        res = res .. parse_unicode_escape(hex)
        j = j + #hex
      else
        if not escape_chars[c] then
          decode_error(str, j - 1, "invalid escape char '" .. c .. "' in string")
        end
        res = res .. escape_char_map_inv[c]
      end
      k = j + 1

    elseif x == 34 then -- `"`: End of string
      res = res .. str:sub(k, j - 1)
      return res, j + 1
    end

    j = j + 1
  end

  decode_error(str, i, "expected closing quote for string")
end


local function parse_number(str, i)
  local x = next_char(str, i, delim_chars)
  local s = str:sub(i, x - 1)
  local n = tonumber(s)
  if not n then
    decode_error(str, i, "invalid number '" .. s .. "'")
  end
  return n, x
end


local function parse_literal(str, i)
  local x = next_char(str, i, delim_chars)
  local word = str:sub(i, x - 1)
  if not literals[word] then
    decode_error(str, i, "invalid literal '" .. word .. "'")
  end
  return literal_map[word], x
end


local function parse_array(str, i)
  local res = {}
  local n = 1
  i = i + 1
  while 1 do
    local x
    i = next_char(str, i, space_chars, true)
    -- Empty / end of array?
    if str:sub(i, i) == "]" then
      i = i + 1
      break
    end
    -- Read token
    x, i = parse(str, i)
    res[n] = x
    n = n + 1
    -- Next token
    i = next_char(str, i, space_chars, true)
    local chr = str:sub(i, i)
    i = i + 1
    if chr == "]" then break end
    if chr ~= "," then decode_error(str, i, "expected ']' or ','") end
  end
  return res, i
end


local function parse_object(str, i)
  local res = {}
  i = i + 1
  while 1 do
    local key, val
    i = next_char(str, i, space_chars, true)
    -- Empty / end of object?
    if str:sub(i, i) == "}" then
      i = i + 1
      break
    end
    -- Read key
    if str:sub(i, i) ~= '"' then
      decode_error(str, i, "expected string for key")
    end
    key, i = parse(str, i)
    -- Read ':' delimiter
    i = next_char(str, i, space_chars, true)
    if str:sub(i, i) ~= ":" then
      decode_error(str, i, "expected ':' after key")
    end
    i = next_char(str, i + 1, space_chars, true)
    -- Read value
    val, i = parse(str, i)
    -- Set
    res[key] = val
    -- Next token
    i = next_char(str, i, space_chars, true)
    local chr = str:sub(i, i)
    i = i + 1
    if chr == "}" then break end
    if chr ~= "," then decode_error(str, i, "expected '}' or ','") end
  end
  return res, i
end


local char_func_map = {
  [ '"' ] = parse_string,
  [ "0" ] = parse_number,
  [ "1" ] = parse_number,
  [ "2" ] = parse_number,
  [ "3" ] = parse_number,
  [ "4" ] = parse_number,
  [ "5" ] = parse_number,
  [ "6" ] = parse_number,
  [ "7" ] = parse_number,
  [ "8" ] = parse_number,
  [ "9" ] = parse_number,
  [ "-" ] = parse_number,
  [ "t" ] = parse_literal,
  [ "f" ] = parse_literal,
  [ "n" ] = parse_literal,
  [ "[" ] = parse_array,
  [ "{" ] = parse_object,
}


parse = function(str, idx)
  local chr = str:sub(idx, idx)
  local f = char_func_map[chr]
  if f then
    return f(str, idx)
  end
  decode_error(str, idx, "unexpected character '" .. chr .. "'")
end


function json.decode(str)
  if type(str) ~= "string" then
    error("expected argument of type string, got " .. type(str))
  end
  local res, idx = parse(str, next_char(str, 1, space_chars, true))
  idx = next_char(str, idx, space_chars, true)
  if idx <= #str then
    decode_error(str, idx, "trailing garbage")
  end
  return res
end

-- End JSON library.

local common = {}

function common.rmrf(root)
  if not root or root == "" then return end
  local info = system.stat(root)
  if not info then return end
  if info.type == "file" then return os.remove(root) end
  for i,v in ipairs(system.ls(root)) do common.rmrf(root .. PATHSEP .. v) end
  system.rmdir(root)
end

function common.mkdirp(path)
  local stat = system.stat(path)
  if stat and stat.type == "dir" then return true end
  if stat and stat.type == "file" then error("path " .. path .. " exists") end
  local subdirs = {}
  while path and path ~= "" do
    system.mkdir(path)
    local updir, basedir = path:match("(.*)[/\\](.+)$")
    table.insert(subdirs, 1, basedir or path)
    path = updir
  end
  for _, dirname in ipairs(subdirs) do
    path = path and path .. PATHSEP .. dirname or dirname
    system.mkdir(path)
  end
end


function common.basename(path)
  local s = path:reverse():find(PATHSEP)
  if not s then return path end
  return path:sub(#path - s + 2)
end


function common.merge(src, merge)
  for k, v in pairs(merge) do src[k] = v end
  return src
end


function common.map(list, predicate)
  local t = {}
  for i, v in ipairs(list) do table.insert(t, predicate(v)) end
  return t
end


function common.grep(list, predicate)
  local t = {}
  for i, v in ipairs(list) do if predicate(v) then table.insert(t, v) end end
  return t
end


function common.join(list, joiner)
  local s = ""
  for i, v in ipairs(list) do if i > 1 then s = s .. joiner .. v else s = v end end
  return s
end


function common.copy(src, dst)
  local src_stat, dst_stat = system.stat(src), system.stat(dst)
  if not src_stat then error("can't find " .. src) end
  if dst_stat and dst_stat.type == "dir" and src_stat.type == "file" then return common.copy(src, dst .. PATHSEP .. common.basename(src)) end
  local src_io, dst_io = io.open(src, "rb"), io.open(dst, "wb")
  while true do
    local chunk = src_io:read(16*1024)
    if not chunk then break end
    dst_io:write(chunk)
  end
  dst_io:flush()
end

local HOME, USERDIR, CACHEDIR, JSON, VERBOSE, LITE_VERSION, MOD_VERSION, QUIET, repositories

local actions = {}
local function log_action(message)
  if JSON then table.insert(actions, message) end
  if not QUIET then io.stderr:write(message .. "\n") end
end


local function match_version(version, pattern)
  return not pattern or version == pattern
end

local function compare_version(a, b)
  return a and b and tonumber(a) < tonumber(b)
end


local Plugin = {}
function Plugin.__index(self, idx) return rawget(self, idx) or Plugin[idx] end
function Plugin.new(repository, metadata)
  local self = setmetatable(common.merge({
    repository = repository,
    tags = {},
    remote = nil,
    path = nil,
    status = "available",
    version = "1.0",
    dependencies = {},
    local_path = repository.local_path .. PATHSEP .. (repository.commit or repository.branch) .. PATHSEP .. (metadata.path:gsub("^/", "") or metadata.name),
    install_path = USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. (metadata.path and common.basename(metadata.path) or metadata.name),
  }, metadata), Plugin)
  -- Directory.
  local stat = system.stat(self.install_path)
  if stat and (not metadata.lite_version or metadata.lite_version == LITE_VERSION) and (not metadata.mod_version or tonumber(metadata.mod_version) == tonumber(MOD_VERSION)) then
    self.status = "installed"
    self.type = stat.type == "dir" and "complex" or "singleton"
  end
  return self
end

function Plugin:is_installed()
  return self.status == "installed" or self.status == "upgradable"
end

function Plugin:is_incompatible(plugin)
  if dependencies[plugin.name] then
    if not match_version(plugin.version, dependencies[plugin.name]) then return true end
  end
  return false
end

function Plugin:get_compatibilities()
  local compatible_plugins = {}
  local incompatible_plugins = {}
  local installed_plugins = {}
  for i, repo in ipairs(repositories) do
    for j, plugin in ipairs(repo.plugins) do
      if plugin:is_installed() then
        table.insert(installed_plugins, plugin)
      end
    end
  end
  for plugin, version in pairs(self.dependencies) do
    local potential_plugins = get_plugin(plugin, version, { mod_version = MODVERSION, lite_version = LITE_VERSION })
    local has_at_least_one = false
    local incomaptibilities = {}
    for i, potential_plugin in ipairs(potential_plugins) do
      for j, installed_plugin in ipairs(installed_plugins) do
        if installed_plugin:is_incompatible(potential_plugin) then
          table.insert(incomaptibilities, installed_plugin)
        end
      end
      if #incomaptibilities == 0 then
        if not compatible_plugins[plugin] or
          potential_plugin:is_installed() or
          (compare_version(compatible_plugins[plugin].version, potential_plugin.version) and not compatible_plugins[plugin]:is_installed())
        then
          compatible_plugins[plugin] = potential_plugin
        end
      else
        incompatible_plugins[plugin] = incompatibilities
      end
    end
  end
  return compatible_plugins, incompatible_plugins
end


local core_plugins = {
  autocomplete = true, autoreload = true, contextmenu = true, detectindent = true, drawwhitespace = true, language_c = true, language_cpp = true, language_css = true, language_html = true, language_js = true, language_lua = true, language_md = true, language_python = true, language_xml = true, lineguide = true, linewrapping = true, macro = true, projectsearch = true, quote = true, reflow = true, scale = true, tabularize = true, toolbarview = true, treeview = true, trimwhitespace = true, workspace = true
}

function Plugin:install(installing)
  installing = installing or {}
  installing[self.name] = true
  if self.status == "installed" then error("plugin " .. self.name .. " is already installed") end
  local compatible, incompatible = self:get_compatibilities()
  for plugin, version in pairs(self.dependencies) do
    if incompatible[plugin] then error("can't install " .. self.name .. ": incompatible with " .. incompatible[plugin][1].name .. ":" .. incompatible[plugin][1].version) end
  end
  for plugin, version in pairs(self.dependencies) do
    if not core_plugins[plugin] and not compatible[plugin] then error("can't find dependency " .. plugin .. ":" .. version) end
  end
  for plugin, version in pairs(self.dependencies) do
    if not core_plugins[plugin] and not compatible[plugin]:is_installed() then
      if installing[plugin] then
        error("circular dependency detected in " .. self.name .. ": requires " .. plugin .. " but, " .. plugin .. " requires " .. self.name)
      end
      compatible[plugin]:install(installing)
    end
  end
  if self.status == "upgradable" then 
    log_action("Upgrading plugin located at " .. self.local_path .. " to " .. self.install_path)
    common.rmrf(self.install_path) 
    common.copy(self.local_path, self.install_path)
  else
    log_action("Installing plugin located at " .. self.local_path .. " to " .. self.install_path)
    common.copy(self.local_path, self.install_path)
  end
end


function Plugin:uninstall()
  log_action("Uninstalling plugin located at " .. self.install_path)
  common.rmrf(self.install_path)
end


local Repository = {}
function Repository.__index(self, idx) return rawget(self, idx) or Repository[idx] end
function Repository.new(hash)
  if not hash.remote then error("requires a remote") end
  local self = setmetatable({ 
    commit = hash.commit,
    remote = hash.remote,
    branch = hash.branch,
    plugins = nil,
    local_path = CACHEDIR .. PATHSEP .. system.hash(hash.remote),
    last_retrieval = nil 
  }, Repository)
  if system.stat(self.local_path) and not self.commit and not self.branch then
    -- In the case where we don't have a branch, and don't have a commit, check for the presence of `master` and `main`.
    if system.stat(self.local_path .. PATHSEP .. "master") then
      self.branch = "master"
    elseif system.stat(self.local_path .. PATHSEP .. PATHSEP .. "main") then
      self.branch = "main"
    else
      error("can't find branch for " .. self.remote)
    end
  end
  self:parse_manifest()
  return self
end


function Repository:parse_manifest()
  if self.manifest then return self.manifest end
  if system.stat(self.local_path) and system.stat(self.local_path .. PATHSEP .. (self.commit or self.branch)) then
    self.manifest_path = self.local_path .. PATHSEP .. (self.commit or self.branch) .. PATHSEP .. "manifest.json"
    if not system.stat(self.manifest_path) then self:generate_manifest() end
    self.manifest = json.decode(io.open(self.manifest_path, "rb"):read("*all")) 
    self.plugins = {}
    for i, metadata in ipairs(self.manifest["plugins"]) do
      table.insert(self.plugins, Plugin.new(self, metadata))
    end
  end
  return self.manifest
end


-- in the cases where we don't have a manifest, assume generalized structure, take plugins folder, trawl through it, build manifest that way
-- assuming each .lua file under the `plugins` folder is a plugin.
function Repository:generate_manifest()
  if not self.commit and not self.branch then error("requires an instantiation") end
  local path = self.local_path .. PATHSEP .. (self.commit or self.branch)
  local plugin_dir = system.stat(path .. PATHSEP .. "plugins") and PATHSEP .. "plugins" .. PATHSEP or PATHSEP
  local plugins = {}
  for i, file in ipairs(system.ls(path .. plugin_dir)) do
    if file:find("%.lua$") then
      local plugin = { description = nil, name = common.basename(file):gsub("%.lua$", ""), dependencies = {}, mod_version = 3, version = "1.0", tags = {}, path = plugin_dir .. file  }
      for line in io.lines(path .. plugin_dir .. file) do
        local _, _, mod_version = line:find("%-%-.*mod%-version:%s*(%w+)")
        if mod_version then plugin.mod_version = mod_version end
        local _, _, lite_version = line:find("%-%-.*lite%-xl%s*:?%s*(%w+)")
        if lite_version then plugin.lite_version = "" .. lite_version end
        local _, _, required_plugin = line:find("require [\"']plugins.([%w_]+)")
        if required_plugin then if required_plugin ~= plugin.name then plugin.dependencies[required_plugin] = ">=1.0" end end
      end
      table.insert(plugins, plugin)
    end
  end
  io.open(path .. PATHSEP .. "manifest.json", "wb"):write(json.encode({ plugins = plugins })):flush()
end

function Repository:add()
  -- If neither specified then pull onto `master`, and check the main branch name, and move if necessary.
  if not self.branch and not self.commit then 
    local path = self.local_path .. PATHSEP .. "master"
    common.mkdirp(path)
    log_action("Retrieving " .. self.remote .. ":master/main...")
    system.init(path, self.remote)
    if not pcall(system.reset, "refs/heads/master") then
      if pcall(system.reset, "refs/heads/main") then
        os.rename(path, self.local_path .. PATHSEP .. "main")
      else
        error("Can't find master or main.")
      end
    end
    log_action("Retrieved " .. self.remote .. ":master/main.")
  else
    local path = self.local_path .. PATHSEP .. (self.commit or self.branch)
    common.mkdirp(path)
    log_action("Retrieving " .. self.remote .. ":master/main...")
    system.init(path, self.remote)
    system.fetch(path)
    system.reset(path, self.commit or ("refs/remotes/origin/" .. self.branch), "hard")
    log_action("Retrieved " .. self.remote .. ":" .. (self.commit or self.branch) .. "...")
    self.manifest = nil
    self:parse_manifest()
  end
end


function Repository:update()
  if self.branch then
    local path = self.local_path .. PATHSEP .. self.branch
    system.fetch(path)
    system.reset(path, "refs/remotes/origin/" .. self.branch, "hard")
    log_action("Updated " .. self.remote .. ":" .. (self.commit or self.branch))
    self.manifest = nil
    self:parse_manifest()
  end
end


function Repository:remove()
  common.rmrf(self.path)
end



local function get_repository(url)
  if not url then error("requires a repository url") end
  for i,v in ipairs(repositories) do
    if v.url == url then return i, v end
  end
  return nil
end


local function get_plugin(name, version, filter)
  local candidates = {}
  filter = filter or {}
  for i,repo in ipairs(repositories) do
    for j,plugin in ipairs(repo.plugins) do
      if plugin.name == name and match_version(plugin.version, version) then
        if (not filter.lite_version or not plugin.lite_version or plugin.lite_version == filter.lite_version) and (not filter.mod_version or not plugin.mod_version or tonumber(plugin.mod_version) == tonumber(filter.mod_version)) then
          table.insert(candidates, plugin)
        end
      end
    end
  end
  table.sort(candidates, function (a,b) return a.version < b.version end)
  return table.unpack(candidates)
end


local function lpm_repo_add(url)
  local idx, repo = get_repository(url)
  if repo then -- if we're alreayd a repo, put this at the head of the resolution list
    table.remove(repositories, idx)
  else
    repo = Repository.new(url):add()
  end
  table.insert(repositories, 1, repo)
  repo:update()
end


local function lpm_repo_rm(url)
  local idx, repo = get_repository(url)
  if not repo then error("cannot find repository " .. url) end
  table.remove(repositories, idx)
  repo:remove()
end


local function lpm_repo_update(url)
  local repo = url and get_repository(url)
  for i,v in ipairs(repositories) do if not repo or v == repo then v:update() end end
end


local function lpm_plugin_install(name, version)
  local plugin = get_plugin(name, version, { mod_version = MOD_VERSION, lite_version = LITE_VERSION })
  if not plugin then error("can't find plugin " .. name .. " mod-version: " .. (MOD_VERSION or 'any') .. " and lite-version: " .. (LITE_VERSION or 'any')) end
  plugin:install()
end


local function lpm_plugin_uninstall(name)
  local plugins = { get_plugin(name) }
  if #plugins == 0 then error("can't find plugin " .. name) end
  local installed_plugins = common.grep(plugins, function(plugin) return plugin:is_installed() end)
  if #installed_plugins == 0 then error("plugin " .. name .. " not installed") end
  for i, plugin in ipairs(installed_plugins) do plugin:uninstall() end
end


local function lpm_repo_list() 
  if JSON then
    io.stdout:write(json.encode({ repositories = common.map(repositories, function(repo) return { remote = repo.remote, commit = repo.commit, branch = repo.branch, path = repo.local_path .. PATHSEP .. (repo.commit or repo.branch)  } end) }) .. "\n")
  else
    for i, repository in ipairs(repositories) do
      if i ~= 0 then print("---------------------------") end
      print("Remote:  " .. repository.remote)
      print("Branch:  " .. repository.branch)
      print("Commit:  " .. (repository.commit or "nil"))
      print("Path  :  " .. repository.local_path .. PATHSEP .. (repository.commit or repository.branch))
    end
  end
end

local function lpm_plugin_list() 
  local result = { plugins = { } }
  for i,repo in ipairs(repositories) do
    if not repo.plugins then error("can't find plugins for repo " .. repo.remote .. ":" .. (repo.commit or repo.branch or "master")) end
    for j,plugin in ipairs(repo.plugins) do
      table.insert(result.plugins, {
        name = plugin.name,
        status = plugin.status,
        version = "" .. plugin.version,
        dependencies = plugin.dependencies,
        lite_version = plugin.lite_version,
        mod_version = plugin.mod_version,
        tags = plugin.tags,
        repository = repo.remote .. ":" .. (repo.commit or repo.branch)
      })
    end
  end
  if JSON then
    io.stdout:write(json.encode(result) .. "\n")
  else
    for i, plugin in ipairs(result.plugins) do
      if i ~= 0 then print("---------------------------") end
      print("Name:          " .. plugin.name)
      print("Version:       " .. plugin.version)
      print("Status:        " .. plugin.status)
      print("Repository:    " .. plugin.repository)
      print("Mod-Version:   " .. (plugin.mod_version or "unknown"))
      print("Lite-Version:  " .. (plugin.lite_version or "unknown"))
      print("Dependencies:  " .. json.encode(plugin.dependencies))
      print("Tags:          " .. common.join(" ", plugin.tags))
    end
  end
end


local function lpm_purge()
  log_action("Removed " .. CACHEDIR .. ".")
  common.rmrf(CACHEDIR)
end

local function parse_arguments(arguments, options)
  local args = {}
  local i = 1
  while i <= #arguments do
    local s,e, option, value = arguments[i]:find("%-%-(%w+)=?(.*)")
    if s then
      local flag_type = options[option]
      if flag_type == "flag" then
        args[option] = true
      elseif flag_type == "string" or flag_type == "number" then
        if not value then
          if i < #arguments then error("option " .. option .. " requires a " .. flag_type) end
          value = arguments[i+1]
          i = i + 1
        end
        if flag_type == "number" and tonumber(flag_type) == nil then error("option " .. option .. " should be a number") end
        args[option] = value
      end
    else
      table.insert(args, arguments[i])
    end
    i = i + 1
  end
  return args
end

local status = 0
local function error_handler(err)
  local s, e = err:find(":%d+")
  local message = e and err:sub(e + 3) or err
  if JSON then
    if VERBOSE then 
      io.stderr:write(json.encode({ error = err, actions = actions, traceback = debug.traceback() }) .. "\n")
    else
      io.stderr:write(json.encode({ error = message or err, actions = actions }) .. "\n")
    end
  else
    io.stderr:write((not VERBOSE and message or err) .. "\n")
    if VERBOSE then io.stderr:write(debug.traceback() .. "\n") end
  end
  status = -1
end

local function run_command(ARGS)
  if not ARGS[2]:find("%S") then return end
  if ARGS[2] == "repo" and ARGV[3] == "add" then lpm_repo_add(ARGS[4])
  elseif ARGS[2] == "repo" and ARGS[3] == "rm" then lpm_repo_rm(ARGS[4])
  elseif ARGS[2] == "add" then lpm_repo_add(ARGS[3])
  elseif ARGS[2] == "rm" then lpm_repo_rm(ARGS[3])
  elseif ARGS[2] == "update" then lpm_repo_update(ARGS[3])
  elseif ARGS[2] == "repo" and ARGS[3] == "update" then lpm_repo_update(ARGS[4])
  elseif ARGS[2] == "repo" and ARGS[3] == "list" then return lpm_repo_list(ARGS[4])
  elseif ARGS[2] == "plugin" and ARGS[3] == "install" then lpm_plugin_install(ARGS[4])
  elseif ARGS[2] == "plugin" and ARGS[3] == "uninstall" then lpm_plugin_uninstall(ARGS[4])
  elseif ARGS[2] == "plugin" and ARGS[3] == "list" then return lpm_plugin_list()
  elseif ARGS[2] == "install" then lpm_plugin_install(ARGS[3])
  elseif ARGS[2] == "uninstall" then lpm_plugin_uninstall(ARGS[3])
  elseif ARGS[2] == "list" then return lpm_plugin_list()
  elseif ARGS[2] == "purge" then lpm_purge()
  else
    error("unknown command: " .. ARGS[2])
  end
  if JSON then
    io.stdout:write(json.encode({ actions = actions }))
  end
end


xpcall(function()
  local ARGS = parse_arguments(ARGV, { json = "flag", userdir = "string", cachedir = "string", version = "flag", verbose = "flag", quiet = "flag", version = "string", modversion = "string" })
  if ARGS["version"] then
    io.stdout:write(VERSION .. "\n")
    return 0
  end
  if ARGS["help"] then
    io.stderr:write([[
Usage: lpm COMMAND [--json] [--userdir=directory] [--cachedir=directory]
  [--verbose] [--liteversion=2.1] [--modversion=3] [--quiet] [--version]
  [--help]

LPM is a package manager for `lite-xl`, written in C (and packed-in lua).

It's designed to install packages from our central github repository (and
affiliated repositories), directly into your lite-xl user directory. It can
be called independently, for from the lite-xl `plugin_manager` plugin.

LPM will always use https://github.com/lite-xl/lite-xl-plugins as its base
repository, though others can be added.

It has the following commands:

lpm repo list                                  -- List all extant repos.
lpm [repo] add <repository remote>             -- Add a source repository.
lpm [repo] rm <repository remote>              -- Remove a source repository.
lpm [repo] update [<repository remote>]        -- Update all/the specified repository.
lpm [plugin] install <plugin name> [<version>] -- Install the specific plugin in question.
lpm [plugin] uninstall <plugin name>           -- Uninstall the specific plugin.
lpm [plugin] list                              -- List all known plugins.
lpm purge                                      -- Completely purge all state for LPM.
]]
    )
    return 0
  end
  VERBOSE = ARGS["verbose"] or false
  JSON = ARGS["json"] or os.getenv("LPM_JSON")
  QUIET = ARGS["quiet"] or os.getenv("LPM_QUIET")
  MOD_VERSION = ARGS["mod-version"] or os.getenv("LPM_MODVERSION") or 3
  if MOD_VERSION == "any" then MOD_VERSION = nil end
  LITE_VERSION = ARGS["lite-version"] or os.getenv("LPM_LITEVERSION") or "2.1"
  if LITE_VERSION == "any" then LITE_VERSION = nil end
  HOME = (os.getenv("USERPROFILE") or os.getenv("HOME")):gsub(PATHSEP .. "$", "")
  USERDIR = ARGS["userdir"] or os.getenv("LITE_USERDIR") or (os.getenv("XDG_CONFIG_HOME") and os.getenv("XDG_CONFIG_HOME") .. PATHSEP .. "lite-xl")
    or (HOME and (HOME .. PATHSEP .. '.config' .. PATHSEP .. 'lite-xl'))
  if not system.stat(USERDIR) then error("can't find user directory " .. USERDIR) end
  CACHEDIR = ARGS["cachedir"] or os.getenv("LPM_CACHE") or USERDIR .. PATHSEP .. "lpm"
  repositories = {}
  repositories = { Repository.new({ remote = "https://github.com/lite-xl/lite-xl-plugins.git", branch = "master" }), Repository.new({ remote = "https://github.com/lite-xl/lite-xl-plugins.git", branch = "2.1" }) }
  local original_repositories = {}
  for i, repository in ipairs(repositories) do
    if not system.stat(CACHEDIR) or not system.stat(repository.local_path) or not system.stat(repository.local_path .. PATHSEP .. (repository.commit or repository.branch)) then 
      common.mkdirp(repository.local_path)
      repository:add()
    end
    table.insert(original_repositories, repository)
  end
  for i, remote_hash in ipairs(system.ls(CACHEDIR)) do
    local remote
    for j, commit_or_branch in ipairs(system.ls(CACHEDIR .. PATHSEP .. remote_hash)) do
      local is_original = false
      for i, repository in ipairs(original_repositories) do
        if commit_or_branch == repository.branch and remote_hash == system.hash(repository.remote) then
          is_original = true
        end
      end
      if not is_original then
        if system.stat(CACHEDIR .. PATHSEP .. remote_hash .. PATHSEP  .. commit_or_branch .. PATHSEP .. ".git" .. PATHSEP .."config") then
          for line in io.lines(CACHEDIR .. PATHSEP .. remote_hash .. PATHSEP  .. commit_or_branch .. PATHSEP .. ".git" .. PATHSEP .."config") do
            local s,e = line:find("url = ") 
            if s then remote = line:sub(e+1) break end
          end
          if remote then
            if #commit_or_branch == 40 and not commit_or_branch:find("[^a-z0-9]") then
              table.insert(repositories, Repository.new({ remote = remote, commit = commit_or_branch }))
            else
              table.insert(repositories, Repository.new({ remote = remote, branch = commit_or_branch }))
            end
          end
        end
      end
    end
  end

  if #ARGS > 1 then
    run_command(ARGS)
  else
    while true do
      local line = io.stdin:read("*line")
      if line == "quit" or line == "exit" then return 0 end
      local args = { ARGS[1] }
      local s = 1
      while true do
        local a,e = line:find("%s+", s)
        table.insert(args, line:sub(s, a and (a - 1) or #line))
        if not e then break end
        s = e + 1
      end
      xpcall(function()
        run_command(args)
      end, error_handler)
      actions = {}
    end
  end

end, error_handler)


return status
