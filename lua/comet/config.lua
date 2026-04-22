-- Options resolution

local M = {}

--- Merge user options with defaults
---@param opts? CometOpts
---@return CometOpts
M.resolve = function(opts)
  opts = opts or {}
  return {
    title = opts.title or "Commands",
    insert_mode = not not opts.insert_mode,
    block_while_running = opts.block_while_running ~= false,
    remember_page = opts.remember_page ~= false,
  }
end

return M
