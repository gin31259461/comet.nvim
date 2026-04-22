local config = require("comet.config")
local events = require("comet.ui.events")
local render = require("comet.ui.render")
local state = require("comet.state")
local window = require("comet.ui.window")

local M = {}

--- Open the two-panel picker UI.
---@param commands CometCommand[] Array of Command Specs
---@param opts? CometOpts User options
M.open = function(commands, opts)
  -- 1. Close cleanly if already open
  if state.is_open() then
    window.close()
  end

  -- 2. Resolve opts
  local resolved_opts = config.resolve(opts)

  -- 3. Calculate Layout Mathematics
  local total_w = math.floor(vim.o.columns * 0.86)
  local total_h = math.floor(vim.o.lines * 0.78)
  local list_h = total_h - 3

  -- 4. Initialize Core State
  state.init(commands, resolved_opts, { list_h = list_h })

  -- 5. Build Windows and Map Buffers
  window.create_layout(total_w, total_h)

  -- 6. Setup Listeners
  events.setup()

  -- 7. Render UI
  render.list()
  render.update_output_title()

  -- 8. UX
  if resolved_opts.insert_mode then
    vim.cmd("startinsert")
  end
end

return M
