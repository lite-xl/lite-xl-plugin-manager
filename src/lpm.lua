setmetatable(_G, { __index = function(t, k) if not rawget(t, k) then error("cannot get undefined global variable: " .. k, 2) end end, __newindex = function(t, k) error("cannot set global variable: " .. k, 2) end  })

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
local function is_commit_hash(hash)
  return #hash == 40 and not hash:find("[^a-z0-9]")
end


local common = {}
function common.merge(dst, src) for k, v in pairs(src) do dst[k] = v end return dst end
function common.map(l, p) local t = {} for i, v in ipairs(l) do table.insert(t, p(v)) end return t end
function common.flat_map(l, p) local t = {} for i, v in ipairs(l) do local r = p(v) for k, w in ipairs(r) do table.insert(t, w) end end return t end
function common.concat(t1, t2) local t = {} for i, v in ipairs(t1) do table.insert(t, v) end for i, v in ipairs(t2) do table.insert(t, v) end return t end
function common.grep(l, p) local t = {} for i, v in ipairs(l) do if p(v) then table.insert(t, v) end end return t end
function common.first(l, p) for i, v in ipairs(l) do if p(v) then return v end end end
function common.slice(t, i, l) local n = {} for j = i, l ~= nil and (i - l) or #t do table.insert(n, t[j]) end return n end
function common.join(j, l) local s = "" for i, v in ipairs(l) do if i > 1 then s = s .. j .. v else s = v end end return s end
function common.sort(t, f) table.sort(t, f) return t end
function common.write(path, contents) local f, err = io.open(path, "wb") if not f then error("can't write to " .. path .. ": " .. err) end f:write(contents) f:flush() end
function common.read(path) local f, err = io.open(path, "rb") if not f then error("can't read from " .. path .. ": " .. err) end return f:read("*all") end
function common.split(splitter, str)
  local o = 1
  local res = {}
  while true do
      local s, e = str:find(splitter, o)
      table.insert(res, str:sub(o, s and (s - 1) or #str))
      if not s then break end
      o = e + 1
  end
  return table.unpack(res)
end

function common.dirname(path) local s = path:reverse():find("[/\\]") if not s then return path end return path:sub(1, #path - s) end
function common.basename(path) local s = path:reverse():find("[/\\]") if not s then return path end return path:sub(#path - s + 2) end
function common.path(exec) return common.first(common.map({ common.split(":", os.getenv("PATH")) }, function(e) return e .. PATHSEP .. exec end), function(e) return system.stat(e) end) end
function common.normalize_path(path) if not path or not path:find("^~") then return path end return os.getenv("HOME") .. path:sub(2) end
function common.rmrf(root)
  local info = root and root ~= "" and system.stat(root)
  if not info then return end
  if info.type == "file" or info.symlink then 
    local status, err = os.remove(root) 
    if not status then 
      if not err:find("denied") then error("can't remove " .. root .. ": " .. err) end
      system.chmod(root, 448) -- chmod so that we can write, for windows.
      status, err = os.remove(root)
      if not status then error("can't remove " .. root .. ": " .. err) end 
    end
  else
    for i,v in ipairs(system.ls(root)) do common.rmrf(root .. PATHSEP .. v) end
    system.rmdir(root)
  end
end
function common.mkdirp(path)
  local stat = system.stat(path)
  if stat and stat.type == "dir" then return true end
  if stat and stat.type == "file" then error("path " .. path .. " exists") end
  local target
  for _, dirname in ipairs({ common.split("[/\\]", path) }) do
    target = target and target .. PATHSEP .. dirname or dirname
    if target ~= "" and not target:find("^[A-Z]:$") and not system.stat(target) then system.mkdir(target) end
  end
end
function common.copy(src, dst)
  local src_stat, dst_stat = system.stat(src), system.stat(dst)
  if not src_stat then error("can't find " .. src) end
  if dst_stat and dst_stat.type == "dir" then return common.copy(src, dst .. PATHSEP .. common.basename(src)) end
  if src_stat.type == "dir" then
    common.mkdirp(dst)
    for i, file in ipairs(system.ls(src)) do common.copy(src .. PATHSEP .. file, dst .. PATHSEP .. file) end
  else
    local src_io, err1 = io.open(src, "rb")
    if err1 then error("can't open for reading " .. src .. ": " .. err1) end
    local dst_io, err2 = io.open(dst, "wb")
    if err2 then error("can't open for writing " .. dst .. ": " .. err2) end
    while true do
      local chunk = src_io:read(64*1024)
      if not chunk then break end
      dst_io:write(chunk)
    end
    dst_io:close()
  end
end
function common.rename(src, dst)
  local _, err = os.rename(src, dst)
  if err then error("can't rename file " .. src ..  " to " .. dst .. ": " .. err) end
end
function common.reset(path, ref, type)
  if is_commit_hash(ref) then
    system.reset(path, ref, type)
  else
    if not pcall(system.reset, path, "refs/tags/" .. ref, type) then system.reset(path, "refs/remotes/origin/" .. ref, type) end
  end
end
function common.chdir(dir, callback)
  local wd = system.pwd()
  system.chdir(dir)
  local status, err = pcall(callback)
  system.chdir(wd)
  if not status then error(err) end
end

local HOME, USERDIR, CACHEDIR, JSON, VERBOSE, MOD_VERSION, QUIET, FORCE, AUTO_PULL_REMOTES, ARCH, ASSUME_YES, NO_INSTALL_OPTIONAL, TMPDIR, DATADIR, BINARY, POST, repositories, lite_xls, system_bottle, progress_bar_label, write_progress_bar

local Plugin, Repository, LiteXL, Bottle = {}, {}, {}, {}

local actions, warnings = {}, {}
local function log_action(message)
  if JSON then table.insert(actions, message) end
  if not QUIET then io.stderr:write(message .. "\n") end
end
local function log_warning(message)
  if JSON then table.insert(warnings, message) end
  if not QUIET then io.stderr:write("warning: " .. message .. "\n") end
end
local function fatal_warning(message)
  if not FORCE then error(message .. "; use --force to override") else log_warning(message) end
end
local function log_progress_action(message)
  if write_progress_bar then
    progress_bar_label = message
  else
    log_action(message)
  end
end
local function prompt(message)
  io.stderr:write(message .. " [Y/n]: ")
  if ASSUME_YES then io.stderr:write("Y\n") return true end
  local response = io.stdin:read("*line")
  return not response:find("%S") or response:find("^%s*[yY]%s*$")
end


function common.get(source, target, checksum, callback, depth)
  if not source then error("requires url") end
  if (depth or 0) > 10 then error("too many redirects") end
  local _, _, protocol, hostname, port, rest = source:find("^(https?)://([^:/?]+):?(%d*)(.*)$")
  log_progress_action("Downloading " .. source:sub(1, 100) .. "...")
  if not protocol then error("malfomed url " .. source) end
  if not port or port == "" then port = protocol == "https" and 443 or 80 end
  if not checksum then 
    local res, headers = system.get(protocol, hostname, port, rest, target, callback) 
    if headers.location then return common.get(headers.location, target, checksum, callback, (depth or 0) + 1) end
    return res
  end
  if not system.stat(CACHEDIR .. PATHSEP .. "files") then common.mkdirp(CACHEDIR .. PATHSEP .. "files") end
  local cache_path = CACHEDIR .. PATHSEP .. "files" .. PATHSEP .. checksum
  if not system.stat(cache_path) then
    local res, headers = system.get(protocol, hostname, port, rest, cache_path, callback)
    if headers.location then return common.get(headers.location, target, checksum, callback, (depth or 0) + 1) end
    if checksum ~= "SKIP" and system.hash(cache_path, "file") ~= checksum then fatal_warning("checksum doesn't match for " .. source) end
  end
  common.copy(cache_path, target)
end


local function compare_version(a, b) -- compares semver
  if not a or not b then return false end
  local _, _, majora, minora, revisiona = tostring(a):find("(%d+)%.?(%d*)%.?(%d*)")
  local _, _, majorb, minorb, revisionb = tostring(b):find("(%d+)%.?(%d*)%.?(%d*)")
  if majora == nil then error("can't parse version " .. a) end
  if majorb == nil then error("can't parse version " .. b) end
  majora, minora, revisiona = majora or 0, minora or 0, revisiona or 0
  majorb, minorb, revisionb = majorb or 0, minorb or 0, revisionb or 0
  if majora ~= majorb then return tonumber(majora) < tonumber(majorb) and -1 or 1 end
  if minora ~= minorb then return tonumber(minora) < tonumber(minorb) and -1 or 1 end
  if revisiona ~= revisionb then return tonumber(revisiona) < tonumber(revisionb) and -1 or 1 end
  return 0
end

local function match_version(version, pattern)
  if not pattern then return true end
  if pattern:find("^>=") then return compare_version(version, pattern:sub(3)) >= 0 end
  if pattern:find("^<=") then return compare_version(version, pattern:sub(3)) <= 0 end
  if pattern:find("^<") then return compare_version(version, pattern:sub(2)) == -1 end
  if pattern:find("^>") then return compare_version(version, pattern:sub(2)) == 1 end
  if pattern:find("^=") then return compare_version(version, pattern:sub(2)) == 0 end
  return version == pattern
end


-- There can exist many different versions of a plugin. All statuses are relative to a particular lite bottle.
-- available: Plugin is available in a repository, and can be installed. There is no comparable version on the system.
-- upgradable: Plugin is installed, but does not match the highest version in any repository.
-- orphan: Plugin is installed, but there is no corresponding plugin in any repository.
-- installed: Plugin is installed, and matches the highest version in any repository, or highest version is incompatible.
-- core: Plugin is a part of the lite data directory, and doesn't have corresponding plugins in any repository.
-- bundled: Plugin is part of the lite data directory, but has corresponding plugins in any repository.
-- incompatible: Plugin is not installed and conflicts with existing installed plugins.
function Plugin.__index(self, idx) return rawget(self, idx) or Plugin[idx] end
function Plugin.new(repository, metadata)
  local type = metadata.type or "plugin"
  local folder = metadata.type == "library" and "libraries" or "plugins"
  if metadata.path then metadata.path = metadata.path:gsub("/", PATHSEP) end
  local self = setmetatable(common.merge({
    repository = repository,
    tags = {},
    type = type,
    path = nil,
    remote = nil,
    version = "1.0",
    dependencies = {},
    conflicts = {},
    local_path = repository and (repository.local_path .. PATHSEP .. (repository.commit or repository.branch) .. (metadata.path and (PATHSEP .. metadata.path:gsub("^/", "")) or "")),
  }, metadata), Plugin)
  self.type = type
  -- Directory.
  self.organization = metadata.organization or (((self.files and #self.files > 0) or self.remote or (not self.path and not self.url)) and "complex" or "singleton")
  return self
end

-- Determines whether two plugins located at different paths are actually different based on their contents.
-- If path1 is a directory, will still return true if it's a subset of path2 (accounting for binary downloads).
function Plugin.is_path_different(path1, path2) 
  local stat1, stat2 = system.stat(path1), system.stat(path2)
  if not stat1 or not stat2 or stat1.type ~= stat2.type or stat1.size ~= stat2.size then return true end
  if stat1.type == "dir" then
    for i, file in ipairs(system.ls(path1)) do if Plugin.is_path_different(path1 .. PATHSEP .. file, path2 .. PATHSEP.. file) then return true end end
    return false
  else
    return system.hash(path1, "file") ~= system.hash(path2, "file")
  end
end

function Plugin.is_plugin_different(downloaded_path, installed_path) 
  local is_downloaded_single = downloaded_path:find("%.lua$")
  local is_installed_single = installed_path:find("%.lua$")
  local target = is_downloaded_single and not is_installed_single and installed_path .. PATHSEP .. "init.lua" or installed_path
  return Plugin.is_path_different(downloaded_path, target)
end

function Plugin:get_install_path(bottle)
  local folder = self.type == "library" and "libraries" or "plugins" 
  local path = (((self:is_core(bottle) or self:is_bundled()) and bottle.lite_xl.datadir_path) or (bottle.local_path and (bottle.local_path .. PATHSEP .. "user") or USERDIR)) .. PATHSEP .. folder .. PATHSEP .. (self.path and common.basename(self.path):gsub("%.lua$", "") or self.name)
  if self.organization == "singleton" then path = path .. ".lua" end
  return path
end

function Plugin:is_core(bottle) return self.type == "core" end
function Plugin:is_bundled(bottle) return self.type == "bundled" end
function Plugin:is_installed(bottle) 
  if self:is_core(bottle) or self:is_bundled(bottle) or not self.repository then return true end
  local install_path = self:get_install_path(bottle)
  if not system.stat(install_path) then return false end
  if #common.grep({ bottle:get_plugin(self.name, nil, {  }) }, function(plugin) return not plugin.repository end) > 0 then return false end
  return not Plugin.is_plugin_different(self.local_path, install_path)
end
function Plugin:is_upgradable(bottle)
  if self:is_installed(bottle) then
    local plugins = { bottle:get_plugin(self.name) }
    for i, v in ipairs(plugins) do
      if self.version and v.version and v ~= self and compare_version(self.version, v.version) <= 1 then
        return true
      end
    end
  end
  return false
end
function Plugin:is_incompatible(plugin) 
  return (self.dependencies[plugin.name] and not match_version(plugin.version, self.dependencies[plugin.name] and self.dependencies[plugin.name].version)) or 
    (self.conflicts[plugin.name] and match_version(plugin.version, self.conflicts[plugin.name] and self.conflicts[plugin.name].version)) 
end

function Plugin:get_path(bottle)
  return self:is_installed(bottle) and self:get_install_path(bottle) or self.local_path 
end

function Plugin:get_compatibilities(bottle)
  local compatible_plugins, incompatible_plugins = {}, {}
  local installed_plugins = bottle:installed_plugins()
  for plugin, v in pairs(self.dependencies) do
    local potential_plugins = { bottle:get_plugin(plugin, v.version, { mod_version = bottle.lite_xl.mod_version }) }
    for i, potential_plugin in ipairs(potential_plugins) do
      local incomaptibilities = common.grep(installed_plugins, function(p) return p:is_incompatible(potential_plugin) end)
      if #incomaptibilities == 0 then
        if not compatible_plugins[plugin] or
          potential_plugin:is_installed(bottle) or
          (compare_version(compatible_plugins[plugin].version, potential_plugin.version) and not compatible_plugins[plugin]:is_installed(bottle))
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



function Plugin:install(bottle, installing)
  if self:is_installed(bottle) then error("plugin " .. self.name .. " is already installed") return end
  local install_path = self:get_install_path(bottle)
  local temporary_install_path = TMPDIR .. PATHSEP .. install_path:sub(#USERDIR + 2)
  local status, err = pcall(function()
    installing = installing or {}
    installing[self.name] = true
    local compatible, incompatible = self:get_compatibilities(bottle)
    for plugin, version in pairs(self.dependencies) do
      if incompatible[plugin] then error("can't install " .. self.name .. ": incompatible with " .. incompatible[plugin][1].name .. ":" .. incompatible[plugin][1].version) end
    end
    for plugin, v in pairs(self.dependencies) do
      if not compatible[plugin] then 
        if not v.optional then 
          error("can't find dependency " .. plugin .. (v.version and (":" .. v.version) or "")) 
        else
          log_warning("can't find optional dependency " .. plugin .. (v.version and (":" .. v.version) or ""))
        end
      end
    end
    for plugin, v in pairs(self.dependencies) do
      if compatible[plugin] and not compatible[plugin]:is_core(bottle) and not compatible[plugin]:is_installed(bottle) then
        if installing[plugin] then
          error("circular dependency detected in " .. self.name .. ": requires " .. plugin .. " but, " .. plugin .. " requires " .. self.name)
        end
        if not NO_INSTALL_OPTIONAL and (not v.optional or prompt(plugin .. " is an optional dependency of " .. self.name .. ". Should we install it?")) then
          compatible[plugin]:install(bottle, installing)
        end
      end
    end
    common.mkdirp(common.dirname(temporary_install_path))
    if self:is_upgradable(bottle) then 
      log_action("Upgrading " .. self.organization .. "plugin located at " .. self.local_path .. " to " .. install_path)
      common.rmrf(install_path) 
    else
      log_action("Installing " .. self.organization .. " plugin located at " .. self.local_path .. " to " .. install_path)
    end

    if self.organization == "complex" and self.path and system.stat(self.local_path).type ~= "dir" then common.mkdirp(install_path) end  
    if self.url then
      local path = temporary_install_path .. (self.organization == 'complex' and self.path and system.stat(self.local_path).type ~= "dir" and (PATHSEP .. "init.lua") or "")
      common.get(self.url, path, self.checksum, write_progress_bar)
      log_action("Downloaded file " .. self.url .. " to " .. path)
      if system.hash(path, "file") ~= self.checksum then fatal_warning("checksum doesn't match for " .. path) end
    elseif self.remote then
      log_progress_action("Fetching repository " .. self.remote .. " into " .. install_path)
      common.mkdirp(temporary_install_path)
      local _, _, url, branch = self.remote:find("^(.*):(.*)$")
      system.init(temporary_install_path, url)
      system.fetch(temporary_install_path, write_progress_bar)
      common.reset(temporary_install_path, branch, "hard")
    elseif self.path then
      local path = install_path .. (self.organization == 'complex' and self.path and system.stat(self.local_path).type ~= "dir" and (PATHSEP .. "init.lua") or "")
      local temporary_path = temporary_install_path .. (self.organization == 'complex' and self.path and system.stat(self.local_path).type ~= "dir" and (PATHSEP .. "init.lua") or "")
      if self.organization == 'complex' and self.path and system.stat(self.local_path).type ~= "dir" then common.mkdirp(temporary_install_path) end
      log_action("Copying " .. self.local_path .. " to " .. path)
      common.copy(self.local_path, temporary_path)
    elseif self.organization == 'complex' then
      common.copy(self.local_path, temporary_install_path)
    end
    for i,file in ipairs(self.files or {}) do
      if not file.arch or file.arch == ARCH then
        if not NO_INSTALL_OPTIONAL and (not file.optional or prompt(common.basename(file.url) .. " is an optional dependency of " .. self.name .. ". Should we install it?")) then
          if not file.checksum then error("requires a checksum") end
          local path = install_path .. PATHSEP .. (file.path or common.basename(file.url))
          local temporary_path = temporary_install_path .. PATHSEP .. (file.path or common.basename(file.url))
          common.get(file.url, temporary_path, file.checksum, write_progress_bar)
          local basename = common.basename(path)
          if basename:find("%.zip$") or basename:find("%.tar%.gz$") then 
            log_action("Extracting file " .. basename .. " in " .. install_path)
            system.extract(temporary_path, temporary_install_path) 
          else
            if file.arch then system.chmod(temporary_path, 448) end -- chmod any ARCH tagged file to rwx-------
          end
        end
      end
    end
  end)
  bottle:invalidate_cache()
  if not status then
    common.rmrf(temporary_install_path)
    error(err)
  else
    if POST and self.post then
      common.chdir(temporary_install_path, function() 
        if type(self.post) == "table" and not self.post[ARCH] then error("can't find post command for arch " .. ARCH) end
        local code = os.system(type(self.post) == "table" and self.post[ARCH] or self.post) ~= 0 
        if code ~= 0 then error("post step failed with error code " .. code) end
      end)
    end
    common.rmrf(install_path)
    common.mkdirp(common.dirname(install_path))
    common.rename(temporary_install_path, install_path)
  end
end

function Plugin:depends_on(plugin)
  if self.dependencies[plugin.name] and self.dependencies[plugin.name].optional ~= true then return true end
  for i,v in ipairs(plugin.provides or {}) do if self.dependencies[v] and self.dependencies[v].optional ~= true then return true end end
  return false
end

function Plugin:uninstall(bottle)
  local install_path = self:get_install_path(bottle)
  if self:is_core(bottle) then error("can't uninstall " .. self.name .. "; is a core plugin") end
  log_action("Uninstalling plugin located at " .. install_path)
  local incompatible_plugins = common.grep(bottle:installed_plugins(), function(p) return p:depends_on(self) end)
  if #incompatible_plugins == 0 or prompt(self.name .. " is depended upon by " .. common.join(", ", common.map(incompatible_plugins, function(p) return p.name end)) .. ". Remove as well?") then
    for i,plugin in ipairs(incompatible_plugins) do 
      if not plugin:uninstall(bottle) then return false end
    end
    common.rmrf(install_path)
    return true
  end
  return false
end


function Repository.__index(self, idx) return rawget(self, idx) or Repository[idx] end
function Repository.new(hash)
  if not hash.remote then error("requires a remote") end
  if not hash.remote:find("^%w+:") and system.stat(hash.remote .. "/.git") then hash.remote = "file://" .. system.stat(hash.remote).abs_path end
  if not hash.remote:find("^https?:") and not hash.remote:find("^file:") then error("only repositories with http and file transports are supported (" .. hash.remote .. ")") end
  local self = setmetatable({ 
    commit = hash.commit,
    remote = hash.remote,
    branch = hash.branch,
    plugins = nil,
    lite_xls = {},
    local_path = CACHEDIR .. PATHSEP .. "repos" .. PATHSEP .. system.hash(hash.remote),
    last_retrieval = nil 
  }, Repository)
  if system.stat(self.local_path) and not self.commit and not self.branch then
    -- In the case where we don't have a branch, and don't have a commit, check for the presence of `master` and `main`.
    if system.stat(self.local_path .. PATHSEP .. "master") then
      self.branch = "master"
    elseif system.stat(self.local_path .. PATHSEP .. "main") then
      self.branch = "main"
    else
      error("can't find branch for " .. self.remote)
    end
  end
  return self
end

function Repository.url(url)
  if type(url) == "table" then return url.remote .. ":" .. (url.branch or url.commit) end 
  local e = url:reverse():find(":")
  local s = e and (#url - e + 1)
  local remote, branch_or_commit = url:sub(1, s and (s-1) or #url), s and url:sub(s+1)
  if remote == "https" or remote == "file" then remote, branch_or_commit = url, nil end
  if branch_or_commit and is_commit_hash(branch_or_commit) then
    return Repository.new({ remote = remote, commit = branch_or_commit })
  end
  return Repository.new({ remote = remote, branch = branch_or_commit })
end

function Repository:parse_manifest(already_pulling)
  if self.manifest then return self.manifest, self.remotes end
  if system.stat(self.local_path) and system.stat(self.local_path .. PATHSEP .. (self.commit or self.branch)) then
    self.manifest_path = self.local_path .. PATHSEP .. (self.commit or self.branch) .. PATHSEP .. "manifest.json"
    if not system.stat(self.manifest_path) then 
      log_action("Can't find manifest.json for " .. self:url() .. "; automatically generating manifest.")
      self:generate_manifest() 
    end
    local status, manifest = pcall(json.decode, common.read(self.manifest_path))
    if not status then error("error parsing manifest for " .. self:url() .. ": " .. manifest) end
    self.manifest = manifest
    self.plugins = {}
    self.remotes = {}
    for i, metadata in ipairs(self.manifest["plugins"] or {}) do
      if metadata.remote then
        local _, _, url, branch_or_commit = metadata.remote:find("^(.-):?(%w*)$")
        if branch_or_commit and is_commit_hash(branch_or_commit) then
          table.insert(self.plugins, Plugin.new(self, metadata))
        else
          -- log_warning("plugin " .. metadata.name .. " specifies remote as source, but isn't a commit")
        end
      else
        table.insert(self.plugins, Plugin.new(self, metadata))
      end
    end
    for i, metadata in ipairs(self.manifest["lite-xls"] or {}) do
      if metadata.remote then
        local _, _, url, branch_or_commit = metadata.remote:find("^(.-):?(%w*)$")
        if branch_or_commit and is_commit_hash(branch_or_commit) then
          table.insert(self.lite_xls, LiteXL.new(self, metadata))
        else
          -- log_warning("plugin " .. metadata.name .. " specifies remote as source, but isn't a commit")
        end
      else
        table.insert(self.lite_xls, LiteXL.new(self, metadata))
      end
    end
    self.remotes = common.map(self.manifest["remotes"] or {}, function(r) return Repository.url(r) end)
  end
  return self.manifest, self.remotes
end


-- in the cases where we don't have a manifest, assume generalized structure, take plugins folder, trawl through it, build manifest that way
-- assuming each .lua file under the `plugins` folder is a plugin. also parse the README, if present, and see if any of the plugins 
function Repository:generate_manifest()
  if not self.commit and not self.branch then error("requires an instantiation") end
  local path = self.local_path .. PATHSEP .. (self.commit or self.branch)
  local plugin_dir = system.stat(path .. PATHSEP .. "plugins") and PATHSEP .. "plugins" .. PATHSEP or PATHSEP
  local plugins, plugin_map = {}, {}
  if system.stat(path .. PATHSEP .. "README.md") then -- If there's a README, parse it for a table like in our primary repository.
    for line in io.lines(path .. PATHSEP .. "README.md") do
      local _, _, name, path, description = line:find("^%s*%|%s*%[`([%w_]+)%??.-`%]%((.-)%).-%|%s*(.-)%s*%|%s*$")
      if name then
        plugin_map[name] = { name = name, description = description }
        if path:find("^http") then
          if path:find("%.lua") then
            plugin_map[name].url = path
            local file = common.get(path, nil, nil, write_progress_bar)
            plugin_map[name].checksum = system.hash(file)
          else
            path = path:gsub("\\", "")
            plugin_map[name].remote = path
            pcall(function()
              local repo = Repository.url(path):add()
              plugin_map[name].remote = path .. ":" .. system.revparse(repo.local_path .. PATHSEP .. (repo.branch))
            end)
          end
        else
          plugin_map[name].path = path:gsub("%?.*$", "")
        end 
      end
    end
  end
  for i, file in ipairs(system.ls(path .. plugin_dir)) do
    if file:find("%.lua$") then
      local plugin = { description = nil, name = common.basename(file):gsub("%.lua$", ""), mod_version = 3, version = "0.1", path = plugin_dir .. file  }
      for line in io.lines(path .. plugin_dir .. file) do
        local _, _, mod_version = line:find("%-%-.*mod%-version:%s*(%w+)")
        if mod_version then plugin.mod_version = mod_version end
        local _, _, required_plugin = line:find("require [\"']plugins.([%w_]+)")
        if required_plugin then if required_plugin ~= plugin.name then if not plugin.dependencies then plugin.dependencies = {} end plugin.dependencies[required_plugin] = ">=1.0" end end
      end
      if plugin_map[plugin.name] then 
        plugin = common.merge(plugin, plugin_map[plugin.name])
        plugin_map[plugin.name].plugin = plugin 
      end
      table.insert(plugins, plugin)
    end
  end
  for k, v in pairs(plugin_map) do
    if not v.plugin then 
      table.insert(plugins, common.merge({ mod_version = 3, version = "0.1" }, v))
    end
  end
  table.sort(plugins, function(a,b) return a.name:lower() < b.name:lower() end)
  common.write(path .. PATHSEP .. "manifest.json", json.encode({ plugins = plugins }))
end

function Repository:add(pull_remotes)
  -- If neither specified then pull onto `master`, and check the main branch name, and move if necessary.
  if not self.branch and not self.commit then 
    local path = self.local_path .. PATHSEP .. "master"
    common.mkdirp(path)
    log_progress_action("Fetching " .. self.remote .. ":master/main...")
    system.init(path, self.remote)
    system.fetch(path, write_progress_bar)
    if not pcall(system.reset, path, "refs/remotes/origin/master", "hard") then
      if pcall(system.reset, path, "refs/remotes/origin/main", "hard") then
        common.rename(path, self.local_path .. PATHSEP .. "main")
        self.branch = "main"
      else
        error("can't find master or main.")
      end
    else
      self.branch = "master"
    end
  else
    local path = self.local_path .. PATHSEP .. (self.commit or self.branch)
    common.mkdirp(path)
    log_progress_action("Fetching " .. self.remote .. ":" .. (self.commit or self.branch) .. "...")
    system.init(path, self.remote)
    system.fetch(path, write_progress_bar)
    common.reset(path, self.commit or self.branch, "hard")
    self.manifest = nil
  end
  local manifest, remotes = self:parse_manifest()
  if pull_remotes then -- any remotes we don't have in our listing, call add, and add into the list
    for i, remote in ipairs(remotes) do 
      if not common.first(repositories, function(repo) return repo.remote == remote.remote and repo.branch == remote.branch and repo.commit == remote.commit end) then
        remote:add(pull_remotes == "recursive" and "recursive" or false)
        table.insert(repositories, remote)
      end
    end
  end
  return self
end


function Repository:update(pull_remotes)
  local manifest, remotes = self:parse_manifest()
  if self.branch then
    local path = self.local_path .. PATHSEP .. self.branch
    system.fetch(path)
    common.reset(path, self.branch, "hard")
    log_action("Updated " .. self:url())
    self.manifest = nil
    manifest, remotes = self:parse_manifest()
  end
  if pull_remotes then -- any remotes we don't have in our listing, call add, and add into the list
    for i, remote in ipairs(remotes) do 
      if common.first(repositories, function(repo) return repo.remote == remote.remote and repo.branch == remote.branch and repo.commit == remote.comit end) then
        remote:add(pull_remotes == "recursive" and "recursive" or false) 
        table.insert(repositories, remote)
      end
    end
  end
end


function Repository:remove()
  common.rmrf(self.local_path .. PATHSEP .. (self.commit or self.branch))
  if #system.ls(self.local_path) == 0 then common.rmrf(self.local_path) end
end


function LiteXL.__index(t, k) return LiteXL[k] end
function LiteXL.new(repository, metadata)
  if not metadata.version then error("lite-xl entry requires a version") end
  local self = setmetatable(common.merge({
    repository = repository,
    tags = {},
    files = {}
  }, metadata), LiteXL)
  self.hash = system.hash((repository and repository:url() or "") .. "-" .. metadata.version .. common.join("", common.map(self.files, function(f) return f.checksum end)))
  self.local_path = self:is_local() and self.path or (CACHEDIR .. PATHSEP .. "lite_xls" .. PATHSEP .. self.version .. PATHSEP .. self.hash)
  self.binary_path = self.binary_path or (self.local_path .. PATHSEP .. "lite-xl")
  self.datadir_path = self.datadir_path or (self.local_path .. PATHSEP .. "data")
  return self
end

function LiteXL:is_system() return system_bottle and system_bottle.lite_xl == self end
function LiteXL:is_local() return not self.repository and self.path end
function LiteXL:is_compatible(plugin) return not plugin.mod_version or compare_version(self.mod_version, plugin.mod_version) == 0 end
function LiteXL:is_installed()  return system.stat(self.local_path) end

function LiteXL:install()
  if self:is_installed() then log_warning("lite-xl " .. self.version .. " already installed") return end
  common.mkdirp(self.local_path)
  if system_bottle.lite_xl == self then -- system lite-xl. We have to copy it because we can't really set the user directory.
    local executable, datadir = common.path("lite-xl")
    if not executable then error("can't find system lite-xl executable") end
    local stat = system.stat(executable)
    executable = stat.symlink and stat.symlink or executable
    datadir = common.dirname(executable) .. PATHSEP .. "data"
    if not system.stat(datadir) then error("can't find system lite-xl data dir") end
    common.copy(executable, self.local_path .. PATHSEP .. "lite-xl")
    system.chmod(self.local_path .. PATHSEP .. "lite-xl", 448) -- chmod to rwx-------
    common.copy(datadir, self.local_path .. PATHSEP .. "data")
  elseif self.path and not self.repository then -- local repository
    system.symlink(self.binary_path, self.path .. PATHSEP .. "lite_xl")
  else
    if self.remote then
      system.init(self.local_path, self.remote)
      common.reset(self.local_path, self.commit or self.branch)
    end
    for i,file in ipairs(self.files or {}) do
      if file.arch and file.arch == ARCH then
        if not file.checksum then error("requires a checksum") end
        local basename = common.basename(file.url)
        local archive = basename:find("%.zip$") or basename:find("%.tar%.gz$")
        local path = self.local_path .. PATHSEP .. (archive and basename or "lite-xl")
        log_action("Downloading file " .. file.url .. "...")
        common.get(file.url, path, file.checksum, write_progress_bar)
        log_action("Downloaded file " .. file.url .. " to " .. path)
        if file.checksum ~= "SKIP" and system.hash(path, "file") ~= file.checksum then fatal_warning("checksum doesn't match for " .. path) end
        if archive then 
          log_action("Extracting file " .. basename .. " in " .. self.local_path)
          system.extract(path, self.local_path) 
        end
      end
    end
  end
  if not system.stat(self.local_path .. PATHSEP .. "lite-xl") then error("can't find executable for lite-xl " .. self.version) end
end

function LiteXL:uninstall()
  if not system.stat(self.local_path) then error("lite-xl " .. self.version .. " not installed") end
  common.rmrf(self.local_path)
end


function Bottle.__index(t, k) return Bottle[k] end
function Bottle.new(lite_xl, plugins, is_system)
  local self = setmetatable({
    lite_xl = lite_xl,
    plugins = plugins,
    is_system = is_system
  }, Bottle)
  if not is_system then 
    table.sort(self.plugins, function(a, b) return (a.name .. ":" .. a.version) < (b.name .. ":" .. b.version) end)
    self.hash = system.hash(lite_xl.version .. " " .. common.join(" ", common.map(self.plugins, function(p) return p.name .. ":" .. p.version end)))
    self.local_path = CACHEDIR .. PATHSEP .. "bottles" .. PATHSEP .. self.hash
  end
  return self
end

function Bottle:is_constructed() return self.is_system or system.stat(self.local_path) end

function Bottle:construct()
  if self.is_system then error("system bottle cannot be constructed") end
  if self:is_constructed() then error("bottle " .. self.hash .. " already constructed") end
  if not self.lite_xl:is_installed() then self.lite_xl:install() end
  common.mkdirp(self.local_path .. PATHSEP .. "user")
  common.copy(self.lite_xl.local_path .. PATHSEP .. "lite-xl", self.local_path .. PATHSEP .. "lite-xl")
  system.chmod(self.local_path .. PATHSEP .. "lite-xl", 448) -- chmod to rwx-------
  common.copy(self.lite_xl.local_path .. PATHSEP .. "data", self.local_path .. PATHSEP .. "data")
  for i,plugin in ipairs(self.plugins) do plugin:install(self) end
end

function Bottle:destruct()
  if self.is_system then error("system bottle cannot be destructed") end
  if not self:is_constructed() then error("lite-xl " .. self.version .. " not constructed") end
  common.rmrf(self.local_path)
end

function Bottle:run(args)
  args = args or {}
  if self.is_system then error("system bottle cannot be run") end
  os.execute(self.local_path .. PATHSEP .. "lite-xl", table.unpack(args))
end

local function get_repository_plugins()
  local t, hash = { }, { }
  for i,p in ipairs(common.flat_map(repositories, function(r) return r.plugins end)) do
    local id = p.name .. ":" .. p.version
    if not hash[id] then 
      table.insert(t, p) 
      hash[id] = p 
      if not hash[p.name] then hash[p.name] = {} end
      table.insert(hash[p.name], p )
    end
  end
  return t, hash
end

function Bottle:invalidate_cache()
  self.all_plugins_cache = nil
end

function Bottle:all_plugins()
  if self.all_plugins_cache then return self.all_plugins_cache end
  local t, hash = get_repository_plugins()
  local plugin_paths = {
    (self.local_path and (self.local_path .. PATHSEP .. "user") or USERDIR) .. PATHSEP .. "plugins",
    self.lite_xl.datadir_path .. PATHSEP .. "plugins"
  }
  for i, plugin_path in ipairs(common.grep(plugin_paths, function(e) return system.stat(e) end)) do
    for j, v in ipairs(system.ls(plugin_path)) do
      local name = v:gsub("%.lua$", "")
      local path = plugin_path .. PATHSEP .. v
      local matching = hash[name] and common.grep(hash[name], function(e) return not Plugin.is_plugin_different(e.local_path, path) end)[1]
      if i == 2 or not hash[name] or not matching then
        table.insert(t, Plugin.new(nil, {
          name = name,
          type = i == 2 and (hash[name] and "bundled" or "core"),
          organization = (v:find("%.lua$") and "singleton" or "complex"),
          mod_version = self.lite_xl.mod_version,
          path = "plugins" .. PATHSEP .. v,
          version = "1.0",
          description = (hash[name] and hash[name][1].description or nil)
        }))
      end
    end
  end
  self.all_plugins_cache = t
  return t
end

function Bottle:installed_plugins()
  return common.grep(self:all_plugins(), function(p) return p:is_installed(self) end)
end

function Bottle:get_plugin(name, version, filter)
  local candidates = {}
  local wildcard = name:find("%*$")
  filter = filter or {}
  for i,plugin in ipairs(self:all_plugins()) do
    if not version and plugin.provides then 
      for k, provides in ipairs(plugin.provides) do
        if provides == name then
          table.insert(candidates, plugin)
        end
      end
    end
    if (plugin.name == name or (wildcard and plugin.name:find("^" .. name:sub(1, #name - 1)))) and match_version(plugin.version, version) then
      if (not filter.mod_version or not plugin.mod_version or tonumber(plugin.mod_version) == tonumber(filter.mod_version)) then
        table.insert(candidates, plugin)
      end
    end
  end  
  return table.unpack(common.sort(candidates, function (a,b) return a.version < b.version end))
end


local function get_repository(url)
  if not url then error("requires a repository url") end
  local r = Repository.url(url)
  for i,v in ipairs(repositories) do
    if v.remote == r.remote and v.branch == r.branch and v.commit == r.commit then return i, v end
  end
  return nil
end


local function lpm_repo_save()
  local directory = CACHEDIR .. PATHSEP .. "repos"
  common.mkdirp(directory)
  common.write(directory .. PATHSEP .. "list", common.join("", common.map(repositories, function(r) return r:url() .. "\n" end)))
end


local DEFAULT_REPOS
local function lpm_repo_init()
  DEFAULT_REPOS = { Repository.url("https://github.com/adamharrison/lite-xl-plugin-manager.git:latest") }
  if not system.stat(CACHEDIR .. PATHSEP .. "repos") then
    for i, repository in ipairs(DEFAULT_REPOS) do
      if not system.stat(repository.local_path) or not system.stat(repository.local_path .. PATHSEP .. (repository.commit or repository.branch)) then 
        table.insert(repositories, repository:add(true))
      end
    end
    lpm_repo_save()
  end
end




local function lpm_repo_add(...)
  for i, url in ipairs({ ... }) do
    local idx, repo = get_repository(url)
    if repo then -- if we're alreayd a repo, put this at the head of the resolution list
      table.remove(repositories, idx)
    else
      repo = Repository.url(url):add(AUTO_PULL_REMOTES and "recursive" or false)
    end
    table.insert(repositories, 1, repo)
    repo:update()
  end
  lpm_repo_save()
end


local function lpm_repo_rm(...)
  for i, url in ipairs({ ... }) do
    local idx, repo = get_repository(url)
    if not repo then error("cannot find repository " .. url) end
    table.remove(repositories, idx)
    repo:remove()
  end
  lpm_repo_save()
end


local function lpm_repo_update(...)
  local t = { ... }
  if #t == 0 then table.insert(t, false) end
  for i, url in ipairs(t) do
    local repo = url and get_repository(url)
    for i,v in ipairs(repositories) do 
      if not repo or v == repo then 
        v:update(AUTO_PULL_REMOTES and "recursive" or false) 
      end 
    end
  end
end

local function get_lite_xl(version)
  return common.first(common.concat(lite_xls, common.flat_map(repositories, function(e) return e.lite_xls end)), function(lite_xl) return lite_xl.version == version end)
end

local function lpm_lite_xl_save()
  common.mkdirp(CACHEDIR .. PATHSEP .. "lite_xls")
  common.write(CACHEDIR .. PATHSEP .. "lite_xls" .. PATHSEP .. "locals.json",
    json.encode(common.map(common.grep(lite_xls, function(l) return l:is_local() and not l:is_system() end), function(l) return { version = l.version, mod_version = l.mod_version, path = l.path } end))
  )
end

local function lpm_lite_xl_add(version, path)
  if not version then error("requires a version") end
  if not path then error("requires a path") end
  if not system.stat(path .. PATHSEP .. "lite-xl") then error("can't find " .. path .. PATHSEP .. "lite-xl") end
  if not system.stat(path .. PATHSEP .. "data") then error("can't find " .. path .. PATHSEP .. "data") end
  table.insert(lite_xls, LiteXL.new(nil, { version = version, path = path:gsub(PATHSEP .. "$", ""), mod_version = MOD_VERSION or 3 }))
  lpm_lite_xl_save()
end

local function lpm_lite_xl_rm(version)
  if not version then error("requires a version") end
  local lite_xl = get_lite_xl(version) or error("can't find lite_xl version " .. version)
  lite_xls = common.grep(lite_xls, function(l) return l ~= lite_xl end)
  lpm_lite_xl_save()
end

local function lpm_lite_xl_install(version)
  if not version then error("requires a version") end
  (get_lite_xl(version) or error("can't find lite-xl version " .. version)):install()
end


local function lpm_lite_xl_switch(version, target)
  if not version then error("requires a version") end
  target = target or common.path("lite-xl")
  if not target then error("can't find installed lite-xl. please provide a target to install the symlink explicitly as a second argument") end
  local lite_xl = get_lite_xl(version) or error("can't find lite-xl version " .. version)
  if not lite_xl:is_installed() then log_action("Installing lite-xl " .. lite_xl.version) lite_xl:install() end
  local stat = system.stat(target)
  if stat and stat.symlink then os.remove(target) end
  system.symlink(lite_xl.binary_path, target)
  if not common.path('lite-xl') then 
    os.remove(target)
    error(target .. " is not on your $PATH; please supply a target that can be found on your $PATH, called `lite-xl`.")
  end
end


local function lpm_lite_xl_uninstall(version)
  (get_lite_xl(version) or error("can't find lite-xl version " .. version)):uninstall()
end


local function lpm_lite_xl_list()
  local result = { ["lite-xl"] = { } }
  local max_version = 0
  for i,lite_xl in ipairs(lite_xls) do
    table.insert(result["lite-xl"], {
      version = lite_xl.version,
      mod_version = lite_xl.mod_version,
      tags = lite_xl.tags,
      is_system = lite_xl:is_system(),
      is_installed = lite_xl:is_installed(),
      status = (lite_xl:is_installed() or lite_xl:is_system()) and (lite_xl:is_local() and "local" or "installed") or "available",
      local_path = lite_xl.local_path
    })
    max_version = math.max(max_version, #lite_xl.version)
  end
  for i,repo in ipairs(repositories) do
    if not repo.lite_xls then error("can't find lite-xl for repo " .. repo:url()) end
    for j, lite_xl in ipairs(repo.lite_xls) do
      table.insert(result["lite-xl"], {
        version = lite_xl.version,
        mod_version = lite_xl.mod_version,
        repository = repo:url(),
        tags = lite_xl.tags,
        is_system = lite_xl:is_system(),
        is_installed = lite_xl:is_installed(),
        status = (lite_xl:is_installed() or lite_xl:is_system()) and (lite_xl:is_local() and "local" or "installed") or "available",
        local_path = lite_xl.local_path
      })
      max_version = math.max(max_version, #lite_xl.version)
    end
  end
  if JSON then
    io.stdout:write(json.encode(result) .. "\n")
  else
    if VERBOSE then
      for i, lite_xl in ipairs(result["lite-xl"]) do
        if i ~= 0 then print("---------------------------") end
        print("Version:       " .. lite_xl.version)
        print("Status:        " .. lite_xl.status)
        print("Mod-Version:   " .. (lite_xl.mod_version or "unknown"))
        print("Tags:          " .. common.join(", ", lite_xl.tags))
      end
    else
      max_version = max_version + 2
      print(string.format("%" .. max_version .. "s | %10s | %s", "Version", "Status", "Location"))
      print(string.format("%" .. max_version .."s | %10s | %s", "-------", "---------", "---------------------------"))
      for i, lite_xl in ipairs(result["lite-xl"]) do
        print(string.format("%" .. max_version .. "s | %10s | %s", (lite_xl.is_system and "* " or "") .. lite_xl.version, lite_xl.status, (lite_xl.is_installed and lite_xl.local_path or lite_xl.repository)))
      end
    end
  end
end

local function lpm_lite_xl_run(version, ...)
  if not version then error("requires a version") end
  local lite_xl = get_lite_xl(version) or error("can't find lite-xl version " .. version)
  local plugins = {}
  local arguments = { ... }
  local i = 1
  while i < #arguments and arguments[i] ~= "--" do
    local str = arguments[i] 
    local name, version = common.split(":", str)
    local plugin = system_bottle:get_plugin(name, version, { mod_version = lite_xl.mod_version })
    if not plugin then error("can't find plugin " .. str) end
    table.insert(plugins, plugin)
    i = i + 1
  end
  local bottle = Bottle.new(lite_xl, plugins)
  if not bottle:is_constructed() then bottle:construct() end
  bottle:run(common.splice(arguments, i + 1))
end


local function lpm_install(...)
  for i, identifier in ipairs({ ... }) do
    local s = identifier:find(":")
    local name, version = (s and identifier:sub(1, s-1) or identifier), (s and identifier:sub(s+1) or nil)
    if not name then error('unrecognized identifier ' .. identifier) end
    if name == "lite-xl" then
      lpm_lite_xl_install(version)
    else
      local potential_plugins = { system_bottle:get_plugin(name, version, { mod_version = system_bottle.lite_xl.mod_version }) }
      local plugins = common.grep(potential_plugins, function(e) return not e:is_installed(system_bottle) end)
      if #plugins == 0 and #potential_plugins == 0 then error("can't find plugin " .. name .. " mod-version: " .. (system_bottle.lite_xl.mod_version or 'any')) end
      if #plugins == 0 then error("plugin " .. name .. " already installed") end
      for j,v in ipairs(plugins) do v:install(system_bottle) end
    end
  end
end


local function lpm_plugin_uninstall(...)
  for i, name in ipairs({ ... }) do
    local plugins = { system_bottle:get_plugin(name) }
    if #plugins == 0 then error("can't find plugin " .. name) end
    local installed_plugins = common.grep(plugins, function(e) return e:is_installed(system_bottle) end)
    if #installed_plugins == 0 then error("plugin " .. name .. " not installed") end
    for i, plugin in ipairs(installed_plugins) do plugin:uninstall(system_bottle) end
  end
end

local function lpm_plugin_reinstall(...) for i, name in ipairs({ ... }) do pcall(lpm_plugin_uninstall, name) end lpm_install(...) end

local function lpm_repo_list() 
  if JSON then
    io.stdout:write(json.encode({ repositories = common.map(repositories, function(repo) return { remote = repo.remote, commit = repo.commit, branch = repo.branch, path = repo.local_path .. PATHSEP .. (repo.commit or repo.branch), remotes = common.map(repo.remotes or {}, function(r) return r:url() end)  } end) }) .. "\n")
  else
    for i, repository in ipairs(repositories) do
      local _, remotes = repository:parse_manifest()
      if i ~= 0 then print("---------------------------") end
      print("Remote :  " .. repository:url())
      print("Path   :  " .. repository.local_path .. PATHSEP .. (repository.commit or repository.branch))
      print("Remotes:  " .. json.encode(common.map(repository.remotes or {}, function(r) return r:url() end)))
    end
  end
end

local function lpm_plugin_list(name) 
  local max_name = 4
  local result = { plugins = { } }
  for j,plugin in ipairs(common.grep(system_bottle:all_plugins(), function(p) return not name or p.name:find(name) end)) do
    max_name = math.max(max_name, #plugin.name)
    local repo = plugin.repository
    table.insert(result.plugins, {
      name = plugin.name,
      status = plugin.repository and (plugin:is_installed(system_bottle) and "installed" or (system_bottle.lite_xl:is_compatible(plugin) and "available" or "incompatible")) or (plugin:is_bundled(system_bottle) and "bundled" or (plugin:is_core(system_bottle) and "core" or (plugin:is_upgradable(system_bottle) and "upgradable" or "orphan"))),
      version = "" .. plugin.version,
      dependencies = plugin.dependencies,
      description = plugin.description,
      author = plugin.author or (plugin:is_core(system_bottle) and "lite-xl"),
      mod_version = plugin.mod_version,
      tags = plugin.tags,
      type = plugin.type,
      organization = plugin.organization,
      repository = repo and repo:url(),
      path = plugin:get_path(system_bottle)
    })
  end
  if JSON then
    io.stdout:write(json.encode(result) .. "\n")
  elseif #result.plugins > 0 then
    if not VERBOSE then
      print(string.format("%" .. max_name .."s | %10s | %10s | %s", "Name", "Version", "ModVer", "Status"))
      print(string.format("%" .. max_name .."s | %10s | %10s | %s", string.rep("-", max_name), "-------", "------", "-----------"))
    end
    for i, plugin in ipairs(common.sort(result.plugins, function(a,b) return a.name < b.name end)) do
      if VERBOSE then
        if i ~= 0 then print("---------------------------") end
        print("Name:          " .. plugin.name)
        print("Version:       " .. plugin.version)
        print("Status:        " .. plugin.status)
        print("Author:        " .. (plugin.author or ""))
        print("Type:          " .. plugin.type)
        print("Orgnization:   " .. plugin.organization)
        print("Repository:    " .. (plugin.repository or "orphan"))
        print("Description:   " .. (plugin.description or ""))
        print("Mod-Version:   " .. (plugin.mod_version or "unknown"))
        print("Dependencies:  " .. json.encode(plugin.dependencies))
        print("Tags:          " .. common.join(", ", plugin.tags))
        print("Path:          " .. plugin.path)
      elseif plugin.status ~= "incompatible" then
        print(string.format("%" .. max_name .."s | %10s | %10s | %s", plugin.name, plugin.version, plugin.mod_version, plugin.status))
      end
    end
  end
end

local function lpm_describe()
  for i,v in ipairs(repositories) do
    if #common.grep(DEFAULT_REPOS, function(r) return r:url() == v:url() end) == 0 then
      io.stdout:write("lpm add " .. v:url() .. " && ")
    end
  end
  print("lpm run " .. system_bottle.lite_xl.version .. " " .. common.join(" ", common.map(system_bottle:installed_plugins(), function(p) return p.name .. ":" .. p.version end)))
end

local function lpm_plugin_upgrade()
  for i,plugin in ipairs(system_bottle:installed_plugins()) do
    local upgrade = common.sort(system_bottle:get_plugin(plugin.name, ">" .. plugin.version), function(a, b) return compare_version(b.version, a.version) end)[1]
    if upgrade then upgrade:install(system_bottle) end
  end
end

local function lpm_purge()
  -- local path = common.path("lite-xl")
  -- if path then
  --   local lite_xl = get_lite_xl("system")
  --   if lite_xl then
  --     os.remove(path)
  --     system.symlink(lite_xl:get_binary_path(), target)
  --     log_action("Reset lite-xl symlink to system.")
  --   end
  -- end
  log_action("Removed " .. CACHEDIR .. ".")
  common.rmrf(CACHEDIR)
end

local function parse_arguments(arguments, options)
  local args = {}
  local i = 1
  while i <= #arguments do
    local s,e, option, value = arguments[i]:find("%-%-([^=]+)=?(.*)")
    if s then
      local flag_type = options[option]
      if not flag_type then error("unknown flag --" .. option) end
      if flag_type == "flag" then
        args[option] = true
      elseif flag_type == "string" or flag_type == "number" then
        if not value or value == "" then
          if i == #arguments then error("option " .. option .. " requires a " .. flag_type) end
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
      io.stderr:write(json.encode({ error = err, actions = actions, warnings = warnings, traceback = debug.traceback() }) .. "\n")
    else
      io.stderr:write(json.encode({ error = message or err, actions = actions, warnings = warnings }) .. "\n")
    end
  else
    io.stderr:write((not VERBOSE and message or err) .. "\n")
    if VERBOSE then io.stderr:write(debug.traceback() .. "\n") end
  end
  status = -1
end

local function run_command(ARGS)
  if not ARGS[2]:find("%S") then return
  elseif ARGS[2] == "init" then return
  elseif ARGS[2] == "repo" and ARGV[3] == "add" then lpm_repo_add(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "repo" and ARGS[3] == "rm" then lpm_repo_rm(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "add" then lpm_repo_add(table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "rm" then lpm_repo_rm(table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "update" then lpm_repo_update(table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "repo" and ARGS[3] == "update" then lpm_repo_update(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "repo" and (#ARGS == 2 or ARGS[3] == "list") then return lpm_repo_list()
  elseif ARGS[2] == "plugin" and ARGS[3] == "install" then lpm_install(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "plugin" and ARGS[3] == "uninstall" then lpm_plugin_uninstall(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "plugin" and ARGS[3] == "reinstall" then lpm_plugin_reinstall(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "plugin" and (#ARGS == 2 or ARGS[3] == "list") then return lpm_plugin_list(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "plugin" and ARGS[3] == "upgrade" then return lpm_plugin_upgrade(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "upgrade" then return lpm_plugin_upgrade(table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "install" then lpm_install(table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "uninstall" then lpm_plugin_uninstall(table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "reinstall" then lpm_plugin_reinstall(table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "describe" then lpm_describe(table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "list" then return lpm_plugin_list(table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "lite-xl" and (#ARGS == 2 or ARGS[3] == "list") then return lpm_lite_xl_list(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "lite-xl" and ARGS[3] == "uninstall" then return lpm_lite_xl_uninstall(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "lite-xl" and ARGS[3] == "install" then return lpm_lite_xl_install(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "lite-xl" and ARGS[3] == "switch" then return lpm_lite_xl_switch(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "lite-xl" and ARGS[3] == "run" then return lpm_lite_xl_run(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "lite-xl" and ARGS[3] == "add" then return lpm_lite_xl_add(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "lite-xl" and ARGS[3] == "rm" then return lpm_lite_xl_rm(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "run" then return lpm_lite_xl_run(table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "switch" then return lpm_lite_xl_switch(table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "purge" then lpm_purge()
  else error("unknown command: " .. ARGS[2]) end
  if JSON then
    io.stdout:write(json.encode({ actions = actions, warnings = warnings }))
  end
end


xpcall(function()
  local ARGS = parse_arguments(ARGV, { 
    json = "flag", userdir = "string", cachedir = "string", version = "flag", verbose = "flag", 
    quiet = "flag", version = "string", ["mod-version"] = "string", remotes = "flag", help = "flag",
    remotes = "flag", ["ssl-certs"] = "string", force = "flag", arch = "string", ["assume-yes"] = "flag",
    ["install-optional"] = "flag", datadir = "string", binary = "string", trace = "flag"
  })
  if ARGS["version"] then
    io.stdout:write(VERSION .. "\n")
    return 0
  end
  if ARGS["help"] or #ARGS == 1 or ARGS[2] == "help" then
    io.stderr:write([[
Usage: lpm COMMAND [...ARGUMENTS] [--json] [--userdir=directory] 
  [--cachedir=directory] [--quiet] [--version] [--help] [--remotes]
  [--ssl-certs=directory/file] [--force] [--arch=]] .. _G.ARCH .. [[]
  [--assume-yes] [--no-install-optional] [--verbose] [--mod-version=3]
  [--datadir=directory] [--binary=path] [--post]

LPM is a package manager for `lite-xl`, written in C (and packed-in lua).

It's designed to install packages from our central github repository (and
affiliated repositories), directly into your lite-xl user directory. It can
be called independently, for from the lite-xl `plugin_manager` plugin.

LPM will always use https://github.com/lite-xl/lite-xl-plugins as its base
repository, if none are present, and the cache directory does't exist,
but others can be added, and this base one can be removed.

It has the following commands:

  lpm init                                 Implicitly called before all commands
                                           if necessary, but can be called
                                           independently to save time later.
  lpm repo list                            List all extant repos.
  lpm [repo] add <repository remote>       Add a source repository.
    [...<repository remote>] 
  lpm [repo] rm <repository remote>        Remove a source repository.
    [...<repository remote>]
  lpm [repo] update [<repository remote>]  Update all/the specified repos.
    [...<repository remote>]        
  lpm [plugin] install                     Install specific plugins.
    <plugin name>[:<version>]              If installed, upgrades.
    [...<plugin name>:<version>]                     
  lpm [plugin] uninstall <plugin name>     Uninstall the specific plugin.
    [...<plugin name>]
  lpm [plugin] reinstall <plugin name>     Uninstall and installs the specific plugin.
    [...<plugin name>]
  lpm [plugin] list <repository remote>    List all/associated plugins.
    [...<repository remote>]    
  lpm [plugin] upgrade                     Upgrades all installed plugins 
                                           to new version if applicable.
  lpm [lite-xl] install <version>          Installs lite-xl. Infers the
    [binary] [datadir]                     paths on your system if not
                                           supplied. Automatically
                                           switches to be your system default
                                           if path auto inferred.
  lpm lite-xl add <version> <path>         Adds a local version of lite-xl to
                                           the managed list, allowing it to be
                                           easily bottled.
  lpm lite-xl remove <path>                Removes a local version of lite-xl
                                           from the managed list.
  lpm [lite-xl] switch <version> [<path>]  Sets the active version of lite-xl
                                           to be the specified version. Auto-detects
                                           current install of lite-xl; if none found
                                           path can be specifeid.
  lpm lite-xl list                         Lists all installed versions of
                                           lite-xl.
  lpm run <version> [...plugins]           Sets up a "bottle" to run the specified
                                           lite version, with the specified plugins
                                           and then opens it.
  lpm describe [bottle]                    Describes the bottle specified in the form
                                           of a list of commands, that allow someone
                                           else to run your configuration.
          
  lpm purge                                Completely purge all state for LPM.
  lpm -                                    Read these commands from stdin in
                                           an interactive print-eval loop.
  lpm help                                 Displays this help text.

Flags have the following effects:

  --json                   Performs all communication in JSON.
  --userdir=directory      Sets the lite-xl userdir manually.
                           If omitted, uses the normal lite-xl logic.
  --cachedir=directory     Sets the directory to store all repositories.
  --tmpdir=directory       During install, sets the staging area.
  --datadir=directory      Sets the data directory where core plugins are located
                           for the system lite-xl.
  --binary=path            Sets the lite-xl binary path for the system lite-xl.
  --verbose                Spits out more information, including intermediate
                           steps to install and whatnot.
  --quiet                  Outputs nothing but explicit responses.
  --mod-version            Sets the mod version of lite-xl to install plugins.
  --version                Returns version information.
  --help                   Displays this help text.
  --ssl-certs              Sets the SSL certificate store. Can be a directory,
                           or path to a certificate bundle.
  --arch                   Sets the architecture (default: ]] .. _G.ARCH .. [[).
  --assume-yes             Ignores any prompts, and automatically answers yes
                           to all.
  --no-install-optional    On install, anything marked as optional
                           won't prompt.
  --trace                  Dumps to STDERR useful debugging information, in
                           particular information relating to SSL connections,
                           and other network activity.

There also several flags which are classified as "risky", and are never enabled
in any circumstance unless explicitly supplied.

  --force                  Ignores checksum inconsistencies. 
  --post                   Run post-install build steps. Must be explicitly enabled.
                           Official repositories must function without this
                           flag being needed; generally they must provide
                           binaries if there is a native compilation step.
  --remotes                Automatically adds any specified remotes in the 
                           repository to the end of the resolution list.
  --ssl-certs=noverify     Ignores SSL certificate validation. Opens you up to
                           man-in-the-middle attacks.
]]
    )
    return 0
  end
  
  VERBOSE = ARGS["verbose"] or false
  JSON = ARGS["json"] or os.getenv("LPM_JSON")
  QUIET = ARGS["quiet"] or os.getenv("LPM_QUIET")
  FORCE = ARGS["force"]
  POST = ARGS["post"]
  DATADIR = common.normalize_path(ARGS["datadir"])
  BINARY = common.normalize_path(ARGS["binary"])
  NO_INSTALL_OPTIONAL = ARGS["no-install-optional"]
  ARCH = ARGS["arch"] or _G.ARCH
  ASSUME_YES = ARGS["assume-yes"] or FORCE
  MOD_VERSION = ARGS["mod-version"] or os.getenv("LPM_MODVERSION")
  if MOD_VERSION == "any" then MOD_VERSION = nil end
  HOME = (os.getenv("USERPROFILE") or os.getenv("HOME")):gsub(PATHSEP .. "$", "")
  USERDIR = common.normalize_path(ARGS["userdir"]) or os.getenv("LITE_USERDIR") or (os.getenv("XDG_CONFIG_HOME") and os.getenv("XDG_CONFIG_HOME") .. PATHSEP .. "lite-xl")
    or (HOME and (HOME .. PATHSEP .. '.config' .. PATHSEP .. 'lite-xl'))
  AUTO_PULL_REMOTES = ARGS["remotes"]
  if not system.stat(USERDIR) then common.mkdirp(USERDIR) end
  CACHEDIR = common.normalize_path(ARGS["cachedir"]) or os.getenv("LPM_CACHE") or USERDIR .. PATHSEP .. "lpm"
  TMPDIR = common.normalize_path(ARGS["tmpdir"]) or CACHEDIR .. PATHSEP .. "tmp"
  if ARGS["trace"] then system.trace(true) end

  if not QUIET then
    local start_time, last_read
    local function format_bytes(bytes)
      if bytes < 1024 then return string.format("%6d  B", math.floor(bytes)) end
      if bytes < 1*1024*1024 then return string.format("%6.1f kB", bytes / 1024) end
      if bytes < 1*1024*1024*1024 then return string.format("%6.1f MB", bytes / (1024*1024))  end
      return string.format("%6.2f GB", bytes / (1024*1024*1024)) 
    end
    write_progress_bar = function(total_read, total_objects, indexed_obejcts, received_objects, local_objects, local_deltas, indexed_deltas)
      if type(total_read) == "boolean" then
        io.stdout:write("\n")
        io.stdout:flush()
        return
      end
      if not start_time or total_read < last_read then start_time = os.time() end
      local status_line = string.format("%s [%s/s]: %s", format_bytes(total_read), format_bytes(total_read / math.max(os.time() - start_time, 1)), progress_bar_label)
      io.stdout:write(string.rep("\b", #status_line))
      io.stdout:write(status_line)
      io.stdout:flush()
      last_read = total_read
    end
  end

  repositories = {}
  if ARGS[2] == "purge" then return lpm_purge() end
  local ssl_certs = ARGS["ssl-certs"] or os.getenv("SSL_CERT_DIR") or os.getenv("SSL_CERT_FILE")
  if ssl_certs then 
    if ssl_certs == "noverify" then
      system.certs("noverify")
    else
      local stat = system.stat(ssl_certs)
      if not stat then error("can't find " .. ssl_certs) end
      system.certs(stat.type, ssl_certs)
    end
  else
    local paths = { -- https://serverfault.com/questions/62496/ssl-certificate-location-on-unix-linux#comment1155804_62500
      "/etc/ssl/certs/ca-certificates.crt",                -- Debian/Ubuntu/Gentoo etc.
      "/etc/pki/tls/certs/ca-bundle.crt",                  -- Fedora/RHEL 6
      "/etc/ssl/ca-bundle.pem",                            -- OpenSUSE
      "/etc/pki/tls/cacert.pem",                           -- OpenELEC
      "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", -- CentOS/RHEL 7
      "/etc/ssl/cert.pem",                                 -- Alpine Linux (and Mac OSX)
      "/etc/ssl/certs",                                    -- SLES10/SLES11, https://golang.org/issue/12139
      "/system/etc/security/cacerts",                      -- Android
      "/usr/local/share/certs",                            -- FreeBSD
      "/etc/pki/tls/certs",                                -- Fedora/RHEL
      "/etc/openssl/certs",                                -- NetBSD
      "/var/ssl/certs",                                    -- AIX
    }
    if PLATFORM == "windows" then
      common.mkdirp(TMPDIR)
      system.certs("system", TMPDIR .. PATHSEP .. "certs.crt")
    else
      local has_certs = false
      for i, path in ipairs(paths) do
        local stat = system.stat(path) 
        if stat then 
          has_certs = true
          system.certs(stat.type, path) 
          break 
        end
      end
      if not has_certs then error("can't autodetect your system's SSL ceritficates; please specify specify a certificate bundle or certificate directory with --ssl-certs") end
    end
  end

  -- Small utility functions that don't play into the larger app; are used for testing
  -- or for handy scripts.
  if ARGS[2] == "download" then
    local file = common.get(ARGS[3]);
    print(file)
    os.exit(0)
  end
  if ARGS[2] == "extract" then
    system.extract(ARGS[3], ARGS[4] or ".")
    os.exit(0)
  end
  if ARGS[2] == "table" then
    local plugins = json.decode(common.read(ARGS[3]))["plugins"]
    table.sort(plugins, function(a,b) return string.lower(a.name) < string.lower(b.name) end)
    local names = common.map(plugins, function(plugin) 
      if plugin.path then return string.format("[`%s`](%s?raw=1)", plugin.name, plugin.path) end
      if plugin.url then return string.format("[`%s`](%s)", plugin.name, plugin.url) end
      if plugin.remote then return string.format("[`%s`](%s)\\*", plugin.name, plugin.remote:gsub(":%w+$")) end
      return plugin.name
    end)
    local descriptions = common.map(plugins, function(e) return e.description or "" end)
    local max_description = math.max(table.unpack(common.map(descriptions, function(e) return #e end)))
    local max_name = math.max(table.unpack(common.map(names, function(e) return #e end)))
    print("| Plugin" .. string.rep(" ", max_name - 6) .. " | Description" .. string.rep(" ", max_description - 11) .. " |")
    print("| :" .. string.rep("-", max_name-1) .. " | :" .. string.rep("-", max_description - 1) .. " |")
    for i = 1, #plugins do
      print("| " .. names[i] .. string.rep(" ", max_name - #names[i]) .. " | " .. descriptions[i] .. string.rep(" ", max_description - #descriptions[i]) .. " |")
    end
    os.exit(0)
  end

  -- Base setup; initialize default repos if applicable, read them in. Determine Lite XL system binary if not specified, and pull in a list of all local lite-xl's.
  lpm_repo_init()
  repositories, lite_xls = {}, {}
  if system.stat(CACHEDIR .. PATHSEP .. "repos" .. PATHSEP .. "list") then
    for url in io.lines(CACHEDIR .. PATHSEP .. "repos" .. PATHSEP .. "list") do
      table.insert(repositories, Repository.url(url))
      repositories[#repositories]:parse_manifest()
    end
  end
  if system.stat(CACHEDIR .. PATHSEP .. "lite_xls" .. PATHSEP .. "locals.json") then
    for i, lite_xl in ipairs(json.decode(common.read(CACHEDIR .. PATHSEP .. "lite_xls" .. PATHSEP .. "locals.json"))) do
      table.insert(lite_xls, LiteXL.new(nil, { version = lite_xl.version, mod_version = lite_xl.mod_version, path = lite_xl.path, tags = { "local" } }))
    end
  end
  local lite_xl_binary = BINARY or common.path("lite-xl")
  if lite_xl_binary then
    local stat = system.stat(lite_xl_binary)
    if not stat then error("can't find lite-xl binary " .. lite_xl_binary) end
    lite_xl_binary = stat.symlink or lite_xl_binary
    local directory = common.dirname(lite_xl_binary)
    local hash = system.hash(lite_xl_binary, "file")
    local system_lite_xl = common.first(common.concat(common.flat_map(repositories, function(r) return r.lite_xls end), lite_xls), function(lite_xl) return lite_xl.local_path == directory end)
    if not system_lite_xl then 
      system_lite_xl = common.first(lite_xls, function(e) return e.version == "system" end)
      if system_lite_xl then error("can't find existing system lite (does " .. system_lite_xl.binary_path .. " exist? was it moved?); run `lpm purge`, or specify --binary and --datadir.") end
      system_lite_xl = LiteXL.new(nil, { datadir_path = DATADIR, binary_path = BINARY, mod_version = MOD_VERSION or 3, version = "system", tags = { "system", "local" } })
      table.insert(lite_xls, system_lite_xl)
      lpm_lite_xl_save()
    else
      table.insert(system_lite_xl.tags, "system")
    end
    system_bottle = Bottle.new(system_lite_xl, nil, true) 
  else
    system_bottle = Bottle.new(LiteXL.new(nil, { mod_version = MOD_VERSION or 3, version = "system", tags = { "system", "local" } }), nil, true)
  end
  if not system_bottle then system_bottle = Bottle.new(nil, nil, true) end
  
  if ARGS[2] ~= '-' then
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
      actions, warnings = {}, {}
    end
  end

end, error_handler)


return status
