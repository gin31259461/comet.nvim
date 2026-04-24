local M = {}

M.check = function()
  vim.health.start("comet.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim version >= 0.10")
  else
    vim.health.warn("Neovim < 0.10. Some UI features or autocmd cleanups might not work optimally.")
  end
end

return M
