-- Minimal init.lua for running tests with plenary.nvim
-- Usage: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/dotnet-cli"

vim.cmd([[set runtimepath+=.]])

-- Bootstrap plenary if not already available
local plenary_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
if vim.fn.isdirectory(plenary_path) == 0 then
  -- Try the user's lazy.nvim installation
  plenary_path = vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim")
end

if vim.fn.isdirectory(plenary_path) == 1 then
  vim.opt.runtimepath:append(plenary_path)
end
