-- Neovim API bindings for creating layouts, closing floating windows, and focus management

local render = require("comet.ui.render")
local state = require("comet.state")
local api = vim.api
local M = {}

--- Set focus to the output panel
M.focus_output = function()
  local S = state.get()
  if not (S and S.output_win and api.nvim_win_is_valid(S.output_win)) then
    return
  end
  vim.cmd("stopinsert")
  api.nvim_set_current_win(S.output_win)
  vim.wo[S.output_win].cursorline = true
  render.update_output_title()
end

--- Return focus to the input panel
M.unfocus_output = function()
  local S = state.get()
  if not S then
    return
  end
  if S.output_win and api.nvim_win_is_valid(S.output_win) then
    vim.wo[S.output_win].cursorline = false
  end
  M.focus_input()
  render.update_output_title()
end

--- Ensure the input window is focused
M.focus_input = function()
  local S = state.get()
  if S and S.input_win and api.nvim_win_is_valid(S.input_win) then
    api.nvim_set_current_win(S.input_win)
    if S.insert_mode then
      vim.cmd("startinsert")
    end
  end
end

--- Switch output buffers within the right panel (cached per page_key)
---@param page_key string
M.switch_output_buf = function(page_key)
  local S = state.get()
  if not S then
    return
  end

  local buf = state.output_buf_cache[page_key]
  if not buf or not api.nvim_buf_is_valid(buf) then
    buf = api.nvim_create_buf(false, true)
    vim.bo[buf].modifiable = false
    vim.bo[buf].buftype = "nofile"
    state.output_buf_cache[page_key] = buf

    -- Lazy require to prevent circular dependency
    require("comet.ui.events").apply_output_keymaps(buf)
  end

  S.output_buf = buf
  S.current_page_key = page_key

  render.rehighlight_output(S.output_buf)

  if S.output_win and api.nvim_win_is_valid(S.output_win) then
    api.nvim_win_set_buf(S.output_win, S.output_buf)
    vim.wo[S.output_win].wrap = true
    render.update_output_title()
  end
end

--- Safely tear down UI and persist session state
M.close = function()
  if not state.is_open() then
    return
  end
  local S = state.get()

  if S.remember_page then
    state.persisted_states[S.list_title] = {
      sub_stack = vim.deepcopy(S.sub_stack),
      selected = S.selected,
      filtered = vim.deepcopy(S.filtered),
      last_query = S.last_query,
      current_page_key = S.current_page_key,
    }
  else
    state.persisted_states[S.list_title] = nil
  end

  pcall(vim.api.nvim_clear_autocmds, { group = "CometUI" })

  for _, win in ipairs({ S.input_win, S.list_win, S.output_win }) do
    pcall(api.nvim_win_close, win, true)
  end

  for _, buf in ipairs({ S.input_buf, S.list_buf }) do
    pcall(api.nvim_buf_delete, buf, { force = true })
  end

  state.clear()
  vim.cmd("stopinsert")
end

--- Creates the 3 physical floating windows (Input, List, Output)
---@param w_total integer
---@param h_total integer
M.create_layout = function(w_total, h_total)
  local S = state.get()

  local list_w = math.floor(w_total * 0.38)
  local output_w = w_total - list_w - 4
  local col_start = math.floor((vim.o.columns - w_total) / 2)
  local row_start = math.floor((vim.o.lines - h_total) / 2)

  S.input_buf = api.nvim_create_buf(false, true)
  S.list_buf = api.nvim_create_buf(false, true)

  -- Mount the proper output buf based on state
  M.switch_output_buf(S.current_page_key)

  S.input_win = api.nvim_open_win(S.input_buf, true, {
    relative = "editor",
    row = row_start,
    col = col_start,
    width = list_w,
    height = 1,
    border = "single",
    style = "minimal",
    title = " " .. S.current_page_key .. " ",
    title_pos = "center",
    zindex = 50,
  })

  S.list_win = api.nvim_open_win(S.list_buf, false, {
    relative = "editor",
    row = row_start + 3,
    col = col_start,
    width = list_w,
    height = S.list_h,
    border = "single",
    style = "minimal",
    zindex = 50,
  })

  S.output_win = api.nvim_open_win(S.output_buf, false, {
    relative = "editor",
    row = row_start,
    col = col_start + list_w + 2,
    width = output_w,
    height = h_total,
    border = "single",
    style = "minimal",
    title = " Output ",
    title_pos = "center",
    zindex = 50,
  })

  -- Styling
  local use_dark = vim.fn.hlID("ExBlack2Bg") ~= 0
  local win_hl = use_dark and "Normal:ExBlack2Bg,FloatBorder:ExBlack2Border"
    or "Normal:NormalFloat,FloatBorder:FloatBorder"

  for _, win in ipairs({ S.input_win, S.list_win, S.output_win }) do
    vim.wo[win].winhl = win_hl
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].cursorline = false
  end
  vim.wo[S.output_win].wrap = true

  vim.bo[S.list_buf].buftype = "nofile"
  vim.bo[S.input_buf].buftype = "prompt"
  vim.fn.prompt_setprompt(S.input_buf, S.prompt)
  vim.fn.prompt_setcallback(S.input_buf, function() end)
end

--- Input extraction helpers
M.take_input_query = function()
  local S = state.get()
  if not (S and S.input_buf and api.nvim_buf_is_valid(S.input_buf)) then
    return ""
  end
  local saved = S.last_query or ""
  local line = api.nvim_buf_get_lines(S.input_buf, 0, 1, false)[1] or S.prompt
  local plen = #S.prompt
  if #line > plen then
    api.nvim_buf_set_text(S.input_buf, 0, plen, 0, #line, { "" })
  end
  S.last_query = ""
  return saved
end

M.put_input_query = function(query)
  local S = state.get()
  if not (S and S.input_buf and api.nvim_buf_is_valid(S.input_buf)) then
    return
  end
  local line = api.nvim_buf_get_lines(S.input_buf, 0, 1, false)[1] or S.prompt
  local plen = #S.prompt
  if #line > plen then
    api.nvim_buf_set_text(S.input_buf, 0, plen, 0, #line, { "" })
  end
  if query ~= "" then
    line = api.nvim_buf_get_lines(S.input_buf, 0, 1, false)[1] or S.prompt
    api.nvim_buf_set_text(S.input_buf, 0, #line, 0, #line, { query })
  end
  S.last_query = query
end

return M
