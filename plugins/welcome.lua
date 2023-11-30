-- mod-version:3 --lite-xl 2.1

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
local loading = nil

local hovered_button = nil
local function draw_button(view, x, y, w, button)
  local highlight = hovered_button == button
  if highlight then core.request_cursor("hand") end
  local button_height = style.font:get_height() + style.padding.y * 2
  renderer.draw_rect(x + w, y, button_height, button_height, highlight and style.dim or style.background2)
  renderer.draw_text(style.icon_font, "+", x + w + style.padding.x, y + style.padding.y + 2, style.accent)
  common.draw_text(style.font, highlight and style.accent or style.text, button.label, "left", x + style.padding.x, y, w, button_height)
  return x, y, w, button_height
end

local buttons = {
  { label = "Install Addons Package", command = "welcome:install-addons", tooltip = {
    "Will install the basic addons package for lite-xl.",
    "",
    "Includes all syntax higlightings, various themes, as well as a few extra plugins to help lite-xl a bit more easy to interact with.",
    "Recommened for newcomers to lite-xl. After install, your editor will silently restart, and you'll be fully ready to start with lite-xl."
  } },
  { label = "Open Plugin Manager", command = "welcome:open-plugin-manager", tooltip = { "Will open the plugin manager, and allow you to select which plugins you'd like to install before beginning with lite-xl." } },
  { label = "Dismiss Welcome Options", command = "welcome:dismiss", tooltip = { "Dismisses this screen, never to be seen again." } }
}

local old_get_name = EmptyView.get_name
function EmptyView:get_name() if welcomed then return old_get_name(self) end return "Welcome!" end

local old_draw = EmptyView.draw
function EmptyView:draw()
  if loading then
    local y = self.position.y + self.size.y / 2
    self:draw_background(style.background)
    PluginView.draw_loading_screen(self, loading.label, loading.percent)
    -- common.draw_text(style.big_font, style.dim, "Installing addons package. Please wait...", "center", self.position.x, y, self.size.x, style.font:get_height())
    return
  end
  old_draw(self)
  if welcomed then return end
  local x, y, w, h = self.position.x + self.size.x / 2

  local button_width = math.min(self.size.x / 2 - 80, 300)
  x = self.position.x + self.size.x / 2 - 50
  local button_height = style.padding.y * 2 + style.font:get_height()
  local y = self.position.y + self.size.y / 2 - ((button_height + style.padding.y) * #buttons) / 2 - style.padding.y
  renderer.draw_rect(x, y, button_width, #buttons * (button_height + style.padding.y), style.background)
  for i,v in ipairs(buttons) do
    v.x, v.y, v.w, v.h = draw_button(self, x + style.padding.x, y, button_width, v)
    y = y + v.h + style.padding.y * 2
  end

  if hovered_button then
    for i, v in ipairs(hovered_button.tooltip) do
      common.draw_text(style.font, style.dim, v, "center", self.position.x, y, self.size.x, style.font:get_height())
      y = y + style.font:get_height()
    end
  else
    common.draw_text(style.font, style.dim, "Hover over one of the options below to get started.", "center", self.position.x, y, self.size.x, style.font:get_height())
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

function EmptyView:on_mouse_released(button, x, y)
  if hovered_button and not welcomed then command.perform(hovered_button.command) end
end



local function terminate_welcome()
  io.open(USERDIR .. PATHSEP .. "welcomed", "wb"):close()
  welcomed = true
end

command.add(EmptyView, {
  ["welcome:install-addons"] = function()
    core.log("Installing addons...")
    loading = { percent = 0, label = "Initializing..." }
    core.redraw = true
    PluginManager:install({ id = "meta_addons" }, { progress = function(progress) loading = progress end, restart = false }):done(function()
      loading = false
      core.log("Addons installed!")
      terminate_welcome()
      command.perform("core:restart")
    end):fail(function(err)
      loading = true
      core.error(err)
    end)
  end,
  ["welcome:open-plugin-manager"] = function()
    command.perform("plugin-manager:show")
    terminate_welcome()
  end,
  ["welcome:dismiss"] = function()
    terminate_welcome()
  end
})

return {  }
