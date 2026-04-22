-- Data filtering module based on user input

local state = require("comet.state")
local M = {}

--- Filter root commands
---@param query string
M.filter_commands = function(query)
  local S = state.get()
  if not S then
    return
  end

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

--- Filter active sub-menu items
---@param query string
M.filter_sub = function(query)
  local sub = state.current_sub()
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

return M
