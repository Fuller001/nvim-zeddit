local M = {}

local FIM_SUFFIX = "<[fim-suffix]>"
local FIM_PREFIX = "<[fim-prefix]>"
local FIM_MIDDLE = "<[fim-middle]>"
local FILE_MARKER = "<filename>"
local CURSOR_MARKER = "<|user_cursor|>"
local END_MARKER = "<[end▁of▁sentence]>"
local MARKER_PATTERN = "<|marker_(%d+)|>"

local defaults = {
  enabled = true,
  -- false = no automatic ghost edits while typing; require("zeddit").request()
  -- (manual trigger) keeps working.
  auto_trigger = true,

  -- LM Studio's OpenAI-compatible completion endpoint.
  provider = "zeta",
  provider_url = "http://localhost:8000",
  -- Set this to your local GGUF path or the id exposed by /v1/models.
  provider_model = "zeta-2.1",

  -- Zeta 2.1 uses the V0318 Seed-Coder multi-region format.
  prompt_format = "auto",
  -- Translate LSP hover documentation into Chinese through the chat
  -- endpoint. The original hover renders first; its float contents are
  -- swapped in place once the model answers (or instantly on cache hits).
  hover_translate = false,
  -- Output token budget for one hover translation. Long docstrings easily
  -- exceed 2048 tokens of Chinese, so keep this comfortably high.
  hover_max_tokens = 4096,
  -- Trace every gate of the hover translation path via vim.notify.
  hover_debug = false,
  temperature = 0.0,
  top_k = 40,
  max_tokens = 160,
  -- Mellum2 FIM completions: small budget keeps ghost-edit latency low.
  fim_max_tokens = 128,
  prompt_budget_tokens = 1400,
  debounce_ms = 250,
  timeout_ms = 120000,

  -- Keep the prompt comfortably below LM Studio's n_ctx=2048 setting.
  context_before_lines = 14,
  context_after_lines = 14,
  editable_before_lines = 7,
  editable_after_lines = 7,
  context_max_chars = 3600,

  -- Empty means all normal filetypes.  Use exclude_filetypes for binaries/UI buffers.
  filetypes = {},
  exclude_filetypes = {
    "help",
    "lazy",
    "mason",
    "TelescopePrompt",
    "neo-tree",
    "oil",
    "gitcommit",
    "gitrebase",
    "qf",
    "terminal",
  },

  -- LM Studio does not require a key. Set this if the endpoint is protected.
  api_key = nil,
  notify_errors = true,
}

local persist_keys = {
  "enabled",
  "provider_url",
  "provider_model",
  "api_key",
  "temperature",
  "top_k",
  "max_tokens",
  "prompt_budget_tokens",
  "debounce_ms",
  "timeout_ms",
  "context_before_lines",
  "context_after_lines",
  "editable_before_lines",
  "editable_after_lines",
  "context_max_chars",
  "notify_errors",
  "hover_translate",
  "hover_max_tokens",
  "fim_max_tokens",
  "fim_max_lines",
  "auto_trigger",
  "prompt_format",
}

local state = {
  opts = vim.deepcopy(defaults),
  plugin_opts = {},
  enabled = defaults.enabled,
  namespace = vim.api.nvim_create_namespace("zeddit.nvim"),
  group = nil,
  timers = {},
  jobs = {},
  generations = {},
  pending = {},
  last_text = {},
  history = {},
  ignore_tick = {},
  last_error_at = 0,
}

local function persist_path()
  return vim.fn.stdpath("data") .. "/zeddit-settings.json"
end

local function load_persisted()
  local path = persist_path()
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return {}
  end
  local ok_read, lines = pcall(vim.fn.readfile, path)
  if not ok_read or type(lines) ~= "table" then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok or type(decoded) ~= "table" then
    return {}
  end
  local cleaned = {}
  for _, key in ipairs(persist_keys) do
    local value = decoded[key]
    if value ~= nil and value ~= vim.NIL then
      cleaned[key] = value
    end
  end
  return cleaned
end

local function save_persisted()
  local data = {}
  for _, key in ipairs(persist_keys) do
    local value = state.opts[key]
    if key == "enabled" then
      data[key] = state.enabled
    elseif key == "api_key" and (value == nil or value == "") then
      data[key] = ""
    else
      data[key] = value
    end
  end
  vim.fn.writefile({ vim.json.encode(data) }, persist_path())
end

local function is_valid_buffer(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function split_lines(text)
  local lines = {}
  local start = 1
  while true do
    local newline = text:find("\n", start, true)
    if not newline then
      lines[#lines + 1] = text:sub(start)
      break
    end
    lines[#lines + 1] = text:sub(start, newline - 1)
    start = newline + 1
  end
  return lines
end

local function join_lines(lines, first, last)
  if first >= last then
    return ""
  end
  local selected = {}
  for i = first + 1, last do
    selected[#selected + 1] = lines[i]
  end
  return table.concat(selected, "\n")
end

-- Return the byte offset of the start of a zero-based line.  The end of the
-- final line is the end of the joined buffer text, not one byte past it.
local function line_start_offset(lines, row)
  local offset = 0
  local last_line = math.min(row, #lines)
  for i = 1, last_line do
    if i == #lines then
      offset = offset + #lines[i]
    else
      offset = offset + #lines[i] + 1
    end
  end
  return offset
end

local function contains(list, value)
  for _, item in ipairs(list or {}) do
    if item == value then
      return true
    end
  end
  return false
end

local function current_path(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return "[No Name]"
  end

  -- Zeta's examples use slash-separated paths.  A relative path also avoids
  -- putting a machine-specific drive prefix into the prompt when possible.
  local relative = vim.fn.fnamemodify(path, ":.")
  if relative == "" or relative == path then
    relative = path
  end
  return relative:gsub("\\", "/")
end

local function notify(message, level, force)
  if not force and not state.opts.notify_errors then
    return
  end
  vim.notify(message, level or vim.log.levels.INFO, { title = "Zeddit" })
end

local function notify_error(message)
  local now = vim.uv.now()
  -- A model request is started after most insert-mode changes; do not make a
  -- transient server error produce one notification per keystroke.
  if now - state.last_error_at < 5000 then
    return
  end
  state.last_error_at = now
  notify(message, vim.log.levels.WARN)
end

local function eligible(bufnr)
  if not is_valid_buffer(bufnr) or not state.enabled or not state.opts.enabled then
    return false
  end
  if vim.api.nvim_get_option_value("buftype", { buf = bufnr }) ~= "" then
    return false
  end
  if vim.b[bufnr].zeddit_enabled == false then
    return false
  end

  local filetype = vim.bo[bufnr].filetype
  if contains(state.opts.exclude_filetypes, filetype) then
    return false
  end
  if #state.opts.filetypes > 0 and not contains(state.opts.filetypes, filetype) then
    return false
  end
  return true
end

local function close_timer(bufnr)
  local timer = state.timers[bufnr]
  if not timer then
    return
  end
  state.timers[bufnr] = nil
  pcall(function()
    timer:stop()
    timer:close()
  end)
end

local function cancel_job(bufnr)
  local request = state.jobs[bufnr]
  state.jobs[bufnr] = nil
  state.generations[bufnr] = (state.generations[bufnr] or 0) + 1
  if request and request.job then
    pcall(function()
      request.job:kill(15)
    end)
  end
end

local function clear_pending(bufnr)
  local pending = state.pending[bufnr]
  state.pending[bufnr] = nil
  if pending and pending.extmark_id and is_valid_buffer(bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, state.namespace, pending.extmark_id)
  end
end

local function clear_buffer(bufnr)
  close_timer(bufnr)
  cancel_job(bufnr)
  clear_pending(bufnr)
end

-- V0318 uses line-boundary markers.  Blocks are at least six and at most
-- sixteen lines where possible, with blank lines preferred as boundaries.
local function marker_offsets(text)
  if text == "" then
    return { 0, 0 }
  end

  local starts = { 0 }
  for i = 1, #text do
    if text:byte(i) == 10 and i < #text then
      starts[#starts + 1] = i
    end
  end

  local line_count = #starts
  local function line_text(index)
    local start = starts[index] + 1
    local finish = (starts[index + 1] or (#text + 1)) - 1
    return text:sub(start, finish)
  end
  local function blank(index)
    return line_text(index):match("^%s*$") ~= nil
  end
  local function good_start(index)
    local line = line_text(index):gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then
      return false
    end
    return not line:match("^[}%])]") and not line:match("^(break|continue|return|throw|end);?$")
  end

  local offsets = { 0 }
  local last_boundary_line = 0
  local line = 0
  while line < line_count do
    local gap = line - last_boundary_line
    local target = nil

    if gap >= 6 and line > 0 and blank(line) and line + 1 <= line_count and good_start(line + 1) then
      -- The marker goes at the start of the non-blank line after the blank
      -- line.  Keep at least six lines in the following block.
      if line_count - line >= 6 then
        target = line
      end
    end

    if not target and gap >= 16 then
      target = line
    end

    if target and starts[target + 1] > offsets[#offsets] then
      offsets[#offsets + 1] = starts[target + 1]
      last_boundary_line = target
      line = target + 1
    else
      line = line + 1
    end
  end

  if offsets[#offsets] ~= #text then
    offsets[#offsets + 1] = #text
  end
  return offsets
end

local function write_marked_editable(text, cursor_offset)
  local offsets = marker_offsets(text)
  local parts = {}

  for i, offset in ipairs(offsets) do
    parts[#parts + 1] = string.format("<|marker_%d|>", i)
    local next_offset = offsets[i + 1]
    if next_offset then
      local block = text:sub(offset + 1, next_offset)
      if cursor_offset >= offset and cursor_offset <= next_offset then
        local inside = cursor_offset - offset
        block = block:sub(1, inside) .. CURSOR_MARKER .. block:sub(inside + 1)
      end
      parts[#parts + 1] = block
    end
  end

  return table.concat(parts), offsets
end

local function format_event(old_text, new_text, path)
  if old_text == new_text then
    return nil
  end

  local old_lines = split_lines(old_text)
  local new_lines = split_lines(new_text)
  local first = 1
  while first <= #old_lines and first <= #new_lines and old_lines[first] == new_lines[first] do
    first = first + 1
  end

  local old_last = #old_lines
  local new_last = #new_lines
  while old_last >= first and new_last >= first and old_lines[old_last] == new_lines[new_last] do
    old_last = old_last - 1
    new_last = new_last - 1
  end

  local diff = { "@@" }
  if first > 1 then
    diff[#diff + 1] = " " .. old_lines[first - 1]
  end
  for i = first, old_last do
    diff[#diff + 1] = "-" .. old_lines[i]
  end
  for i = first, new_last do
    diff[#diff + 1] = "+" .. new_lines[i]
  end
  if old_last < #old_lines then
    diff[#diff + 1] = " " .. old_lines[old_last + 1]
  end

  return table.concat({
    "<filename>edit_history",
    "--- a/" .. path,
    "+++ b/" .. path,
    table.concat(diff, "\n"),
  }, "\n")
end

local function record_change(bufnr, text)
  local previous = state.last_text[bufnr]
  if previous and previous ~= text then
    local event = format_event(previous, text, current_path(bufnr))
    if event then
      local history = state.history[bufnr] or {}
      history[#history + 1] = event
      while #history > 2 do
        table.remove(history, 1)
      end
      state.history[bufnr] = history
    end
  end
  state.last_text[bufnr] = text
end

local function history_section(bufnr)
  local history = state.history[bufnr]
  if not history or #history == 0 then
    return ""
  end
  return table.concat(history, "\n")
end

local function snapshot(bufnr)
  if not is_valid_buffer(bufnr) then
    return nil, "invalid buffer"
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  if #lines == 0 then
    lines = { "" }
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_row = math.max(0, cursor[1] - 1)
  local cursor_col = math.min(cursor[2], #(lines[cursor_row + 1] or ""))
  cursor_row = math.min(cursor_row, #lines - 1)

  local editable_start = math.max(0, cursor_row - state.opts.editable_before_lines)
  local editable_end = math.min(#lines, cursor_row + state.opts.editable_after_lines + 1)
  local context_start = math.max(0, cursor_row - state.opts.context_before_lines)
  local context_end = math.min(#lines, cursor_row + state.opts.context_after_lines + 1)

  -- Trim only outside the editable region so the cursor-facing edit remains
  -- intact while the prompt is kept within the local model's context budget.
  while context_end > context_start do
    local context = join_lines(lines, context_start, context_end)
    if #context <= state.opts.context_max_chars then
      break
    end
    if context_start < editable_start then
      context_start = context_start + 1
    elseif context_end > editable_end then
      context_end = context_end - 1
    else
      break
    end
  end

  local context = join_lines(lines, context_start, context_end)
  if #context > state.opts.context_max_chars then
    return nil, "the current code context contains an unusually long line"
  end

  local context_offset = line_start_offset(lines, context_start)
  local editable_start_abs = line_start_offset(lines, editable_start)
  local editable_end_abs = line_start_offset(lines, editable_end)
  local cursor_abs = line_start_offset(lines, cursor_row) + cursor_col

  local editable_start_rel = editable_start_abs - context_offset
  local editable_end_rel = editable_end_abs - context_offset
  local cursor_rel = cursor_abs - editable_start_abs
  local editable = context:sub(editable_start_rel + 1, editable_end_rel)

  -- A final line can be empty, but there is always at least one editable
  -- line containing the cursor.
  if cursor_rel < 0 or cursor_rel > #editable then
    return nil, "could not locate the cursor in the editable region"
  end

  local marked, offsets = write_marked_editable(editable, cursor_rel)
  local suffix = context:sub(editable_end_rel + 1)
  if suffix == "" or not suffix:find("\n$", 1, false) then
    suffix = suffix .. "\n"
  end

  local history = history_section(bufnr)
  local prompt_parts = {
    FIM_SUFFIX,
    suffix,
    FIM_PREFIX,
  }
  if history ~= "" then
    prompt_parts[#prompt_parts + 1] = history
    prompt_parts[#prompt_parts + 1] = "\n"
  end
  prompt_parts[#prompt_parts + 1] = FILE_MARKER .. current_path(bufnr) .. "\n"
  prompt_parts[#prompt_parts + 1] = context:sub(1, editable_start_rel)
  prompt_parts[#prompt_parts + 1] = marked
  prompt_parts[#prompt_parts + 1] = "\n"
  prompt_parts[#prompt_parts + 1] = FIM_MIDDLE

  local prompt = table.concat(prompt_parts)
  if #prompt > state.opts.prompt_budget_tokens * 4 then
    -- History is useful but optional.  Dropping it is preferable to sending a
    -- prompt which would be rejected by a 2048-token LM Studio context.
    if history ~= "" then
      prompt_parts = {
        FIM_SUFFIX,
        suffix,
        FIM_PREFIX,
        FILE_MARKER .. current_path(bufnr) .. "\n",
        context:sub(1, editable_start_rel),
        marked,
        "\n",
        FIM_MIDDLE,
      }
      prompt = table.concat(prompt_parts)
    end
  end

  return {
    bufnr = bufnr,
    tick = vim.api.nvim_buf_get_changedtick(bufnr),
    lines = lines,
    context = context,
    editable = editable,
    editable_start_line = editable_start,
    editable_end_line = editable_end,
    editable_start_rel = editable_start_rel,
    editable_end_rel = editable_end_rel,
    cursor_rel = cursor_rel,
    cursor_row = cursor_row,
    cursor_col = cursor_col,
    marker_offsets = offsets,
    prompt = prompt,
  }
end

local function completion_url(base)
  base = tostring(base or ""):gsub("/$", "")
  if base:match("/v1/completions$") then
    return base
  end
  if base:match("/v1$") then
    return base .. "/completions"
  end
  return base .. "/v1/completions"
end

local function chat_url(base)
  base = tostring(base or ""):gsub("/$", "")
  if base:match("/v1/chat/completions$") then
    return base
  end
  if base:match("/v1$") then
    return base .. "/chat/completions"
  end
  return base .. "/v1/chat/completions"
end

local function models_url(base)
  base = tostring(base or ""):gsub("/$", "")
  if base:match("/v1$") then
    return base .. "/models"
  end
  return base .. "/v1/models"
end

local function props_url(base)
  base = tostring(base or ""):gsub("/$", "")
  base = base:gsub("/v1$", "")
  return base .. "/props"
end

-- Resolve prompt_format = "auto" by probing the server once per session.
-- The fixed --alias hides the real model id from /v1/models, so detection
-- matches on model_path from llama-server's /props (falling back to the
-- /v1/models id). Mellum* models complete through their trained FIM
-- protocol; everything else falls back to the Zeta 2.1 raw-completions format.
-- Forward declarations: the shared /props model probe is defined in the
-- hover section below; resolve_format uses it as well.
local hover_model --- kind: "mellum" | "zeta" | "other" | "down"
local probe_hover_model

-- Resolve prompt_format = "auto" from the live server model: the shared
-- probe (10 s TTL) makes model switches take effect within seconds, without
-- an nvim restart and without a blocking curl on the typing path.
local function resolve_format()
  local fmt = state.opts.prompt_format
  if fmt ~= "auto" then
    return fmt
  end
  if hover_model.kind == "mellum" then
    return "Mellum2"
  end
  if hover_model.kind == "zeta" then
    return "Zeta2.1"
  end
  -- Probe result stale or missing: refresh in the background and meanwhile
  -- fall back to the configured model string, then to Zeta.
  probe_hover_model(function() end)
  local model = (state.opts.provider_model or ""):lower()
  if model:find("mellum", 1, true) then
    return "Mellum2"
  end
  return "Zeta2.1"
end

-- Mellum2's trained completion mode is FIM (fill-in-the-middle) on the raw
-- completions endpoint: <fim_prefix>..<fim_suffix>..<fim_middle>. Driving it
-- through a chat template makes it answer conversationally instead of
-- completing code, and the small token budget keeps ghost edits fast.
local function editable_cursor_offset(context)
  local lines = vim.split(context.editable, "\n", { plain = true })
  local row = context.cursor_row - context.editable_start_line + 1
  local offset = 0
  for i = 1, row - 1 do
    offset = offset + #(lines[i] or "") + 1
  end
  return offset + context.cursor_col
end

local function mellum_fim_prompt(context)
  local cursor_abs = context.editable_start_rel + editable_cursor_offset(context)
  local prefix = context.context:sub(1, cursor_abs)
  local suffix = context.context:sub(cursor_abs + 1)
  return "<fim_prefix>" .. prefix .. "<fim_suffix>" .. suffix .. "<fim_middle>"
end

-- The FIM answer is the raw middle text; the editable-region rewrite is the
-- old region with that middle inserted at the cursor offset.
local function trim_fim_middle(middle)
  local lines = vim.split(middle, "\n", { plain = true })
  local run = 1
  local cut = #lines
  for i = 2, #lines do
    if lines[i] == lines[i - 1] and lines[i]:match("%S") then
      run = run + 1
      if run >= 3 then
        cut = i - 2
        break
      end
    else
      run = 1
    end
  end
  cut = math.min(cut, state.opts.fim_max_lines or 5)
  return table.concat(lines, "\n", 1, cut)
end

local function parse_fim_output(middle, context)
  if type(middle) ~= "string" then
    return nil
  end
  middle = middle:gsub("<|endoftext|>", "")
  -- Without a stop event the model fills the whole token budget with
  -- paragraph-less continuation; greedy decoding can also loop one line
  -- forever. Truncate exact-duplicate runs and cap the line count.
  middle = trim_fim_middle(middle)
  local offset = editable_cursor_offset(context)
  local after = context.editable:sub(offset + 1)
  -- Mid-line cursor with text following: the model tends to echo that text
  -- or ramble past it. Keep the suggestion on the current line...
  if after:match("^[^\n]*%S") then
    middle = middle:match("^[^\n]*")
  end
  -- ...and cut a tail that duplicates what already sits after the cursor.
  for k = math.min(#middle, #after), 1, -1 do
    if middle:sub(-k) == after:sub(1, k) then
      middle = middle:sub(1, #middle - k)
      break
    end
  end
  if middle:gsub("%s", "") == "" then
    return nil
  end
  local text = context.editable:sub(1, offset) .. middle .. after
  if text == context.editable then
    return nil
  end
  return { text = text, cursor_offset = nil }
end

-- --------------------------------------------------------------------------
-- LSP hover translation (opt-in via hover_translate = true).
--
-- Two hook points cover both hover renderers:
--  * native Neovim hover ends in vim.lsp.util.open_floating_preview
--    (wrapped below; 0.12 bypasses vim.lsp.handlers, so the handler table
--    is not a viable hook point);
--  * noice.nvim replaces vim.lsp.buf.hover and routes results to its own
--    on_hover (wrapped below; it never calls open_floating_preview).
-- Whichever path renders the float, the original English documentation
-- shows first and is then replaced in place with the Chinese translation
-- (or instantly on cache hits). Translation requires a chat-capable model:
-- while the server runs Zeta 2.1 (completion-only) it is disabled entirely,
-- re-probed every 10 s so live model switches are picked up. Failures are
-- reported loudly, leaving the original English float untouched.
-- --------------------------------------------------------------------------
-- Assigned later next to the hover model gate; M.enable/M.disable call it to
-- keep the <leader>z menu labels fresh.
local sync_menu_labels

local HOVER_TRANSLATE_PROMPT = table.concat({
  "你是技术文档翻译器。把用户给出的 LSP 悬浮文档翻译成简体中文。",
  "规则：保留所有代码、类型签名、标识符、参数名与 markdown 结构（含代码块）原样不动；",
  "只翻译自然语言说明文字；不要添加任何解释或前后缀。",
  "必须逐段完整翻译全部内容，不得省略、概括或跳过任何段落、参数说明、返回值说明、异常说明或示例。",
})

local hover_cache = {}

local function hover_dbg(msg)
  if state.opts.hover_debug then
    vim.api.nvim_echo({ { "[zeddit-hover] " .. msg, "WarningMsg" } }, true, {})
  end
end

local function translate_via_chat(source, on_done)
  local key = vim.fn.sha256(source)
  if hover_cache[key] then
    on_done(hover_cache[key])
    return
  end
  local payload = vim.json.encode({
    model = state.opts.provider_model,
    temperature = 0.0,
    max_tokens = state.opts.hover_max_tokens or 4096,
    messages = {
      { role = "system", content = HOVER_TRANSLATE_PROMPT },
      { role = "user", content = source },
    },
  })
  local args = {
    "curl",
    "--noproxy",
    "*",
    "--silent",
    "--max-time",
    "120",
    "-H",
    "Content-Type: application/json",
  }
  if state.opts.api_key and state.opts.api_key ~= "" then
    args[#args + 1] = "-H"
    args[#args + 1] = "Authorization: Bearer " .. state.opts.api_key
  end
  args[#args + 1] = "--data-binary"
  args[#args + 1] = "@-"
  args[#args + 1] = chat_url(state.opts.provider_url)
  vim.system(args, { text = true, stdin = payload }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, "curl exit " .. result.code .. ": " .. (result.stderr or ""):sub(1, 120))
        return
      end
      local ok, decoded = pcall(vim.json.decode, result.stdout or "")
      local choice = ok and decoded and decoded.choices and decoded.choices[1]
      local content = choice and choice.message and choice.message.content
      if type(content) ~= "string" or content == "" then
        on_done(nil, "empty response from server")
        return
      end
      content = content:gsub("^%s*<think>.-</think>%s*", "")
      if choice and choice.finish_reason == "length" then
        vim.api.nvim_echo({ { "[zeddit-hover] translation hit the token budget; showing partial result", "WarningMsg" } }, true, {})
      end
      hover_cache[key] = content
      on_done(content)
    end)
  end)
end

-- Model gate for hover translation. Zeta 2.1 is a raw completion model that
-- cannot chat, so translation is fully disabled while the server runs it.
-- /props is probed with a 10 s cache: live model switches are picked up
-- quickly and K never blocks on a probe. Basename match only -- directory
-- names may contain model tokens (both GGUFs live in a "zeta-2.1-GGUF" dir).
hover_model = { kind = nil, at = 0 } --- kind: "mellum" | "zeta" | "other" | "down"

probe_hover_model = function(cb)
  if hover_model.kind ~= nil and os.time() - hover_model.at < 10 then
    cb(hover_model.kind == "mellum")
    return
  end
  vim.system(
    { "curl", "--noproxy", "*", "--silent", "--max-time", "3", props_url(state.opts.provider_url) },
    { text = true },
    function(result)
      vim.schedule(function()
        local kind = "down"
        if result.code == 0 then
          local ok, props = pcall(vim.json.decode, result.stdout or "")
          local base = ok
            and props
            and type(props.model_path) == "string"
            and props.model_path:match("[^/\\]+$")
          local lower = base and base:lower() or ""
          kind = lower:find("mellum", 1, true) and "mellum" or (lower:find("zeta", 1, true) and "zeta" or "other")
        end
        local changed = hover_model.kind ~= kind
        if changed and kind ~= "mellum" then
          vim.api.nvim_echo({
            { "[zeddit-hover] translation off: server model is " .. kind .. " (needs Mellum2)", "WarningMsg" },
          }, true, {})
        end
        hover_model = { kind = kind, at = os.time() }
        if changed then
          sync_menu_labels()
        end
        cb(kind == "mellum")
      end)
    end
  )
end

-- Gate wrapper: cache hits answer instantly; misses are translated only when
-- the server currently runs Mellum2. Gated misses call on_done(nil) with no
-- error so callers skip quietly.
local function translate_hover_text(source, on_done)
  probe_hover_model(function(ok)
    if not ok then
      hover_dbg("translation disabled: server is not running Mellum2")
      on_done(nil)
      return
    end
    translate_via_chat(source, on_done)
  end)
end

-- Refresh which-key labels for the <leader>z toggles. which-key cannot grey
-- out entries, so a Zeta-gated toggle is labelled with the serving model
-- instead. No-op without which-key or when the user maps different keys.
sync_menu_labels = function()
  local ok, wk = pcall(require, "which-key")
  if not ok then
    return
  end
  local auto = state.opts.auto_trigger and "auto completion: on" or "auto completion: off"
  local master = state.enabled and "plugin (master): enabled" or "plugin (master): disabled"
  local hover
  if hover_model.kind ~= nil and hover_model.kind ~= "mellum" then
    hover = "hover translate: off (" .. hover_model.kind .. " model)"
  else
    hover = state.opts.hover_translate and "hover translate: on" or "hover translate: off"
  end
  pcall(wk.add, {
    { "<leader>zt", desc = auto },
    { "<leader>zT", desc = master },
    { "<leader>zh", desc = hover },
  })
end

-- Quick toggle for hover translation, mirroring the settings-page switch
-- (same option, persisted). Refuses to flip while the server runs Zeta.
function M.toggle_auto_trigger()
  local target = not state.opts.auto_trigger
  local ok, err = M.set("auto_trigger", target)
  if not ok then
    vim.notify("[zeddit] " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  vim.notify("[zeddit] auto completion: " .. (target and "on" or "off (manual via <M-g>)"))
  sync_menu_labels()
  return target
end
function M.toggle_hover_translate()
  if hover_model.kind ~= nil and hover_model.kind ~= "mellum" then
    vim.notify(
      ("[zeddit] hover translation unavailable: server model is %s (needs Mellum2)"):format(hover_model.kind),
      vim.log.levels.WARN
    )
    return false
  end
  local target = not state.opts.hover_translate
  local ok, err = M.set("hover_translate", target)
  if not ok then
    vim.notify("[zeddit] " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  vim.notify("[zeddit] hover translate: " .. (target and "on" or "off"))
  sync_menu_labels()
  return target
end
-- Hook the one rendering funnel every hover implementation ends up in:
-- vim.lsp.util.open_floating_preview. Neovim 0.12's vim.lsp.buf.hover
-- aggregates clients internally and never consults vim.lsp.handlers, so the
-- handler table is not a viable hook point. Scoped by focus_id so ONLY
-- hover floats are touched; signature help, diagnostics and every other
-- caller pass through byte-identical. Content is swapped keyed on the float
-- BUFFER (recovered via bufwinid), never the window id, so cursor movement
-- during the model round-trip cannot strand the translation.
local function wrap_hover_renderer()
  local util = vim.lsp.util
  local current = util.open_floating_preview
  if current == state.hover_wrapper_ofp then
    return
  end
  state.hover_orig_ofp = current
  state.hover_wrapper_ofp = function(contents, syntax, opts, ...)
    if state.opts.hover_debug then
      vim.api.nvim_echo({ { ("[zeddit-hover] ofp called: syntax=%s focus_id=%s"):format(tostring(syntax), tostring(opts and opts.focus_id)), "WarningMsg" } }, true, {})
    end
    local bufnr, winid = state.hover_orig_ofp(contents, syntax, opts, ...)
    if bufnr and opts and opts.focus_id == "textDocument/hover" and syntax == "markdown" then
      local source = table.concat(contents, "\n")
      if #source:gsub("%s", "") > 0 then
        if not hover_cache[vim.fn.sha256(source)] and winid and vim.api.nvim_win_is_valid(winid) then
          pcall(vim.api.nvim_win_set_config, winid, { title = " Translating... ", title_pos = "center" })
        end
        hover_dbg("translating hover (" .. #source .. " chars)")
        translate_hover_text(source, function(translated, err)
          if not translated then
            if err then
              vim.api.nvim_echo(
                { { "[zeddit-hover] translation failed: " .. tostring(err), "WarningMsg" } },
                true,
                {}
              )
              local fw = vim.fn.bufwinid(bufnr)
              if fw ~= -1 then
                pcall(vim.api.nvim_win_set_config, fw, { title = " Translation failed ", title_pos = "center" })
              end
            end
            return
          end
          if not vim.api.nvim_buf_is_valid(bufnr) then
            hover_dbg("float buffer gone, translation dropped")
            return
          end
          hover_dbg("replacing float contents (" .. #translated .. " chars)")
          local fw = vim.fn.bufwinid(bufnr)
          if fw ~= -1 then
            pcall(vim.api.nvim_win_set_config, fw, { title = " Translated by zeddit ", title_pos = "center" })
          end
          local tlines = vim.split(translated, "\n", { plain = true })
          vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, tlines)
          vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
          if fw ~= -1 then
            pcall(function()
              local width, height = util._make_floating_popup_size(tlines, opts)
              vim.api.nvim_win_set_width(fw, width)
              vim.api.nvim_win_set_height(fw, height)
            end)
          end
        end)
      end
    end
    return bufnr, winid
  end
  util.open_floating_preview = state.hover_wrapper_ofp
end

-- noice.nvim replaces vim.lsp.buf.hover and renders through its own view
-- system, never touching open_floating_preview. Hook its on_hover instead:
-- the original English float shows instantly, and once the translation
-- arrives the same hover message is re-rendered in place (Docs.get clears
-- the memoized message, so a second on_hover pass is a clean update, not an
-- append). If the float was closed meanwhile the translation stays in the
-- cache and the next K on the same symbol opens in Chinese instantly.
local function wrap_noice_hover()
  local ok, hover = pcall(require, "noice.lsp.hover")
  if not ok or type(hover) ~= "table" or type(hover.on_hover) ~= "function" then
    return
  end
  if hover.on_hover == state.hover_wrapper_noice then
    return
  end
  state.hover_orig_noice = hover.on_hover
  state.hover_wrapper_noice = function(err, result, ctx, config)
    if not (result and result.contents) then
      return state.hover_orig_noice(err, result, ctx, config)
    end
    local source = table.concat(vim.lsp.util.convert_input_to_markdown_lines(result.contents), "\n")
    if #source:gsub("%s", "") == 0 then
      return state.hover_orig_noice(err, result, ctx, config)
    end
    local cached = hover_cache[vim.fn.sha256(source)]
    if cached then
      return state.hover_orig_noice(err, vim.tbl_extend("force", {}, result, {
        contents = { kind = "markdown", value = cached },
      }), ctx, config)
    end
    state.hover_orig_noice(err, result, ctx, config)
    hover_dbg("translating noice hover (" .. #source .. " chars)")
    translate_hover_text(source, function(translated, terr)
      if not translated then
        if terr then
          vim.api.nvim_echo(
            { { "[zeddit-hover] translation failed: " .. tostring(terr), "WarningMsg" } },
            true,
            {}
          )
        end
        return
      end
      local ok_docs, docs = pcall(require, "noice.lsp.docs")
      local ok_fmt, format = pcall(require, "noice.lsp.format")
      local message = ok_docs and docs._messages and docs._messages.hover
      if not (ok_docs and ok_fmt and message and message:win()) then
        hover_dbg("noice hover closed, translation cached for next K")
        return
      end
      hover_dbg("re-rendering noice hover translated (" .. #translated .. " chars)")
      -- Do NOT re-enter on_hover here: its message:focus() guard would steal
      -- the cursor into the open float and skip the update. Replicate its
      -- benign half instead: clear + reformat + reshow the hover message.
      local msg = docs.get("hover")
      format.format(msg, { kind = "markdown", value = translated }, { ft = vim.bo[ctx.bufnr].filetype })
      docs.show(msg)
    end)
  end
  hover.on_hover = state.hover_wrapper_noice
end

local function install_hover_hook()
  if not state.opts.hover_translate or state.hover_hook_wrapped then
    return
  end
  state.hover_hook_wrapped = true
  local function install_all()
    wrap_hover_renderer()
    wrap_noice_hover()
  end
  vim.api.nvim_create_autocmd("LspAttach", {
    group = state.group,
    callback = install_all,
  })
  vim.api.nvim_create_autocmd("User", {
    group = state.group,
    pattern = "VeryLazy",
    callback = install_all,
  })
  install_all()
  if state.opts.hover_debug then
    local noice_src = "n/a"
    local ok, nh = pcall(require, "noice.lsp.hover")
    if ok and type(nh.on_hover) == "function" then
      noice_src = debug.getinfo(nh.on_hover, "S").short_src
    end
    vim.api.nvim_echo({ { ("[zeddit-hover] hook installed: translate=%s ofp_src=%s noice_src=%s"):format(tostring(state.opts.hover_translate), debug.getinfo(vim.lsp.util.open_floating_preview, "S").short_src, noice_src), "WarningMsg" } }, true, {})
  end
end


local function parse_output(raw, old_editable)
  if type(raw) ~= "string" or raw == "" then
    return nil
  end

  local end_at = raw:find(END_MARKER, 1, true)
  if end_at then
    raw = raw:sub(1, end_at - 1)
  end
  if raw:find("NO_EDITS", 1, true) then
    return nil
  end

  local tags = {}
  local search = 1
  while true do
    local start_pos, end_pos, number = raw:find(MARKER_PATTERN, search)
    if not start_pos then
      break
    end
    tags[#tags + 1] = {
      start_pos = start_pos,
      end_pos = end_pos,
      number = tonumber(number),
    }
    search = end_pos + 1
  end

  if #tags < 2 then
    return nil
  end

  local first = tags[1].number
  local last = tags[#tags].number
  if not first or not last then
    return nil
  end

  local offsets = marker_offsets(old_editable)
  if first == last then
    return { text = old_editable, cursor_offset = nil }
  end
  if first < 1 or last > #offsets or first > last then
    return nil
  end

  local replacement_parts = {}
  for i = 1, #tags - 1 do
    local start_pos = tags[i].end_pos + 1
    local end_pos = tags[i + 1].start_pos - 1
    local part = raw:sub(start_pos, end_pos)
    -- Models occasionally put the first marker on its own line even though
    -- the V0318 training format puts it directly before the block content.
    if i == 1 and part:sub(1, 1) == "\n" then
      part = part:sub(2)
    end
    replacement_parts[#replacement_parts + 1] = part
  end
  local replacement = table.concat(replacement_parts)
  local start_byte = offsets[first]
  local end_byte = offsets[last]
  local new_text = old_editable:sub(1, start_byte) .. replacement .. old_editable:sub(end_byte + 1)

  local cursor_pos = new_text:find(CURSOR_MARKER, 1, true)
  local cursor_offset
  if cursor_pos then
    cursor_offset = cursor_pos - 1
    new_text = new_text:sub(1, cursor_pos - 1) .. new_text:sub(cursor_pos + #CURSOR_MARKER)
  end

  -- The model is trained with newline-terminated regions.  Neovim's buffer
  -- API represents the final line without a trailing newline, so avoid
  -- turning an otherwise ordinary completion into an extra empty line.
  if not old_editable:find("\n$", 1, false) and new_text:sub(-1) == "\n" then
    new_text = new_text:sub(1, -2)
  elseif old_editable:find("\n$", 1, false) and new_text:sub(-1) ~= "\n" then
    new_text = new_text .. "\n"
  end

  if new_text == old_editable then
    return nil
  end
  return { text = new_text, cursor_offset = cursor_offset }
end

local function split_suffix(old_text, new_text, cursor_offset)
  local old_after = old_text:sub(cursor_offset + 1)
  local new_after = new_text:sub(cursor_offset + 1)
  if new_text:sub(1, cursor_offset) ~= old_text:sub(1, cursor_offset) then
    return nil
  end

  local ghost = new_after
  local common_suffix = 0
  local max_common = math.min(#old_after, #new_after)
  while common_suffix < max_common do
    local old_byte = old_after:sub(#old_after - common_suffix, #old_after - common_suffix)
    local new_byte = new_after:sub(#new_after - common_suffix, #new_after - common_suffix)
    if old_byte ~= new_byte then
      break
    end
    common_suffix = common_suffix + 1
  end
  if common_suffix > 0 then
    ghost = new_after:sub(1, #new_after - common_suffix)
  end
  return ghost
end

local function set_preview(bufnr, context, parsed)
  if parsed.text == context.editable then
    return
  end
  clear_pending(bufnr)

  local ghost = split_suffix(context.editable, parsed.text, context.cursor_rel)
  local extmark_opts = {
    hl_mode = "combine",
    virt_text_pos = "inline",
  }

  if ghost and ghost ~= "" then
    local ghost_lines = split_lines(ghost)
    local first_line = ghost_lines[1] or ""
    if first_line == "" then
      first_line = "↵"
    end
    extmark_opts.virt_text = { { first_line, "ZedditGhost" } }
    if #ghost_lines > 1 then
      extmark_opts.virt_lines = {}
      for i = 2, #ghost_lines do
        extmark_opts.virt_lines[#extmark_opts.virt_lines + 1] = {
          { ghost_lines[i], "ZedditGhost" },
        }
      end
    end
  else
    -- A multi-line rewrite is still safely applicable, but it cannot be
    -- represented as a single inline suffix without hiding existing code.
    extmark_opts.virt_text = { { " 󰛩 Zeddit edit", "ZedditEdit" } }
    extmark_opts.virt_text_pos = "eol"
  end

  local extmark_id = vim.api.nvim_buf_set_extmark(
    bufnr,
    state.namespace,
    context.cursor_row,
    context.cursor_col,
    extmark_opts
  )

  local cursor_offset = parsed.cursor_offset
  if cursor_offset == nil then
    if ghost then
      cursor_offset = context.cursor_rel + #ghost
    else
      cursor_offset = math.min(context.cursor_rel, #parsed.text)
    end
  end

  state.pending[bufnr] = {
    bufnr = bufnr,
    tick = context.tick,
    cursor_row = context.cursor_row,
    cursor_col = context.cursor_col,
    editable_start_line = context.editable_start_line,
    editable_end_line = context.editable_end_line,
    old_text = context.editable,
    new_text = parsed.text,
    new_cursor_offset = cursor_offset,
    insert_text = ghost,
    extmark_id = extmark_id,
  }
end

local function pending_still_valid(bufnr, pending)
  if not pending or not is_valid_buffer(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then
    return false
  end
  if vim.api.nvim_buf_get_changedtick(bufnr) ~= pending.tick then
    return false
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  return cursor[1] - 1 == pending.cursor_row and cursor[2] == pending.cursor_col
end

local function apply_pending(bufnr, pending)
  if not pending_still_valid(bufnr, pending) then
    if state.pending[bufnr] == pending then
      clear_pending(bufnr)
    end
    return false
  end

  clear_pending(bufnr)

  local new_row, new_col
  if pending.insert_text and pending.insert_text ~= "" then
    local lines = split_lines(pending.insert_text)
    vim.api.nvim_buf_set_text(
      bufnr,
      pending.cursor_row,
      pending.cursor_col,
      pending.cursor_row,
      pending.cursor_col,
      lines
    )
    new_row = pending.cursor_row + #lines - 1
    if #lines == 1 then
      new_col = pending.cursor_col + #lines[1]
    else
      new_col = #lines[#lines]
    end
  else
    local end_row = pending.editable_end_line - 1
    local current_lines = vim.api.nvim_buf_get_lines(bufnr, pending.editable_start_line, pending.editable_end_line, true)
    local end_col = #(current_lines[#current_lines] or "")
    vim.api.nvim_buf_set_text(
      bufnr,
      pending.editable_start_line,
      0,
      end_row,
      end_col,
      split_lines(pending.new_text)
    )

    local cursor_offset = math.max(0, math.min(pending.new_cursor_offset or #pending.new_text, #pending.new_text))
    local before_cursor = pending.new_text:sub(1, cursor_offset)
    local line_delta = 0
    for _ in before_cursor:gmatch("\n") do
      line_delta = line_delta + 1
    end
    local last_newline = before_cursor:match(".*()\n")
    new_row = pending.editable_start_line + line_delta
    new_col = last_newline and (#before_cursor - last_newline) or #before_cursor
  end

  state.ignore_tick[bufnr] = vim.api.nvim_buf_get_changedtick(bufnr)
  state.last_text[bufnr] = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), "\n")
  pcall(vim.api.nvim_win_set_cursor, 0, { new_row + 1, new_col })
  return true
end

local function request_now(bufnr, force)
  if not eligible(bufnr) or (not force and vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i") then
    return
  end
  if not force and vim.fn.pumvisible() == 1 then
    return
  end

  close_timer(bufnr)
  cancel_job(bufnr)
  clear_pending(bufnr)

  local context, error_message = snapshot(bufnr)
  if not context then
    if error_message then
      notify_error(error_message)
    end
    return
  end

  local model = state.opts.provider_model or state.opts.model
  if not model or model == "" then
    notify_error("provider_model is not configured")
    return
  end

  local fmt = resolve_format()
  local body, url
  if fmt == "Mellum2" then
    body = {
      model = model,
      prompt = mellum_fim_prompt(context),
      max_tokens = state.opts.fim_max_tokens,
      -- Greedy decoding degenerates into exact-repeat loops on FIM; a small
      -- temperature floor plus a mild repeat penalty keeps completions sane.
      temperature = math.max(state.opts.temperature, 0.1),
      top_k = state.opts.top_k,
      repeat_penalty = 1.05,
      -- "\n\n" stops the completion at the paragraph boundary: without it
      -- the model free-runs through the whole token budget (a lone comment
      -- can snowball into an entire file).
      stop = { "<fim_prefix>", "<fim_suffix>", "<fim_middle>", "<|endoftext|>", "\n\n" },
    }
    url = completion_url(state.opts.provider_url)
  else
    body = {
      model = model,
      prompt = context.prompt,
      max_tokens = state.opts.max_tokens,
      temperature = state.opts.temperature,
      top_k = state.opts.top_k,
      stop = { END_MARKER },
    }
    url = completion_url(state.opts.provider_url)
  end

  local payload = vim.json.encode(body)
  local args = {
    "curl",
    "--noproxy",
    "*",
    "--silent",
    "--show-error",
    "--fail-with-body",
    "--max-time",
    tostring(math.max(1, math.ceil(state.opts.timeout_ms / 1000))),
    "-H",
    "Content-Type: application/json",
  }
  if state.opts.api_key and state.opts.api_key ~= "" then
    args[#args + 1] = "-H"
    args[#args + 1] = "Authorization: Bearer " .. state.opts.api_key
  end
  args[#args + 1] = "--data-binary"
  args[#args + 1] = "@-"
  args[#args + 1] = url

  local generation = (state.generations[bufnr] or 0) + 1
  state.generations[bufnr] = generation
  local request = {
    generation = generation,
    tick = context.tick,
  }
  state.jobs[bufnr] = request

  local ok, job_or_error = pcall(vim.system, args, { text = true, stdin = payload }, function(result)
    vim.schedule(function()
      if state.jobs[bufnr] ~= request or state.generations[bufnr] ~= generation then
        return
      end
      state.jobs[bufnr] = nil

      if not is_valid_buffer(bufnr) or vim.api.nvim_buf_get_changedtick(bufnr) ~= context.tick then
        return
      end
      if result.code ~= 0 then
        local detail = (result.stderr or result.stdout or "curl failed"):gsub("%s+$", "")
        notify_error("request failed: " .. detail)
        return
      end

      local decoded_ok, decoded = pcall(vim.json.decode, result.stdout or "")
      if not decoded_ok or type(decoded) ~= "table" then
        notify_error("LM Studio returned invalid JSON")
        return
      end
      if decoded.error then
        local detail = type(decoded.error) == "table" and (decoded.error.message or vim.inspect(decoded.error)) or tostring(decoded.error)
        notify_error("LM Studio: " .. detail)
        return
      end

      local choice = decoded.choices and decoded.choices[1]
      local parsed
      if fmt == "Mellum2" then
        parsed = parse_fim_output(choice and choice.text, context)
      else
        parsed = parse_output(choice and choice.text, context.editable)
      end
      if parsed then
        set_preview(bufnr, context, parsed)
      end
    end)
  end)

  if not ok then
    state.jobs[bufnr] = nil
    notify_error("could not start curl: " .. tostring(job_or_error))
    return
  end
  request.job = job_or_error
end

local function schedule_request(bufnr, delay, force)
  if not eligible(bufnr) then
    return
  end
  close_timer(bufnr)
  cancel_job(bufnr)
  clear_pending(bufnr)

  local timer = vim.uv.new_timer()
  state.timers[bufnr] = timer
  timer:start(delay == nil and state.opts.debounce_ms or delay, 0, function()
    if state.timers[bufnr] == timer then
      state.timers[bufnr] = nil
    end
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
    vim.schedule(function()
      request_now(bufnr, force)
    end)
  end)
end

function M.has()
  local bufnr = vim.api.nvim_get_current_buf()
  return pending_still_valid(bufnr, state.pending[bufnr])
end

function M.accept()
  -- Let completion menus and snippet jumps win over a Zeddit ghost edit.
  if vim.fn.pumvisible() == 1 then
    return false
  end
  local blink_ok, blink = pcall(require, "blink.cmp")
  if blink_ok and blink.is_menu_visible and blink.is_menu_visible() then
    return false
  end
  if vim.snippet and vim.snippet.active then
    local ok, active = pcall(vim.snippet.active, { direction = 1 })
    if ok and active then
      return false
    end
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local pending = state.pending[bufnr]
  if not pending_still_valid(bufnr, pending) then
    return false
  end

  -- Blink's <Tab> is an expr mapping.  Mutating the buffer inside that
  -- callback is discarded by Neovim, so apply after the mapping returns.
  if blink_ok and blink.hide then
    pcall(blink.hide)
  end
  vim.schedule(function()
    apply_pending(bufnr, pending)
  end)
  return true
end

function M.clear()
  clear_pending(vim.api.nvim_get_current_buf())
end

function M.request(force)
  local bufnr = vim.api.nvim_get_current_buf()
  if eligible(bufnr) then
    schedule_request(bufnr, 0, force == true)
    return
  end
  -- Manual triggers must fail loudly: a silent no-op reads as "no
  -- suggestion" and hides that the plugin itself is switched off.
  if not state.enabled or not state.opts.enabled then
    notify_error("zeddit is disabled (:ZedditToggle or <leader>zt to enable)")
  end
end

local function persist_now()
  local ok, err = pcall(save_persisted)
  if not ok then
    notify_error("could not save settings: " .. tostring(err))
  end
end

local number_keys = {
  temperature = true,
  top_k = true,
  max_tokens = true,
  prompt_budget_tokens = true,
  debounce_ms = true,
  timeout_ms = true,
  context_before_lines = true,
  context_after_lines = true,
  editable_before_lines = true,
  editable_after_lines = true,
  context_max_chars = true,
  fim_max_tokens = true,
  fim_max_lines = true,
  hover_max_tokens = true,
}

local integer_keys = {
  top_k = true,
  max_tokens = true,
  prompt_budget_tokens = true,
  debounce_ms = true,
  timeout_ms = true,
  context_before_lines = true,
  context_after_lines = true,
  editable_before_lines = true,
  editable_after_lines = true,
  context_max_chars = true,
  fim_max_tokens = true,
  fim_max_lines = true,
  hover_max_tokens = true,
}

local function parse_bool(value)
  if type(value) == "boolean" then
    return value
  end
  local text = tostring(value or ""):lower()
  if text == "true" or text == "1" or text == "yes" or text == "on" then
    return true
  end
  if text == "false" or text == "0" or text == "no" or text == "off" or text == "" then
    return false
  end
  return nil, "expected true/false"
end

local function coerce_option(key, value)
  if key == "enabled" or key == "notify_errors" or key == "hover_translate" or key == "hover_debug" or key == "auto_trigger" then
    return parse_bool(value)
  end
  if number_keys[key] then
    local number = tonumber(value)
    if not number then
      return nil, "expected a number"
    end
    if integer_keys[key] then
      number = math.floor(number)
    end
    if number < 0 then
      return nil, "must be >= 0"
    end
    return number
  end
  if key == "prompt_format" then
    local fmt = vim.trim(tostring(value or ""))
    if fmt ~= "auto" and fmt ~= "Zeta2.1" and fmt ~= "Mellum2" then
      return nil, "expected auto | Zeta2.1 | Mellum2"
    end
    return fmt
  end
  if value == nil then
    value = ""
  else
    value = vim.trim(tostring(value))
  end
  if key == "provider_url" and value == "" then
    return nil, "API URL cannot be empty"
  end
  if key == "provider_model" and value == "" then
    return nil, "model cannot be empty"
  end
  if key == "api_key" and value == "" then
    return vim.NIL
  end
  return value
end

local function display_option(key, value)
  if key == "api_key" then
    if value and value ~= "" then
      return "********"
    end
    return "(none)"
  end
  if type(value) == "boolean" then
    return value and "on" or "off"
  end
  if value == nil or value == "" then
    return "(empty)"
  end
  return tostring(value)
end

function M.get(key)
  if key == "enabled" then
    return state.enabled
  end
  if key then
    return state.opts[key]
  end
  local opts = vim.deepcopy(state.opts)
  opts.enabled = state.enabled
  return opts
end

function M.set(key, value, set_opts)
  set_opts = set_opts or {}
  local coerced, err = coerce_option(key, value)
  if err then
    return false, err
  end
  if coerced == vim.NIL then
    coerced = nil
  end

  if key == "enabled" then
    if coerced then
      M.enable({ persist = false })
    else
      M.disable({ persist = false })
    end
  else
    state.opts[key] = coerced
    for bufnr in pairs(state.jobs) do
      cancel_job(bufnr)
    end
    clear_pending(vim.api.nvim_get_current_buf())
  end

  if set_opts.persist ~= false then
    persist_now()
  end
  return true
end

function M.enable(enable_opts)
  enable_opts = enable_opts or {}
  state.enabled = true
  state.opts.enabled = true
  vim.g.zeddit_enabled = true
  if enable_opts.persist ~= false then
    persist_now()
  end
  sync_menu_labels()
end

function M.disable(disable_opts)
  disable_opts = disable_opts or {}
  state.enabled = false
  state.opts.enabled = false
  vim.g.zeddit_enabled = false
  for bufnr in pairs(state.jobs) do
    clear_buffer(bufnr)
  end
  for bufnr in pairs(state.pending) do
    clear_pending(bufnr)
  end
  if disable_opts.persist ~= false then
    persist_now()
  end
  sync_menu_labels()
end

function M.toggle()
  if state.enabled then
    M.disable()
  else
    M.enable()
  end
  return state.enabled
end

function M.buffer_enabled(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return vim.b[bufnr].zeddit_enabled ~= false
end

function M.toggle_buffer(bufnr, toggle_opts)
  if type(bufnr) == "table" then
    toggle_opts = bufnr
    bufnr = nil
  end
  toggle_opts = toggle_opts or {}
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local enabled = not M.buffer_enabled(bufnr)
  vim.b[bufnr].zeddit_enabled = enabled
  if not enabled then
    clear_buffer(bufnr)
  end
  if toggle_opts.notify ~= false then
    notify(
      (enabled and "Enabled" or "Disabled") .. " Zeddit in this buffer",
      enabled and vim.log.levels.INFO or vim.log.levels.WARN,
      true
    )
  end
  return enabled
end

function M.reset_settings()
  local enabled = state.plugin_opts.enabled
  if enabled == nil then
    enabled = defaults.enabled
  end
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), vim.deepcopy(state.plugin_opts))
  if enabled then
    M.enable({ persist = false })
  else
    M.disable({ persist = false })
  end
  persist_now()
  notify("Reset Zeddit settings to plugin defaults", vim.log.levels.INFO, true)
end

function M.status()
  local bufnr = vim.api.nvim_get_current_buf()
  local message = string.format(
    "Zeddit %s | buffer %s | %s | model: %s",
    state.enabled and "enabled" or "disabled",
    M.buffer_enabled(bufnr) and "on" or "off",
    completion_url(state.opts.provider_url),
    tostring(state.opts.provider_model or state.opts.model)
  )
  notify(message, vim.log.levels.INFO, true)
end

local setting_fields = {
  {
    key = "enabled",
    label = "Enabled",
    type = "boolean",
    desc = "Globally enable or disable Zeddit ghost edits.",
  },
  {
    key = "provider_url",
    label = "API URL",
    type = "string",
    desc = "OpenAI-compatible base URL. `/v1/completions` is added when missing.\nExample: http://localhost:8000",
  },
  {
    key = "provider_model",
    label = "Model",
    type = "string",
    desc = "Model id sent as `model`. For LM Studio this is usually the GGUF path.",
  },
  {
    key = "prompt_format",
    label = "Prompt format",
    type = "choice",
    values = { "auto", "Zeta2.1", "Mellum2" },
    desc = "auto = follow the served model (live /props probe). Force Zeta2.1 or Mellum2 only when the probe is unavailable or wrong.",
  },
  {
    key = "api_key",
    label = "API key",
    type = "secret",
    desc = "Optional Bearer token. Leave empty for local LM Studio.",
  },
  {
    key = "temperature",
    label = "Temperature",
    type = "number",
    desc = "Sampling temperature. 0 is greedy / most deterministic.",
  },
  {
    key = "top_k",
    label = "Top K",
    type = "integer",
    desc = "Top-k sampling used by llama.cpp / LM Studio.",
  },
  {
    key = "max_tokens",
    label = "Max tokens",
    type = "integer",
    desc = "Maximum tokens in the completion. Keep this small when n_ctx is 2048.",
  },
  {
    key = "fim_max_tokens",
    label = "FIM max tokens",
    type = "integer",
    desc = "Token budget for one Mellum2 FIM completion. Small (64-128) keeps ghost edits snappy.",
  },
  {
    key = "fim_max_lines",
    label = "FIM max lines",
    type = "integer",
    desc = "Client-side cap on ghost-edit length. The FIM middle is truncated after this many lines.",
  },
  {
    key = "prompt_budget_tokens",
    label = "Prompt budget",
    type = "integer",
    desc = "Soft prompt size limit. History is dropped if the prompt would exceed this.",
  },
  {
    key = "debounce_ms",
    label = "Debounce (ms)",
    type = "integer",
    desc = "How long to wait after typing before requesting a suggestion.",
  },
  {
    key = "timeout_ms",
    label = "Timeout (ms)",
    type = "integer",
    desc = "curl timeout for each LM Studio request.",
  },
  {
    key = "context_before_lines",
    label = "Context before",
    type = "integer",
    desc = "How many lines above the cursor are sent as surrounding context.",
  },
  {
    key = "context_after_lines",
    label = "Context after",
    type = "integer",
    desc = "How many lines below the cursor are sent as surrounding context.",
  },
  {
    key = "editable_before_lines",
    label = "Editable before",
    type = "integer",
    desc = "How many lines above the cursor the model is allowed to rewrite.",
  },
  {
    key = "editable_after_lines",
    label = "Editable after",
    type = "integer",
    desc = "How many lines below the cursor the model is allowed to rewrite.",
  },
  {
    key = "context_max_chars",
    label = "Max context chars",
    type = "integer",
    desc = "Hard character cap on the code context included in the prompt.",
  },
  {
    key = "notify_errors",
    label = "Notify errors",
    type = "boolean",
    desc = "Show a notification when a request fails.",
  },
  {
    key = "hover_translate",
    label = "Hover translate",
    type = "boolean",
    desc = "Translate LSP hover docs into Chinese. Requires Mellum2 (chat-capable); auto-disabled while the server runs Zeta (completion-only).",
  },
  {
    key = "auto_trigger",
    label = "Auto trigger",
    type = "boolean",
    desc = "Request ghost edits automatically while typing. Off = manual only (map an insert-mode key to require('zeddit').request(true)).",
  },
  {
    key = "hover_max_tokens",
    label = "Hover max tokens",
    type = "integer",
    desc = "Output token budget for one hover translation. Long docstrings need 4096+.",
  },
}

local function current_setting_value(field)
  if field.key == "enabled" then
    return state.enabled
  end
  return state.opts[field.key]
end

local function prompt_setting(field, on_done)
  local current = current_setting_value(field)
  local default_text
  if field.type == "secret" then
    default_text = (current and current ~= "") and "********" or ""
  elseif field.type == "boolean" then
    default_text = current and "true" or "false"
  elseif current == nil then
    default_text = ""
  else
    default_text = tostring(current)
  end

  vim.ui.input({
    prompt = field.label .. ": ",
    default = default_text,
  }, function(value)
    if value == nil then
      if on_done then
        on_done(false)
      end
      return
    end
    if field.type == "secret" and value == "********" then
      if on_done then
        on_done(false)
      end
      return
    end
    local ok, err = M.set(field.key, value)
    if not ok then
      notify(field.label .. ": " .. err, vim.log.levels.WARN, true)
    else
      notify(field.label .. " = " .. display_option(field.key, M.get(field.key)), vim.log.levels.INFO, true)
    end
    if on_done then
      on_done(ok)
    end
  end)
end

local function apply_setting_item(item, on_done)
  if item.action == "reset" then
    vim.ui.select({ "Reset to plugin defaults", "Cancel" }, {
      prompt = "Reset Zeddit settings?",
    }, function(choice)
      if choice == "Reset to plugin defaults" then
        M.reset_settings()
      end
      if on_done then
        on_done(choice == "Reset to plugin defaults")
      end
    end)
    return
  end

  local field = item.field
  if field.type == "choice" then
    vim.ui.select(field.values, {
      prompt = field.label .. " (current: " .. tostring(current_setting_value(field)) .. ")",
    }, function(choice)
      if choice == nil then
        if on_done then
          on_done(false)
        end
        return
      end
      local ok, err = M.set(field.key, choice)
      if not ok then
        notify(field.label .. ": " .. err, vim.log.levels.WARN, true)
      else
        notify(field.label .. " = " .. display_option(field.key, M.get(field.key)), vim.log.levels.INFO, true)
      end
      if on_done then
        on_done(ok)
      end
    end)
    return
  end
  if field.type == "boolean" then
    local ok, err = M.set(field.key, not current_setting_value(field))
    if not ok then
      notify(field.label .. ": " .. err, vim.log.levels.WARN, true)
    else
      notify(field.label .. " = " .. display_option(field.key, M.get(field.key)), vim.log.levels.INFO, true)
    end
    if on_done then
      on_done(ok)
    end
    return
  end

  prompt_setting(field, on_done)
end

function M.configure()
  local items = {}
  for _, field in ipairs(setting_fields) do
    local value = current_setting_value(field)
    local display = display_option(field.key, value)
    items[#items + 1] = {
      field = field,
      label = field.label,
      display = display,
      text = field.label .. " " .. field.key .. " " .. display .. " " .. field.desc,
      preview = {
        text = table.concat({
          field.label,
          "",
          "Current: " .. display,
          "Key: " .. field.key,
          "",
          field.desc,
        }, "\n"),
        ft = "markdown",
      },
    }
  end
  items[#items + 1] = {
    action = "reset",
    label = "Reset settings",
    display = "plugin defaults",
    text = "Reset settings plugin defaults",
    preview = {
      text = "Restore API URL, model, and sampling options from your plugin spec.\nSaved GUI settings in nvim-data/zeddit-settings.json are replaced.",
      ft = "markdown",
    },
  }

  local function reopen()
    vim.schedule(M.configure)
  end

  if Snacks and Snacks.picker then
    Snacks.picker.pick({
      source = "zeddit_settings",
      title = "Zeddit Settings",
      items = items,
      format = function(item)
        local label = item.label or ""
        local pad = math.max(1, 20 - vim.api.nvim_strwidth(label))
        return {
          { label, "SnacksPickerLabel" },
          { string.rep(" ", pad), "SnacksPickerDelim" },
          { item.display or "", "SnacksPickerComment" },
        }
      end,
      preview = "preview",
      confirm = function(picker, item)
        picker:close()
        if not item then
          return
        end
        vim.schedule(function()
          apply_setting_item(item, reopen)
        end)
      end,
      layout = { preset = "ivy" },
    })
    return
  end

  vim.ui.select(items, {
    prompt = "Zeddit Settings",
    format_item = function(item)
      return string.format("%-18s %s", item.label, item.display)
    end,
  }, function(item)
    if not item then
      return
    end
    apply_setting_item(item, reopen)
  end)
end

function M.setup(user_opts)
  state.plugin_opts = vim.deepcopy(user_opts or {})
  local persisted = load_persisted()
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), state.plugin_opts, persisted)
  if state.opts.api_key == "" then
    state.opts.api_key = nil
  end
  state.enabled = state.opts.enabled ~= false
  vim.g.zeddit_enabled = state.enabled

  if state.group then
    pcall(vim.api.nvim_del_augroup_by_id, state.group)
  end
  state.group = vim.api.nvim_create_augroup("zeddit", { clear = true })

  vim.api.nvim_set_hl(0, "ZedditGhost", { link = "Comment", default = true })
  install_hover_hook()
  vim.api.nvim_set_hl(0, "ZedditEdit", { link = "DiagnosticVirtualTextInfo", default = true })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = state.group,
    callback = function(args)
      if is_valid_buffer(args.buf) then
        state.last_text[args.buf] = table.concat(vim.api.nvim_buf_get_lines(args.buf, 0, -1, true), "\n")
      end
    end,
  })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = state.group,
    callback = function(args)
      if state.opts.auto_trigger and eligible(args.buf) then
        schedule_request(args.buf, 100)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
    group = state.group,
    callback = function(args)
      if not eligible(args.buf) then
        return
      end
      local text = table.concat(vim.api.nvim_buf_get_lines(args.buf, 0, -1, true), "\n")
      record_change(args.buf, text)
      local tick = vim.api.nvim_buf_get_changedtick(args.buf)
      if state.ignore_tick[args.buf] == tick then
        state.ignore_tick[args.buf] = nil
        return
      end
      if state.opts.auto_trigger then
        schedule_request(args.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("CursorMovedI", {
    group = state.group,
    callback = function(args)
      if eligible(args.buf) then
        clear_pending(args.buf)
        if state.opts.auto_trigger then
          schedule_request(args.buf)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = state.group,
    callback = function(args)
      clear_buffer(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = state.group,
    callback = function(args)
      clear_buffer(args.buf)
      state.last_text[args.buf] = nil
      state.history[args.buf] = nil
      state.ignore_tick[args.buf] = nil
    end,
  })

  vim.api.nvim_create_user_command("ZedditEnable", function()
    M.enable()
  end, { force = true })
  vim.api.nvim_create_user_command("ZedditDisable", function()
    M.disable()
  end, { force = true })
  vim.api.nvim_create_user_command("ZedditToggle", function()
    M.toggle()
  end, { force = true })
  vim.api.nvim_create_user_command("ZedditHoverToggle", function()
    M.toggle_hover_translate()
  end, { force = true })
  -- Initial menu labels once which-key has finished loading.
  vim.defer_fn(sync_menu_labels, 800)
  -- Warm the shared model probe so the first completion/hover already knows
  -- which model the server runs.
  probe_hover_model(function() end)
  vim.api.nvim_create_user_command("ZedditToggleBuffer", function()
    M.toggle_buffer()
  end, { force = true })
  vim.api.nvim_create_user_command("ZedditAccept", M.accept, { force = true })
  vim.api.nvim_create_user_command("ZedditClear", M.clear, { force = true })
  vim.api.nvim_create_user_command("ZedditRequest", function()
    M.request(true)
  end, { force = true })
  vim.api.nvim_create_user_command("ZedditStatus", M.status, { force = true })
  vim.api.nvim_create_user_command("ZedditHoverStatus", function()
    local src = debug.getinfo(vim.lsp.util.open_floating_preview, "S").short_src
    local noice_src = "n/a"
    local ok, nh = pcall(require, "noice.lsp.hover")
    if ok and type(nh.on_hover) == "function" then
      noice_src = debug.getinfo(nh.on_hover, "S").short_src
    end
    vim.notify(
      ("hover_translate=%s | ofp wrapped=%s | noice wrapped=%s | model=%s | debug=%s | url=%s"):format(
        tostring(state.opts.hover_translate),
        tostring(src:find("zeddit", 1, true) ~= nil),
        tostring(noice_src:find("zeddit", 1, true) ~= nil),
        tostring(hover_model.kind or "unknown"),
        tostring(state.opts.hover_debug),
        tostring(state.opts.provider_url)
      )
    )
  end, { force = true })
  vim.api.nvim_create_user_command("ZedditConfig", M.configure, { force = true })
  vim.api.nvim_create_user_command("ZedditReset", M.reset_settings, { force = true })

  vim.schedule(function()
    local ok, snacks = pcall(require, "snacks")
    if not ok or not snacks.toggle then
      return
    end
    snacks.toggle({
      name = "Zeddit",
      get = function()
        return M.get("enabled") == true
      end,
      set = function(enabled)
        if enabled then
          M.enable()
        else
          M.disable()
        end
      end,
    }):map("<leader>zz")
    snacks.toggle({
      name = "Zeddit Buffer",
      get = function()
        return M.buffer_enabled()
      end,
      set = function(enabled)
        if enabled ~= M.buffer_enabled() then
          M.toggle_buffer({ notify = false })
        end
      end,
    }):map("<leader>zb")
  end)
end

return M
