# nvim-zeddit

Local LLM next-edit suggestions for Neovim, with optional LSP hover translation.

Zeddit talks to an OpenAI-compatible server (llama.cpp `llama-server`, LM Studio, …) and shows ghost text at the cursor. Two model families are supported and detected **live** from the server:

- **Zeta 2.1** — Zed's [edit-prediction](https://zed.dev/edit-prediction) model, V0318 Seed-Coder multi-region prompt format.
- **Mellum2** (e.g. `Mellum2-12B-A2.5B-Instruct`) — driven through its native FIM protocol (`<fim_prefix>/<fim_suffix>/<fim_middle>`), which is its trained completion mode.

Switch the served model and zeddit follows within seconds (a shared `/props` probe, 10 s TTL) — no restart, no config edits.

Extras:

- **Manual mode**: turn off automatic inference and trigger completions on demand.
- **Hover translation**: translate LSP hover docs (e.g. English → Chinese) through the server's chat endpoint. Automatically gated off while a non-chat model (Zeta) is serving.

## Origin

This plugin is a working implementation derived from the empty plugin-template repository:

- [Southporter/zeta.nvim](https://github.com/Southporter/zeta.nvim) (`trunk` / `fc7fe862`)

`Southporter/zeta.nvim` currently ships the [nvimdev/nvim-plugin-template](https://github.com/nvimdev/nvim-plugin-template) skeleton (`lua/zeta/init.lua` and `plugin/zeta.lua` are empty). Zeddit keeps the documented Zeta 2.1 / V0318 Seed-Coder multi-region prompt format and implements the Neovim side locally.

Prompt-format details follow Zed's `zeta_prompt` crate (`V0318SeedMultiRegions`): Seed-Coder SPM FIM tokens, `<|user_cursor|>`, and numbered `<|marker_N|>` regions.

## Requirements

- Neovim 0.10+ (`vim.system`, `vim.uv`, inline extmarks)
- `curl`
- A local server exposing `/v1/completions` (and `/v1/chat/completions` + `/props` for hover translation / live model detection), e.g. llama.cpp at `http://localhost:8000`
- A Zeta 2.1 GGUF **or** a Mellum2 GGUF

The default sampling budget is sized for `n_ctx = 2048`. Raise `prompt_budget_tokens` / `max_tokens` if your server context is larger.

## Install (lazy.nvim)

```lua
{
  "Fuller001/nvim-zeddit",
  lazy = false,
  opts = {
    provider_url = "http://localhost:8000",
    prompt_format = "auto",   -- follow the served model (default)
    hover_translate = true,   -- optional: translate LSP hover docs
  },
}
```

A fuller LazyVim + blink.cmp example lives in [`examples/lazy.lua`](examples/lazy.lua). Put machine-specific GGUF paths and API keys in your Neovim config, not in this repository.

## How completion works

- **Automatic**: requests are debounced (`debounce_ms`) after edits/cursor moves in insert mode.
- **Manual**: set `auto_trigger = false` (settings GUI or `<leader>zt` in the example spec). Typing then stays quiet; call `require("zeddit").request(true)` — mapped to `<M-g>` in the example — to infer once, then accept with `<M-l>` / `<C-l>` / `<Tab>`.
- The master enable/disable (`<leader>zT` / `:ZedditToggle`) is separate and gates manual triggers too; a manual trigger while disabled tells you so instead of silently doing nothing.

### Mellum2 FIM fuses

Small models at temperature 0 occasionally derail (endless continuation, greedy repetition loops, echoing the text right of the cursor). The Mellum2 path guards each failure mode client-side:

- `"\n\n"` paragraph stop token — bounds runaway continuations server-side.
- Duplicate-run truncation (3+ identical consecutive lines cut) + `fim_max_lines` cap — kills repetition avalanches while keeping legitimate repeated patterns.
- Mid-line cursor: the suggestion is cut at the first newline and trimmed against the text after the cursor (longest-overlap), so it can never duplicate your suffix.

## Hover translation

With `hover_translate = true` and a chat-capable model serving:

1. `K` renders the original hover immediately.
2. The text is translated through `/v1/chat/completions`; on completion the float contents are swapped in place (both plain `vim.lsp.buf.hover` floats and noice.nvim's hover pipeline are hooked).
3. Results are cached by text hash, so repeated lookups are instant.

The served model is probed via `/props` (`model_path` basename): while a Zeta (completion-only) model is serving, translation is skipped silently and `:ZedditHoverStatus` shows why. Translation failures are always loud.

## Commands

| Command | Action |
| --- | --- |
| `:ZedditEnable` / `:ZedditDisable` / `:ZedditToggle` | Global on/off (master switch) |
| `:ZedditToggleBuffer` | Buffer-local on/off |
| `:ZedditAccept` | Apply the current ghost edit |
| `:ZedditClear` | Dismiss the current preview |
| `:ZedditRequest` | Force a request now (manual trigger) |
| `:ZedditStatus` | Show enabled state, URL, and model |
| `:ZedditHoverToggle` | Toggle hover translation (refuses while a non-chat model serves) |
| `:ZedditHoverStatus` | Show translate/debug state, cache size, served model kind |
| `:ZedditConfig` | Settings GUI (Snacks picker or `vim.ui.select`) |
| `:ZedditReset` | Restore plugin-spec defaults |

## Keymaps (optional)

The plugin itself only maps snacks toggles when snacks.nvim is present:

- `<leader>zz` global toggle
- `<leader>zb` buffer toggle

The example spec also maps:

- `<leader>zt` auto-completion on/off (typing-triggered inference; manual keeps working)
- `<leader>zT` plugin master on/off
- `<leader>zh` hover-translation on/off
- `<leader>zc` settings, `<leader>zs` status, `<leader>zr` request
- insert `<M-g>` manual trigger, `<M-l>` / `<C-l>` accept
- Blink `<Tab>`: accept Zeddit first, then snippet / AI / fallback

which-key menu labels for the three toggles update live (e.g. `hover translate: off (zeta model)` when gated by the served model).

`<leader>uz` / `<leader>uZ` are left alone (LazyVim zen / zoom).

## Options

| Option | Default | Notes |
| --- | --- | --- |
| `enabled` | `true` | Master switch |
| `auto_trigger` | `true` | `false` = no automatic inference; manual trigger keeps working |
| `provider_url` | `http://localhost:8000` | `/v1/completions` is appended when missing |
| `provider_model` | `"zeta-2.1"` | Model id or local GGUF path; only a fallback hint when `prompt_format = "auto"` |
| `api_key` | `nil` | Optional Bearer token; leave empty for local servers |
| `prompt_format` | `"auto"` | `"auto"` follows the served model (`/props` probe); or force `"Zeta2.1"` / `"Mellum2"` |
| `hover_translate` | `false` | Translate LSP hover docs via the chat endpoint |
| `hover_max_tokens` | `4096` | Output budget per translation (long docstrings need it) |
| `hover_debug` | `false` | Trace every hover gate via `vim.notify` |
| `temperature` | `0.0` | Mellum2 FIM is clamped to a 0.1 floor (0 degenerates on FIM models) |
| `top_k` | `40` | |
| `max_tokens` | `160` | Zeta path budget; keep small when `n_ctx` is 2048 |
| `fim_max_tokens` | `128` | Mellum2 FIM budget (small = low ghost-edit latency) |
| `fim_max_lines` | `5` | Mellum2 FIM line cap (repetition fuse) |
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

## Prompt shapes

Zeta 2.1 (V0318 multi-region):

```
<[fim-suffix]>
<suffix>
<[fim-prefix]><filename>path
<prefix><|marker_1|>…<|user_cursor|>…<|marker_2|>
<[fim-middle]>
```

Stop token: `<[end▁of▁sentence]>`. `NO_EDITS` and identical rewrites are ignored.

Mellum2 (native FIM on `/v1/completions`):

```
<fim_prefix><prefix><fim_suffix><suffix><fim_middle>
```

Stop tokens: the three FIM markers, `<|endoftext|>`, and `"\n\n"`. Sampled with `repeat_penalty = 1.05`.

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
