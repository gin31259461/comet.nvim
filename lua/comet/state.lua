-- Centralized state management and type definitions for Comet.nvim

---@class CometCommand
---@field name string Display name of the item
---@field icon string Icon to display
---@field icon_hl? string Highlight group for the icon (default "String")
---@field desc? string Used for fuzzy filtering
---@field action fun(ctx: CometCtx) Callback executed when selected

---@class CometOpts
---@field session_id? string Title for the left panel
---@field root_title? string Optional title for the root page (defaults to session_id)
---@field insert_mode? boolean Automatically enter insert mode
---@field block_while_running? boolean Prevent executing new commands while running
---@field remember_page? boolean Remember sub-page, selection, and query across sessions

---@class RunningTaskInfo
---@field abort_fn fun()|nil Function to call to signal the task to stop
---@field status "running"|"done"|"abort"|"error"|nil Current status of the task for UI display
---@field id integer|nil Job ID if applicable

---@class SubMenuState
---@field all_items any[]
---@field items any[]
---@field selected integer
---@field title string
---@field page_key string
---@field saved_query string
---@field multi_select boolean
---@field marked table<any, boolean>
---@field on_select? fun(item_or_items: any, ctx: CometCtx)
---@field on_cancel? fun()

---@class CometState
---@field commands CometCommand[]
---@field filtered any[]
---@field selected integer
---@field sub_stack SubMenuState[]
---@field last_query string
---@field prompt string
---@field list_h integer
---@field session_id string
---@field root_title string
---@field insert_mode boolean
---@field block_while_running boolean
---@field remember_page boolean
---@field current_page_key string
---@field ns integer
---@field out_ns integer
---@field default_abort_fn fun(job_id: integer, ctx: CometCtx)
---@field input_buf? integer
---@field list_buf? integer
---@field output_buf? integer
---@field input_win? integer
---@field list_win? integer
---@field output_win? integer

local M = {}

-- ── Persistent Session State ──────────────────────────────────────────────────

--- Cache output buffers by page title to persist them across opens and depths
---@type table<string, integer>
M.output_buf_cache = {}

--- Track running tasks by page key to manage their lifecycle and UI state
---@type table<string, RunningTaskInfo>
M.running_tasks = {}

--- Store the UI state across closing and reopening
---@type table|nil
M.persisted_states = {}

-- ── Active UI State ───────────────────────────────────────────────────────────

---@type CometState|nil
local S = nil

--- Check if the UI is currently open
---@return boolean
M.is_open = function()
  return S ~= nil and S.ns ~= nil
end

--- Get the current state object (Read/Write reference)
---@return CometState
M.get = function()
  if not S then
    error("Comet UI is closed. Cannot access active UI state.", 2)
  end

  return S
end

--- Clear current state (used when closing the UI)
M.clear = function()
  S = nil
end

--- Initialize a new session state
---@param commands CometCommand[]
---@param opts CometOpts
---@param layout_opts table Pre-calculated layout dimensions
M.init = function(commands, opts, layout_opts)
  local session_id = opts.session_id or "Comet"
  local root_title = opts.root_title or session_id

  S = {
    session_id = session_id,
    root_title = root_title,
    commands = commands,
    filtered = vim.deepcopy(commands),
    selected = 1,
    sub_stack = {},
    last_query = "",
    prompt = "  ",
    list_h = layout_opts.list_h,
    insert_mode = opts.insert_mode or false,
    block_while_running = opts.block_while_running ~= false,
    remember_page = opts.remember_page ~= false,
    current_page_key = root_title,
    ns = vim.api.nvim_create_namespace("CometUI"),
    out_ns = vim.api.nvim_create_namespace("CometUIOutput"),
    default_abort_fn = function(job_id, ctx)
      vim.fn.jobstop(job_id)
      ctx:append("\n[Process Terminated by User]")
      if M.running_tasks[ctx.target_page_key] then
        M.running_tasks[ctx.target_page_key].status = nil
      end
    end,
  }

  local p_state = M.persisted_states[S.session_id]
  if S.remember_page and p_state then
    S.sub_stack = vim.deepcopy(p_state.sub_stack)
    S.selected = p_state.selected
    S.filtered = vim.deepcopy(p_state.filtered)
    S.last_query = p_state.last_query
    S.current_page_key = p_state.current_page_key
  end
end

--- Helper to get current active list of items (root or sub-menu)
---@return any[]
M.current_items = function()
  if not S then
    return {}
  end
  local sub = S.sub_stack[#S.sub_stack]
  return sub and sub.items or S.filtered
end

--- Helper to get current active selection index
---@return integer
M.current_selected = function()
  if not S then
    return 1
  end
  local sub = S.sub_stack[#S.sub_stack]
  return sub and sub.selected or S.selected
end

--- Helper to get current sub-menu state, if any
---@return SubMenuState|nil
M.current_sub = function()
  if not S or #S.sub_stack == 0 then
    return nil
  end
  return S.sub_stack[#S.sub_stack]
end

return M
