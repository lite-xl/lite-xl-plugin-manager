-- mod-version:4 --lite-xl 3.0

local core = require "core"
local style = require "core.style"
local command = require "core.command"
local keymap = require "core.keymap"
local View = require "core.view"
local common = require "core.common"
local EmptyView = require "core.emptyview"
local Node = require "core.node"

local PluginManager = require "plugins.plugin_manager"
local PluginView = require "plugins.plugin_manager.plugin_view"


local welcomed = system.get_file_info(USERDIR .. PATHSEP .. "welcomed") ~= nil
if welcomed then return end

local status, tv = pcall(require "plugins.treeview")
if not status then command.perform("treeview:toggle") end

local loading = nil

local hovered_button = nil
local function draw_button(view, x, y, w, button)
  local highlight = hovered_button == button
  if highlight then core.request_cursor("hand") end
  local button_height = style.font:get_height() + style.padding.y * 2
  local tw = common.draw_text(style.font, highlight and style.accent or style.text, button.label, "left", x, y, w, button_height)
  if tw < x + w then
    renderer.draw_rect(x + w, y - 3, button_height, button_height, highlight and style.dim or style.background2)
    renderer.draw_text(style.icon_font, "+", x + w + style.padding.x, y + style.padding.y, style.accent)
  end
  return x, y, w + button_height, button_height
end

local buttons = {
  { label = "Install Addons Package", command = "welcome:install-addons", tooltip = {
    "Installs syntax highlightings, themes, and plugins that make Lite XL easier to use.",
    "",
    "Recommended for newcomers to Lite XL.",
    "Requires a network connection."
  } },
  { label = "Open Plugin Manager", command = "welcome:open-plugin-manager", tooltip = { "Manually select plugins you'd like to install before beginning with Lite XL.", "", "Requires a network connection." } },
  { label = "Dismiss Welcome Options", command = "welcome:dismiss", tooltip = { "Dismisses this screen permanently." } }
}

local old_get_name = EmptyView.get_name
function EmptyView:get_name() if welcomed then return old_get_name(self) end return "Welcome!" end

local old_draw = EmptyView.draw
function EmptyView:draw()
  if welcomed then return old_draw(self) end
  self:draw_background(style.background)
  if loading then
    local y = self.position.y + self.size.y / 2
    self:draw_background(style.background)
    PluginView.draw_loading_screen(self, loading.label, loading.percent)
    return
  end


  local title = "Lite XL"
  local version = "version " .. VERSION
  local title_width = style.big_font:get_width(title)
  local version_width = style.font:get_width(version)

  local button_width = math.min(self.size.x / 2 - 80, 300)

  local th = style.big_font:get_height()
  local dh = 2 * th + style.padding.y * #buttons
  local w = math.max(title_width, version_width) + button_width + style.padding.x * 2 + math.ceil(1*SCALE)
  local h = (style.font:get_height() + style.padding.y) * #buttons + style.padding.y + style.font:get_height()
  local x = self.position.x + math.max(style.padding.x, (self.size.x - w) / 2)
  local y = self.position.y + (self.size.y - h) / 2


  local x1, y1 = x, y + ((dh - th) / #buttons)
  local xv = x1
  if version_width > title_width then
    version = VERSION
    version_width = style.font:get_width(version)
    xv = x1 - (version_width - title_width)
  end
  x = renderer.draw_text(style.big_font, title, x1, y1, style.dim)
  renderer.draw_text(style.font, version, xv, y1 + th, style.dim)
  x = x + style.padding.x
  renderer.draw_rect(x, y, math.ceil(1 * SCALE), dh, style.dim)

  x = x + style.padding.x

  local button_height = style.padding.y * 2 + style.font:get_height()
  renderer.draw_rect(x, y, button_width, #buttons * (button_height + style.padding.y), style.background)
  for i,v in ipairs(buttons) do
    v.x, v.y, v.w, v.h = draw_button(self, x + style.padding.x, y, button_width, v)
    y = y + v.h + style.padding.y * 2
  end

  if hovered_button then
    for i, v in ipairs(hovered_button.tooltip) do
      common.draw_text(style.font, style.text, v, "center", self.position.x, y + style.padding.y, self.size.x, style.font:get_height())
      y = y + style.font:get_height()
    end
  else
    common.draw_text(style.font, style.text, "Hover over one of the options above to get started.", "center", self.position.x, y + style.padding.y, self.size.x, style.font:get_height())
  end
end

function EmptyView:on_mouse_moved(x, y)
  hovered_button = nil
  for i,v in ipairs(buttons) do
    if v.x and x >= v.x and x < v.x + v.w and y >= v.y and y < v.y + v.h then
      hovered_button = v
    end
  end
end

function EmptyView:on_mouse_pressed(button, x, y)
  if hovered_button and not welcomed then command.perform(hovered_button.command) end
end



local function terminate_welcome()
  io.open(USERDIR .. PATHSEP .. "welcomed", "wb"):close()
  command.perform("treeview:toggle")
  welcomed = true
end

command.add(EmptyView, {
  ["welcome:install-addons"] = function()
    core.log("Installing addons...")
    loading = { percent = 0, label = "Initializing..." }
    core.redraw = true
    PluginManager:install({ id = "meta_addons" }, { progress = function(progress)
      loading = progress
      core.redraw = true
    end, restart = false }):done(function()
      loading = false
      core.log("Addons installed!")
      terminate_welcome()
      command.perform("core:restart")
    end):fail(function(err)
      loading = false
      core.redraw = true
      core.error(err or "Error installing addons.")
    end)
  end,
  ["welcome:open-plugin-manager"] = function()
    command.perform("plugin-manager:show")
  end,
  ["welcome:dismiss"] = function()
    terminate_welcome()
  end
})

