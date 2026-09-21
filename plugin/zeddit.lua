if vim.g.loaded_zeddit then
  return
end
vim.g.loaded_zeddit = true

-- Commands and autocmds are registered from require("zeddit").setup().
-- Users of lazy.nvim should call setup from the plugin spec.
