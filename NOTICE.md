# Notice

nvim-zeddit is derived from:

- https://github.com/Southporter/zeta.nvim
  commit `fc7fe862b53d30bfecbb5420855a2071d2262438` on branch `trunk`

That repository is currently an empty [nvim-plugin-template](https://github.com/nvimdev/nvim-plugin-template) skeleton. This project keeps the intended Zeta 2.1 edit-completion behavior and implements it for Neovim against an OpenAI-compatible `/v1/completions` server.

The Zeta 2.1 prompt format follows Zed's public `zeta_prompt` / `V0318SeedMultiRegions` design (Seed-Coder SPM FIM tokens, `<|user_cursor|>`, numbered `<|marker_N|>` regions).
