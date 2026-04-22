-- The Command Context Builder

---@class CometCtx
---@field target_buf integer
---@field target_page_key string
---@field write fun(self: CometCtx, lines: string[]|string)
---@field clear fun(self: CometCtx)
---@field done fun(self: CometCtx)
---@field error fun(self: CometCtx)
---@field append fun(self: CometCtx, line: string)
---@field start_async_task fun(self: CometCtx, job_id: integer, abort_fn: function|nil)
---@field select fun(self: CometCtx, items: any[], opts: {title?: string, multi_select?: boolean, on_select: fun(item_or_items: any, ctx: CometCtx), on_cancel?: fun()})

local render = require("comet.ui.render")
local state = require("comet.state")
local window = require("comet.ui.window")
local M = {}

--- Create a new API Context specifically bound to a page key buffer
---@param trigger_name string
---@return CometCtx
M.make = function(trigger_name)
  local S = state.get()

  ---@type CometCtx
  local ctx = {
    target_buf = S.output_buf,
    target_page_key = S.current_page_key,

    write = function(self, lines)
      render.out_write(self.target_buf, lines)
    end,
    clear = function(self)
      render.out_clear(self.target_buf)
    end,
    append = function(self, line)
      render.out_write(self.target_buf, line)
    end,

    start_async_task = function(self, job_id, abort_fn)
      state.running_tasks[self.target_page_key] = {
        abort_fn = function()
          local abort = abort_fn or S.default_abort_fn
          abort(job_id, self)
        end,
        status = "running",
        id = job_id,
      }
      vim.schedule(render.update_output_title)
    end,

    done = function(self)
      if state.running_tasks[self.target_page_key] then
        state.running_tasks[self.target_page_key].status = "done"
        vim.schedule(render.update_output_title)
      end
    end,

    error = function(self)
      if state.running_tasks[self.target_page_key] then
        state.running_tasks[self.target_page_key].status = "error"
        vim.schedule(render.update_output_title)
      end
    end,

    select = function(self, items, opts)
      local saved = window.take_input_query()
      local all = vim.deepcopy(items)
      for i, it in ipairs(all) do
        if type(it) == "table" then
          it._idx = i
        end
      end

      local sub_title = opts.title or "Select"

      -- Routing Logic: Determine which cache buffer we use for nested contexts
      if #S.sub_stack == 0 then
        self.target_page_key = trigger_name
      else
        self.target_page_key = S.sub_stack[1].page_key
      end

      table.insert(S.sub_stack, {
        all_items = all,
        items = vim.deepcopy(all),
        selected = 1,
        on_select = opts.on_select,
        on_cancel = opts.on_cancel,
        title = sub_title,
        page_key = self.target_page_key,
        saved_query = saved,
        multi_select = opts.multi_select or false,
        marked = {},
      })

      window.switch_output_buf(self.target_page_key)

      pcall(vim.api.nvim_win_set_config, S.input_win, { title = " " .. sub_title .. " ", title_pos = "center" })
      render.list()
      window.focus_input()
    end,
  }

  return ctx
end

return M
