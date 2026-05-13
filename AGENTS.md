# AGENTS.md — comet.nvim

Guide for AI agents working in this repository.

---

## Project Overview

**comet.nvim** is a generic two-panel picker and task UI library for Neovim. It provides a floating window layout (input + list left, output right) with async task management, nested sub-menus, fuzzy filtering, and state persistence across open/close cycles. It is designed to be consumed by other plugins, not used standalone.

Minimum Neovim version: **0.10**.

---

## Repository Layout

```
lua/comet/
  init.lua        -- Public API (setup, open)
  config.lua      -- Global defaults and option resolution
  state.lua       -- All type definitions and runtime state
  action.lua      -- Keybind handlers (move, run, esc, stop, toggle_mark)
  context.lua     -- CometCtx builder passed to command actions
  filter.lua      -- Fuzzy filtering for root commands and sub-menus
  health.lua      -- :checkhealth comet
  ui/
    window.lua    -- nvim_open_win layout, focus helpers, buffer switching
    events.lua    -- Autocmds and keymap registration
    render.lua    -- Buffer writes, list rendering, extmark highlighting

plugin/comet.lua  -- Plugin guard (sets vim.g.loaded_comet)
tests/
  comet/config_spec.lua
  minimal_init.lua
```

---

## Architecture

### State

All live UI state lives in a single private `S` table inside `lua/comet/state.lua`. Agents must never hold their own copy of `S` across async boundaries — always call `state.get()` fresh. The public helpers `state.current_items()`, `state.current_selected()`, and `state.current_sub()` resolve whether the root or the top of `sub_stack` is active.

**Persistent cross-open state** lives in module-level tables:
- `state.output_buf_cache` — maps `page_key → buf` so output survives close/reopen.
- `state.running_tasks` — maps `page_key → RunningTaskInfo` for job lifecycle.
- `state.persisted_states` — maps `session_id → saved UI state` for `remember_page`.

### Data Flow: Open

```
comet.open(commands, opts)
  → config.resolve(opts)          -- merge global defaults + local opts
  → state.init(...)               -- build S, restore persisted_states if remember_page
  → window.create_layout(...)     -- create 3 floating wins, mount output buf
  → events.setup()                -- register autocmds + keymaps on input/list bufs
  → render.list()                 -- draw left panel
  → render.update_output_title()  -- draw output panel title
```

### Data Flow: Action Execution

```
<CR> → action.run_selected()
  → context.make(trigger_name)   -- bind ctx to current output_buf + page_key
  → item.action(ctx)             -- user callback runs
  → ctx:write / ctx:append       -- → render.out_write(target_buf, ...)
  → ctx:start_async_task(...)    -- registers in state.running_tasks
  → ctx:done / ctx:error         -- updates task status + calls render.update_output_title
```

### Data Flow: Sub-menus

`ctx:select(items, opts)` pushes a `SubMenuState` onto `S.sub_stack`. Navigation and filtering transparently use the top of the stack. `<Esc>` pops it via `action.handle_esc`. Output buffer routing: all sub-levels of a root command share the root command's cached output buffer (`sub_stack[1].page_key`).

### Data Flow: Close

```
window.close()
  → persist S into state.persisted_states[session_id] (if remember_page)
  → clear CometUI augroup
  → close all 3 wins, delete input/list bufs (output bufs are kept in cache)
  → state.clear()                -- sets S = nil
```

---

## Key Invariants

- **`S` is nil when UI is closed.** Every module that reads `S` must guard with `state.is_open()` before scheduling async callbacks — the UI may close while a job runs.
- **Output buffers are never deleted.** Only `input_buf` and `list_buf` are deleted on close. Output buffers live in `state.output_buf_cache` indefinitely so background writes remain valid.
- **`target_buf` in `ctx` is captured at action dispatch time.** The context is safe to use in `vim.schedule` / job callbacks after the UI closes.
- **`page_key` uniqueness.** At root level, `page_key = root_title`. For the first sub-level, `page_key = trigger_name` (the root command's name). Deeper nesting reuses `sub_stack[1].page_key` so all nested levels share one output buffer.
- **`block_while_running`** — when true, `action.run_selected` bails early if the current page has a task with `status == "running"`.
- **Prompt bytes offset.** `S.prompt = "  "` (2 bytes). The input buffer is a `:h prompt-buffer`. Text before the prompt is off-limits; cursor clamping in events enforces this.

---

## Module Responsibilities (Summary)

| Module | Owns |
|---|---|
| `init.lua` | Public API surface (`setup`, `open`) |
| `config.lua` | Default values, `resolve()` merge logic |
| `state.lua` | Type annotations, `S` lifecycle, persistent caches |
| `action.lua` | All user-triggered mutations to `S` |
| `context.lua` | Constructing the `CometCtx` passed to `action` callbacks |
| `filter.lua` | Substring filter over `S.commands` and `sub.all_items` |
| `ui/window.lua` | `nvim_open_win`, focus routing, buffer switching, `close()` |
| `ui/events.lua` | Keymap and autocmd registration; output buf keymap injection |
| `ui/render.lua` | All `nvim_buf_set_lines` and extmark writes |

---

## Coding Conventions

- **Lua 5.1** (LuaJIT as embedded by Neovim). No external dependencies.
- Formatter: **StyLua** (`stylua lua/ tests/ plugin/`). Config in `.stylua.toml`.
- Linter: `luac -p` (syntax only) via `make lint`.
- No `require` cycles — `ui/window.lua` lazy-requires `ui/events.lua` with `require(...)` inside a function body to break the cycle.
- Module pattern: every file returns `local M = {}` and exposes only named functions on `M`.
- Type annotations use EmmyLua/LuaLS style (`---@class`, `---@param`, `---@return`). All public types are declared in `state.lua`.

---

## Development Workflow

```bash
make test     # run plenary busted tests (requires nvim + plenary.nvim)
make lint     # luac syntax check
make format   # apply stylua
make check    # stylua --check (CI dry-run)
```

Tests use `tests/minimal_init.lua` as the headless init file and plenary's busted runner.

---

## What to Avoid

- Do not add global vim commands or autocommands outside of the `CometUI` augroup.
- Do not store references to `S` in upvalues that outlive the open/close cycle — always re-fetch via `state.get()`.
- Do not delete output buffers; they are the persistence mechanism for background writes.
- Do not bypass `pcall` on win/buf APIs — windows and buffers can be invalidated at any point.
- Do not introduce external plugin dependencies. This is a zero-dependency library.
