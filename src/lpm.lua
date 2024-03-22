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


local function encode_table(val, stack, options, depth)
  local res = {}
  stack = stack or {}

  -- Circular reference?
  if stack[val] then error("circular reference") end

  stack[val] = true

  if rawget(val, 1) ~= nil and next(val) ~= nil then
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
      if options.pretty then
        table.insert(res, string.rep(options.indent, depth + 1) .. encode(v, stack, options, depth + 1))
      else
        table.insert(res, encode(v, stack, options, depth + 1))
      end
    end
    stack[val] = nil
    if options.pretty then
      if #res == 0 then return "[]" end
      return "[\n" ..
          table.concat(res, ",\n") .. "\n" ..
      string.rep(options.indent, depth) .. "]"
    end
    return "[" .. table.concat(res, ",") .. "]"
  else
    -- Treat as an object
    for k, v in pairs(val) do
      if type(k) ~= "string" then
        error("invalid table: mixed or invalid key types")
      end
      if options.pretty then
        table.insert(res, string.rep(options.indent, depth + 1) .. encode(k, stack, options, depth + 1) .. ": " .. encode(v, stack, options, depth + 1))
      else
        table.insert(res, encode(k, stack, options, depth + 1) .. ":" .. encode(v, stack, options, depth + 1))
      end
    end
    stack[val] = nil
    if options.pretty then
      if #res == 0 then return "{}" end
      table.sort(res)
      return "{\n" ..
        table.concat(res, ",\n") .. "\n" ..
      string.rep(options.indent, depth) .. "}"
    end
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


encode = function(val, stack, options, depth)
  local t = type(val)
  local f = type_func_map[t]
  if f then
    return f(val, stack, options, depth)
  end
  error("unexpected type '" .. t .. "'")
end


function json.encode(val, options)
  if not options then options = {} end
  if options.pretty and not options.indent then options.indent = "  " end
  return encode(val, nil, options or {}, 0)
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
function common.map(l, p) local t = {} for i, v in ipairs(l) do table.insert(t, p(v, i)) end return t end
function common.each(l, p) for i, v in ipairs(l) do p(v) end end
function common.flat_map(l, p) local t = {} for i, v in ipairs(l) do local r = p(v) for k, w in ipairs(r) do table.insert(t, w) end end return t end
function common.concat(...) local t = {} for i, tt in ipairs({ ... }) do for j, v in ipairs(tt) do table.insert(t, v) end end return t end
function common.grep(l, p) local t = {} for i, v in ipairs(l) do if p(v) then table.insert(t, v) end end return t end
function common.first(l, p) for i, v in ipairs(l) do if (type(p) == 'function' and p(v)) or p == v then return v end end end
function common.slice(t, i, l) local n = {} for j = i, l ~= nil and (i - l) or #t do table.insert(n, t[j]) end return n end
function common.join(j, l) local s = "" for i, v in ipairs(l) do if i > 1 then s = s .. j .. v else s = v end end return s end
function common.sort(t, f) table.sort(t, f) return t end
function common.write(path, contents) local f, err = io.open(path, "wb") if not f then error("can't write to " .. path .. ": " .. err) end f:write(contents) f:flush() f:close() end
function common.read(path) local f, err = io.open(path, "rb") if not f then error("can't read from " .. path .. ": " .. err) end local str = f:read("*all") f:close() return str end
function common.uniq(l) local t = {} local k = {} for i,v in ipairs(l) do if not k[v] then table.insert(t, v) k[v] = true end end return t end
function common.delete(h, d) local t = {} for k,v in pairs(h) do if k ~= d then t[k] = v end end return t end
function common.canonical_order(hash) local t = {} for k,v in pairs(hash) do table.insert(t, k) end table.sort(t) return t end
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
function common.path(exec)
  -- On windows, in theory to resolve things, we also check the working directory even without a PATHSEP.
  if exec:find(PATHSEP) or PLATFORM == "windows" and system.stat(exec) then return exec end
  return common.first(common.map({ common.split(":", os.getenv("PATH")) }, function(e) return e .. PATHSEP .. exec end), function(e) local s = system.stat(e) return s and s.type ~= "dir" and s.mode and s.mode & 73 and (not s.symlink or system.stat(s.symlink)) end)
end
function common.normalize_path(path) if PLATFORM == "windows" and path then path = path:gsub("/", PATHSEP) end if not path or not path:find("^~") then return path end return os.getenv("HOME") .. path:sub(2) end
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
  local segments = { common.split("[/\\]", path) }
  local target
  local extant_root = 0
  for i, dirname in ipairs(segments) do -- we need to do this, incase directories earlier in the chain exist, but we don't have permission to read.
    target = target and target .. PATHSEP .. dirname or dirname
    if system.stat(target) then extant_root = i end
  end
  target = nil
  for i, dirname in ipairs(segments) do
    target = target and target .. PATHSEP .. dirname or dirname
    if i >= extant_root and target ~= "" and not target:find("^[A-Z]:$") and not system.stat(target) then system.mkdir(target) end
  end
end
function common.copy(src, dst, hidden)
  local src_stat, dst_stat = system.stat(src), system.stat(dst)
  if not src_stat then error("can't find " .. src) end
  if not hidden and common.basename(src):find("^%.") then return end
  if dst_stat and dst_stat.type == "dir" then return common.copy(src, dst .. PATHSEP .. common.basename(src), hidden) end
  if src_stat.type == "dir" then
    common.mkdirp(dst)
    for i, file in ipairs(system.ls(src)) do common.copy(src .. PATHSEP .. file, dst .. PATHSEP .. file, hidden) end
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
    src_io:close()
    system.chmod(dst, src_stat.mode)
  end
end
function common.rename(src, dst)
  if not os.rename(src, dst) then
    common.copy(src, dst)
    common.rmrf(src)
  end
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
  if not status then error(err, 0) end
end
function common.stat(path)
  local stat = system.stat(path)
  if not stat then error("can't find file or directory at " .. path) end
  return stat
end

function common.args(arguments, options)
  local args = {}
  local i = 1
  while i <= #arguments do
    local s,e, option, value = arguments[i]:find("%-%-([^=]+)=?(.*)")
    if s and options[option] then
      local flag_type = options[option]
      if flag_type == "flag" then
        args[option] = true
      elseif flag_type == "string" or flag_type == "number" or flag_type == "array" then
        if not value or value == "" then
          if i == #arguments then error("option " .. option .. " requires a " .. flag_type) end
          value = arguments[i+1]
          i = i + 1
        end
        if flag_type == "number" and tonumber(flag_type) == nil then error("option " .. option .. " should be a number") end
        if flag_type == "array" then
          args[option] = args[option] or {}
          table.insert(args[option], value)
        else
          args[option] = value
        end
      end
    else
      table.insert(args, arguments[i])
    end
    i = i + 1
  end
  return args
end

local LATEST_MOD_VERSION = "3.0.0"
local EXECUTABLE_EXTENSION = PLATFORM == "windows" and ".exe" or ""
local HOME, USERDIR, CACHEDIR, JSON, TABLE, HEADER, RAW, VERBOSE, FILTRATION, MOD_VERSION, QUIET, FORCE, REINSTALL, CONFIG,  NO_COLOR, AUTO_PULL_REMOTES, ARCH, ASSUME_YES, NO_INSTALL_OPTIONAL, TMPDIR, DATADIR, BINARY, POST, PROGRESS, SYMLINK, REPOSITORY, EPHEMERAL, MASK, settings, repositories, lite_xls, system_bottle, progress_bar_label, write_progress_bar
local SHOULD_COLOR = (PLATFORM == "windows" or (os.getenv("TERM") and os.getenv("TERM") ~= "dumb")) and not os.getenv("NO_COLOR")
local Addon, Repository, LiteXL, Bottle, lpm, log = {}, {}, {}, {}, {}, {}

local function engage_locks(func, err, warn)
  if not system.stat(CACHEDIR) then common.mkdirp(CACHEDIR) end
  local lockfile = CACHEDIR .. PATHSEP .. ".lock"
  if not system.stat(lockfile) then common.write(lockfile, "") end
  return system.flock(lockfile, func, err, warn)
end

local colors = {
  red = 31,
  green = 32,
  yellow = 33,
  blue = 34,
  cyan = 36
}
local function colorize(text, color)
  if not SHOULD_COLOR or not TTY or NO_COLOR or not color then return text end
  return "\x1B[" .. colors[color] .. "m" .. text .. "\x1B[0m"
end

local actions, warnings = {}, {}
function log.action(message, color)
  if JSON then table.insert(actions, message) end
  if not QUIET then
    io.stderr:write(colorize(message .. "\n", color))
    io.stderr:flush()
  end
end
function log.warning(message)
  if JSON then table.insert(warnings, message) end
  if not QUIET then
    io.stderr:write(colorize("warning: " .. message .. "\n", "yellow"))
    io.stderr:flush()
  end
end
function log.fatal_warning(message)
  if not FORCE then error(message .. "; use --force to override") else log.warning(message) end
end
function log.progress_action(message)
  if write_progress_bar then
    progress_bar_label = message
  else
    log.action(message)
  end
end
local function prompt(message)
  system.tcflush(0)
  if not ASSUME_YES or not JSON then
    io.stderr:write(colorize(message .. " [Y/n]: ", "cyan"))
    if ASSUME_YES then io.stderr:write("Y\n") end
    io.stderr:flush()
  end
  if ASSUME_YES then return true end
  local response = io.stdin:read("*line")
  return not response:find("%S") or response:find("^%s*[yY]%s*$")
end


function common.get(source, options)
  options = options or {}
  if not options.depth then options.depth = {} end
  table.insert(options.depth, source)
  local target, checksum, callback, depth = options.target, options.checksum or "SKIP", options.callback, options.depth
  if not source then error("requires url") end
  if #depth > 10 then error("too many redirects") end
  local _, _, protocol, hostname, port, rest = source:find("^(https?)://([^:/?]+):?(%d*)(.*)$")
  if #depth == 1 then log.progress_action("Downloading " .. options.depth[1]:sub(1, 100) .. "...") end
  if not protocol then error("malfomed url " .. source) end
  if not port or port == "" then port = protocol == "https" and 443 or 80 end
  if not rest or rest == "" then rest = "/" end
  local res, headers
  if checksum == "SKIP" and not target then
    res, headers = system.get(protocol, hostname, port, rest, target, callback)
    if headers.location then return common.get(headers.location, common.merge(options, { })) end
    return res
  end
  local cache_dir = checksum == "SKIP" and TMPDIR or (options.cache or CACHEDIR)
  if not system.stat(cache_dir .. PATHSEP .. "files") then common.mkdirp(cache_dir .. PATHSEP .. "files") end
  local cache_path = cache_dir .. PATHSEP .. "files" .. PATHSEP .. system.hash(checksum .. options.depth[1])
  if checksum ~= "SKIP" and system.stat(cache_path) and system.hash(cache_path, "file") ~= checksum then common.rmrf(cache_path) end
  local res
  if not system.stat(cache_path) then
    res, headers = system.get(protocol, hostname, port, rest, cache_path .. ".part", callback)
    if headers.location then return common.get(headers.location, common.merge(options, {  })) end
    if checksum ~= "SKIP" and system.hash(cache_path .. ".part", "file") ~= checksum then
      common.rmrf(cache_path .. ".part")
      log.fatal_warning("checksum doesn't match for " .. options.depth[1])
    end
    common.rename(cache_path .. ".part", cache_path)
  end
  if target then common.copy(cache_path, target) else res = io.open(cache_path, "rb"):read("*all") end
  if checksum == "SKIP" then common.rmrf(cache_path) end
  return res
end


-- Determines whether two addons located at different paths are actually different based on their contents.
-- If path1 is a directory, will still return true if it's a subset of path2 (accounting for binary downloads).
function common.is_path_different(path1, path2)
  local stat1, stat2 = system.stat(path1), system.stat(path2)
  if not stat1 or not stat2 or stat1.type ~= stat2.type or (stat1 == "file" and stat1.size ~= stat2.size) then return true end
  if stat1.type == "dir" then
    for i, file in ipairs(system.ls(path1)) do
      if not common.basename(file):find("^%.") and common.is_path_different(path1 .. PATHSEP .. file, path2 .. PATHSEP.. file) then return true end
    end
    return false
  end
  return system.hash(path1, "file") ~= system.hash(path2, "file")
end



local function compare_version(a, b) -- compares semver
  if not a or not b then return false end
  local _, _, majora, minora, revisiona = tostring(a):find("(%d+)%.?(%d*)%.?(%d*)")
  local _, _, majorb, minorb, revisionb = tostring(b):find("(%d+)%.?(%d*)%.?(%d*)")
  if majora == nil then error("can't parse version " .. a) end
  if majorb == nil then error("can't parse version " .. b) end
  majora, minora, revisiona = tonumber(majora) or 0, tonumber(minora) or 0, tonumber(revisiona) or 0
  majorb, minorb, revisionb = tonumber(majorb) or 0, tonumber(minorb) or 0, tonumber(revisionb) or 0
  if majora ~= majorb then return majora < majorb and -3 or 3 end
  if minora ~= minorb then return minora < minorb and -2 or 2 end
  if revisiona ~= revisionb then return revisiona < revisionb and -1 or 1 end
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

local function compatible_modversion(lite_xl_modversion, addon_modversion)
  local result = compare_version(lite_xl_modversion, addon_modversion)
  return result >= 0 and result < 3
end


-- There can exist many different versions of an addon. All statuses are relative to a particular lite bottle.
-- available: Addon is available in a repository, and can be installed. There is no comparable version on the system.
-- upgradable: Addon is installed, but does not match the highest version in any repository.
-- orphan: Addon is installed, but there is no corresponding addon in any repository.
-- installed: Addon is installed, and matches the highest version in any repository, or highest version is incompatible.
-- core: Addon is a part of the lite data directory, and doesn't have corresponding addons in any repository.
-- bundled: Addon is part of the lite data directory, but has corresponding addons in any repository.
-- incompatible: Addon is not installed and conflicts with existing installed addons.
function Addon.__index(self, idx) return rawget(self, idx) or Addon[idx] end
function Addon.new(repository, metadata)
  if type(metadata.id) ~= 'string' or metadata.id:find("[^a-z0-9%-_]") then error("addon requires a valid id " .. (metadata.id and "(" .. metadata.id .. " is invalid)" or "")) end
  local type = metadata.type or "plugin"
  if metadata.type ~= "meta" and not metadata.path and not metadata.files and not metadata.url then metadata.path = "." end
  if metadata.path then metadata.path = metadata.path:gsub("/", PATHSEP) end
  local self = setmetatable(common.merge({
    repository = repository,
    tags = {},
    type = type,
    path = nil,
    remote = nil,
    version = "1.0",
    location = "user",
    dependencies = {},
    conflicts = {},
    name = metadata.id
  }, metadata), Addon)
  self.type = type
  -- Directory.
  local plural_type = type == "library" and "libraries" or (type .. "s")
  if not self.path and repository and repository.local_path and system.stat(repository.local_path .. PATHSEP .. plural_type  .. PATHSEP .. self.id .. ".lua") then self.path = plural_type .. PATHSEP .. self.id .. ".lua" end
  if not self.path and repository and repository.local_path and system.stat(repository.local_path .. PATHSEP .. plural_type .. PATHSEP .. self.id) then self.path = plural_type .. PATHSEP .. self.id end
  self.organization = metadata.organization or (((self.files and #self.files > 0) or (not self.path and not self.url) or (self.path and not self.path:find("%.lua$"))) and "complex" or "singleton")
  if self.dependencies and #self.dependencies > 0 then
    local t = {}
    for i,v in ipairs(self.dependencies) do t[v] = {} end
    self.dependencies = t
  end
  if not self.local_path and repository then
    if self.remote then
      local repo = Repository.url(self.remote)
      local local_path = repo.local_path and (repo.local_path .. (self.path and (PATHSEP .. self.path:gsub("^/", ""):gsub("%.$", "")) or ""))
      self.local_path = local_path and system.stat(local_path) and local_path or nil
    else
      self.local_path = (repository.local_path .. (self.path and (PATHSEP .. self.path:gsub("^/", ""):gsub("%.$", "")) or "")) or nil
    end
  end
  return self
end

function Addon:is_stub() return self.remote end
function Addon:is_asset() return self.type == "font" end

function Addon:unstub()
  if not self:is_stub() or self.inaccessible then return end
  local repo
  local status, err = pcall(function()
    repo = Repository.url(self.remote):fetch_if_not_present()
    local manifest = repo:parse_manifest(self.id)
    local remote_entry = common.grep(manifest['addons'] or manifest['plugins'], function(e) return e.id == self.id end)[1]
    if not remote_entry then error("can't find " .. self.type .. " " .. self.id .. " on " .. self.remote) end
    local addon = Addon.new(repo, remote_entry)

    -- merge in attribtues that are probably more accurate than the stub
    if addon.version ~= self.version then log.warning(self.id .. " stub on " .. self.repository:url() .. " has differing version from remote (" .. self.version .. " vs " .. addon.version .. "); may lead to install being inconsistent") end
    -- if addon.mod_version ~= self.mod_version then log.warning(self.id .. " stub on " .. self.repository:url() .. " has differing mod_version from remote (" .. self.mod_version .. " vs " .. addon.mod_version .. ")") end
    for k,v in pairs(addon) do self[k] = v end
  end)
  if not status then self.inaccessible = err end
  return repo
end

function Addon.is_addon_different(downloaded_path, installed_path)
  local is_downloaded_single = downloaded_path:find("%.lua$")
  local is_installed_single = installed_path:find("%.lua$")
  local target = is_downloaded_single and not is_installed_single and installed_path .. PATHSEP .. "init.lua" or installed_path
  return common.is_path_different(downloaded_path, target)
end

function Addon:get_install_path(bottle)
  local folder = self.type == "library" and "libraries" or (self.type .. "s")
  local path = (((self:is_core(bottle) or self:is_bundled()) and bottle.lite_xl.datadir_path) or (bottle.local_path and (bottle.local_path .. PATHSEP .. "user") or USERDIR)) .. PATHSEP .. folder
  if self:is_asset() and self.organization == "singleton" then
    path = path .. PATHSEP .. (self.path or (self.url and common.basename(self.url) or self.id))
  else
    path = path .. PATHSEP .. self.id
    if self.organization == "singleton" then path = path .. ".lua" end
  end
  return path
end

function Addon:is_orphan(bottle) return not self.repository end
function Addon:is_core(bottle) return self.location == "core" end
function Addon:is_bundled(bottle) return self.location == "bundled" end
function Addon:is_installed(bottle)
  if self:is_core(bottle) or self:is_bundled(bottle) or not self.repository then return true end
  if self.type == "meta" and self:is_explicitly_installed(bottle) then return true end
  local install_path = self:get_install_path(bottle)
  if not system.stat(install_path) then return false end
  if self:is_asset() then return true end
  local installed_addons = common.grep({ bottle:get_addon(self.id, nil, {  }) }, function(addon) return not addon.repository end)
  if #installed_addons > 0 then return false end
  return self.local_path and not Addon.is_addon_different(self.local_path, install_path)
end
function Addon:is_upgradable(bottle)
  if self:is_installed(bottle) then
    local addons = { bottle:get_addon(self.id) }
    for i, v in ipairs(addons) do
      if self.version and v.version and v ~= self and compare_version(self.version, v.version) <= 1 then
        return true
      end
    end
  end
  return false
end
function Addon:is_installable(bottle) return not self:is_core(bottle) and not self:is_orphan(bottle) end
function Addon:is_incompatible(addon)
  return (self.dependencies[addon.id] and not match_version(addon.version, self.dependencies[addon.id] and self.dependencies[addon.id].version)) or
    (self.conflicts[addon.id] and match_version(addon.version, self.conflicts[addon.id] and self.conflicts[addon.id].version))
end

function Addon:get_path(bottle)
  return self:is_installed(bottle) and self:get_install_path(bottle) or self.local_path
end

function Addon:get_compatibilities(bottle)
  local compatible_addons, incompatible_addons = {}, {}
  local installed_addons = bottle:installed_addons()
  local dependency_list = common.canonical_order(self.dependencies)
  for _, addon in ipairs(dependency_list) do
    local v = self.dependencies[addon]
    local potential_addons = { bottle:get_addon(addon, v.version, { mod_version = bottle.lite_xl.mod_version }) }
    for i, potential_addon in ipairs(potential_addons) do
      local incomaptibilities = common.grep(installed_addons, function(p) return p:is_incompatible(potential_addon) end)
      if #incomaptibilities == 0 then
        if not compatible_addons[addon] or
          potential_addon:is_installed(bottle) or
          (compare_version(compatible_addons[addon].version, potential_addon.version) and not compatible_addons[addon]:is_installed(bottle))
        then
          compatible_addons[addon] = potential_addon
        end
      else
        incompatible_addons[addon] = incompatibilities
      end
    end
  end
  return compatible_addons, incompatible_addons
end



function Addon:install(bottle, installing)
  if MASK[self.id] then if not installing[self.id] then log.warning("won't install masked addon " .. self.id) end installing[self.id] = true return end
  if self:is_installed(bottle) and not REINSTALL then error("addon " .. self.id .. " is already installed") return end
  if self:is_stub() then self:unstub() end
  if self.inaccessible then error("addon " .. self.id .. " is inaccessible: " .. self.inaccessible) end
  local install_path = self:get_install_path(bottle)
  if install_path:find(USERDIR, 1, true) ~= 1 and install_path:find(TMPDIR, 1, true) ~= 1 then error("invalid install path: " .. install_path) end
  local temporary_install_path = TMPDIR .. PATHSEP .. install_path:sub(((install_path:find(TMPDIR, 1, true) == 1) and #TMPDIR or #USERDIR) + 2)
  local status, err = pcall(function()
    installing = installing or {}
    installing[self.id] = true
    local compatible, incompatible = self:get_compatibilities(bottle)
    local dependency_list = common.canonical_order(self.dependencies)
    for _, addon in ipairs(dependency_list) do
      if incompatible[addon] then error("can't install " .. self.id .. ": incompatible with " .. incompatible[addon][1].id .. ":" .. incompatible[addon][1].version) end
    end
    for _, addon in ipairs(dependency_list) do
      local v = self.dependencies[addon]
      if not compatible[addon] then
        if not v.optional then
          error("can't find dependency " .. addon .. (v.version and (":" .. v.version) or ""))
        else
          log.warning("can't find optional dependency " .. addon .. (v.version and (":" .. v.version) or ""))
        end
      end
    end
    for _, addon in ipairs(dependency_list) do
      local v = self.dependencies[addon]
      if compatible[addon] and not compatible[addon]:is_core(bottle) and not compatible[addon]:is_installed(bottle) then
        if installing[addon] then
          error("circular dependency detected in " .. self.id .. ": requires " .. addon .. " but, " .. addon .. " requires " .. self.id)
        end
        if not v.optional or (not NO_INSTALL_OPTIONAL and prompt(addon .. " is an optional dependency of " .. self.id .. ". Should we install it?")) then
          compatible[addon]:install(bottle, installing)
        end
      end
    end

    if self.type == "meta" then
      log.action("Installed metapackage " .. self.id .. ".", "green")
      return
    end

    common.mkdirp(common.dirname(temporary_install_path))
    if self:is_upgradable(bottle) then
      log.action("Upgrading " .. self.organization .. " " .. self.type .. " " .. self.id .. ".", "green")
      common.rmrf(install_path)
    else
      log.action("Installing " .. self.organization .. " " .. self.type .. " " .. self.id .. ".", "green")
    end
    if self.organization == "complex" and self.path and common.stat(self.local_path).type ~= "dir" then common.mkdirp(install_path) end
    if self.url then -- remote simple addon
      local path = temporary_install_path .. (self.organization == 'complex' and self.path and system.stat(self.local_path).type ~= "dir" and (PATHSEP .. "init.lua") or "")
      common.get(self.url, { target = path, checksum = self.checksum, callback = write_progress_bar })
      if VERBOSE then log.action("Downloaded file " .. self.url .. " to " .. path) end
    else -- local addon that has a local path
      local temporary_path = temporary_install_path .. (self.organization == 'complex' and self.path and system.stat(self.local_path).type ~= "dir" and (PATHSEP .. "init.lua") or "")
      if self.organization == 'complex' and self.path and common.stat(self.local_path).type ~= "dir" then common.mkdirp(temporary_install_path) end
      if self.path then
        local path = install_path .. (self.organization == 'complex' and self.path and common.stat(self.local_path).type ~= "dir" and (PATHSEP .. "init.lua") or "")
        if SYMLINK then
          if VERBOSE then log.action("Symlinking " .. self.local_path .. " to " .. path .. ".") end
          system.symlink(self.local_path, temporary_path)
        else
          if VERBOSE then log.action("Copying " .. self.local_path .. " to " .. path .. ".") end
          common.copy(self.local_path, temporary_path)
        end
      end
    end


    local has_nonoptional_arched_files = #common.grep(self.files or {}, function(e) return e.arch and not e.optional end) > 0
    for _, arch in ipairs(ARCH) do
      local has_one_file = false
      for _, file in ipairs(self.files or {}) do
        local file_arch = file.arch and type(file.arch) == "string" and { file.arch } or file.arch
        if not file.arch or #common.grep(file_arch, function(e) return e == arch end) > 0 then
          if file.arch then has_one_file = true end
          if not file.optional or (not NO_INSTALL_OPTIONAL and prompt(common.basename(file.url) .. " is an optional file for " .. self.id .. ". Should we install it?")) then
            if not file.checksum then error("requires a checksum") end
            local target_path = install_path .. PATHSEP .. (file.path or common.basename(file.url))
            local temporary_path = temporary_install_path .. PATHSEP .. (file.path or common.basename(file.url))

            local local_path = self.repository.repo_path .. PATHSEP .. (file.path or common.basename(file.url))
            local stripped_local_path = local_path:find("%.[^%.]+%-[^%.]+%.[^%.]*$") and local_path:gsub("%.[^%.]+%-[^%.]+", "") or local_path

            if not system.stat(temporary_path) then
              common.mkdirp(common.dirname(temporary_path))
              if SYMLINK and self.repository:is_local() and system.stat(local_path) then
                log.action("Symlinking " .. local_path .. " to " .. target_path .. ".")
                system.symlink(local_path, temporary_path)
              elseif SYMLINK and self.repository:is_local() and system.stat(stripped_local_path) then
                log.action("Symlinking " .. stripped_local_path .. " to " .. target_path .. ".")
                system.symlink(stripped_local_path, temporary_path)
              else
                common.get(file.url, { target = temporary_path, checksum = file.checksum, callback = write_progress_bar })
                local basename = common.basename(target_path)
                local is_archive = basename:find("%.zip$") or basename:find("%.tar%.gz$") or basename:find("%.tgz$")
                local target = temporary_path
                if is_archive or basename:find("%.gz$") then
                  if VERBOSE then log.action("Extracting file " .. basename .. " in " .. install_path .. "...") end
                  target = temporary_install_path .. (not is_archive and (PATHSEP .. basename:gsub(".gz$", "")) or "")
                  system.extract(temporary_path, target)
                  os.remove(temporary_path)
                end
                if not is_archive and file.arch and file.arch ~= "*" then system.chmod(target, 448) end -- chmod any ARCH tagged file to rwx-------
              end
              if file.extra and file.extra.chmod_executable then
                for _, executable in ipairs(file.extra.chmod_executable) do
                  local path = common.dirname(temporary_path) .. PATHSEP .. executable:gsub("/", PATHSEP):gsub("^" .. PATHSEP, "")
                  if path:find(PATHSEP .. "%.%.") then error("invalid chmod_executable value " .. executable) end
                  local stat = system.stat(path)
                  if not stat then error("can't find executable to chmod_executable " .. path) end
                  if VERBOSE then log.action("Chmodding file " .. executable .. " to be executable.") end
                  system.chmod(path, stat.mode | 73)
                end
              end
            end
          end
        end
      end

      if has_nonoptional_arched_files and not has_one_file and (not self.arch or (self.arch ~= "*" and #common.grep(self.arch, function(a) return a == arch end) == 0)) then
        error("Addon " .. self.id .. " does not support arch " .. arch)
      end
    end
  end)
  bottle:invalidate_cache()
  if not status then
    common.rmrf(temporary_install_path)
    error(err, 0)
  elseif self.type ~= "meta" then
    if POST and self.post then
      common.chdir(temporary_install_path, function()
        for i, arch in ipairs(ARCH) do
          if type(self.post) == "table" and not self.post[ARCH] then error("can't find post command for arch " .. ARCH) end
          local code = os.system(type(self.post) == "table" and self.post[ARCH] or self.post) ~= 0
          if code ~= 0 then error("post step failed with error code " .. code) end
        end
      end)
    end
    if install_path ~= temporary_install_path then
      common.rmrf(install_path)
      common.mkdirp(common.dirname(install_path))
      common.rename(temporary_install_path, install_path)
    end
  end
end

function Addon:depends_on(addon)
  if self.dependencies[addon.id] and self.dependencies[addon.id].optional ~= true then return true end
  for i,v in ipairs(addon.provides or {}) do if self.dependencies[v] and self.dependencies[v].optional ~= true then return true end end
  return false
end


function Addon:is_explicitly_installed(bottle)
  return common.first(settings.installed, function(id) return self.id == id end)
end


function Addon:get_orphaned_dependencies(bottle)
  local t = {}
  local installed_addons = system_bottle:installed_addons()
  for id, options in pairs(self.dependencies) do
    local dependency = bottle:get_addon(id, options.version)
    if dependency then
      if  ( dependency.type == "meta" or dependency:is_installed(bottle) )
      and #common.grep(installed_addons, function(addon) return addon ~= self and addon:depends_on(dependency) end) == 0
      and not ( dependency:is_explicitly_installed(bottle) or dependency:is_core(bottle) )
      then
        table.insert(t, dependency)
        if dependency.type == "meta" then
          t = common.concat(t, dependency:get_orphaned_dependencies(bottle))
        end
      end
    end
  end
  return t
end


function Addon:uninstall(bottle, uninstalling)
  if MASK[self.id] then if not uninstalling[self.id] then log.warning("won't uninstall masked addon " .. self.id) end uninstalling[self.id] = true return end
  local install_path = self:get_install_path(bottle)
  if self:is_core(bottle) then error("can't uninstall " .. self.id .. "; is a core addon") end
  local orphans = common.sort(common.grep(self:get_orphaned_dependencies(bottle), function(e) return not uninstalling or not uninstalling[e.id] end), function(a, b) return a.id < b.id end)
  -- debate about this being a full abort, vs. just not uninstalling the orphans; settled in favour of full abort. can be revisited.
  if #orphans > 0 and not uninstalling and not prompt("Uninstalling " .. self.id .. " will uninstall the following orphans: " .. common.join(", ", common.map(orphans, function(e) return e.id end)).. ". Do you want to continue?") then
    return false
  end
  common.each(orphans, function(e) e:uninstall(bottle, common.merge(uninstalling or {}, { [self.id] = true })) end)
  if self.type == "meta" then
    log.action("Uninstalling meta " .. self.id .. ".", "green")
  else
    log.action("Uninstalling " .. self.type .. " located at " .. install_path, "green")
  end
  local incompatible_addons = common.grep(bottle:installed_addons(), function(p) return p:depends_on(self) and (not uninstalling or not uninstalling[p.id]) end)
  local should_uninstall = #incompatible_addons == 0 or uninstalling
  if not should_uninstall then
    should_uninstall = prompt(self.id .. " is depended upon by " .. common.join(", ", common.map(incompatible_addons, function(p) return p.id end)) .. ". Remove as well?")
    if not should_uninstall and self:is_explicitly_installed(bottle) and prompt(self.id .. " is explicitly installed. Mark as non-explicit?") then
      settings.installed = common.grep(settings.installed, function(e) return e ~= self.id end)
      return false
    end
  end
  if should_uninstall then
    for i,addon in ipairs(incompatible_addons) do
      if not addon:uninstall(bottle, common.merge(uninstalling or {}, { [self.id] = true })) then return false end
    end
    common.rmrf(install_path)
    return true
  end
  return false
end


function Repository.__index(self, idx) return rawget(self, idx) or Repository[idx] end
function Repository.new(hash)
  if hash.remote then
    if not hash.remote:find("^%w+:") and system.stat(hash.remote .. "/.git") then hash.remote = "file://" .. system.stat(hash.remote).abs_path end
    if not hash.remote:find("^https?:") and not hash.remote:find("^file:") then error("only repositories with http and file transports are supported (" .. hash.remote .. ")") end
  else
    if not hash.repo_path then error("requires a remote, or a repo_path") end
  end
  local self = setmetatable({
    commit = hash.commit,
    remote = hash.remote,
    branch = hash.branch,
    live = nil,
    addons = nil,
    repo_path = hash.repo_path or (CACHEDIR .. PATHSEP .. "repos" .. PATHSEP .. system.hash(hash.remote)),
    lite_xls = {},
    last_retrieval = nil
  }, Repository)
  if not self:is_local() then
    if system.stat(self.repo_path) and not self.commit and not self.branch then
      -- In the case where we don't have a branch, and don't have a commit, check for the presence of `master` and `main`.
      if system.stat(self.repo_path .. PATHSEP .. "master") then
        self.branch = "master"
      elseif system.stat(self.repo_path .. PATHSEP .. "main") then
        self.branch = "main"
      else
        error("can't find branch for " .. self.remote .. " in " .. self.repo_path)
      end
    end
    if self.commit or self.branch then
      self.local_path = self.repo_path .. PATHSEP .. (self.commit or self.branch)
    end
  else
    self.local_path = self.repo_path
  end
  return self
end

function Repository:is_local()
  return self.remote == nil
end

function Repository.url(url)
  if type(url) == "table" then return (url.remote and (url.remote .. ":" .. (url.branch or url.commit)) or url.repo_path) end
  if not url:find("^%a+:") then
    local stat = system.stat(url:gsub("[/\\]$", "")) or error("can't find repository " .. url)
    return Repository.new({ repo_path = stat.abs_path })
  end
  local e = url:reverse():find(":")
  local s = e and (#url - e + 1)
  local remote, branch_or_commit = url:sub(1, s and (s-1) or #url), s and url:sub(s+1)
  if remote == "https" or remote == "file" then remote, branch_or_commit = url, nil end
  if branch_or_commit and is_commit_hash(branch_or_commit) then
    return Repository.new({ remote = remote, commit = branch_or_commit })
  end
  return Repository.new({ remote = remote, branch = branch_or_commit })
end

function Repository:parse_manifest(repo_id)
  if self.manifest then return self.manifest, self.remotes end
  if system.stat(self.local_path) then
    self.manifest_path = self.local_path .. PATHSEP .. "manifest.json"
    if not system.stat(self.manifest_path) then
      log.warning("Can't find manifest.json for " .. self:url() .. "; automatically generating manifest.")
      self:generate_manifest(repo_id)
    end
    local status, err = pcall(function()
      self.manifest = json.decode(common.read(self.manifest_path))
      self.addons = {}
      self.remotes = {}
      for i, metadata in ipairs(self.manifest["addons"] or self.manifest["plugins"] or {}) do
        table.insert(self.addons, Addon.new(self, metadata))
      end
      for i, metadata in ipairs(self.manifest["lite-xls"] or {}) do
        table.insert(self.lite_xls, LiteXL.new(self, metadata))
      end
      self.remotes = common.map(self.manifest["remotes"] or {}, function(r) return Repository.url(r) end)
    end)
    if not status then error("error parsing manifest for " .. self:url() .. ": " .. err) end
  end
  return self.manifest, self.remotes
end


-- in the cases where we don't have a manifest, assume generalized structure, take addons folder, trawl through it, build manifest that way
-- assuming each .lua file under the `addons` folder is a addon. also parse the README, if present, and see if any of the addons
-- Ignore any requries that are in CORE_PLUGINS.
local CORE_PLUGINS = {
  autocomplete = true, autoreload = true, contextmenu = true, detectindent = true, drawwhitespace = true, language_c = true, language_cpp = true, language_css = true, language_dart = true,
  language_html = true, language_js = true, language_lua = true, language_md = true, language_python = true, language_xml = true, lineguide = true, linewrapping = true, macro = true,
  projectsearch = true, quote = true, reflow = true, scale = true, tabularize = true, toolbarview = true, treeview = true, trimwhitespace = true, workspace = true
}
function Repository:generate_manifest(repo_id)
  if not self.local_path and not self.commit and not self.branch then error("requires an instantiation") end
  local path = self.local_path
  local addons, addon_map = {}, {}
  for _, folder in ipairs({ "plugins", "colors", "libraries", "fonts" }) do
    if system.stat(path .. PATHSEP .. "README.md") then -- If there's a README, parse it for a table like in our primary repository.
      for line in io.lines(path .. PATHSEP .. "README.md") do
        local _, _, name, path, description = line:find("^%s*%|%s*%[`([%w_]+)%??.-`%]%((.-)%).-%|%s*(.-)%s*%|%s*$")
        if name then
          local id = name:lower():gsub("[^a-z0-9%-_]", "")
          addon_map[id] = { id = id, description = description, name = name }
          if path:find("^http") then
            if path:find("%.lua") then
              addon_map[id].url = path
              local file = common.get(path, { callback = write_progress_bar })
              addon_map[id].checksum = system.hash(file)
            else
              path = path:gsub("\\", "")
              addon_map[id].remote = path
              pcall(function()
                local repo = Repository.url(path):add()
                addon_map[id].remote = path .. ":" .. (repo.branch or repo.commit)
              end)
            end
          else
            addon_map[id].path = path:gsub("%?.*$", "")
          end
        end
      end
    end
    if folder == "plugins" or system.stat(path .. PATHSEP .. folder) then
      local addon_dir = system.stat(path .. PATHSEP .. folder) and folder or ""
      local files = folder == "plugins" and system.stat(path .. PATHSEP .. "init.lua") and { "init.lua" } or system.ls(path .. PATHSEP .. addon_dir)
      for i, file in ipairs(files) do
        if file:find("%.lua$") then
          local filename = common.basename(file):gsub("%.lua$", "")
          local name = filename
          if name == "init" then name = repo_id or common.basename(self.remote or self.local_path) end
          if name ~= "init" then
            local type = folder == "libraries" and "library" or folder:sub(1, #folder - 1)
            local addon = { description = nil, id = name:lower():gsub("[^a-z0-9%-_]", ""), name = name, mod_version = LATEST_MOD_VERSION, version = "0.1", path = (filename ~= "init" and (addon_dir .. PATHSEP .. file) or nil), type = type }
            for line in io.lines(path .. PATHSEP .. addon_dir .. PATHSEP .. file) do
              local _, _, mod_version = line:find("%-%-.*mod%-version:%s*(%w+)")
              if mod_version then addon.mod_version = mod_version end
              local _, _, required_addon = line:find("require [\"']plugins%.([%w_-]+)")
              if required_addon and not CORE_PLUGINS[required_addon] then
                if required_addon ~= addon.id then
                  if not addon.dependencies then addon.dependencies = {} end
                  addon.dependencies[required_addon] = ">=0.1"
                end
              end
              local _, _, name_override = line:find("config%.plugins%.([%w_-]+)%s*=%s*common%.merge")
              if not repo_id and name_override then
                addon.name = name_override
                addon.id = name_override:lower():gsub("[^a-z0-9%-_]", "")
                addon.dependencies = common.delete(addon.dependencies, addon.id)
              end
            end
            if addon_map[addon.id] then
              addon = common.merge(addon, addon_map[addon.id])
              addon_map[addon.id].addon = addon
            end
            table.insert(addons, addon)
          end
        end
      end
    end
  end
  for k, v in pairs(addon_map) do
    if not v.addon then
      table.insert(addons, common.merge({ mod_version = LATEST_MOD_VERSION, version = "0.1" }, v))
    end
  end
  if #addons == 1 and not addons[1].path then addons[1].path = "." end
  table.sort(addons, function(a,b) return a.id:lower() < b.id:lower() end)
  common.write(path .. PATHSEP .. "manifest.json", json.encode({ addons = addons }, { pretty = true }))
end

function Repository:fetch_if_not_present()
  if self.local_path and system.stat(self.local_path) then return self end
  return self:fetch()
end

-- useds to fetch things from a generic place
function Repository:fetch()
  if self:is_local() then return self end
  local path, temporary_path
  local status, err = pcall(function()
    if not self.branch and not self.commit then
      temporary_path = TMPDIR .. PATHSEP .. "transient-repo"
      common.rmrf(temporary_path)
      common.mkdirp(temporary_path)
      log.progress_action("Fetching " .. self.remote .. "...")
      system.init(temporary_path, self.remote)
      self.branch = system.fetch(temporary_path, write_progress_bar):gsub("^refs/heads/", "")
      if not self.branch then error("Can't find remote branch for " .. self.remote) end
      path = self.repo_path .. PATHSEP .. self.branch
      self.local_path = path
      common.reset(temporary_path, self.branch, "hard")
    else
      path = self.local_path
      local exists = system.stat(path)
      if not exists then
        temporary_path = TMPDIR .. PATHSEP .. "tranient-repo"
        common.rmrf(temporary_path)
        common.mkdirp(temporary_path)
        system.init(temporary_path, self.remote)
      end
      if not exists or self.branch then
        log.progress_action("Fetching " .. self.remote .. ":" .. (self.commit or self.branch) .. "...")
        if self.commit then
          system.fetch(temporary_path or path, write_progress_bar, self.commit)
        elseif self.branch then
          system.fetch(temporary_path or path, write_progress_bar, "+refs/heads/" .. self.branch  .. ":refs/remotes/origin/" .. self.branch)
        end
        common.reset(temporary_path or path, self.commit or self.branch, "hard")
      end
      self.manifest = nil
    end
    if temporary_path then
      common.mkdirp(common.dirname(path))
      common.rename(temporary_path, path)
    end
  end)
  if not status then
    if path then
      common.rmrf(path)
      local dir = common.dirname(path)
      if system.stat(dir) and #system.ls(dir) == 0 then common.rmrf(dir) end
    end
    error(err, 0)
  end
  return self
end

function Repository:add(pull_remotes)
  -- If neither specified then pull onto `master`, and check the main branch name, and move if necessary.
  local manifest, remotes = self:fetch():parse_manifest()
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
    log.progress_action("Updating " .. self:url() .. "...")
    local status, err = pcall(system.fetch, self.local_path, write_progress_bar, "+refs/heads/" .. self.branch  .. ":refs/remotes/origin/" .. self.branch)
    if not status then -- see https://github.com/lite-xl/lite-xl-plugin-manager/issues/85
      if not err:find("object not found %- no match for id") then error(err, 0) end
      common.rmrf(self.local_path)
      return self:fetch()
    end
    common.reset(self.local_path, self.branch, "hard")
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
  if not self:is_local() then
    common.rmrf(self.local_path)
    if #system.ls(self.repo_path) == 0 then common.rmrf(self.repo_path) end
  end
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
  self.binary_path = self.binary_path or { }
  self.datadir_path = self.datadir_path or (self.local_path .. PATHSEP .. "data")
  return self
end

function LiteXL:get_binary_path(arch)
  if self.binary_path and self.binary_path[arch or _G.ARCH] then return self.binary_path[arch or _G.ARCH] end
  return self.local_path .. PATHSEP .. "lite-xl." .. (arch or _G.ARCH)
end

function LiteXL:is_system() return system_bottle and system_bottle.lite_xl == self end
function LiteXL:is_local() return not self.repository and self.path end
function LiteXL:is_compatible(addon) return not addon.mod_version or compatible_modversion(self.mod_version, addon.mod_version) end
function LiteXL:is_installed() return system.stat(self.local_path) ~= nil end

function LiteXL:install()
  if self:is_installed() then log.warning("lite-xl " .. self.version .. " already installed") return end
  common.mkdirp(self.local_path)
  if system_bottle.lite_xl == self then -- system lite-xl. We have to copy it because we can't really set the user directory.
    local executable, datadir = common.path("lite-xl" .. EXECUTABLE_EXTENSION)
    if not executable then error("can't find system lite-xl executable") end
    local stat = system.stat(executable)
    executable = stat.symlink and stat.symlink or executable
    datadir = common.dirname(executable) .. PATHSEP .. "data"
    if not system.stat(datadir) then error("can't find system lite-xl data dir") end
    common.copy(executable, self.local_path .. PATHSEP .. "lite-xl")
    system.chmod(self.local_path .. PATHSEP .. "lite-xl", 448) -- chmod to rwx-------
    common.copy(datadir, self.local_path .. PATHSEP .. "data")
  elseif self.path and not self.repository then -- local repository
    system.symlink(self:get_binary_path(), self.local_path .. PATHSEP .. "lite_xl")
  else
    if self.remote then
      system.init(self.local_path, self.remote)
      common.reset(self.local_path, self.commit or self.branch)
    end
    for i,file in ipairs(self.files or {}) do
      if file.arch and common.grep(ARCH, function(e) return e == file.arch end)[1] then
        if not file.checksum then error("requires a checksum") end
        local basename = common.basename(file.url)
        local archive = basename:find("%.zip$") or basename:find("%.tar%.gz$")
        local path = self.local_path .. PATHSEP .. (archive and basename or "lite-xl")
        log.action("Downloading file " .. file.url .. "...")
        common.get(file.url, { target = path, checksum = file.checksum, callback = write_progress_bar })
        log.action("Downloaded file " .. file.url .. " to " .. path)
        if archive then
          log.action("Extracting file " .. basename .. " in " .. self.local_path)
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
function Bottle.new(lite_xl, addons, config, is_system)
  local self = setmetatable({
    lite_xl = lite_xl,
    addons = addons,
    config = config,
    is_system = is_system
  }, Bottle)
  if not is_system then
    table.sort(self.addons, function(a, b) return (a.id .. ":" .. a.version) < (b.id .. ":" .. b.version) end)
    self.hash = system.hash(lite_xl.version .. " " .. common.join(" ", common.map(self.addons, function(p) return (p.repository and p.repository:url() or "") .. ":" .. p.id .. ":" .. p.version end)) .. (config or "") .. (EPHEMERAL and "E" or ""))
    self.local_path = CACHEDIR .. PATHSEP .. "bottles" .. PATHSEP .. self.hash
  end
  return self
end

function Bottle:is_constructed() return self.is_system or system.stat(self.local_path) end

function Bottle:construct()
  if self.is_system then error("system bottle cannot be constructed") end
  if self:is_constructed() and not REINSTALL then error("bottle " .. self.hash .. " already constructed") end
  -- swap out the local path for a temporary path while we construct the bottle to make things atomic
  local local_path = self.local_path
  self.local_path = TMPDIR .. PATHSEP .. "bottles" .. PATHSEP .. self.hash
  common.rmrf(self.local_path)

  if not self.lite_xl:is_installed() then self.lite_xl:install() end
  common.mkdirp(self.local_path .. PATHSEP .. "user")
  if self.config then
    io.open(self.local_path .. PATHSEP .. "user" .. PATHSEP .. "init.lua", "wb"):write([[
      local core = require "core"
      local command = require "core.command"
      local keymap = require "core.keymap"
      local config = require "core.config"
      local style = require "core.style"
      ]] .. self.config
    ):close()
  end

  -- Always copy the executbale, because of the way that lite determines the user folder (for now).
  common.copy(self.lite_xl:get_binary_path(), self.local_path .. PATHSEP .. "lite-xl" .. EXECUTABLE_EXTENSION)
  system.chmod(self.local_path .. PATHSEP .. "lite-xl" .. EXECUTABLE_EXTENSION, 448) -- chmod to rwx-------\
  if SYMLINK then
    system.symlink(self.lite_xl.datadir_path, self.local_path .. PATHSEP .. "data")
  else
    common.copy(self.lite_xl.datadir_path, self.local_path .. PATHSEP .. "data")
  end
  local installing = {}
  for i,addon in ipairs(self.addons) do
    if not installing[addon.id] then
      addon:install(self, installing)
    end
  end
  -- atomically move things
  common.rmrf(local_path)
  common.mkdirp(common.dirname(local_path))
  common.rename(self.local_path, local_path)
  self.local_path = local_path
end

function Bottle:destruct()
  if self.is_system then error("system bottle cannot be destructed") end
  if not self:is_constructed() then error("lite-xl " .. self.version .. " not constructed") end
  common.rmrf(self.local_path)
end

function Bottle:run(args)
  args = args or {}
  if self.is_system then error("system bottle cannot be run") end
  local path = self.local_path .. PATHSEP .. "lite-xl" .. EXECUTABLE_EXTENSION
  if not system.stat(path) then error("cannot find bottle executable " .. path) end
  local line = path .. (#args > 0 and " " or "") .. table.concat(common.map(args, function(arg)
    return "'" .. arg:gsub("'", "'\"'\"'"):gsub("\\", "\\\\") .. "'"
  end), " ")
  if VERBOSE then log.action("Running " .. line) end
  return os.execute(line)
end

local function get_repository_addons()
  local t, hash = { }, { }
  for i,p in ipairs(common.flat_map(repositories, function(r) return r.addons end)) do
    local id = p.id .. ":" .. p.version
    if not hash[id] then
      table.insert(t, p)
      hash[id] = p
      if not hash[p.id] then hash[p.id] = {} end
      table.insert(hash[p.id], p)
      if p:is_asset() and p.organization == "singleton" then
        local filename = (p.path or (p.url and common.basename(p.url) or p.id)):lower():gsub("[^a-z0-9%-_]", "")
        if not hash[filename] then hash[filename] = {} end
        table.insert(hash[filename], p)
      end
    elseif hash[id].remote and not p.remote then
      for k,v in ipairs(t) do
        if v == hash[id] then
          t[k] = p
          break
        end
      end
      for k,v in ipairs(hash[p.id]) do
        if v == hash[id] then
          hash[p.id][k] = p
          hash[id] = p
          break
        end
      end
    end
  end
  return t, hash
end

function Bottle:invalidate_cache()
  self.all_addons_cache = nil
end

function Bottle:all_addons()
  if self.all_addons_cache then return self.all_addons_cache end
  local t, hash = get_repository_addons()
  for _, addon_type in ipairs({ "plugins", "libraries", "fonts", "colors" }) do
    local addon_paths = {
      (self.local_path and (self.local_path .. PATHSEP .. "user") or USERDIR) .. PATHSEP .. addon_type,
      self.lite_xl.datadir_path .. PATHSEP .. addon_type
    }
    for i, addon_path in ipairs(common.grep(addon_paths, function(e) return system.stat(e) end)) do
      for j, v in ipairs(system.ls(addon_path)) do
        local id = v:gsub("%.lua$", ""):lower():gsub("[^a-z0-9%-_]", "")
        local path = addon_path .. PATHSEP .. v
        -- in the case where we have an existing plugin that targets a stub, then fetch that repository
        local fetchable = hash[id] and common.grep(hash[id], function(e) return e:is_stub() end)[1]
        if fetchable then fetchable:unstub() end
        local matching = hash[id] and common.grep(hash[id], function(e)
          return e.local_path and not Addon.is_addon_different(e.local_path, path)
        end)[1]
        if i == 2 or not hash[id] or not matching then
          table.insert(t, Addon.new(nil, {
            id = id,
            type = (addon_type == "plugins" and "plugin") or "library",
            location = (i == 2 and (hash[id] and "bundled" or "core")) or "user",
            organization = (v:find("%.lua$") and "singleton" or "complex"),
            local_path = path,
            mod_version = self.lite_xl.mod_version,
            path = addon_type .. PATHSEP .. v,
            description = (hash[id] and hash[id][1].description or nil),
            repo_path = (hash[id] and hash[id][1].local_path or nil)
          }))
        end
      end
    end
  end
  self.all_addons_cache = t
  return t
end

function Bottle:installed_addons()
  return common.grep(self:all_addons(), function(p) return p:is_installed(self) end)
end

local function filter_match(field, filter)
  if not filter then return true end
  if not field then return false end
  local filters = type(filter) == "table" and filter or { filter }
  local fields = type(field) == "table" and field or { field }
  local matches = false
  for i,v in ipairs(filters) do
    local inverted = v:find("^!")
    local actual_filter = inverted and v:sub(2) or v
    for k, field in ipairs(fields) do
      matches = field:find("^" .. actual_filter .. "$")
      if not inverted and matches then return true end
      if inverted and matches then return false end
    end
    if inverted then
      if matches then return false end
      matches = true
    end
  end
  return matches
end

local function addon_matches_filter(addon, filters)
  return filter_match(addon.author, filters["author"]) and
    filter_match(addon.tags, filters["tag"]) and
    filter_match(addon.status, filters["status"]) and
    filter_match(addon.stub, filters["stub"]) and
    filter_match(addon.dependencies, filters["dependency"]) and
    filter_match(addon.type, filters["type"]) and
    filter_match(addon.name or addon.id, filters["name"])
end

function Bottle:get_addon(id, version, filter)
  local candidates = {}
  local wildcard = id:find("%*$")
  filter = filter or {}
  for i,addon in ipairs(self:all_addons()) do
    if (common.first(addon.replaces or {}, function(replaces) return replaces == id end) or
      common.first(addon.provides or {}, function(provides) return provides == id end) or
      (addon.id == id or (wildcard and addon.id:find("^" .. id:sub(1, #id - 1))))) and
      match_version(addon.version, version) and (not filter.mod_version or not addon.mod_version or compatible_modversion(filter.mod_version, addon.mod_version)) and
      (not filter.type or addon.type == filter.type)
    then
      table.insert(candidates, addon)
    end
  end
  return table.unpack(common.sort(common.uniq(candidates), function (a,b)
    return (a.replaces == id and b.replaces ~= id) or (a.version > b.version)
  end))
end

local function get_repository(url)
  if not url then error("requires a repository url") end
  local r = Repository.url(url)
  for i,v in ipairs(repositories) do
    if (v.repo_path and v.repo_path == r.repo_path) or (v.remote and v.remote == r.remote and v.branch == r.branch and v.commit == r.commit) then return i, v end
  end
  return nil
end

function lpm.settings_save()
  common.write(CACHEDIR .. PATHSEP .. "settings.json", json.encode(settings))
end


function lpm.repo_save()
  settings.repositories = common.map(repositories, function(r) return r:url() end)
  lpm.settings_save()
end


local DEFAULT_REPOS
function lpm.repo_init(repos)
  DEFAULT_REPOS = { Repository.url(DEFAULT_REPO_URL) }
  common.mkdirp(CACHEDIR)
  if not system.stat(CACHEDIR .. PATHSEP .. "settings.json") then
    for i, repository in ipairs(repos or DEFAULT_REPOS) do
      table.insert(repositories, repository:add(true))
    end
    lpm.repo_save()
  end
end




function lpm.repo_add(...)
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
  lpm.repo_save()
end


function lpm.repo_rm(...)
  for i, url in ipairs({ ... }) do
    local idx, repo = get_repository(url)
    if not repo then error("cannot find repository " .. url) end
    table.remove(repositories, idx)
    repo:remove()
  end
  lpm.repo_save()
end


function lpm.repo_update(...)
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

function lpm.lite_xl_save()
  settings.lite_xls = common.map(common.grep(lite_xls, function(l) return l:is_local() and not l:is_system() end), function(l) return { version = l.version, mod_version = l.mod_version, path = l.path, binary_path = l.binary_path, datadir_path = l.datadir_path } end)
  lpm.settings_save()
end

function lpm.lite_xl_add(version, path)
  if not version then error("requires a version") end
  if not version:find("^%d") then error("versions must begin numerically (i.e. 2.1.1-debug)") end
  if common.first(lite_xls, function(lite_xl) return lite_xl.version == version end) then error(version .. " lite-xl already exists") end
  local binary_path  = BINARY or (path and(path .. PATHSEP .. "lite-xl" .. EXECUTABLE_EXTENSION))
  local data_path = DATADIR or (path and (path .. PATHSEP .. "data"))
  local binary_stat, data_stat = system.stat(binary_path), system.stat(data_path)
  if not binary_stat then error("can't find binary path " .. binary_path) end
  if not data_stat then error("can't find data path " .. data_path) end
  local path_stat = system.stat(path:gsub(PATHSEP .. "$", ""))
  if not path_stat then error("can't find lite-xl path " .. path) end
  table.insert(lite_xls, LiteXL.new(nil, { version = version, binary_path = { [ARCH[1]] = binary_stat.abs_path }, datadir_path = data_stat.abs_path, path = path_stat.abs_path, mod_version = MOD_VERSION or LATEST_MOD_VERSION }))
  lpm.lite_xl_save()
end

function lpm.lite_xl_rm(version)
  if not version then error("requires a version") end
  local lite_xl = get_lite_xl(version) or error("can't find lite_xl version " .. version)
  lite_xls = common.grep(lite_xls, function(l) return l ~= lite_xl end)
  lpm.lite_xl_save()
end

function lpm.lite_xl_install(version)
  if not version then error("requires a version") end
  (get_lite_xl(version) or error("can't find lite-xl version " .. version)):install()
end


function lpm.lite_xl_switch(version, target)
  if not version then error("requires a version") end
  target = target or common.path("lite-xl" .. EXECUTABLE_EXTENSION)
  if not target then error("can't find installed lite-xl. please provide a target to install the symlink explicitly as a second argument") end
  local lite_xl = get_lite_xl(version) or error("can't find lite-xl version " .. version)
  if not lite_xl:is_installed() then log.action("Installing lite-xl " .. lite_xl.version) lite_xl:install() end
  local stat = system.stat(target)
  if stat and stat.symlink then os.remove(target) end
  system.symlink(lite_xl:get_binary_path(), target)
  if not common.path('lite-xl' .. EXECUTABLE_EXTENSION) then
    os.remove(target)
    error(target .. " is not on your $PATH; please supply a target that can be found on your $PATH, called `lite-xl`.")
  end
end


function lpm.lite_xl_uninstall(version)
  (get_lite_xl(version) or error("can't find lite-xl version " .. version)):uninstall()
end


function lpm.lite_xl_list()
  local result = { ["lite-xls"] = { } }
  local max_version = 0
  for i,lite_xl in ipairs(lite_xls) do
    table.insert(result["lite-xls"], {
      version = lite_xl.version,
      mod_version = lite_xl.mod_version,
      tags = lite_xl.tags,
      is_system = lite_xl:is_system(),
      is_installed = lite_xl:is_installed(),
      status = (lite_xl:is_installed() or lite_xl:is_system()) and (lite_xl:is_local() and "local" or "installed") or "available",
      local_path = lite_xl:is_installed() and lite_xl.local_path or nil,
      datadir_path = lite_xl:is_installed() and lite_xl.datadir_path or nil,
      binary_path = lite_xl:is_installed() and lite_xl.binary_path or nil
    })
    max_version = math.max(max_version, #lite_xl.version)
  end
  for i,repo in ipairs(repositories) do
    if not repo.lite_xls then error("can't find lite-xl for repo " .. repo:url()) end
    for j, lite_xl in ipairs(repo.lite_xls) do
      table.insert(result["lite-xls"], {
        version = lite_xl.version,
        mod_version = lite_xl.mod_version,
        repository = repo:url(),
        tags = lite_xl.tags,
        is_system = lite_xl:is_system(),
        is_installed = lite_xl:is_installed(),
        status = (lite_xl:is_installed() or lite_xl:is_system()) and (lite_xl:is_local() and "local" or "installed") or "available",
        local_path = lite_xl:is_installed() and lite_xl.local_path
      })
      max_version = math.max(max_version, #lite_xl.version)
    end
  end
  if JSON then
    io.stdout:write(json.encode(result) .. "\n")
  else
    if VERBOSE then
      for i, lite_xl in ipairs(result["lite-xls"]) do
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
      for i, lite_xl in ipairs(result["lite-xls"]) do
        print(string.format("%" .. max_version .. "s | %10s | %s", (lite_xl.is_system and "* " or "") .. lite_xl.version, lite_xl.status, (lite_xl.is_installed and lite_xl.local_path or lite_xl.repository)))
      end
    end
  end
end

local function is_argument_repo(arg)
  return arg:find("^http") or arg:find("[\\/]") or arg == "."
end

function lpm.lite_xl_run(version, ...)
  if not version then error("requires a version or arguments") end
  local arguments = { ... }
  if not version:find("^%d+") and version ~= "system" then
    table.insert(arguments, 1, version)
    version = "system"
  end
  local lite_xl = get_lite_xl(version) or error("can't find lite-xl version " .. version)
  local addons = {}
  local i = 1
  while i <= #arguments do
    if arguments[i] == "--" then break end
    local str = arguments[i]
    if is_argument_repo(str) then
      table.insert(repositories, 1, Repository.url(str):add(AUTO_PULL_REMOTES))
      system_bottle:invalidate_cache()
    else
      local id, version = common.split(":", str)
      local potentials = { system_bottle:get_addon(id, version, { mod_version = lite_xl.mod_version }) }
      local uniq = {}
      local found_one = false
      for i, addon in ipairs(potentials) do
        if addon:is_core(system_bottle) then
          uniq[addon.id] = true
          found_one = true
        elseif not addon:is_orphan(system_bottle) and not uniq[addon.id] then
          table.insert(addons, addon)
          uniq[addon.id] = true
          found_one = true
        end
      end
      if not found_one then error("can't find addon " .. str) end
    end
    i = i + 1
  end
  local bottle = Bottle.new(lite_xl, addons, CONFIG)
  if not bottle:is_constructed() or REINSTALL then bottle:construct() end
  return function()
    bottle:run(common.slice(arguments, i + 1))
    if EPHEMERAL then bottle:destruct() end
  end
end


function lpm.install(type, ...)
  local repo_only = nil
  local to_install = {}
  local to_explicitly_install = {}
  for i, identifier in ipairs({ ... }) do
    local s = identifier:find(":")
    local id, version = (s and identifier:sub(1, s-1) or identifier), (s and identifier:sub(s+1) or nil)
    if not id then error('unrecognized identifier ' .. identifier) end
    if id == "lite-xl" then
      lpm.lite_xl_install(version)
    else
      if is_argument_repo(identifier) then
        table.insert(repositories, 1, Repository.url(identifier):add(AUTO_PULL_REMOTES))
        system_bottle:invalidate_cache()
        if repo_only == nil then repo_only = true end
      else
        repo_only = false
        local potential_addons = { system_bottle:get_addon(id, version, { mod_version = system_bottle.lite_xl.mod_version, type = type }) }
        local addons = common.grep(potential_addons, function(e) return e:is_installable(system_bottle) and (not e:is_installed(system_bottle) or REINSTALL) end)
        if #addons == 0 and #potential_addons == 0 then error("can't find " .. (type or "addon") .. " " .. id .. " mod-version: " .. (system_bottle.lite_xl.mod_version or 'any')) end
        if #addons == 0 then
          log.warning((potential_addons[1].type or "addon") .. " " .. id .. " already installed")
          if not common.first(settings.installed, id) then table.insert(to_explicitly_install, id) end
        else
          for j,v in ipairs(addons) do
            if not common.first(settings.installed, v.id) then table.insert(to_explicitly_install, v.id) end
            table.insert(to_install, v)
          end
        end
      end
    end
  end
  if #to_install == 0 and repo_only == true then error("no addons specified for install") end
  local installing = {}
  common.each(to_install, function(e)
    if not installing[e.id] then
      e:install(system_bottle, installing)
    end
  end)
  settings.installed = common.concat(settings.installed, to_explicitly_install)
  lpm.settings_save()
end

local function get_table(headers, rows)
  local maxes = common.map(headers, function(h) return #h end)
  for i,row in ipairs(rows) do for k,v in ipairs(row) do
    if type(v) == "table" then v = table.concat(v, ", ") else v = tostring(v) end
    maxes[k] = math.max(#v, maxes[k] or 0)
  end end
  local strs = {}
  table.insert(strs, "| " .. table.concat(common.map(headers, function(v, i) return v .. string.rep(" ", maxes[i] - #v) end), " | ") .. " |")
  table.insert(strs, "| " .. table.concat(common.map(headers, function(v, i) return string.rep("-", maxes[i]) end), " | ") .. " |")
  for i,row in ipairs(rows) do
    table.insert(strs, "| " .. table.concat(common.map(row, function(v, i)
      if type(v) == "table" then v = table.concat(v, ", ") else v = tostring(v) end
      return v .. string.rep(" ", maxes[i] - #v)
    end), " | ") .. " |")
  end
  return table.concat(strs, "\n")
end

local function print_addon_info(type, addons, filters)
  local max_id = 4
  local plural = (type or "addon") .. "s"
  local result = { [plural] = { } }
  for j,addon in ipairs(addons) do
    max_id = math.max(max_id, #addon.id)
    local url = addon.name or addon.id
    if addon.remote then url = string.format("[`%s`](%s)\\*", addon.name or addon.id, addon.remote:gsub(":%w+$", ""))
    elseif addon.url then url = string.format("[`%s`](%s)\\*", addon.name or addon.id, addon.url)
    elseif addon.path and addon.path:find(".lua$") then url = string.format("[`%s`](%s?raw=1)", addon.name or addon.id, addon.path)
    elseif addon.path then url = string.format("[`%s`](%s)", addon.name or addon.id, addon.path) end
    local hash = {
      id = addon.id,
      status = addon.repository and (addon:is_installed(system_bottle) and "installed" or (system_bottle.lite_xl:is_compatible(addon) and "available" or "incompatible")) or (addon:is_bundled(system_bottle) and "bundled" or (addon:is_core(system_bottle) and "core" or (addon:is_upgradable(system_bottle) and "upgradable" or "orphan"))),
      stub = addon:is_stub(),
      name = addon.name or addon.id,
      version = "" .. addon.version,
      dependencies = addon.dependencies,
      remote = addon.remote,
      description = addon.description,
      author = addon.author or (addon:is_core(system_bottle) and "lite-xl") or nil,
      mod_version = addon.mod_version or LATEST_MOD_VERSION,
      tags = addon.tags,
      type = addon.type,
      organization = addon.organization,
      repository = addon.repository and addon.repository:url(),
      path = addon:get_path(system_bottle),
      repo_path = addon.repo_path or (addon.repository and addon.repository.local_path or nil),
      url = url
    }
    if addon_matches_filter(hash, filters or {}) then
      table.insert(result[plural], hash)
    end
  end
  if JSON then
    io.stdout:write(json.encode(result) .. "\n")
  elseif #result[plural] > 0 then
    local sorted = common.sort(result[plural], function(a,b) return a.id < b.id end)
    if not VERBOSE and not TABLE and not RAW then
      TABLE = { "id", "version", "type", "mod_version", "status" }
    end
    if TABLE then
      local addons = common.grep(sorted, function(addon) return addon.status ~= "incompatible" end)
      print(get_table(HEADER or common.map(TABLE, function(header)
        return ("" .. header:gsub("^%l", string.upper):gsub("_", " "))
      end), common.map(result[plural], function(addon)
        return common.map(TABLE, function(header) return _G.type(header) == "function" and header(addon) or addon[header] or "" end)
      end)))
    elseif RAW then
      local addons = common.grep(sorted, function(addon) return addon.status ~= "incompatible" end)
      print(common.join("\n", common.map(result[plural], function(addon)
        return common.join("\t", common.map(RAW, function(header) return _G.type(header) == "function" and header(addon) or addon[header] or "" end))
      end)))
    else
      for i, addon in ipairs(sorted) do
        if i ~= 0 then print("---------------------------") end
        print("ID:            " .. addon.id)
        print("Name:          " .. addon.name)
        print("Version:       " .. addon.version)
        print("Status:        " .. addon.status)
        print("Author:        " .. (addon.author or ""))
        print("Type:          " .. addon.type)
        print("Orgnization:   " .. addon.organization)
        print("Repository:    " .. (addon.repository or "orphan"))
        print("Remote:        " .. (addon.remote or ""))
        print("Description:   " .. (addon.description or ""))
        print("Mod-Version:   " .. (addon.mod_version or "unknown"))
        print("Dependencies:  " .. json.encode(addon.dependencies))
        print("Tags:          " .. common.join(", ", addon.tags))
        print("Path:          " .. (addon.path or ""))
      end
    end
  end
end


function lpm.unstub(type, ...)
  local addons = {}
  for i, identifier in ipairs({ ... }) do
    if not identifier then error('unrecognized identifier ' .. identifier) end
    if is_argument_repo(identifier) then
      table.insert(repositories, 1, Repository.url(identifier):add(AUTO_PULL_REMOTES))
      system_bottle:invalidate_cache()
    else
      local potential_addons = { system_bottle:get_addon(identifier, nil, { mod_version = system_bottle.lite_xl.mod_version }) }
      addons = common.grep(potential_addons, function(e) return e:is_stub() end)
      if #addons == 0 and #potential_addons == 0 then error("can't find " .. (type or "addon") .. " " .. identifier .. " mod-version: " .. (system_bottle.lite_xl.mod_version or 'any')) end
      if #addons == 0 then
        log.warning((potential_addons[1].type or "addon") .. " " .. identifier .. " already unstubbed")
      end
    end
  end
  common.each(addons, function(e) e:unstub() end)
  print_addon_info(nil, addons)
end


function lpm.addon_uninstall(type, ...)
  for i, id in ipairs({ ... }) do
    local addons = { system_bottle:get_addon(id, nil, { type = type }) }
    if #addons == 0 then error("can't find addon " .. id) end
    local installed_addons = common.grep(addons, function(e) return e:is_installed(system_bottle) and not e:is_core(system_bottle) end)
    if #installed_addons == 0 then error("addon " .. id .. " not installed") end
    for i, addon in ipairs(installed_addons) do
      addon:uninstall(system_bottle)
      settings.installed = common.grep(settings.installed, function(e) return e ~= addon.id end)
    end
  end
  lpm.settings_save()
end

function lpm.addon_reinstall(type, ...) for i, id in ipairs({ ... }) do pcall(lpm.addon_uninstall, type, id) end lpm.install(type, ...) end

function lpm.repo_list()
  if JSON then
    io.stdout:write(json.encode({ repositories = common.map(repositories, function(repo) return { remote = repo.remote, commit = repo.commit, branch = repo.branch, path = repo.local_path, remotes = common.map(repo.remotes or {}, function(r) return r:url() end)  } end) }) .. "\n")
  else
    for i, repository in ipairs(repositories) do
      local _, remotes = repository:parse_manifest()
      if i ~= 0 then print("---------------------------") end
      if not repository:is_local() then print("Remote :  " .. repository:url()) end
      print("Path   :  " .. repository.local_path)
      print("Remotes:  " .. json.encode(common.map(repository.remotes or {}, function(r) return r:url() end)))
    end
  end
end

function lpm.addon_list(type, id, filters)
  print_addon_info(type, common.grep(system_bottle:all_addons(), function(p) return (not type or p.type == type) and (not id or p.id:find(id)) end), filters)
end

function lpm.describe()
  local repo_urls = common.grep(common.map(repositories, function(e) return e:url() end), function(url) return #common.grep(DEFAULT_REPOS, function(r) return r:url() == url end) == 0  end)
  print("lpm run " .. common.join(" ", { system_bottle.lite_xl.version, table.unpack(repo_urls) }) .. " " .. common.join(" ", common.map(system_bottle:installed_addons(), function(p) return p.id .. ":" .. p.version end)))
end

function lpm.addon_upgrade()
  for i,addon in ipairs(system_bottle:installed_addons()) do
    local upgrade = common.sort({ system_bottle:get_addon(addon.id, ">" .. addon.version) }, function(a, b) return compare_version(b.version, a.version) end)[1]
    if upgrade then upgrade:install(system_bottle) end
  end
end

function lpm.self_upgrade(release)
  if not DEFAULT_RELEASE_URL or #DEFAULT_RELEASE_URL == 0 then error("self-upgrade has been disabled on lpm version " .. VERSION .. "; please upgrade it however you installed it") end
  release = release or "latest"
  local release_url = release and release:find("^https://") and release or (DEFAULT_RELEASE_URL:gsub("%%r", release))
  local stat = EXEFILE and system.stat(EXEFILE)
  if not stat then error("can't find lpm at " .. EXEFILE) end
  local new_temporary_file = SYSTMPDIR ..  PATHSEP .. "lpm.upgrade"
  local old_temporary_file = SYSTMPDIR ..  PATHSEP .. "lpm.backup"
  common.rmrf(new_temporary_file)
  common.rmrf(old_temporary_file)
  local status, err = pcall(common.get, release_url, { cache = SYSTMPDIR, target = new_temporary_file, callback = write_progress_bar })
  if not status then error("can't find release for lpm at " .. release_url .. (VERBOSE and (": " .. err) or  "")) end
  if common.is_path_different(new_temporary_file, EXEFILE) then
    status, err = pcall(common.rename, EXEFILE, old_temporary_file)
    if not status then error("can't move lpm executable; do you need to " .. (PLATFORM == "windows" and "run as administrator" or "be root") .. "?" .. (VERBOSE and ": " .. err or "")) end
    common.rename(new_temporary_file, EXEFILE)
    system.chmod(EXEFILE, stat.mode)
    if PLATFORM ~= "windows" then -- because we can't delete the running executbale on windows
      common.rmrf(old_temporary_file)
    end
    log.action("Upgraded lpm to " .. release .. ".")
  else
    log.warning("aborting upgrade; remote executable is identical to current")
    common.rmrf(new_temporary_file)
  end
end

function lpm.bottle_purge()
  common.rmrf(CACHEDIR .. PATHSEP .. "bottles")
end

function lpm.purge()
  log.action("Purged " .. CACHEDIR .. ".", "green")
  common.rmrf(CACHEDIR)
end



local function run_command(ARGS)
  if not ARGS[2]:find("%S") then return
  elseif ARGS[2] == "init" then return
  elseif ARGS[2] == "repo" and ARGS[3] == "add" then lpm.repo_add(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "repo" and ARGS[3] == "rm" then lpm.repo_rm(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "add" then lpm.repo_add(table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "rm" then lpm.repo_rm(table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "update" then lpm.repo_update(table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "repo" and ARGS[3] == "update" then lpm.repo_update(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "repo" and (#ARGS == 2 or ARGS[3] == "list") then return lpm.repo_list()
  elseif (ARGS[2] == "plugin" or ARGS[2] == "color" or ARGS[2] == "library" or ARGS[2] == "font") and ARGS[3] == "install" then lpm.install(ARGS[2], table.unpack(common.slice(ARGS, 4)))
  elseif (ARGS[2] == "plugin" or ARGS[2] == "color" or ARGS[2] == "library" or ARGS[2] == "font") and ARGS[3] == "uninstall" then lpm.addon_uninstall(ARGS[2], table.unpack(common.slice(ARGS, 4)))
  elseif (ARGS[2] == "plugin" or ARGS[2] == "color" or ARGS[2] == "library" or ARGS[2] == "font") and ARGS[3] == "reinstall" then lpm.addon_reinstall(ARGS[2], table.unpack(common.slice(ARGS, 4)))
  elseif (ARGS[2] == "plugin" or ARGS[2] == "color" or ARGS[2] == "library" or ARGS[2] == "font") and (#ARGS == 2 or ARGS[3] == "list") then return lpm.addon_list(ARGS[2], ARGS[4], ARGS)
  elseif ARGS[2] == "upgrade" then return lpm.addon_upgrade(table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "install" then lpm.install(nil, table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "unstub" then return lpm.unstub(nil, table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "uninstall" then lpm.addon_uninstall(nil, table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "reinstall" then lpm.addon_reinstall(nil, table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "describe" then lpm.describe(nil, table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "list" then return lpm.addon_list(nil, ARGS[3], ARGS)
  elseif ARGS[2] == "lite-xl" and (#ARGS == 2 or ARGS[3] == "list") then return lpm.lite_xl_list(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "lite-xl" and ARGS[3] == "uninstall" then return lpm.lite_xl_uninstall(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "lite-xl" and ARGS[3] == "install" then return lpm.lite_xl_install(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "lite-xl" and ARGS[3] == "switch" then return lpm.lite_xl_switch(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "lite-xl" and ARGS[3] == "run" then return lpm.lite_xl_run(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "lite-xl" and ARGS[3] == "add" then return lpm.lite_xl_add(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "lite-xl" and ARGS[3] == "rm" then return lpm.lite_xl_rm(table.unpack(common.slice(ARGS, 4)))
  elseif ARGS[2] == "lite-xl" then error("unknown lite-xl command: " .. ARGS[3])
  elseif ARGS[2] == "bottle" and ARGS[3] == "purge" then return lpm.bottle_purge(common.slice(ARGS, 4))
  elseif ARGS[2] == "run" then return lpm.lite_xl_run(table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "switch" then return lpm.lite_xl_switch(table.unpack(common.slice(ARGS, 3)))
  elseif ARGS[2] == "purge" then lpm.purge()
  else error("unknown command: " .. ARGS[2]) end
  if JSON then
    io.stdout:write(json.encode({ actions = actions, warnings = warnings }))
  end
end


local status = 0
local function error_handler(err)
  local s, e
  if err then s, e = err:find("%:%d+") end
  local message = e and err:sub(e + 3) or err
  if JSON then
    if VERBOSE then
      io.stderr:write(json.encode({ error = err, actions = actions, warnings = warnings, traceback = debug.traceback(nil, 2) }) .. "\n")
    else
      io.stderr:write(json.encode({ error = message or err, actions = actions, warnings = warnings }) .. "\n")
    end
  else
    if err then io.stderr:write(colorize((not VERBOSE and message or err) .. "\n", "red")) end
    if VERBOSE then io.stderr:write(debug.traceback(nil, 2) .. "\n") end
  end
  io.stderr:flush()
  status = -1
end
local function lock_warning()
  log.warning("waiting for lpm global lock to be released (only one instance of lpm can be run at once)")
end


xpcall(function()
  rawset(_G, "ARGS", ARGV)
  ARGS = common.args(ARGS, {
    json = "flag", userdir = "string", cachedir = "string", version = "flag", verbose = "flag",
    quiet = "flag", version = "flag", ["mod-version"] = "string", remotes = "flag", help = "flag",
    remotes = "flag", ["ssl-certs"] = "string", force = "flag", arch = "array", ["assume-yes"] = "flag",
    ["no-install-optional"] = "flag", datadir = "string", binary = "string", trace = "flag", progress = "flag",
    symlink = "flag", reinstall = "flag", ["no-color"] = "flag", config = "string", table = "string", header = "string",
    repository = "string", ephemeral = "flag", mask = "array", raw = "string", plugin = "array",
    -- filtration flags
    author = "array", tag = "array", stub = "array", dependency = "array", status = "array",
    type = "array", name = "array"
  })
  if ARGS["version"] then
    io.stdout:write(VERSION .. "\n")
    return 0
  end
  if ARGS["help"] or #ARGS == 1 or ARGS[2] == "help" then
    io.stdout:write([[
Usage: lpm COMMAND [...ARGUMENTS] [--json] [--userdir=directory]
  [--cachedir=directory] [--quiet] [--version] [--help] [--remotes]
  [--ssl-certs=directory/file] [--force] [--arch=]] .. _G.ARCH .. [[]
  [--assume-yes] [--no-install-optional] [--verbose] [--mod-version=3]
  [--datadir=directory] [--binary=path] [--symlink] [--post] [--reinstall]
  [--no-color] [--table=...] [--plugin=file/url]

LPM is a package manager for `lite-xl`, written in C (and packed-in lua).

It's designed to install packages from our central github repository (and
affiliated repositories), directly into your lite-xl user directory. It can
be called independently, or from the lite-xl `plugin_manager` addon.

LPM will always use
]] .. DEFAULT_REPO_URL .. [[

as its base repository, if none are present, and the cache directory
doesn't exist, but others can be added, and this base one can be removed.

It has the following commands:

  lpm init [repo 1] [repo 2] [...]         Implicitly called before all commands
                                           if necessary, but can be called
                                           independently to save time later, or
                                           to set things up differently.

                                           Adds the built in repository to your
                                           repository list, and all `remotes`.

                                           If repo 1 ... is specified, uses that
                                           list of repositories as the base instead.

                                           If "none" is specified, initializes
                                           an empty repository list.

  lpm repo list                            List all extant repos.
  lpm [repo] add <repository remote>       Add a source repository.
    [...<repository remote>]
  lpm [repo] rm <repository remote>        Remove a source repository.
    [...<repository remote>]
  lpm [repo] update [<repository remote>]  Update all/the specified repos.
    [...<repository remote>]
  lpm [plugin|library|color] install       Install specific addons.
    <addon id>[:<version>]                 If installed, upgrades.
    [...<addon id>:<version>]
  lpm [plugin|library|color] uninstall     Uninstall the specific addon.
    <addon id> [...<addon id>]
  lpm [plugin|library|color] reinstall     Uninstall and installs the specific addon.
   <addon id> [...<addon id>]

  lpm [plugin|library|color] list          List all/associated addons.
   <remote> [...<remote>]

  lpm upgrade                              Upgrades all installed addons
                                           to new version if applicable.
  lpm self-upgrade [version]               Upgrades lpm to a new version,
                                           if applicable. Defaults to
                                           latest.
  lpm [lite-xl] install <version>          Installs lite-xl. Infers the
    [binary] [datadir]                     paths on your system if not
                                           supplied. Automatically
                                           switches to be your system default
                                           if path auto inferred.
  lpm lite-xl add <version> <path>         Adds a local version of lite-xl to
                                           the managed list, allowing it to be
                                           easily bottled.
  lpm lite-xl rm <path>                    Removes a local version of lite-xl
                                           from the managed list.
  lpm [lite-xl] switch <version> [<path>]  Sets the active version of lite-xl
                                           to be the specified version. Auto-detects
                                           current install of lite-xl; if none found
                                           path can be specified.
  lpm lite-xl list [name pattern]          Lists all installed versions of
     [...filters]                          lite-xl. Can specify the flags listed
                                           in the filtering section.
  lpm run <version> [...addons]            Sets up a "bottle" to run the specified
                                           lite version, with the specified addons
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
  --datadir=directory      Sets the data directory where core addons are located
                           for the system lite-xl.
  --binary=path            Sets the lite-xl binary path for the system lite-xl.
  --verbose                Spits out more information, including intermediate
                           steps to install and whatnot.
  --quiet                  Outputs nothing but explicit responses.
  --mod-version=version    Sets the mod version of lite-xl to install addons.
  --version                Returns version information.
  --help                   Displays this help text.
  --ssl-certs              Sets the SSL certificate store. Can be a directory,
                           or path to a certificate bundle.
  --arch=architecture      Sets the architecture (default: ]] .. _G.ARCH .. [[).
  --assume-yes             Ignores any prompts, and automatically answers yes
                           to all.
  --no-install-optional    On install, anything marked as optional
                           won't prompt.
  --trace                  Dumps to stderr useful debugging information, in
                           particular information relating to SSL connections,
                           and other network activity.
  --progress               For JSON mode, lines of progress as JSON objects.
                           By default, JSON does not emit progress lines.
  --symlink                Use symlinks where possible when installing modules.
                           If a repository contains a file of the same name as a
                           `files` download in the primary directory, will also
                           symlink that, rather than downloading.
  --reinstall              Ignores that things may be the same, and attempts
                           to reinstall all modules.
  --no-color               Suppresses ANSI escape sequences that are emitted
                           when connected over a TTY.
  --config=string          When used with `run`, applies the literal supplied
                           config.
  --table                  Outputs things a markdown table, specify the columns
                           you'd like.
  --raw                    Outputs things in a raw format, separated by tabs
                           and newlines; specify the columns you'd like.
  --repository             For the duration of this command, do not load default
                           repositories, simply act as if the only repositories
                           are those specified in this option.
  --ephemeral              Designates a bottle as 'ephemeral', meaning that it
                           is fully cleaned up when lpm exits.
  --plugin                 Loads the specified plugin as part of lpm. Used
                           for customizing lpm for various tasks. Can be
                           specified as a remote URL. By default, will always
                           load all the plugins specified in $HOME/.config/lpm/plugins.

The following flags are useful when listing addons, or generating the addon
table. Putting a ! infront of the string will invert the filter. Multiple
filters of the same type can be specified to create an OR relationship.

  --author=author          Only display addons by the specified author.
  --tag=tag                Only display addons with the specified tag.
  --stub=git/file/false    Only display the specified stubs.
  --dependency=dep         Only display addons that have a dependency on the
                           specified addon.
  --status=status          Only display addons that have the specified status.
  --type=type              Only display addons on the specified type.
  --name=name              Only display addons that have a name which matches the
                           specified filter.

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
  --mask                   Excludes the specified addons from the operation
                           you're performing. Can break packages if you exclude
                           dependencies that the addon actually requires to run.
                           Ensure you know what you're doing if you use this.

There exist also other debug commands that are potentially useful, but are
not commonly used publically.

  lpm test <test file>               Runs the specified test suite.
  lpm exec <file|string>             Runs the specified lua file/string with the internal
                                     interpreter.
  lpm download <url> [target]        Downloads the specified URL to stdout,
                                     or to the specified target file.
  lpm hash <file>                    Returns the sha256sum of the file.
  lpm update-checksums <manifest>    Pulls all remote files, computes their
                                     checksums, and updates them in the file.
  lpm extract <file.[tar.gz|zip]>    Extracts the specified archive at
    [target]                         target, or the current working directory.
]]
    )
    return 0
  end

  VERBOSE = ARGS["verbose"] or false
  JSON = ARGS["json"] or os.getenv("LPM_JSON")
  QUIET = ARGS["quiet"] or os.getenv("LPM_QUIET")
  EPHEMERAL = ARGS["ephemeral"] or os.getenv("LPM_EPHEMERAL")
  local arg = ARGS["table"] or ARGS["raw"]
  if arg then
    local offset,s,e,i = 1, 1, 0, 1
    local result = {}
    while true do
      if arg:sub(offset, offset) == "{" then
        s,e = arg:find("%b{}", offset)
        if not e then error(string.format("no end to chunk %s", arg:sub(offset))) end
        local chunk = arg:sub(s + 1, e - 1)
        local func, err = load("local addon = ... return " .. chunk)
        if err then error(string.format("can't parse chunk %s: %s", chunk, err)) end
        result[i] = func
        offset = e + 1
      end
      s,e = arg:find("%s*,%s*", offset)
      if not e then s,e = #arg+1, #arg end
      if offset >= e then break end
      result[i] = arg:sub(offset, s - 1)
      offset = e + 1
      i = i + 1
    end
    if ARGS["table"] then
      TABLE = result
    else
      RAW = result
    end
  end
  HEADER = ARGS["header"] and { common.split("%s*,%s*", ARGS["header"]) }
  REPOSITORY = ARGS["repository"]
  FORCE = ARGS["force"]
  POST = ARGS["post"]
  CONFIG = ARGS["config"]
  SYMLINK = ARGS["symlink"]
  PROGRESS = ARGS["progress"]
  REINSTALL = ARGS["reinstall"]
  NO_COLOR = ARGS["no-color"]
  DATADIR = common.normalize_path(ARGS["datadir"])
  BINARY = common.normalize_path(ARGS["binary"])
  NO_INSTALL_OPTIONAL = ARGS["no-install-optional"]
  ARCH = ARGS["arch"] or { _G.ARCH }
  ASSUME_YES = ARGS["assume-yes"] or FORCE
  MOD_VERSION = ARGS["mod-version"] or os.getenv("LPM_MODVERSION")
  if MOD_VERSION == "any" then MOD_VERSION = nil end
  HOME = (os.getenv("USERPROFILE") or os.getenv("HOME")):gsub(PATHSEP .. "$", "")
  USERDIR = common.normalize_path(ARGS["userdir"]) or os.getenv("LITE_USERDIR") or (os.getenv("XDG_CONFIG_HOME") and os.getenv("XDG_CONFIG_HOME") .. PATHSEP .. "lite-xl")
    or (HOME and (HOME .. PATHSEP .. '.config' .. PATHSEP .. 'lite-xl'))
  AUTO_PULL_REMOTES = ARGS["remotes"]
  CACHEDIR = common.normalize_path(ARGS["cachedir"]) or os.getenv("LPM_CACHE") or USERDIR .. PATHSEP .. "lpm"
  TMPDIR = common.normalize_path(ARGS["tmpdir"]) or CACHEDIR .. PATHSEP .. "tmp"
  if ARGS["trace"] then system.trace(true) end

  MASK = {}
  if ARGS["mask"] then
    if type(ARGS["mask"]) ~= "table" then ARGS["mask"] = { ARGS["mask"] } end
    for i,v in ipairs(ARGS["mask"]) do
      MASK[v] = true
    end
  end

  if (not JSON and not QUIET and (TTY or PROGRESS)) or (JSON and PROGRESS) then
    local start_time, last_read
    local function format_bytes(bytes)
      if bytes < 1024 then return string.format("%6d  B", math.floor(bytes)) end
      if bytes < 1*1024*1024 then return string.format("%6.1f kB", bytes / 1024) end
      if bytes < 1*1024*1024*1024 then return string.format("%6.1f MB", bytes / (1024*1024))  end
      return string.format("%6.2f GB", bytes / (1024*1024*1024))
    end
    if JSON then
      write_progress_bar = function(total_read, total_objects_or_content_length, indexed_objects, received_objects, local_objects, local_deltas, indexed_deltas)
        if type(total_read) == "boolean" then
          io.stdout:write(json.encode({ progress = { percent = 1, label = progress_bar_label } }) .. "\n")
          io.stdout:flush()
          last_read = nil
          return
        end
        if not last_read then last_read = system.time() end
        if not last_read or system.time() - last_read > 0.05 then
          io.stdout:write(json.encode({ progress = { percent = (received_objects and (received_objects/total_objects_or_content_length) or (total_read/total_objects_or_content_length) or 0), label = progress_bar_label } }) .. "\n")
          io.stdout:flush()
          last_read = system.time()
        end
      end
    else
      write_progress_bar = function(total_read, total_objects_or_content_length, indexed_objects, received_objects, local_objects, local_deltas, indexed_deltas)
        if type(total_read) == "boolean" then
          if not last_read then io.stdout:write(progress_bar_label) end
          io.stdout:write("\n")
          io.stdout:flush()
          last_read = nil
          return
        end
        if not start_time or not last_read or total_read < last_read then start_time = system.time() end
        local status_line = total_objects_or_content_length and
          string.format("%s [%s/s][%03d%%]: ", format_bytes(total_read), format_bytes(total_read / (system.time() - start_time)), math.floor((received_objects and (received_objects/total_objects_or_content_length) or (total_read/total_objects_or_content_length) or 0)*100)) or
          string.format("%s [%s/s]: ", format_bytes(total_read), format_bytes(total_read / (system.time() - start_time)))
        local terminal_width = system.tcwidth(1)
        if not terminal_width then terminal_width = #status_line + #progress_bar_label end
        local characters_remaining = terminal_width - #status_line
        local message = progress_bar_label:sub(1, characters_remaining)
        io.stdout:write("\r")
        io.stdout:write(status_line .. message)
        io.stdout:flush()
        last_read = total_read
      end
    end
  end

  repositories = {}
  if ARGS[2] == "purge" then return lpm.purge() end
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

  local lpm_plugins_path = HOME .. PATHSEP .. ".config" .. PATHSEP .. "lpm" .. PATHSEP .. "plugins"
  local lpm_plugins = system.stat(lpm_plugins_path) and common.map(common.grep(system.ls(lpm_plugins_path), function(path) return path:find("%.lua$") end), function(path) return lpm_plugins_path .. PATHSEP .. path end) or {}
  local env = setmetatable({
    EXECUTABLE_EXTENSION = EXECUTABLE_EXTENSION, SHOULD_COLOR = SHOULD_COLOR, HOME = HOME, USERDIR = USERDIR, CACHEDIR = CACHEDIR, JSON = JSON, TABLE = TABLE, HEADER = HEADER, RAW = RAW, VERBOSE = VERBOSE, FILTRATION = FILTRATION, MOD_VERSION = MOD_VERSION, QUIET = QUIET, FORCE = FORCE, REINSTALL = REINSTALL, CONFIG = CONFIG,  NO_COLOR = NO_COLOR, AUTO_PULL_REMOTES = AUTO_PULL_REMOTES, ARCH = ARCH, ASSUME_YES = ASSUME_YES, NO_INSTALL_OPTIONAL = NO_INSTALL_OPTIONAL, TMPDIR = TMPDIR, DATADIR = DATADIR, BINARY = BINARY, POST = POST, PROGRESS = PROGRESS, SYMLINK = SYMLINK, REPOSITORY = REPOSITORY, EPHEMERAL = EPHEMERAL, MASK = MASK,
    Addon = Addon, Repository = Repository, LiteXL = LiteXL, Bottle = Bottle, lpm = lpm, common = common, json = json, log = log,
    settings = settings, repositories = repositories, lite_xls = lite_xls, system_bottle = system_bottle, progress_bar_label = progress_bar_label, write_progress_bar = write_progress_bar
  }, { __index = _G, __newindex = function(t, k, v) _G[k] = v end })
  for i,v in ipairs(common.concat(ARGS["plugin"] or {}, { common.split(":", os.getenv("LPM_PLUGINS") or "") }, lpm_plugins)) do
    if v ~= "" then
      local contents = v:find("^https?://") and common.get(v) or common.read(v)
      local func, err = load(contents, v, "bt", env)
      if func then
        func()
      else
        log.warning("unable to load lpm plugin " .. v .. ": " .. err)
      end
    end
  end

  for i,v in ipairs(ARGS) do
    if v:find("^%-%-") then
      if #v == 2 then break end
      error("unknown flag " .. v)
    end
  end

  -- Small utility functions that don't play into the larger app; are used for testing
  -- or for handy scripts.
  if ARGS[2] == "test" or ARGS[2] == "exec" then
    local arg = common.slice(ARGS, 4)
    arg[0] = ARGS[1]
    rawset(_G, "arg", arg)
    local chunk, err
    if system.stat(ARGS[3]) then
      chunk, err = load(common.read(ARGS[3]), ARGS[3], "bt", env)
    else
      chunk, err = load(ARGS[3], "", "bt", env)
    end
    if chunk then
      chunk(table.unpack(arg))
    else
      error(err)
    end
    os.exit(0)
  end
  if ARGS[2] == "download" then
    if ARGS[4] then log.progress_action("Downloading " .. ARGS[3]) end
    local file = common.get(ARGS[3], { target = ARGS[4], callback = write_progress_bar });
    if file then print(file) end
    os.exit(0)
  end
  if ARGS[2] == "hash" then
    print(system.hash(ARGS[3], "file"))
    os.exit(0)
  end
  if ARGS[2] == "extract" then
    system.extract(ARGS[3], ARGS[4] or ".")
    os.exit(0)
  end
  if ARGS[2] == "update-checksums" then
    if #ARGS == 2 then error("usage: lpm update-checksums manifest.json") end
    local contents = common.read(ARGS[3])
    local m = json.decode(contents)
    local computed = {}
    local filter
    if #ARGS > 3 then
      filter = {}
      for i, arg in ipairs(ARGS) do
        if i > 3 then filter[arg] = true end
      end
    end
    for _, section in ipairs(common.concat(m.addons or {}, m["lite-xls"] or {})) do
      for _, file in ipairs(common.concat({ section }, section.files or {})) do
        if (not filter or (section.id and filter[section.id])) and file.url and file.checksum ~= "SKIP" and type(file.checksum) == "string" then
          log.action("Computing checksum for " .. (section.id or section.version) .. " (" .. file.url .. ")...")
          local checksum = system.hash(common.get(file.url))
          if computed[file.checksum] and computed[file.checksum] ~= checksum then
            error("can't update manifest; existing checksum " .. file.checksum .. " exists in two separate places that now have disparate checksum values")
          end
          computed[file.checksum] = checksum
          contents = contents:gsub(file.checksum, checksum)
        end
      end
    end
    common.write(ARGS[3], contents)
    os.exit(0)
  end
  if ARGS[2] == "manifest" then
    local repo = Repository.url(ARGS[3])
    repo.branch = "master"
    repo:generate_manifest()
    os.exit(0)
  end
  if ARGS[2] == "self-upgrade" then
    lpm.self_upgrade(table.unpack(common.slice(ARGS, 3)))
    os.exit(0)
  end

  if not system.stat(USERDIR) then common.mkdirp(USERDIR) end
  -- Base setup; initialize default repos if applicable, read them in. Determine Lite XL system binary if not specified, and pull in a list of all local lite-xl's.
  if engage_locks(function()
    settings = { lite_xls = {}, repositories = {}, installed = {}, version = VERSION }
    lpm.repo_init(ARGS[2] == "init" and #ARGS > 2 and (ARGS[3] ~= "none" and common.map(common.slice(ARGS, 3), function(url) return Repository.url(url) end) or {}) or nil)
    repositories, lite_xls = {}, {}
    if system.stat(CACHEDIR .. PATHSEP .. "settings.json") then settings = json.decode(common.read(CACHEDIR .. PATHSEP .. "settings.json")) end
    repositories = common.map(settings.repositories or {}, function(url) local repo = Repository.url(url) repo:parse_manifest() return repo end)
    lite_xls = common.map(settings.lite_xls or {}, function(lite_xl) return LiteXL.new(nil, { version = lite_xl.version, mod_version = lite_xl.mod_version, binary_path = lite_xl.binary_path, datadir_path = lite_xl.datadir_path, path = lite_xl.path, tags = { "local" } }) end)

    if BINARY and not system.stat(BINARY) then error("can't find specified --binary") end
    if DATADIR and not system.stat(DATADIR) then error("can't find specified --datadir") end
    local lite_xl_binary = BINARY or common.path("lite-xl" .. EXECUTABLE_EXTENSION)
    if lite_xl_binary then
      local stat = system.stat(lite_xl_binary)
      if not stat then error("can't find lite-xl binary " .. lite_xl_binary) end
      lite_xl_binary = stat.symlink or lite_xl_binary
      local system_lite_xl = common.first(common.concat(common.flat_map(repositories, function(r) return r.lite_xls end), lite_xls), function(lite_xl) return lite_xl:get_binary_path() == lite_xl_binary end)
      if not system_lite_xl then
        system_lite_xl = common.first(lite_xls, function(e) return e.version == "system" end)

        local directory = common.dirname(lite_xl_binary)
        local lite_xl_datadirs = { DATADIR or "", directory .. PATHSEP .. "data", directory:find(PATHSEP .. "bin$") and common.dirname(directory) .. PATHSEP .. "share" .. PATHSEP .. "lite-xl" or "", directory .. PATHSEP .. "data" }
        local lite_xl_datadir = common.first(lite_xl_datadirs, function(p) return p and system.stat(p) end)

        if not BINARY and not DATADIR and system_lite_xl then error("can't find existing system lite (does " .. system_lite_xl:get_binary_path() .. " exist? was it moved?); run `lpm purge`, or specify --binary and --datadir.") end
        local detected_lite_xl = LiteXL.new(nil, { path = directory, datadir_path = lite_xl_datadir, binary_path = { [_G.ARCH] = lite_xl_binary }, mod_version = MOD_VERSION or LATEST_MOD_VERSION, version = "system", tags = { "system", "local" } })
        if not system_lite_xl then
          system_lite_xl = detected_lite_xl
          table.insert(lite_xls, system_lite_xl)
          lpm.lite_xl_save()
        else
          lite_xls = common.grep(lite_xls, function(e) return e ~= system_lite_xl end)
          system_lite_xl = detected_lite_xl
          table.insert(lite_xls, system_lite_xl)
        end
      else
        if DATADIR then system_lite_xl.datadir_path = DATADIR end
        table.insert(system_lite_xl.tags, "system")
      end
      system_bottle = Bottle.new(system_lite_xl, nil, nil, true)
    else
      system_bottle = Bottle.new(LiteXL.new(nil, { mod_version = MOD_VERSION or LATEST_MOD_VERSION, datadir_path = DATADIR, version = "system", tags = { "system", "local" } }), nil, nil, true)
    end
    if not system_bottle then system_bottle = Bottle.new(nil, nil, nil, true) end
    if REPOSITORY then repositories = common.map(type(REPOSITORY) == "table" and REPOSITORY or { REPOSITORY }, function(url) local repo = Repository.url(url) repo:parse_manifest() return repo end) end
  end, error_handler, lock_warning) then return end
  if ARGS[2] ~= '-' then
    local res
    engage_locks(function()
      res = run_command(ARGS)
    end, error_handler, lock_warning)
    if res then
      res()
    end
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
        local res
        engage_locks(function()
          res = run_command(args)
        end, error_handler, lock_warning)
        if res then
          res()
        end
      end, error_handler)
      actions, warnings = {}, {}
    end
  end
end, error_handler)


return status
