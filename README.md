# comet.nvim

A generic two-panel picker and task UI for Neovim.

comet.nvim provides a floating layout with a searchable list on the left and an output/preview panel on the right. It is built around a strictly decoupled, state-safe architecture that guarantees 100% background async execution without zombie windows.

Designed for building custom menus, task runners, build system integrations, or any workflow that requires executing actions and displaying real-time output.

## Features

- **Two-panel layout** — left panel for fuzzy-searching and selecting items; right panel for viewing action output.
- **Async task management** — close the UI while a task runs; it continues writing to the buffer in the background. Reopen to resume seamlessly.
- **State persistence** — output buffers, sub-menu depth, selections, and search queries are cached and restored on reopen.
- **Nested sub-menus** — push sub-selections onto the left panel to build step-by-step interactive flows.
- **Multi-select** — toggle multiple items with `<Tab>` in sub-menus.
- **Output highlighting** — automatically highlights patterns like `Build succeeded`, `Error`, `✓`, `✗`, `Abort`.
- **Intuitive navigation** — toggle focus between input and output panels with `<C-l>` / `<C-h>`.

## Reference implementation

[dotnet-cli.nvim](https://github.com/gin31259461/dotnet-cli.nvim) uses comet.nvim as its core UI engine. Its source is a good reference for structuring complex nested commands and using the context API.

---

## Installation

**lazy.nvim:**

```lua
{ "Orbit-Lua/comet.nvim" }
```

**packer.nvim:**

```lua
use { "Orbit-Lua/comet.nvim" }
```

---

## Quick Start

```lua
local comet = require("comet")

local my_commands = {
  {
    name = "Run Tests",
    icon = "",
    desc = "Run all unit tests",
    action = function(ctx)
      ctx:clear()
      ctx:write("$ jest --watchAll=false")

      ctx:start_async_task(12345, function(job_id, task_ctx)
        task_ctx:append("\n[Process Terminated by User]")
      end)

      vim.defer_fn(function()
        ctx:append("✓ Test suite passed!")
        ctx:done()
      end, 1500)
    end,
  },
  {
    name = "Build Project",
    icon = "",
    icon_hl = "WarningMsg",
    desc = "Compile the source code",
    action = function(ctx)
      ctx:clear()
      ctx:append("Build FAILED")
      ctx:error()
    end,
  },
}

vim.keymap.set("n", "<leader>c", function()
  comet.open(my_commands, {
    session_id = "My Tasks",
    insert_mode = true,
    remember_page = true,
  })
end, { desc = "Open Comet UI" })
```

---

## API

### `require("comet").setup(opts)`

Set global default options. Optional — call only if you want to change defaults across all `open()` calls.

### `require("comet").open(commands, opts)`

Opens the UI with a given set of commands.

- `commands` — array of Command Spec objects (see below).
- `opts` — options table (merged with global defaults).

**Options:**

| Key | Type | Default | Description |
|---|---|---|---|
| `session_id` | string | `"Comet"` | Unique identifier for this plugin session. |
| `root_title` | string | `session_id` | Title for the root left panel. |
| `insert_mode` | boolean | `true` | Enter insert mode in the search prompt on open. |
| `block_while_running` | boolean | `true` | Prevent executing new commands while a job is running. |
| `remember_page` | boolean | `true` | Restore sub-page, selection, and query on reopen. |

### Command Spec

```lua
{
  name    = "string",             -- display name
  icon    = "string",             -- icon shown beside the name
  icon_hl = "string",             -- (optional) highlight group for icon; defaults to "String"
  desc    = "string",             -- (optional) extra text used for fuzzy filtering
  action  = function(ctx) end,    -- callback executed when the item is selected
}
```

### The `ctx` object

Each `action` receives a `ctx` bound to the current output buffer and page key. It is safe to use inside `vim.schedule`, job callbacks, and after the UI is closed.

| Method | Description |
|---|---|
| `ctx:write(lines)` | Append a string or array of strings to the output panel. |
| `ctx:append(line)` | Append a single line to the output panel. |
| `ctx:clear()` | Clear the output panel. |
| `ctx:start_async_task(job_id, abort_fn)` | Register a running task. `abort_fn(job_id, ctx)` is called on `<C-c>`. |
| `ctx:done()` | Mark the task as finished — shows `[Done]` in the output title. |
| `ctx:error()` | Mark the task as failed — shows `[Error]` in the output title. |
| `ctx:select(items, opts)` | Replace the left panel with a new list (nested sub-menu). |

### Sub-menus (`ctx:select`)

```lua
ctx:select(items, {
  title        = "string",    -- title for the sub-menu panel
  multi_select = true,        -- enable <Tab> multi-select
  on_select    = function(item_or_items, ctx) end,
  on_cancel    = function() end,  -- optional, called on <Esc>
})
```

`items` may be an array of strings or Command Spec tables.

---

## Keymaps

### Input / List panels

| Key | Mode | Action |
|---|---|---|
| `<C-j>` / `<C-k>` | Normal / Insert | Move selection down / up |
| `<Down>` / `<Up>` | Normal / Insert | Move selection down / up |
| `j` / `k` | Normal | Move selection down / up |
| `<CR>` | Normal / Insert | Execute selected item |
| `<Tab>` | Normal / Insert | Toggle multi-select mark (if enabled) |
| `<C-l>` | Normal / Insert | Focus the right output panel |
| `<C-c>` | Normal / Insert | Stop / abort the running task |
| `<Esc>` / `q` | Normal / Insert | Go back (pop sub-menu) or close UI |

### Output panel

| Key | Mode | Action |
|---|---|---|
| `<C-h>` | Normal | Return focus to the left panel |
| `<C-c>` | Normal | Stop / abort the running task |
| `<Esc>` / `q` | Normal | Return focus to the left panel (does not close UI) |
