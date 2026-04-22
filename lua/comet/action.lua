-- Actions bound to User Interactions (Enter, Esc, Move)

local context = require("comet.context")
local filter = require("comet.filter")
local render = require("comet.ui.render")
local state = require("comet.state")
local window = require("comet.ui.window")
local api = vim.api
local M = {}

--- Shift selection in the left panel
---@param delta integer +1 for down, -1 for up
M.move = function(delta)
  local n = #state.current_items()
  if n == 0 then
    return
  end
  local S = state.get()
  local sub = state.current_sub()

  if sub then
    sub.selected = (sub.selected - 1 + delta) % n + 1
  else
    S.selected = (S.selected - 1 + delta) % n + 1
  end

  render.list()
end

--- Handle `<Esc>` or `q`: Either pop the menu stack or close the UI
M.handle_esc = function()
  local S = state.get()
  if #S.sub_stack > 0 then
    local popped = table.remove(S.sub_stack)
    if popped.on_cancel then
      popped.on_cancel()
    end

    local parent_title = S.list_title
    local parent_key = S.list_title

    if #S.sub_stack > 0 then
      local parent = S.sub_stack[#S.sub_stack]
      parent_title = parent.title
      parent_key = S.sub_stack[1].page_key
    end

    pcall(api.nvim_win_set_config, S.input_win, { title = " " .. parent_title .. " ", title_pos = "center" })

    window.switch_output_buf(parent_key)
    window.put_input_query(popped.saved_query or "")

    if #S.sub_stack > 0 then
      filter.filter_sub(S.last_query)
    else
      filter.filter_commands(S.last_query or "")
    end

    render.list()
  else
    window.close()
  end
end

--- Safely stop a running job using its context
M.stop_job = function()
  local S = state.get()
  if not (S and S.current_page_key and state.running_tasks[S.current_page_key]) then
    return
  end

  local task = state.running_tasks[S.current_page_key]
  if task.abort_fn and task.status == "running" then
    task.abort_fn()
    task.status = nil
    render.update_output_title()
  end
end

--- Execute the currently focused item
M.run_selected = function()
  local S = state.get()

  -- Block if running
  if
    S.block_while_running
    and state.running_tasks[S.current_page_key]
    and state.running_tasks[S.current_page_key].status == "running"
  then
    vim.api.nvim_echo({ { " Task is still running. Press <C-c> to stop it first.", "DiagnosticWarn" } }, false, {})
    return
  end

  local was_insert = api.nvim_get_mode().mode == "i"
  local items = state.current_items()
  local sel = state.current_selected()
  if #items == 0 then
    return
  end

  local item = items[sel]
  if not item then
    return
  end

  local trigger_name = type(item) == "table" and (item.name or "Item") or tostring(item)
  local sub = state.current_sub()

  if sub then
    if sub.multi_select then
      local selected_items = {}
      if vim.tbl_count(sub.marked) > 0 then
        for _, it in ipairs(sub.all_items) do
          local key = type(it) == "table" and it._idx or it
          if sub.marked[key] then
            table.insert(selected_items, it)
          end
        end
        if #selected_items > 1 then
          trigger_name = "Multi(" .. #selected_items .. ")"
        else
          local first = selected_items[1]
          trigger_name = type(first) == "table" and (first.name or "Item") or tostring(first)
        end
      else
        selected_items = { item }
      end

      local on_sel = sub.on_select
      local popped = table.remove(S.sub_stack)

      local parent_title = S.list_title
      local parent_key = S.list_title
      if #S.sub_stack > 0 then
        local parent = S.sub_stack[#S.sub_stack]
        parent_title = parent.title
        parent_key = S.sub_stack[1].page_key
      end

      pcall(api.nvim_win_set_config, S.input_win, { title = " " .. parent_title .. " ", title_pos = "center" })
      window.switch_output_buf(parent_key)
      window.put_input_query(popped.saved_query or "")

      if #S.sub_stack > 0 then
        filter.filter_sub(S.last_query)
      else
        filter.filter_commands(S.last_query or "")
      end

      render.list()
      if on_sel and #selected_items > 0 then
        on_sel(selected_items, context.make(trigger_name))
      end
    else
      if sub.on_select then
        sub.on_select(item, context.make(trigger_name))
      end
      render.list()
    end
  else
    if item.action then
      item.action(context.make(trigger_name))
    end
  end

  vim.schedule(function()
    if state.is_open() and S.input_win and api.nvim_win_is_valid(S.input_win) then
      local cur = api.nvim_get_current_win()
      if cur == S.input_win or cur == S.list_win or cur == S.output_win then
        api.nvim_set_current_win(S.input_win)
        if was_insert then
          vim.cmd("startinsert")
        end
      end
    end
  end)
end

local function get_mark_key(item)
  return type(item) == "table" and item._idx or item
end

--- Update multi-select title counter
local function update_multi_title()
  local S = state.get()
  local sub = state.current_sub()
  if not sub or not sub.multi_select then
    return
  end

  local count = vim.tbl_count(sub.marked)
  local title = sub.title
  if count > 0 then
    title = title .. " (" .. count .. " selected)"
  end

  pcall(api.nvim_win_set_config, S.input_win, { title = " " .. title .. " ", title_pos = "center" })
end

--- Toggle checkbox for current item in multi-select mode
M.toggle_mark = function()
  local sub = state.current_sub()
  if not sub or not sub.multi_select then
    return
  end
  local items, sel = sub.items, sub.selected
  if sel < 1 or sel > #items then
    return
  end

  local key = get_mark_key(items[sel])
  if sub.marked[key] then
    sub.marked[key] = nil
  else
    sub.marked[key] = true
  end

  update_multi_title()
  M.move(1)
end

return M
