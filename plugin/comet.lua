if vim.g.loaded_comet then
  return
end
vim.g.loaded_comet = true

-- NOTE: The user calls require("comet").setup(opts) from their plugin spec.
-- Any global user commands (e.g., :CometToggle) could be registered here in the future.
