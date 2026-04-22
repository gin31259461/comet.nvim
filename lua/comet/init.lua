-- comet.nvim – generic two-panel picker UI for Neovim
-- Left : search input (top) + item list (below)
-- Right: output / preview panel
--
-- Usage:
--   require("comet").open(commands, { title = "..." })
--
-- Command spec:
--   { name, icon, icon_hl?, desc?, action: fun(ctx) }
--
-- ctx passed to action:
--   ctx.write(lines)   – append string or string[] to output
--   ctx.clear()        – clear output
--   ctx.append(line)   – append a single line
--   ctx.select(items, opts) – push a sub-selection list onto the left panel
--     opts: { title?, multi_select?, on_select: fun(item_or_items, ctx), on_cancel?: fun() }

local M = {}
local api = vim.api

-- ── persistent state ──────────────────────────────────────────────────────────

-- Cache output buffers by page title to persist them across opens and depths
local output_buf_cache = {}

---@class RunningTaskInfo
---@field abort_fn fun(job_id: integer, ctx: CometCtx)|nil Function to call to signal the task to stop
---@field status "running"|"done"|"abort"|"error"|nil Current status of the task for UI display
---@field id integer|nil Job ID if applicable
---@field ctx CometCtx|nil Context passed to the task, useful for updating output on abort

--- Track running tasks by page key to manage their lifecycle and UI state
--- [page_key] -> RunningTaskInfo
---@type table<string, RunningTaskInfo>
local running_tasks = {}

--- Store the UI state (sub_stack, query, selection) across closing and reopening
---@type table|nil
local persisted_state = nil

-- ── active UI state ───────────────────────────────────────────────────────────

local S = {}

local function is_open()
  return S.ns ~= nil
end

-- ── output highlight patterns ─────────────────────────────────────────────────

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

-- ── output highlight helper ───────────────────────────────────────────────────

---@param target_buf integer The specific buffer to highlight
---@param start_line integer 0-based first line
---@param end_line integer 0-based one-past-last line
local function highlight_output(target_buf, start_line, end_line)
  -- Use target_buf instead of S.output_buf
  if not (target_buf and api.nvim_buf_is_valid(target_buf)) then
    return
  end
  if not S.out_ns then
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

--- Re-apply highlights for the entire buffer (used when reopening/switching)
---@param target_buf integer
local function rehighlight_output(target_buf)
  if not (target_buf and api.nvim_buf_is_valid(target_buf)) then
    return
  end
  if S.out_ns then
    api.nvim_buf_clear_namespace(target_buf, S.out_ns, 0, -1)
  end
  local line_count = api.nvim_buf_line_count(target_buf)
  highlight_output(target_buf, 0, line_count)
end

-- ── window helper ───────────────────────────────────────────────────

local function update_output_title()
  if not (S.output_win and api.nvim_win_is_valid(S.output_win)) then
    return
  end

  local title = " Output "

  -- Add page key indicator only if we are inside a sub-menu (level > 0)
  if #S.sub_stack > 0 then
    title = title .. S.current_page_key .. " "
  end

  -- Evaluate task status and window focus for ALL pages (including root)
  local status = running_tasks[S.current_page_key] and running_tasks[S.current_page_key].status or nil
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

  -- Apply focus indicator uniformly
  title = title .. (is_focused and "(focused) " or " ")

  pcall(api.nvim_win_set_config, S.output_win, {
    title = title,
    title_pos = "center",
  })
end

local function stop_job()
  local abort = running_tasks[S.current_page_key].abort_fn
  local job_id = running_tasks[S.current_page_key].id
  local ctx = running_tasks[S.current_page_key].ctx
  local status = running_tasks[S.current_page_key].status

  if abort and job_id and ctx and (status == "running") then
    abort(job_id, ctx)

    running_tasks[S.current_page_key].status = nil
    update_output_title()
  end
end

-- ── focus helpers ─────────────────────────────────────────────────────────────

local function focus_output()
  if not (S.output_win and api.nvim_win_is_valid(S.output_win)) then
    return
  end
  vim.cmd("stopinsert")
  api.nvim_set_current_win(S.output_win)
  vim.wo[S.output_win].cursorline = true
  update_output_title()
end

local function unfocus_output()
  if S.output_win and api.nvim_win_is_valid(S.output_win) then
    vim.wo[S.output_win].cursorline = false
  end
  if S.input_win and api.nvim_win_is_valid(S.input_win) then
    api.nvim_set_current_win(S.input_win)
    if S.insert_mode then
      vim.cmd("startinsert")
    end
  end
  update_output_title()
end

-- ── keymap helpers ───────────────────────────────────────────────────

local function apply_output_keymaps(buf)
  local function km(mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true })
  end

  -- Output keybinds (replacing the ones previously in setup_keymaps)
  km("n", "<Esc>", unfocus_output)
  km("n", "q", unfocus_output)
  km("n", "<C-h>", unfocus_output)
  km("n", "<C-l>", focus_output)
  km({ "n", "i" }, "<C-i>", "<Nop>")

  -- Stop job from output panel
  km("n", "<C-c>", stop_job)
end

-- ── output helpers ────────────────────────────────────────────────────────────

---@param target_buf integer The buffer where the output should be written
---@param lines string|string[]
local function out_write(target_buf, lines)
  if not (target_buf and api.nvim_buf_is_valid(target_buf)) then
    return
  end
  if type(lines) == "string" then
    lines = vim.split(lines, "\n")
  end

  -- Strip trailing empty string from jobstart and \r from CRLF
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

  highlight_output(target_buf, start, start + #to_write)

  -- Scroll only if the output window is currently displaying this specific buffer
  if S.output_win and api.nvim_win_is_valid(S.output_win) then
    if api.nvim_win_get_buf(S.output_win) == target_buf then
      local new_n = api.nvim_buf_line_count(target_buf)
      pcall(api.nvim_win_set_cursor, S.output_win, { new_n, 0 })
    end
  end
end

---@param target_buf integer The buffer to clear
local function out_clear(target_buf)
  if not (target_buf and api.nvim_buf_is_valid(target_buf)) then
    return
  end
  vim.bo[target_buf].modifiable = true
  api.nvim_buf_set_lines(target_buf, 0, -1, false, {})
  vim.bo[target_buf].modifiable = false
  if S.out_ns then
    api.nvim_buf_clear_namespace(target_buf, S.out_ns, 0, -1)
  end
end

---Switch the output buffer to the one associated with the given page key
---@param page_key string
local function switch_output_buf(page_key)
  local buf = output_buf_cache[page_key]

  if not buf or not api.nvim_buf_is_valid(buf) then
    buf = api.nvim_create_buf(false, true)
    vim.bo[buf].modifiable = false
    vim.bo[buf].buftype = "nofile"
    output_buf_cache[page_key] = buf

    -- Apply keymaps directly when a new output buffer is created
    apply_output_keymaps(buf)
  end

  S.output_buf = buf
  S.current_page_key = page_key

  rehighlight_output(S.output_buf)

  if S.output_win and api.nvim_win_is_valid(S.output_win) then
    api.nvim_win_set_buf(S.output_win, S.output_buf)
    vim.wo[S.output_win].wrap = true
    update_output_title()
  end
end
-- ── close ─────────────────────────────────────────────────────────────────────

local function do_close()
  if not is_open() then
    return
  end

  if S.remember_page then
    persisted_state = {
      sub_stack = S.sub_stack,
      selected = S.selected,
      filtered = S.filtered,
      last_query = S.last_query,
      current_page_key = S.current_page_key,
    }
  else
    persisted_state = nil
  end

  for _, win in ipairs({ S.input_win, S.list_win, S.output_win }) do
    pcall(api.nvim_win_close, win, true)
  end

  -- NOTE: ONLY delete input and list buffers; spare the output buffer
  for _, buf in ipairs({ S.input_buf, S.list_buf }) do
    pcall(api.nvim_buf_delete, buf, { force = true })
  end
  S = {}
  vim.cmd("stopinsert")
end

-- ── list rendering ────────────────────────────────────────────────────────────

local function current_sub()
  return S.sub_stack and S.sub_stack[#S.sub_stack]
end

local function current_items()
  local sub = current_sub()
  return sub and sub.items or S.filtered
end

local function current_selected()
  local sub = current_sub()
  return sub and sub.selected or S.selected
end

---@param item any
---@return any
local function get_mark_key(item)
  if type(item) == "table" then
    return item._idx
  end
  return item
end

local function render_list()
  if not (S.list_buf and api.nvim_buf_is_valid(S.list_buf)) then
    return
  end

  local items = current_items()
  local sel = current_selected()
  local sub = current_sub()
  local is_multi = sub and sub.multi_select

  api.nvim_buf_clear_namespace(S.list_buf, S.ns, 0, -1)
  vim.bo[S.list_buf].modifiable = true

  local lines = {}
  local mark_offsets = {}
  for idx, item in ipairs(items) do
    local mark = ""
    if is_multi then
      local key = get_mark_key(item)
      mark = sub.marked[key] and "✓ " or "  "
    end
    mark_offsets[idx] = #mark
    if type(item) == "string" then
      table.insert(lines, "  " .. mark .. item)
    else
      table.insert(lines, "  " .. mark .. item.icon .. "  " .. item.name)
    end
  end
  -- Pad to fill window height
  while #lines < S.list_h do
    table.insert(lines, "")
  end

  api.nvim_buf_set_lines(S.list_buf, 0, -1, false, lines)

  for i, item in ipairs(items) do
    local row = i - 1
    local is_sel = (i == sel)
    local moff = mark_offsets[i] or 0

    if is_sel then
      api.nvim_buf_set_extmark(S.list_buf, S.ns, row, 0, {
        line_hl_group = "Visual",
      })
    end

    if is_multi and moff > 0 and sub.marked[get_mark_key(item)] then
      api.nvim_buf_set_extmark(S.list_buf, S.ns, row, 2, {
        end_col = 2 + moff,
        hl_group = "DiagnosticOk",
      })
    end

    if type(item) ~= "string" then
      local icon_hl = item.icon_hl or "String"
      local icon_start = 2 + moff
      local icon_end = icon_start + #item.icon
      api.nvim_buf_set_extmark(S.list_buf, S.ns, row, icon_start, {
        end_col = icon_end,
        hl_group = icon_hl,
      })
      local name_hl = is_sel and "CursorLineNr" or "Normal"
      api.nvim_buf_set_extmark(S.list_buf, S.ns, row, icon_end + 2, {
        end_col = #lines[i],
        hl_group = name_hl,
      })
    else
      local hl = is_sel and "CursorLineNr" or "Normal"
      api.nvim_buf_set_extmark(S.list_buf, S.ns, row, 2 + moff, {
        end_col = #lines[i],
        hl_group = hl,
      })
    end
  end

  vim.bo[S.list_buf].modifiable = false

  if S.list_win and api.nvim_win_is_valid(S.list_win) then
    local sel_row = current_selected()
    if sel_row > 0 and sel_row <= #items then
      pcall(api.nvim_win_set_cursor, S.list_win, { sel_row, 0 })
    end
  end
end

-- ── filter ────────────────────────────────────────────────────────────────────

local function filter_commands(query)
  if not query or query == "" then
    S.filtered = vim.deepcopy(S.commands)
  else
    local q = query:lower()
    S.filtered = {}
    for _, item in ipairs(S.commands) do
      if item.name:lower():find(q, 1, true) or (item.desc and item.desc:lower():find(q, 1, true)) then
        table.insert(S.filtered, item)
      end
    end
  end
  S.selected = math.min(S.selected, math.max(1, #S.filtered))
end

local function filter_sub(query)
  local sub = current_sub()
  if not sub then
    return
  end
  if not query or query == "" then
    sub.items = vim.deepcopy(sub.all_items)
  else
    local q = query:lower()
    sub.items = {}
    for _, item in ipairs(sub.all_items) do
      local text = type(item) == "string" and item or (item.name or "")
      if text:lower():find(q, 1, true) then
        table.insert(sub.items, item)
      end
    end
  end
  sub.selected = math.min(sub.selected, math.max(1, #sub.items))
end

-- ── input query helpers ───────────────────────────────────────────────────────

---@return string
local function take_input_query()
  if not (S.input_buf and api.nvim_buf_is_valid(S.input_buf)) then
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

---@param query string
local function put_input_query(query)
  if not (S.input_buf and api.nvim_buf_is_valid(S.input_buf)) then
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

-- ── ctx factory ───────────────────────────────────────────────────────────────

---@param trigger_name string
---@return CometCtx
local function make_ctx(trigger_name)
  -- Capture the currently active buffer and page key at context creation time.
  -- This locks the output destination for this specific task.
  local target_buf = S.output_buf
  local target_page_key = S.current_page_key

  ---@type CometCtx
  local ctx = {
    write = function(lines)
      out_write(target_buf, lines)
    end,

    clear = function()
      out_clear(target_buf)
    end,

    append = function(line)
      out_write(target_buf, line)
    end,

    ---Register a function to be called when user presses send stop signal. Pass nil to clear.
    start_async_task = function(job_id, abort_fn)
      -- HACK:
      -- DYNAMIC EVALUATION: Fetch the current page key at execution time.
      -- If the action logic changed the page (e.g., via ctx.select) before
      -- starting the job, this ensures the task is tracked under the newly
      -- activated page, displaying the "running" state correctly.
      local pk = S.current_page_key

      running_tasks[pk].abort_fn = abort_fn or S.default_abort_fn
      running_tasks[pk].status = "running"
      running_tasks[pk].id = job_id
      vim.schedule(update_output_title)
    end,

    done = function()
      -- HACK:
      -- CLOSURE BINDING: Always use the originally captured page key.
      -- Task completion is asynchronous. Even if the user has navigated away
      -- (e.g., back to the root page), this guarantees the completion status
      -- ("done") is applied to the exact page that spawned the task.
      if running_tasks[target_page_key] then
        running_tasks[target_page_key].status = "done"
        vim.schedule(update_output_title)
      end
    end,

    error = function()
      if running_tasks[target_page_key] then
        running_tasks[target_page_key].status = "error"
        vim.schedule(update_output_title)
      end
    end,

    select = function(items, opts)
      local saved = take_input_query()
      local all = vim.deepcopy(items)
      for i, it in ipairs(all) do
        if type(it) == "table" then
          it._idx = i
        end
      end

      local sub_title = opts.title or "Select"

      -- Key Logic: If entering level 2 from root, use the item's name (e.g., "build").
      -- If entering level 3+, reuse the base level 2 page_key so they all share the same buffer.
      if #S.sub_stack == 0 then
        target_page_key = trigger_name
      else
        target_page_key = S.sub_stack[1].page_key
      end

      table.insert(S.sub_stack, {
        all_items = all,
        items = vim.deepcopy(all),
        selected = 1,
        on_select = opts.on_select,
        on_cancel = opts.on_cancel,
        title = sub_title,
        page_key = target_page_key, -- Store the shared key in the stack
        saved_query = saved,
        multi_select = opts.multi_select or false,
        marked = {},
      })

      -- Switch to the shared branch buffer
      switch_output_buf(target_page_key)

      pcall(api.nvim_win_set_config, S.input_win, {
        title = " " .. sub_title .. " ",
        title_pos = "center",
      })
      render_list()
      if S.input_win and api.nvim_win_is_valid(S.input_win) then
        api.nvim_set_current_win(S.input_win)
        if S.insert_mode then
          vim.cmd("startinsert")
        end
      end
    end,
  }
  running_tasks[S.current_page_key] = { abort_fn = S.default_abort_fn, ctx = ctx, status = nil, id = nil } -- Initialize task tracking for this trigger name
  return ctx
end

-- ── execute selected ──────────────────────────────────────────────────────────

local function run_selected()
  -- Prevent execution if a job is currently running and the option is enabled
  if
    S.block_while_running
    and running_tasks[S.current_page_key]
    and running_tasks[S.current_page_key].status == "running"
  then
    vim.api.nvim_echo({
      { " Task is still running. Press <C-c> to stop it first.", "DiagnosticWarn" },
    }, false, {})
    return
  end

  local was_insert = api.nvim_get_mode().mode == "i"
  local items = current_items()
  local sel = current_selected()
  if #items == 0 then
    return
  end
  local item = items[sel]
  if not item then
    return
  end

  -- Identify the trigger item's name to scope child buffers correctly
  local trigger_name = type(item) == "table" and (item.name or "Item") or tostring(item)

  local sub = current_sub()
  if sub then
    if sub.multi_select then
      local selected_items = {}
      if vim.tbl_count(sub.marked) > 0 then
        for _, it in ipairs(sub.all_items) do
          if sub.marked[get_mark_key(it)] then
            table.insert(selected_items, it)
          end
        end
        -- Adjust trigger name if multiple items are executed
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
        -- Restore to the shared branch buffer if still in a sub-menu
        parent_key = S.sub_stack[1].page_key
      end

      pcall(api.nvim_win_set_config, S.input_win, {
        title = " " .. parent_title .. " ",
        title_pos = "center",
      })

      switch_output_buf(parent_key)

      put_input_query(popped.saved_query or "")
      if #S.sub_stack > 0 then
        filter_sub(S.last_query)
      else
        filter_commands(S.last_query or "")
      end

      render_list()
      if on_sel and #selected_items > 0 then
        on_sel(selected_items, make_ctx(trigger_name))
      end
    else
      if sub.on_select then
        sub.on_select(item, make_ctx(trigger_name))
      end
      render_list()
    end
  else
    if item.action then
      item.action(make_ctx(trigger_name))
    end
  end

  vim.schedule(function()
    if is_open() and S.input_win and api.nvim_win_is_valid(S.input_win) then
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

-- ── navigation ────────────────────────────────────────────────────────────────

local function move(delta)
  local n = #current_items()
  if n == 0 then
    return
  end
  local sub = current_sub()
  if sub then
    sub.selected = (sub.selected - 1 + delta) % n + 1
  else
    S.selected = (S.selected - 1 + delta) % n + 1
  end
  render_list()
end

local function handle_esc()
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
      -- Restore to the shared branch buffer if still in a sub-menu
      parent_key = S.sub_stack[1].page_key
    end

    pcall(api.nvim_win_set_config, S.input_win, {
      title = " " .. parent_title .. " ",
      title_pos = "center",
    })

    switch_output_buf(parent_key)

    put_input_query(popped.saved_query or "")
    if #S.sub_stack > 0 then
      filter_sub(S.last_query)
    else
      filter_commands(S.last_query or "")
    end
    render_list()
  else
    do_close()
  end
end

-- ── multi-select helpers ──────────────────────────────────────────────────────

local function update_multi_title()
  local sub = current_sub()
  if not sub or not sub.multi_select then
    return
  end
  local count = vim.tbl_count(sub.marked)
  local title = sub.title
  if count > 0 then
    title = title .. " (" .. count .. " selected)"
  end
  pcall(api.nvim_win_set_config, S.input_win, {
    title = " " .. title .. " ",
    title_pos = "center",
  })
end

local function toggle_mark()
  local sub = current_sub()
  if not sub or not sub.multi_select then
    return
  end
  local items = sub.items
  local sel = sub.selected
  if sel < 1 or sel > #items then
    return
  end
  local item = items[sel]
  local key = get_mark_key(item)
  if sub.marked[key] then
    sub.marked[key] = nil
  else
    sub.marked[key] = true
  end
  update_multi_title()
  move(1)
end

-- ── keymaps ───────────────────────────────────────────────────────────────────
--

local function setup_keymaps()
  local function km(mode, lhs, fn, buf)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true })
  end

  -- Shared keymaps for input and list buffers
  for _, buf in ipairs({ S.input_buf, S.list_buf }) do
    -- Close UI
    km({ "n", "i" }, "<Esc>", handle_esc, buf)
    km("n", "q", handle_esc, buf)

    -- Abort running task
    km({ "n", "i" }, "<C-c>", stop_job, buf)

    -- Focus / unfocus output panel
    km({ "n", "i" }, "<C-l>", focus_output, buf)
    km({ "n", "i" }, "<C-h>", unfocus_output, buf)

    -- Nop (prevent unintended jumps)
    km({ "n", "i" }, "<C-i>", "<Nop>", buf)
  end

  -- Navigate list from input (insert mode)
  km("i", "<C-j>", function()
    move(1)
  end, S.input_buf)
  km("i", "<C-k>", function()
    move(-1)
  end, S.input_buf)
  km("i", "<Down>", function()
    move(1)
  end, S.input_buf)
  km("i", "<Up>", function()
    move(-1)
  end, S.input_buf)
  km("i", "<CR>", run_selected, S.input_buf)

  -- Navigate list from input (normal mode)
  km("n", "<C-j>", function()
    move(1)
  end, S.input_buf)
  km("n", "<C-k>", function()
    move(-1)
  end, S.input_buf)
  km("n", "j", function()
    move(1)
  end, S.input_buf)
  km("n", "k", function()
    move(-1)
  end, S.input_buf)
  km("n", "<CR>", run_selected, S.input_buf)

  -- Navigate list from list panel (normal mode)
  km("n", "j", function()
    move(1)
  end, S.list_buf)
  km("n", "k", function()
    move(-1)
  end, S.list_buf)
  km("n", "<CR>", run_selected, S.list_buf)

  -- Tab: toggle multi-select mark
  km({ "n", "i" }, "<Tab>", toggle_mark, S.input_buf)
  km("n", "<Tab>", toggle_mark, S.list_buf)
end

-- ── autocmds ──────────────────────────────────────────────────────────────────

local function setup_autocmds()
  local aug = api.nvim_create_augroup("CometUI", { clear = true })

  -- local promptw = api.nvim_strwidth(S.prompt)
  -- Use byte length instead of strwidth because string.sub operates on bytes
  local prompt_bytes = #S.prompt

  -- Listen to both Insert and Normal mode text changes
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = aug,
    buffer = S.input_buf,
    callback = function()
      local line = api.nvim_get_current_line()
      local query = line:sub(prompt_bytes + 1)
      S.last_query = query
      local sub = current_sub()
      if sub then
        sub.selected = 1
        filter_sub(query)
      else
        S.selected = 1
        filter_commands(query)
      end
      render_list()
    end,
  })

  -- Prevent cursor from moving into the prompt area
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = aug,
    buffer = S.input_buf,
    callback = function()
      local cursor = api.nvim_win_get_cursor(0)
      local mode = api.nvim_get_mode().mode
      local line_len = #api.nvim_get_current_line()

      local min_col = prompt_bytes
      -- In normal mode, Neovim clamps cursor to line_len - 1.
      -- We must adjust min_col to prevent an infinite CursorMoved loop.
      if mode:sub(1, 1) ~= "i" then
        min_col = math.min(prompt_bytes, math.max(0, line_len - 1))
      end

      -- cursor[2] is the 0-indexed byte column
      if cursor[2] < min_col then
        pcall(api.nvim_win_set_cursor, 0, { cursor[1], min_col })
      end
    end,
  })

  api.nvim_create_autocmd("WinClosed", {
    group = aug,
    callback = function(ev)
      local closed = tonumber(ev.match)
      if S.input_win and (closed == S.input_win or closed == S.list_win or closed == S.output_win) then
        vim.schedule(do_close)
      end
    end,
  })
end

-- ── open ──────────────────────────────────────────────────────────────────────

---@class CometCommand
---@field name string
---@field icon string
---@field icon_hl? string highlight group for the icon (default "String")
---@field desc? string used for fuzzy filtering
---@field action fun(ctx: CometCtx)

---@class CometCtx
---@field write fun(lines: string[]|string)
---@field clear fun()
---@field done fun()
---@field append fun(line: string)
---@field start_async_task fun(job_id: integer, abort_fn: function|nil) Register or clear a stop handler for stop signal
---@field select fun(items: any[], opts: {title?: string, multi_select?: boolean, on_select: fun(item_or_items: any, ctx: CometCtx), on_cancel?: fun()})

---@class CometOpts
---@field title? string
---@field insert_mode? boolean
---@field block_while_running? boolean If true, prevents executing new commands in the current page until the running job finishes
---@field remember_page? boolean If true, remembers the last active sub-page for each root command and restores it when re-entering that command

---@param ctx CometCtx
---@param job_id integer
local function default_abort_fn(job_id, ctx)
  vim.fn.jobstop(job_id)
  ctx.append("\n[Process Terminated by User]")
  running_tasks[S.current_page_key].status = nil
end

---Open the two-panel picker UI.
---@param commands CometCommand[]
---@param opts? CometOpts
M.open = function(commands, opts)
  if is_open() then
    do_close()
  end

  opts = opts or {}

  -- ── layout math ─────────────────────────────────────────────────────────────
  local total_w = math.floor(vim.o.columns * 0.86)
  local total_h = math.floor(vim.o.lines * 0.78)
  local list_w = math.floor(total_w * 0.38)
  local output_w = total_w - list_w - 4
  local col_start = math.floor((vim.o.columns - total_w) / 2)
  local row_start = math.floor((vim.o.lines - total_h) / 2)
  local list_h = total_h - 3
  local prompt = "  "
  local title = opts.title or "Commands"

  S = {
    commands = commands,
    filtered = vim.deepcopy(commands),
    selected = 1,
    sub_stack = {},
    last_query = "",
    prompt = prompt,
    list_h = list_h,
    list_title = title,
    insert_mode = not not opts.insert_mode, -- default is false (normal mode)
    block_while_running = opts.block_while_running ~= false, -- default is true
    ns = api.nvim_create_namespace("CometUI"),
    out_ns = api.nvim_create_namespace("CometUIOutput"),
    default_abort_fn = default_abort_fn,
    remember_page = opts.remember_page ~= false,
    current_page_key = title, -- Start with root page key as the main title
  }

  if S.remember_page and persisted_state then
    S.sub_stack = persisted_state.sub_stack
    S.selected = persisted_state.selected
    S.filtered = persisted_state.filtered
    S.last_query = persisted_state.last_query
    S.current_page_key = persisted_state.current_page_key
  end

  -- ── buffers ─────────────────────────────────────────────────────────────────
  S.input_buf = api.nvim_create_buf(false, true)
  S.list_buf = api.nvim_create_buf(false, true)
  -- S.output_buf = api.nvim_create_buf(false, true)

  -- Initialize root page buffer using our caching system
  switch_output_buf(S.current_page_key)

  -- ── windows ─────────────────────────────────────────────────────────────────
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
    height = list_h,
    border = "single",
    style = "minimal",
    zindex = 50,
  })

  S.output_win = api.nvim_open_win(S.output_buf, false, {
    relative = "editor",
    row = row_start,
    col = col_start + list_w + 2,
    width = output_w,
    height = total_h,
    border = "single",
    style = "minimal",
    title = " Output ",
    title_pos = "center",
    zindex = 50,
  })

  -- ── window options ──────────────────────────────────────────────────────────
  local use_dark = vim.fn.hlID("ExBlack2Bg") ~= 0
  local win_hl = use_dark and "Normal:ExBlack2Bg,FloatBorder:ExBlack2Border"
    or "Normal:NormalFloat,FloatBorder:FloatBorder"

  for _, win in ipairs({ S.input_win, S.list_win, S.output_win }) do
    vim.wo[win].winhl = win_hl
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].cursorline = false
  end
  vim.wo[S.output_win].wrap = true

  -- ── buffer options ──────────────────────────────────────────────────────────
  vim.bo[S.output_buf].modifiable = false
  vim.bo[S.output_buf].buftype = "nofile"
  vim.bo[S.list_buf].buftype = "nofile"

  vim.bo[S.input_buf].buftype = "prompt"
  vim.fn.prompt_setprompt(S.input_buf, prompt)
  vim.fn.prompt_setcallback(S.input_buf, function() end)

  -- ── initial render ──────────────────────────────────────────────────────────
  render_list()
  setup_keymaps()
  setup_autocmds()

  update_output_title()
  rehighlight_output(S.output_buf)

  if S.insert_mode then
    vim.cmd("startinsert")
  end
end

return M
