# nvim-zeddit

Local [Zeta](https://zed.dev/edit-prediction) next-edit suggestions for Neovim.

Zeddit talks to an OpenAI-compatible `/v1/completions` server (typically [LM Studio](https://lmstudio.ai/) serving a Zeta 2.1 GGUF) and shows ghost text at the cursor. Accept with `<Tab>` when no completion menu is open, or with `<M-l>` / `<C-l>`.

## Origin

This plugin is a working implementation derived from the empty plugin-template repository:

- [Southporter/zeta.nvim](https://github.com/Southporter/zeta.nvim) (`trunk` / `fc7fe862`)

`Southporter/zeta.nvim` currently ships the [nvimdev/nvim-plugin-template](https://github.com/nvimdev/nvim-plugin-template) skeleton (`lua/zeta/init.lua` and `plugin/zeta.lua` are empty). Zeddit keeps the documented Zeta 2.1 / V0318 Seed-Coder multi-region prompt format and implements the Neovim side locally.

Prompt-format details follow Zed's `zeta_prompt` crate (`V0318SeedMultiRegions`): Seed-Coder SPM FIM tokens, `<|user_cursor|>`, and numbered `<|marker_N|>` regions.

## Requirements

- Neovim 0.10+ (`vim.system`, `vim.uv`, inline extmarks)
- `curl`
- A local completions server, for example LM Studio at `http://localhost:8000`
- A Zeta 2.1 GGUF (or another model that understands the Zeta 2.1 FIM format)

The default sampling budget is sized for `n_ctx = 2048`. Raise `prompt_budget_tokens` / `max_tokens` if your server context is larger.

## Install (lazy.nvim)

```lua
{
  "Fuller001/nvim-zeddit",
  lazy = false,
  opts = {
    provider_url = "http://localhost:8000",
    -- Use the id from GET /v1/models, or the GGUF path your server expects.
    provider_model = "zeta-2.1",
    prompt_format = "Zeta2.1",
    max_tokens = 160,
    prompt_budget_tokens = 1400,
  },
}
```

A fuller LazyVim + blink.cmp example lives in [`examples/lazy.lua`](examples/lazy.lua). Put machine-specific GGUF paths and API keys in your Neovim config, not in this repository.

## Setup

```lua
require("zeddit").setup({
  provider_url = "http://localhost:8000",
  provider_model = "zeta-2.1",
})
```

`setup()` registers commands, insert-mode requests, ghost-text previews, and optional [snacks.nvim](https://github.com/folke/snacks.nvim) toggles.

## Commands

| Command | Action |
| --- | --- |
| `:ZedditEnable` / `:ZedditDisable` / `:ZedditToggle` | Global on/off |
| `:ZedditToggleBuffer` | Buffer-local on/off |
| `:ZedditAccept` | Apply the current ghost edit |
| `:ZedditClear` | Dismiss the current preview |
| `:ZedditRequest` | Force a request now |
| `:ZedditStatus` | Show enabled state, URL, and model |
| `:ZedditConfig` | Settings GUI (Snacks picker or `vim.ui.select`) |
| `:ZedditReset` | Restore plugin-spec defaults |

## Keymaps (optional)

The plugin itself only maps snacks toggles when snacks.nvim is present:

- `<leader>zz` global toggle
- `<leader>zb` buffer toggle

The example spec also maps:

- `<leader>zc` settings
- `<leader>zs` status
- `<leader>zr` request
- insert `<M-l>` / `<C-l>` accept
- Blink `<Tab>`: accept Zeddit first, then snippet / AI / fallback

`<leader>uz` / `<leader>uZ` are left alone (LazyVim zen / zoom).

## Options

| Option | Default | Notes |
| --- | --- | --- |
| `enabled` | `true` | Global switch |
| `provider_url` | `http://localhost:8000` | `/v1/completions` is appended when missing |
| `provider_model` | `"zeta-2.1"` | Model id or local GGUF path expected by the server |
| `api_key` | `nil` | Optional Bearer token; leave empty for local LM Studio |
| `prompt_format` | `"Zeta2.1"` | V0318 multi-region FIM |
| `temperature` | `0.0` | |
| `top_k` | `40` | |
| `max_tokens` | `160` | Keep small when `n_ctx` is 2048 |
| `prompt_budget_tokens` | `1400` | History is dropped if the prompt would exceed this |
| `debounce_ms` | `250` | |
| `timeout_ms` | `120000` | curl timeout |
| `context_before_lines` / `context_after_lines` | `14` | Surrounding context |
| `editable_before_lines` / `editable_after_lines` | `7` | Region the model may rewrite |
| `context_max_chars` | `3600` | Hard cap on context size |
| `filetypes` | `{}` | Empty = all normal buffers |
| `exclude_filetypes` | help/lazy/mason/... | UI and VCS buffers |
| `notify_errors` | `true` | |

GUI values persist in `stdpath("data")/zeddit-settings.json` and override plugin defaults. An empty `api_key` is stored as `""` so a previous key is not restored from defaults.

## Prompt shape

```
<[fim-suffix]>
<suffix>
<[fim-prefix]><filename>path
<prefix><|marker_1|>…<|user_cursor|>…<|marker_2|>
<[fim-middle]>
```

Stop token: `<[end▁of▁sentence]>`. `NO_EDITS` and identical rewrites are ignored.

## Tab vs completion menus

Blink's `<Tab>` is an expr mapping. Zeddit schedules the buffer edit after that mapping returns, otherwise Neovim discards the change. If a completion menu or snippet jump is active, `<Tab>` is left to Blink; use `<M-l>` / `<C-l>` to accept the ghost text instead.

## Privacy

This repository does not include:

- local GGUF paths
- API keys
- machine usernames or `AppData` paths
- persisted `zeddit-settings.json`

Put those only in your private Neovim config.

## License

MIT. See [LICENSE](LICENSE).

Derived from [Southporter/zeta.nvim](https://github.com/Southporter/zeta.nvim), which itself started from [nvimdev/nvim-plugin-template](https://github.com/nvimdev/nvim-plugin-template).
