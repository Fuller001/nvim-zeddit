-- Example lazy.nvim spec. Copy into lua/plugins/zeddit.lua and set
-- `provider_model` to the id or path your local server exposes.
--
-- Do not commit machine-specific GGUF paths or API keys.

return {
  {
    "Fuller001/nvim-zeddit",
    lazy = false,
    opts = {
      provider = "zeta",
      provider_url = "http://localhost:8000",
      -- Replace with your local model id. For LM Studio this is often the
      -- GGUF path shown by GET /v1/models.
      provider_model = "zeta-2.1",
      prompt_format = "Zeta2.1",
      temperature = 0.0,
      top_k = 40,
      -- Leave room for the response when the server n_ctx is 2048.
      max_tokens = 160,
      prompt_budget_tokens = 1400,
      debounce_ms = 250,
      timeout_ms = 120000,
    },
    config = function(_, opts)
      require("zeddit").setup(opts)
      if LazyVim and LazyVim.cmp and LazyVim.cmp.actions then
        LazyVim.cmp.actions.ai_accept = function()
          local zeddit = require("zeddit")
          if zeddit.has and zeddit.has() then
            if LazyVim.create_undo then
              LazyVim.create_undo()
            end
            return zeddit.accept()
          end
        end
      end
    end,
    keys = {
      { "<leader>z", "", desc = "+zeddit" },
      {
        "<leader>zc",
        function()
          require("zeddit").configure()
        end,
        desc = "Zeddit Settings",
      },
      {
        "<leader>zs",
        function()
          require("zeddit").status()
        end,
        desc = "Zeddit Status",
      },
      {
        "<leader>zr",
        function()
          require("zeddit").request(true)
        end,
        desc = "Zeddit Request",
      },
      {
        "<M-l>",
        function()
          require("zeddit").accept()
        end,
        mode = "i",
        desc = "Accept Zeddit edit",
      },
      {
        "<C-l>",
        function()
          require("zeddit").accept()
        end,
        mode = "i",
        desc = "Accept Zeddit edit",
      },
    },
  },

  -- Put Zeddit ahead of Blink's normal <Tab> actions. If no Zeddit edit is
  -- pending, the normal snippet/AI/fallback behavior remains available.
  {
    "saghen/blink.cmp",
    optional = true,
    opts = function(_, opts)
      opts.keymap = opts.keymap or {}
      local zeddit_accept = function()
        return require("zeddit").accept()
      end
      local blink_fallback = "snippet_forward"
      if LazyVim and LazyVim.cmp and LazyVim.cmp.map then
        blink_fallback = LazyVim.cmp.map({ "snippet_forward", "ai_nes", "ai_accept" })
      end
      opts.keymap["<Tab>"] = {
        zeddit_accept,
        blink_fallback,
        "fallback",
      }
    end,
  },
}
