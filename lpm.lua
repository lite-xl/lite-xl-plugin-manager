local strict = {}
strict.defined = {}

-- used to define a global variable
function global(t)
  for k, v in pairs(t) do
    strict.defined[k] = true
    rawset(_G, k, v)
  end
end

function strict.__newindex(t, k, v)
  error("cannot set undefined variable: " .. k, 2)
end

function strict.__index(t, k)
  if not strict.defined[k] then
    error("cannot get undefined variable: " .. k, 2)
  end
end

setmetatable(_G, strict)


-- Begin JSON library.
--
-- json.lua
--
-- Copyright (c) 2020 rxi
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy of
-- this software and associated documentation files (the "Software"), to deal in
-- the Software without restriction, including without limitation the rights to
-- use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
-- of the Software, and to permit persons to whom the Software is furnished to do
-- so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.
--

local json = { _version = "0.1.2" }

-------------------------------------------------------------------------------
-- Encode
-------------------------------------------------------------------------------

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


-------------------------------------------------------------------------------
-- Decode
-------------------------------------------------------------------------------

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
  return path:sub(#path - s + 1)
end


function common.merge(src, merge)
  for k, v in pairs(merge) do src[k] = v end
  return src
end

function common.copy(src, dst)
  local src_stat, dst_stat = system.stat(src), system.stat(dst)
  if not src_stat then error("can't find " .. src) end
  if dst_stat and dst_stat.type == "dir" and src_stat.type == "file" then return common.copy(src, dst .. PATHSEP .. common.basename(src)) end
  if dst_stat then error("path " .. dst .. " exists") end
  local src_io, dst_io = io.open(src, "rb"), io.write(dst, "wb")
  while true do
    local chunk = src_io:read(16*1024)
    if not chunk then break end
    dst_io:write(chunk)
  end
end

local HOME, USERDIR, CACHEDIR, JSON, repositories

local Plugin = {}

local Plugin = { __index = function(self, idx) return rawget(self, idx) or Plugin[idx] end }
function Plugin.new(repository, metadata)
  local self = setmetatable(common.merge({
    repository = repository,
    tags = {},
    remote = nil,
    path = nil,
    status = "available",
    version = "1.0",
    dependencies = {},
    local_path = repository.local_path .. PATHSEP .. "repo" .. PATHSEP .. metadata.name,
    install_path = USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. metadata.name,
  }, metadata), Plugin)
  -- Directory.
  if system.stat(self.install_path) then
    self.status = "installed"
  end
  -- Single file.
  if system.stat(self.install_path .. ".lua") then
    self.status = "installed"
  end
  return self
end

function Plugin:install()
  common.copy(self.local_path, self.install_path)
end


function Plugin:uninstall()
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
      local plugin = { description = nil, name = common.basename(file):gsub("%.lua$", ""), dependencies = {}, ["mod-version"] = 3, version = "1.0", tags = {}, path = plugin_dir .. file  }
      for line in io.lines(path .. plugin_dir .. file) do
        local _, _, mod_version = line:find("--.*mod-version:%s*(%w+)")
        if mod_version then plugin["mod-version"] = mod_version end
        local _, _, lite_version = line:find("--.*lite-xl%s*:?%s*(%w+)")
        if lite_version then plugin["lite-version"] = lite_version end
        local _, _, required_plugin = line:find("require [\"']plugins.(%w+)")
        if required_plugin then plugin.dependencies[required_plugin] = ">=1.0" end
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
    system.init(path, self.remote)
    if not pcall(system.reset, "refs/heads/master") then
      if pcall(system.reset, "refs/heads/main") then
        os.rename(path, self.local_path .. PATHSEP .. "main")
      else
        error("Can't find master or main.")
      end
    end
  else
    local path = self.local_path .. PATHSEP .. (self.commit or self.branch)
    common.mkdirp(path)
    system.init(path, self.remote)
    system.fetch(path)
    system.reset(path, self.commit or ("refs/remotes/origin/" .. self.branch), "hard")
    self.manifest = nil
    self:parse_manifest()
  end
end


function Repository:update()
  if self.branch then
    local path = self.local_path .. PATHSEP .. self.branch
    system.fetch(path)
    system.reset(path, "refs/remotes/origin/" .. self.branch, "hard")
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


local function match_version(version, pattern)
  return not pattern or version == pattern
end


local function get_plugin(name, version)
  local candidates = {}
  for i,repo in ipairs(repositories) do
    for j,plugin in ipairs(repo.plugins) do
      if match_version(plugin.version, version) then
        table.insert(candidates, plugin)
      end
    end
  end
  return table.unpack(table.sort(candidates, function (a,b) return a.version < b.version end))
end


local function lpm_add(url)
  local idx, repo = get_repository(url)
  if repo then -- if we're alreayd a repo, put this at the head of the resolution list
    table.remove(repositories, idx)
  else
    repo = Repository.new(url):add()
  end
  table.insert(repositories, 1, repo)
  repo:update()
end


local function lpm_rm(url)
  local idx, repo = get_repository(url)
  if not repo then error("cannot find repository " .. url) end
  table.remove(repositories, idx)
  repo:remove()
end


local function lpm_update(url)
  local repo = url and get_repository(url)
  for i,v in ipairs(repositories) do if not repo or v == repo then v:update() end end
end


local function lpm_install(name, version)
  local plugin = get_plugin(name, version)
  if not plugin then error("can't find plugin " .. name) end
  plugin:install()
end


local function lpm_uninstall(name)
  local plugin = get_plugin(name, version)
  if not plugin then error("can't find plugin " .. name) end
  if not plugin.installed then error("plugin " .. name .. " not installed") end
  plugin:uninstall()
end


local function lpm_list() 
  local result = { plugins = { } }
  for i,repo in ipairs(repositories) do
    if not repo.plugins then error("can't find plugins for repo " .. repo.remote .. ":" .. (repo.commit or repo.branch or "master")) end
    for j,plugin in ipairs(repo.plugins) do
      table.insert(result.plugins, {
        name = plugin.name,
        status = plugin.status,
        version = "" .. plugin.version,
        dependencies = plugin.dependencies
      })
    end
  end
  if JSON then
    io.stdout:write(json.encode(result))
  else
    for i, plugin in ipairs(result.plugins) do
      if i ~= 0 then print("---------------------------") end
      print("Name:          " .. plugin.name)
      print("Version:       " .. plugin.version)
      print("Status:        " .. plugin.status)
      print("Dependencies:  " .. json.encode(plugin.dependencies))
    end
  end
end


local function lpm_purge()
  common.rmrf(CACHEDIR)
end

local function parse_arguments(arguments, options)
  local args = {}
  for i=1, #arguments do
    local s,e = arguments[i]:find("%-%-")
    if s then
      local type = options[arguments[i]:sub(e + 1)]
      if type == "flag" then
        args[arguments[i]:sub(e + 1)] = true
      end
    else
      table.insert(args, arguments[i])
    end
  end
  return args
end

local status = 0
xpcall(function()
  local ARGS = parse_arguments(ARGV, { json = "flag" })
  JSON = ARGS["json"] or os.getenv("LPM_JSON")
  HOME = (os.getenv("USERPROFILE") or os.getenv("HOME")):gsub(PATHSEP .. "$", "")
  USERDIR = os.getenv("LITE_USERDIR") or (os.getenv("XDG_CONFIG_HOME") and os.getenv("XDG_CONFIG_HOME") .. PATHSEP .. "lite-xl")
       or (HOME and (HOME .. PATHSEP .. '.config' .. PATHSEP .. 'lite-xl'))
  CACHEDIR = os.getenv("LPM_CACHE") or USERDIR .. PATHSEP .. "lpm"
  repositories = {}
  repositories = { Repository.new({ remote = "https://github.com/lite-xl/lite-xl-plugins.git", branch = "master" }) }
  if not system.stat(CACHEDIR) or not system.stat(repositories[1].local_path) then 
    common.mkdirp(repositories[1].local_path)
    repositories[1]:add()
  else
    for i, remote_hash in ipairs(system.ls(CACHEDIR)) do
      local remote
      for j, commit_or_branch in ipairs(system.ls(CACHEDIR .. PATHSEP .. remote_hash)) do
        if commit_or_branch ~= repositories[1].branch and remote_hash ~= system.hash(repositories[1].remote) then
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
  end

  if ARGV[2] == "add" then return lpm_add(ARGV[3]) end
  if ARGV[2] == "rm" then  return lpm_rm(ARGV[3]) end
  if ARGV[2] == "update" then return lpm_update(ARGV[3]) end
  if ARGV[2] == "install" then return lpm_install(ARGV[3]) end
  if ARGV[2] == "uninstall" then return lpm_uninstall(ARGV[3]) end
  if ARGV[2] == "purge" then return lpm_purge(ARGV[4]) end
  if ARGV[2] == "list" then return lpm_list() end
  io.stderr:write([[
Usage: lpm COMMAND

LPM is a package manager for `lite-xl`, written in C (and packed-in lua).

It has the following commands:

lpm add <repository remote>
lpm rm <repository remote>
lpm update [<repository remote>]
lpm install <plugin name>
lpm uninstall <plugin name>
lpm list
]])
end, function(err)
  if JSON then
    io.stderr:write(json.encode({ error = err, traceback = debug.traceback() }))
  else
    io.stderr:write(err .. "\n")
    io.stderr:write(debug.traceback() .. "\n")
  end
  status = -1
end)


return status;
