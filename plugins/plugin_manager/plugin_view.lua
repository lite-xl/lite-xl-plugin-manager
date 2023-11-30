
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

function PluginView:new()
  PluginView.super.new(self)
  self.scrollable = true
  self.progress = nil
  self.show_incompatible_plugins = false
  self.plugin_table_columns = { "Name", "Version", "Type", "Status", "Tags", "Author", "Description" }
  self.hovered_plugin = nil
  self.hovered_plugin_idx = nil
  self.selected_plugin = nil
  self.selected_plugin_idx = nil
  self.initialized = false
  self.offset_y = 1
  self.plugin_manager = require "plugins.plugin_manager"
  self.progress_callback = function(progress)
    self.progress = progress
    core.redraw = true
  end
  self:refresh()
  plugin_view = self
end

local function get_plugin_text(plugin)
  return (plugin.name or plugin.id), (plugin.status == "core" and VERSION or plugin.version), plugin.type, plugin.status, join(", ", plugin.tags), plugin.author or "unknown", plugin.description-- (plugin.description or ""):gsub("%[[^]+%]%([^)]+%)", "")
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
  self.loading = true
  return self.plugin_manager:refresh({ progress = self.progress_callback }):done(function()
    self.loading = false
    self.initialized = true
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
    local max = 0
    if self.widths then
      for i, v in ipairs(self.widths) do max = max + v end
    end
    self.max_width = max + style.padding.x * #self.widths
    core.redraw = true
  end)
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

function PluginView:get_h_scrollable_size()
  return self.max_width or 0
end

local function draw_loading_bar(x, y, width, height, percent)
  renderer.draw_rect(x, y, width, height, style.line_highlight)
  renderer.draw_rect(x, y, width * percent, height, style.caret)
end

function PluginView:draw_loading_screen(label, percent)
  common.draw_text(style.big_font, style.dim, "Loading...", "center", self.position.x, self.position.y, self.size.x, self.size.y)
  local width = self.size.x / 2
  local offset_y = self.size.y / 2
  if label or percent then
    local th = style.font:get_height()
    local lh = th + style.padding.y
    common.draw_text(style.font, style.dim, label, "center", self.position.x, self.position.y + offset_y + lh, self.size.x, lh)
    draw_loading_bar(self.position.x + (self.size.x / 2) - (width / 2), self.position.y + self.size.y / 2 + (lh * 2), width, lh, percent)
  end
end

function PluginView:draw()
  self:draw_background(style.background)
  local th = style.font:get_height()
  local lh = th + style.padding.y

  if not self.initialized or not self.widths then
    return self:draw_loading_screen(self.progress and self.progress.label, self.progress and self.progress.percent)
  end


  local ox, oy = self:get_content_offset()
  oy = oy + lh * self.offset_y

  local x, y = ox + style.padding.x, oy
  for i, v in ipairs(self.plugin_table_columns) do
    common.draw_text(style.font, style.accent, v, "left", x, self.position.y, self.widths[i], lh)
    x = x + self.widths[i] + style.padding.x
  end

  core.push_clip_rect(self.position.x, self.position.y + lh * self.offset_y, self.size.x, self.size.y)
  for i, plugin in ipairs(self:get_plugins()) do
    local x, y = ox, oy
    if y + lh >= self.position.y and y <= self.position.y + self.size.y then
      if plugin == self.selected_plugin then
        renderer.draw_rect(x, y, self.max_width or self.size.x, lh, style.dim)
      elseif plugin == self.hovered_plugin then
        renderer.draw_rect(x, y, self.max_width or self.size.x, lh, style.line_highlight)
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

  if self.loading and self.progress then
    draw_loading_bar(self.position.x, self.position.y, self.size.x, 2, self.progress.percent)
  end

  core.pop_clip_rect()
  PluginView.super.draw_scrollbar(self)
end

function PluginView:install(plugin)
  self.loading = true
  return self.plugin_manager:install(plugin, { progress = self.progress_callback }):done(function()
    self.loading = false
    self.selected_plugin, plugin_view.selected_plugin_idx = nil, nil
  end)
end

function PluginView:uninstall(plugin)
  self.loading = true
  return self.plugin_manager:uninstall(plugin, { progress = self.progress_callback }):done(function()
    self.loading = false
    self.selected_plugin, plugin_view.selected_plugin_idx = nil, nil
  end)
end


function PluginView:unstub(plugin)
  self.loading = true
  return self.plugin_manager:unstub(plugin, { progress = self.progress_callback }):done(function()
    self.loading = false
  end)
end

function PluginView:reinstall(plugin)
  self.loading = true
  return self.plugin_manager:reinstall(plugin, { progress = self.progress_callback }):done(function()
    self.loading = false
    self.selected_plugin, plugin_view.selected_plugin_idx = nil, nil
  end)
end


function PluginView:upgrade()
  self.loading = true
  return self.plugin_manager:upgrade({ progress = self.progress_callback }):done(function()
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
  ["plugin-manager:find"] = function()
    local plugin_names = {}
    local plugins = plugin_view:get_plugins()
    for i,v in ipairs(plugins) do
      table.insert(plugin_names, v.id)
    end
    table.sort(plugin_names)
    core.command_view:enter("Find Plugin", {
      submit = function(value)
        for i,v in ipairs(plugin_names) do
          if v == value then
            plugin_view.selected_plugin_idx = i
            plugin_view.selected_plugin = plugin_view:get_plugins()[i]
            local lh = style.font:get_height() + style.padding.y
            plugin_view.scroll.to.y = math.max(i * lh - plugin_view.size.y / 2, 0)
          end
        end
      end,
      suggest = function(value)
        return common.fuzzy_match(plugin_names, value)
      end
    })
  end,
  ["plugin-manager:scroll-page-up"] = function()
    plugin_view.scroll.to.y = math.max(plugin_view.scroll.y - plugin_view.size.y, 0)
  end,
  ["plugin-manager:scroll-page-down"] = function()
    plugin_view.scroll.to.y = math.min(plugin_view.scroll.y + plugin_view.size.y, plugin_view:get_scrollable_size())
  end,
  ["plugin-manager:scroll-page-top"] = function()
    plugin_view.scroll.to.y = 0
  end,
  ["plugin-manager:scroll-page-bottom"] = function()
    plugin_view.scroll.to.y = plugin_view:get_scrollable_size()
  end,
  ["plugin-manager:refresh-all"] = function() -- Separate command from `refresh`, because we want to only have the keycombo be valid on the plugin view screen.
    plugin_view:refresh():done(function() core.log("Successfully refreshed plugin listing.") end)
  end,
  ["plugin-manager:upgrade-all"] = function()
    plugin_view:upgrade():done(function() core.log("Successfully upgraded installed plugins.") end)
  end
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
    plugin_view:unstub(plugin_view.hovered_plugin):done(function(plugin)
      local opened = false
      for i, path in ipairs({ plugin.path, plugin.path .. PATHSEP .. "init.lua" }) do
        local stat = system.get_file_info(path)
        if stat and stat.type == "file" then
          core.root_view:open_doc(core.open_doc(path))
          opened = true
        end
      end
      if not opened then core.error("Can't find source for plugin.") end
    end)
  end,
  ["plugin-manager:view-readme-hovered"] = function()
    plugin_view:unstub(plugin_view.hovered_plugin):done(function(plugin)
      local opened = false
      local directories = { plugin.path }
      if plugin.repo_path then
        table.insert(directories, plugin.repo_path)
        table.insert(directories, ("" .. plugin.repo_path:gsub(PATHSEP .. "plugins" .. PATHSEP .. plugin.id .. "$", "")))
      end
      for _, directory in ipairs(directories) do
        for i, path in ipairs({ directory .. PATHSEP .. "README.md", directory .. PATHSEP .. "readme.md" }) do
          local stat = system.get_file_info(path)
          if stat and stat.type == "file" then
            core.root_view:open_doc(core.open_doc(path))
            opened = true
          end
        end
      end
      if not opened then core.error("Can't find README for plugin.") end
    end)
  end
})


keymap.add {
  ["up"]          = "plugin-manager:select-prev",
  ["down"]        = "plugin-manager:select-next",
  ["pagedown"]    = "plugin-manager:scroll-page-down",
  ["pageup"]      = "plugin-manager:scroll-page-up",
  ["home"]        = "plugin-manager:scroll-page-top",
  ["end"]         = "plugin-manager:scroll-page-bottom",
  ["lclick"]      = "plugin-manager:select",
  ["ctrl+f"]      = "plugin-manager:find",
  ["ctrl+r"]      = "plugin-manager:refresh-all",
  ["ctrl+u"]      = "plugin-manager:upgrade-all",
  ["2lclick"]     = { "plugin-manager:install-selected", "plugin-manager:uninstall-selected" },
  ["return"]      = { "plugin-manager:install-selected", "plugin-manager:uninstall-selected" }
}


PluginView.menu:register(function() return core.active_view:is(PluginView) end, {
  { text = "Install", command = "plugin-manager:install-hovered" },
  { text = "Uninstall", command = "plugin-manager:uninstall-hovered" },
  { text = "View Source", command = "plugin-manager:view-source-hovered" },
  { text = "View README", command = "plugin-manager:view-readme-hovered" },
  ContextMenu.DIVIDER,
  { text = "Refresh Listing", command = "plugin-manager:refresh-all" },
  { text = "Upgrade All", command = "plugin-manager:upgrade-all" },
})

return PluginView
