
local core = require "core"
local style = require "core.style"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local json = require "libraries.json"
local View = require "core.view"
local keymap = require "core.keymap"
local RootView = require "core.rootview"
local ContextMenu = require "core.contextmenu"

local PluginView = View:extend()


local function join(joiner, t)
  local s = ""
  for i,v in ipairs(t) do if i > 1 then s = s .. joiner end s = s .. v end
  return s
end


local plugin_view = nil
PluginView.menu = ContextMenu()

PluginView.menu:register(nil, {
  { text = "Install", command = "plugin-manager:install-hovered" },
  { text = "Uninstall", command = "plugin-manager:uninstall-hovered" },
  { text = "View Source", command = "plugin-manager:view-source-hovered" }
})

function PluginView:new()
  PluginView.super.new(self)
  self.scrollable = true
  self.show_incompatible_plugins = false
  self.plugin_table_columns = { "ID", "Name", "Version", "Type", "Modversion", "Status", "Tags", "Author", "Description" }
  self.hovered_plugin = nil
  self.hovered_plugin_idx = nil
  self.selected_plugin = nil
  self.selected_plugin_idx = nil
  self.initialized = false
  self.plugin_manager = require "plugins.plugin_manager"
  self.plugin_manager:refresh():done(function()
    self.initialized = true
    self:refresh()
  end)
  plugin_view = self
end

local function get_plugin_text(plugin)
  return plugin.id, (plugin.name or plugin.id), plugin.version, plugin.type, plugin.mod_version, plugin.status, join(", ", plugin.tags), plugin.author or "unknown", plugin.description-- (plugin.description or ""):gsub("%[[^]+%]%([^)]+%)", "")
end


function PluginView:get_name()
  return "Plugin Manager"
end


local root_view_update = RootView.update
function RootView:update(...)
  root_view_update(self, ...)
  PluginView.menu:update()
end


local root_view_draw = RootView.draw
function RootView:draw(...)
  root_view_draw(self, ...)
  PluginView.menu:draw()
end


local root_view_on_mouse_moved = RootView.on_mouse_moved
function RootView:on_mouse_moved(...)
  if PluginView.menu:on_mouse_moved(...) then return end
  return root_view_on_mouse_moved(self, ...)
end


local on_view_mouse_pressed = RootView.on_view_mouse_pressed
function RootView.on_view_mouse_pressed(button, x, y, clicks)
  local handled = PluginView.menu:on_mouse_pressed(button, x, y, clicks)
  return handled or on_view_mouse_pressed(button, x, y, clicks)
end


function PluginView:on_mouse_moved(x, y, dx, dy)
  PluginView.super.on_mouse_moved(self, x, y, dx, dy)
  if self.initialized then
    local th = style.font:get_height()
    local lh = th + style.padding.y
    local offset = math.floor((y - self.position.y + self.scroll.y) / lh)
    self.hovered_plugin = offset > 0 and self:get_plugins()[offset]
    self.hovered_plugin_idx = offset > 0 and offset
  end
end


function PluginView:refresh()
  self.widths = {}
  for i,v in ipairs(self.plugin_table_columns) do
    table.insert(self.widths, style.font:get_width(v))
  end
  for i, plugin in ipairs(self:get_plugins()) do
    local t = { get_plugin_text(plugin) }
    for j = 1, #self.widths do  
      self.widths[j] = math.max(style.font:get_width(t[j] or ""), self.widths[j])
    end
  end
end


function PluginView:get_plugins()
  return self.show_incompatible_plugins and self.plugin_manager.addons or self.plugin_manager.valid_addons
end


function PluginView:get_scrollable_size()
  if not self.initialized then return math.huge end
  local th = style.font:get_height() + style.padding.y
  local plugins = self:get_plugins()
  return th * #self:get_plugins()
end


local function mul(color1, color2)
  return { color1[1] * color2[1] / 255, color1[2] * color2[2] / 255, color1[3] * color2[3] / 255, color1[4] * color2[4] / 255 }
end


function PluginView:draw()
  self:draw_background(style.background)
  if not self.initialized then 
    common.draw_text(style.big_font, style.dim, "Loading...", "center", self.position.x, self.position.y, self.size.x, self.size.y)
    return 
  end
  
  local th = style.font:get_height()
  local lh = th + style.padding.y

  local ox, oy = self:get_content_offset()
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  local x, y = ox + style.padding.x, oy
  for i, v in ipairs(self.plugin_table_columns) do
    common.draw_text(style.font, style.accent, v, "left", x, y, self.widths[i], lh)
    x = x + self.widths[i] + style.padding.x
  end
  oy = oy + lh
  for i, plugin in ipairs(self:get_plugins()) do
    local x, y = ox, oy
    if y + lh >= self.position.y and y <= self.position.y + self.size.y then
      if plugin == self.selected_plugin then 
        renderer.draw_rect(x, y, self.size.x, lh, style.dim)
      elseif plugin == self.hovered_plugin then
        renderer.draw_rect(x, y, self.size.x, lh, style.line_highlight)
      end
      x = x + style.padding.x
      for j, v in ipairs({ get_plugin_text(plugin) }) do
        local color = (plugin.status == "installed" or plugin.status == "bundled" or plugin.status == "orphan") and style.good or
          (plugin.status == "core" and style.warn or 
          (plugin.status == "special" and style.modified or style.text)
        )
        if self.loading then color = mul(color, style.dim) end
        common.draw_text(style.font, color, v, "left", x, y, self.widths[j], lh)
        x = x + self.widths[j] + style.padding.x
      end
    end
    oy = oy + lh
  end
  core.pop_clip_rect()
  PluginView.super.draw_scrollbar(self)
end

function PluginView:install(plugin)
  self.loading = true
  self.plugin_manager:install(plugin):done(function()
    self.loading = false
    self.selected_plugin, plugin_view.selected_plugin_idx = nil, nil
  end)
end

function PluginView:uninstall(plugin)
  self.loading = true
  self.plugin_manager:uninstall(plugin):done(function()
    self.loading = false
    self.selected_plugin, plugin_view.selected_plugin_idx = nil, nil
  end)
end


function PluginView:reinstall(plugin)
  self.loading = true
  self.plugin_manager:reinstall(plugin):done(function()
    self.loading = false
    self.selected_plugin, plugin_view.selected_plugin_idx = nil, nil
  end)
end

command.add(PluginView, {
  ["plugin-manager:select"] = function(x, y) 
    plugin_view.selected_plugin, plugin_view.selected_plugin_idx = plugin_view.hovered_plugin, plugin_view.hovered_plugin_idx 
  end,
  ["plugin-manager:select-prev"] = function()
    local plugins = plugin_view:get_plugins()
    if plugin_view.selected_plugin_idx > 1 then plugin_view.selected_plugin_idx = plugin_view.selected_plugin_idx - 1 end
    plugin_view.selected_plugin = plugins[plugin_view.selected_plugin_idx]
  end,
  ["plugin-manager:select-next"] = function()
    local plugins = plugin_view:get_plugins()
    if plugin_view.selected_plugin_idx < #plugins then plugin_view.selected_plugin_idx = plugin_view.selected_plugin_idx + 1 end
    plugin_view.selected_plugin = plugins[plugin_view.selected_plugin_idx]
  end,
  ["plugin-manager:select"] = function(x, y) 
    plugin_view.selected_plugin, plugin_view.selected_plugin_idx = plugin_view.hovered_plugin, plugin_view.hovered_plugin_idx 
  end,
})
command.add(function()
  return core.active_view and core.active_view:is(PluginView) and plugin_view.selected_plugin and plugin_view.selected_plugin.status == "available"
end, {
  ["plugin-manager:install-selected"] = function() plugin_view:install(plugin_view.selected_plugin) end
})
command.add(function()
  return core.active_view and core.active_view:is(PluginView) and plugin_view.hovered_plugin and plugin_view.hovered_plugin.status == "available"
end, {
  ["plugin-manager:install-hovered"] = function() plugin_view:install(plugin_view.hovered_plugin) end
})
command.add(function()
  return core.active_view and core.active_view:is(PluginView) and plugin_view.selected_plugin and (plugin_view.selected_plugin.status == "installed" or plugin_view.selected_plugin.status == "orphan" or plugin_view.selected_plugin.status == "bundled")
end, {
  ["plugin-manager:uninstall-selected"] = function() plugin_view:uninstall(plugin_view.selected_plugin) end
})
command.add(function()
  return core.active_view and core.active_view:is(PluginView) and plugin_view.hovered_plugin and (plugin_view.hovered_plugin.status == "installed" or plugin_view.hovered_plugin.status == "orphan" or plugin_view.hovered_plugin.status == "bundled")
end, {
  ["plugin-manager:uninstall-hovered"] = function() plugin_view:uninstall(plugin_view.hovered_plugin) end,
  ["plugin-manager:reinstall-hovered"] = function() plugin_view:reinstall(plugin_view.hovered_plugin) end
})
command.add(function()
  return core.active_view and core.active_view:is(PluginView) and plugin_view.hovered_plugin
end, {
  ["plugin-manager:view-source-hovered"] = function() 
    local directory = plugin_view.hovered_plugin.type == "library" and "libraries" or "plugins"
    local opened = false
    for i, path in ipairs({ plugin_view.hovered_plugin.path, plugin_view.hovered_plugin.path .. PATHSEP .. "init.lua" }) do
      local stat = system.get_file_info(path)
      if stat and stat.type == "file" then
        core.root_view:open_doc(core.open_doc(path))
        opened = true
      end
    end
    if not opened then core.error("Can't find source for plugin.") end
  end
})


keymap.add {
  ["up"]          = "plugin-manager:select-prev",
  ["down"]        = "plugin-manager:select-next",
  ["lclick"]      = "plugin-manager:select",
  ["2lclick"]     = { "plugin-manager:install-selected", "plugin-manager:uninstall-selected" },
  ["return"]      = { "plugin-manager:install-selected", "plugin-manager:uninstall-selected" }
}


return PluginView
