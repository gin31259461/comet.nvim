-- Handles writing to buffers, list rendering, and syntax highlighting

local state = require("comet.state")
local api = vim.api
local M = {}

local OUT_HL_PATTERNS = {
  { pat = "^%$ ", line_hl = "Comment" },
  { pat = "✓", line_hl = "DiagnosticOk" },
  { pat = "✗", line_hl = "DiagnosticError" },
  { pat = "Build succeeded", line_hl = "DiagnosticOk" },
  { pat = "Build FAILED", line_hl = "DiagnosticError" },
  { pat = "[Ww]arning%s", line_hl = "DiagnosticWarn" },
  { pat = "[Aa]bort%s", line_hl = "DiagnosticWarn" },
  { pat = "%[Process Terminated by User%]", line_hl = "DiagnosticWarn" },
  { pat = "[Ee]rror%s", line_hl = "DiagnosticError" },
  { pat = "Restored%s", line_hl = "DiagnosticOk" },
  { pat = "Passed!", line_hl = "DiagnosticOk" },
  { pat = "Failed!", line_hl = "DiagnosticError" },
}

--- Extmark patterns onto target buffer
---@param target_buf integer
---@param start_line integer
---@param end_line integer
M.highlight_output = function(target_buf, start_line, end_line)
  if not state.is_open() then
    return
  end

  local S = state.get()
  if not (S.out_ns and target_buf and api.nvim_buf_is_valid(target_buf)) then
    return
  end

  local lines = api.nvim_buf_get_lines(target_buf, start_line, end_line, false)
  for i, line in ipairs(lines) do
    local row = start_line + i - 1
    for _, rule in ipairs(OUT_HL_PATTERNS) do
      if line:find(rule.pat) then
        api.nvim_buf_set_extmark(target_buf, S.out_ns, row, 0, {
          line_hl_group = rule.line_hl,
        })
        break
      end
    end
  end
end

--- Clear and reapply highlights for the entire buffer
---@param target_buf integer
M.rehighlight_output = function(target_buf)
  local S = state.get()
  if not (S.out_ns and target_buf and api.nvim_buf_is_valid(target_buf)) then
    return
  end

  api.nvim_buf_clear_namespace(target_buf, S.out_ns, 0, -1)
  local line_count = api.nvim_buf_line_count(target_buf)
  M.highlight_output(target_buf, 0, line_count)
end

--- Update the output window title to reflect status
M.update_output_title = function()
  if not state.is_open() then
    return
  end

  local S = state.get()
  if not (S.output_win and api.nvim_win_is_valid(S.output_win)) then
    return
  end

  local title = " Output "
  if #S.sub_stack > 0 then
    title = title .. S.current_page_key .. " "
  end

  local status = state.running_tasks[S.current_page_key] and state.running_tasks[S.current_page_key].status or nil
  local is_focused = api.nvim_get_current_win() == S.output_win

  if status == "running" then
    title = title .. "[C-c: Stop]"
  elseif status == "done" then
    title = title .. "[Done]"
  elseif status == "abort" then
    title = title .. "[Abort]"
  elseif status == "error" then
    title = title .. "[Error]"
  end

  title = title .. (is_focused and "(focused) " or " ")

  pcall(api.nvim_win_set_config, S.output_win, { title = title, title_pos = "center" })
end

--- Append lines to the target buffer
---@param target_buf integer
---@param lines string|string[]
M.out_write = function(target_buf, lines)
  if not (target_buf and api.nvim_buf_is_valid(target_buf)) then
    return
  end
  if type(lines) == "string" then
    lines = vim.split(lines, "\n")
  end

  local to_write = {}
  for i, l in ipairs(lines) do
    if i < #lines or l ~= "" then
      table.insert(to_write, (l:gsub("\r", "")))
    end
  end
  if #to_write == 0 then
    return
  end

  vim.bo[target_buf].modifiable = true
  local n = api.nvim_buf_line_count(target_buf)
  local start = n
  if n == 1 and api.nvim_buf_get_lines(target_buf, 0, 1, false)[1] == "" then
    start = 0
  end
  api.nvim_buf_set_lines(target_buf, start, -1, false, to_write)
  vim.bo[target_buf].modifiable = false

  if state.is_open() then
    M.highlight_output(target_buf, start, start + #to_write)

    local S = state.get()
    if S.output_win and api.nvim_win_is_valid(S.output_win) and api.nvim_win_get_buf(S.output_win) == target_buf then
      local new_n = api.nvim_buf_line_count(target_buf)
      pcall(api.nvim_win_set_cursor, S.output_win, { new_n, 0 })
    end
  end
end

--- Clear target buffer
---@param target_buf integer
M.out_clear = function(target_buf)
  if not (target_buf and api.nvim_buf_is_valid(target_buf)) then
    return
  end

  vim.bo[target_buf].modifiable = true
  api.nvim_buf_set_lines(target_buf, 0, -1, false, {})
  vim.bo[target_buf].modifiable = false

  if state.is_open() then
    local S = state.get()
    if S.out_ns then
      api.nvim_buf_clear_namespace(target_buf, S.out_ns, 0, -1)
    end
  end
end

local function get_mark_key(item)
  return type(item) == "table" and item._idx or item
end

--- Render the left panel list based on current state
M.list = function()
  local S = state.get()
  if not (S.list_buf and api.nvim_buf_is_valid(S.list_buf)) then
    return
  end

  local items = state.current_items()
  local sel = state.current_selected()
  local sub = state.current_sub()
  local is_multi = sub and sub.multi_select

  api.nvim_buf_clear_namespace(S.list_buf, S.ns, 0, -1)
  vim.bo[S.list_buf].modifiable = true

  local lines = {}
  local mark_offsets = {}

  for idx, item in ipairs(items) do
    local mark = ""
    if is_multi and sub then
      mark = sub.marked[get_mark_key(item)] and "✓ " or "  "
    end
    mark_offsets[idx] = #mark
    if type(item) == "string" then
      table.insert(lines, "  " .. mark .. item)
    else
      table.insert(lines, "  " .. mark .. item.icon .. "  " .. item.name)
    end
  end

  while #lines < S.list_h do
    table.insert(lines, "")
  end
  api.nvim_buf_set_lines(S.list_buf, 0, -1, false, lines)

  -- Apply list highlights
  for i, item in ipairs(items) do
    local row = i - 1
    local is_sel = (i == sel)
    local moff = mark_offsets[i] or 0

    if is_sel then
      api.nvim_buf_set_extmark(S.list_buf, S.ns, row, 0, { line_hl_group = "Visual" })
    end

    if is_multi and moff > 0 and sub and sub.marked[get_mark_key(item)] then
      api.nvim_buf_set_extmark(S.list_buf, S.ns, row, 2, { end_col = 2 + moff, hl_group = "DiagnosticOk" })
    end

    if type(item) == "table" then
      local icon_hl = item.icon_hl or "String"
      local icon_start = 2 + moff
      local icon_end = icon_start + #item.icon
      api.nvim_buf_set_extmark(S.list_buf, S.ns, row, icon_start, { end_col = icon_end, hl_group = icon_hl })
      api.nvim_buf_set_extmark(
        S.list_buf,
        S.ns,
        row,
        icon_end + 2,
        { end_col = #lines[i], hl_group = is_sel and "CursorLineNr" or "Normal" }
      )
    else
      api.nvim_buf_set_extmark(
        S.list_buf,
        S.ns,
        row,
        2 + moff,
        { end_col = #lines[i], hl_group = is_sel and "CursorLineNr" or "Normal" }
      )
    end
  end

  vim.bo[S.list_buf].modifiable = false

  if S.list_win and api.nvim_win_is_valid(S.list_win) and sel > 0 and sel <= #items then
    pcall(api.nvim_win_set_cursor, S.list_win, { sel, 0 })
  end
end

return M
