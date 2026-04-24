local M = {}

---@type CometOpts
M.defaults = {
  session_id = "Comet",
  -- root_title is optional and will default to session_id if not provided
  insert_mode = false,
  block_while_running = true,
  remember_page = true,
}

---@type CometOpts
M.values = vim.deepcopy(M.defaults)

--- Set global default options
---@param opts? CometOpts
M.setup = function(opts)
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

--- Merge incoming options with the global defaults
---@param opts? CometOpts
---@return CometOpts
M.resolve = function(opts)
  -- If `open` is called with local opts, override the global `M.values`
  return vim.tbl_deep_extend("force", vim.deepcopy(M.values), opts or {})
end

return M
