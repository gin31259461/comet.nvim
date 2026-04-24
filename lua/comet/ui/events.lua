-- Neovim Events and Keymap Registrations

local action = require("comet.action")
local filter = require("comet.filter")
local render = require("comet.ui.render")
local state = require("comet.state")
local window = require("comet.ui.window")
local api = vim.api
local M = {}

--- Inject output panel specific keybinds dynamically onto dynamically created buffers
---@param buf integer
M.apply_output_keymaps = function(buf)
  local function km(mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true })
  end

  km("n", "<Esc>", window.unfocus_output)
  km("n", "q", window.unfocus_output)
  km("n", "<C-h>", window.unfocus_output)
  km("n", "<C-l>", window.focus_output)
  km({ "n", "i" }, "<C-i>", "<Nop>")
  km("n", "<C-c>", action.stop_job)
end

--- Bootstrap all event handlers onto the active layout
M.setup = function()
  local S = state.get()
  if not S then
    return
  end

  -- Setup Keymaps
  local function km(mode, lhs, fn, buf)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true })
  end

  for _, buf in ipairs({ S.input_buf, S.list_buf }) do
    km({ "n", "i" }, "<Esc>", action.handle_esc, buf)
    km("n", "q", action.handle_esc, buf)
    km({ "n", "i" }, "<C-c>", action.stop_job, buf)
    km({ "n", "i" }, "<C-l>", window.focus_output, buf)
    km({ "n", "i" }, "<C-h>", window.unfocus_output, buf)
    km({ "n", "i" }, "<C-i>", "<Nop>", buf)
  end

  km("i", "<C-j>", function()
    action.move(1)
  end, S.input_buf)
  km("i", "<C-k>", function()
    action.move(-1)
  end, S.input_buf)
  km("i", "<Down>", function()
    action.move(1)
  end, S.input_buf)
  km("i", "<Up>", function()
    action.move(-1)
  end, S.input_buf)
  km("i", "<CR>", action.run_selected, S.input_buf)

  km("n", "<C-j>", function()
    action.move(1)
  end, S.input_buf)
  km("n", "<C-k>", function()
    action.move(-1)
  end, S.input_buf)
  km("n", "j", function()
    action.move(1)
  end, S.input_buf)
  km("n", "k", function()
    action.move(-1)
  end, S.input_buf)
  km("n", "<CR>", action.run_selected, S.input_buf)

  km("n", "j", function()
    action.move(1)
  end, S.list_buf)
  km("n", "k", function()
    action.move(-1)
  end, S.list_buf)
  km("n", "<CR>", action.run_selected, S.list_buf)

  km({ "n", "i" }, "<Tab>", action.toggle_mark, S.input_buf)
  km("n", "<Tab>", action.toggle_mark, S.list_buf)

  -- Setup Autocmds
  local aug = api.nvim_create_augroup("CometUI", { clear = true })
  local prompt_bytes = #S.prompt

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = aug,
    buffer = S.input_buf,
    callback = function()
      local line = api.nvim_get_current_line()
      local query = line:sub(prompt_bytes + 1)
      S.last_query = query

      if state.current_sub() then
        state.current_sub().selected = 1
        filter.filter_sub(query)
      else
        S.selected = 1
        filter.filter_commands(query)
      end
      render.list()
    end,
  })

  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = aug,
    buffer = S.input_buf,
    callback = function()
      local cursor = api.nvim_win_get_cursor(0)
      local mode = api.nvim_get_mode().mode
      local line_len = #api.nvim_get_current_line()

      local min_col = prompt_bytes
      if mode:sub(1, 1) ~= "i" then
        min_col = math.min(prompt_bytes, math.max(0, line_len - 1))
      end

      if cursor[2] < min_col then
        pcall(api.nvim_win_set_cursor, 0, { cursor[1], min_col })
      end
    end,
  })

  api.nvim_create_autocmd("WinClosed", {
    group = aug,
    callback = function(ev)
      local closed = tonumber(ev.match)
      -- Always check the latest state dynamically to avoid stale closure issues
      if state.is_open() then
        local cur_S = state.get()
        if
          cur_S.input_win and (closed == cur_S.input_win or closed == cur_S.list_win or closed == cur_S.output_win)
        then
          vim.schedule(window.close)
        end
      end
    end,
  })
end

return M
