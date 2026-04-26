# ☄️ comet.nvim

A sleek, robust, and generic two-panel picker and task UI for Neovim.

**comet.nvim** provides an elegant interface featuring a searchable list on the
left and an output/preview panel on the right. Under the hood, it is powered by
a strictly decoupled, state-safe architecture that guarantees **100% background
async execution** without zombie windows.

It is designed for building custom menus, task runners, build system
integrations, or any workflow that requires executing actions and displaying
real-time output.

## ✨ Features

- **🌗 Two-Panel Layout**: Left panel for fuzzy-searching and selecting items;
  right panel for viewing action output.
- **🔄 Async Task Management**: Built-in support for tracking running jobs.
  Close the UI while a task runs, and it will safely continue writing to the
  buffer in the background. Open it again to seamlessly resume where you left
  off.
- **State Persistence**: Output buffers, sub-menu depth, selections, and search
  queries are securely cached and smoothly restored when reopening the UI.
- **📂 Nested Sub-menus**: Push sub-selections onto the left panel to create
  step-by-step interactive flows.
- **✅ Multi-select Support**: Built-in multi-select capabilities for sub-menus
  via `<Tab>`.
- **✨ Output Highlighting**: Automatically highlights specific output patterns
  (e.g., `Build succeeded`, `Error`, `✓`, `✗`, `Abort`) for visual feedback.
- **⌨️ Intuitive Navigation**: Navigate lists and toggle focus between the input
  and output panels effortlessly.

## 💡 Use Case

For a practical implementation of **comet.nvim**, refer to
[**dotnet-cli.nvim**](https://github.com/gin31259461/dotnet-cli.nvim).

`dotnet-cli.nvim` is a .NET development plugin that utilizes `comet.nvim` as its
core UI engine to manage .NET CLI commands and display their output. The source
code serves as a reference for structuring complex, nested commands and
utilizing the context API.

---

## 📦 Installation

Install `comet.nvim` using your preferred package manager.

**[lazy.nvim](https://github.com/folke/lazy.nvim):**

```lua
{
  "Orbit-Lua/comet.nvim",
}
```

**[packer.nvim](https://github.com/wbthomason/packer.nvim):**

```lua
use { 'Orbit-Lua/comet.nvim' }
```

---

## 🚀 Quick Start

Basic example of configuring and opening the Comet UI. The API is entirely
downward compatible.

```lua
local comet = require("comet")

local my_commands = {
  {
    name = "Run Tests",
    icon = "🧪",
    desc = "Run all unit tests",
    action = function(ctx)
      ctx:clear()
      ctx:write("$ jest --watchAll=false")

      -- Example of async task registration
      ctx:start_async_task(12345, function(job_id, task_ctx)
        task_ctx:append("\n[Process Terminated by User]")
      end)

      vim.defer_fn(function()
        ctx:append("✓ Test suite passed!")
        ctx:done() -- Update UI status to [Done]
      end, 1500)
    end,
  },
  {
    name = "Build Project",
    icon = "🔨",
    icon_hl = "WarningMsg",
    desc = "Compile the source code",
    action = function(ctx)
      ctx:clear()
      ctx:append("Build FAILED")
      ctx:error()
    end,
  }
}

vim.keymap.set("n", "<leader>c", function()
  comet.open(my_commands, {
    session_id = "My Tasks",
    insert_mode = true,
    remember_page = true
  })
end, { desc = "Open Comet UI" })
```

---

## API & Configuration

### `require("comet").open(commands, opts)`

Opens the UI with a given set of commands.

- `commands`: An array of **Command Spec** objects.
- `opts`: Options table.
  - `session_id` _(string)_: Unique identifier for different plugin sessions
  - `root_title` _(string)_: Title for the root left panel.
  - `insert_mode` _(boolean)_: If `true`, automatically enters insert mode in
    the search prompt.
  - `block_while_running` _(boolean)_: If `true`, prevents executing new
    commands in the current page until the running job finishes. Defaults to
    `true`.
  - `remember_page` _(boolean)_: If `true`, remembers the last active sub-page,
    selection, and query for each root command when reopening. Defaults to
    `true`.

### Command Spec

Each item in the `commands` list must follow this structure:

```lua
{
  name = "String",        -- Display name of the item
  icon = "String",        -- Icon to display next to the name
  icon_hl = "String",     -- (Optional) Highlight group for the icon. Defaults to "String".
  desc = "String",        -- (Optional) Hidden description used for fuzzy filtering.
  action = function(ctx) end  -- Callback executed when the item is selected.
}
```

### The `ctx` Object

When an `action` is triggered, it receives a `ctx` (context) object. This object
is securely bound to the target buffer and page key, ensuring safe background
writes even if the UI is closed.

| Method                                   | Description                                                             |
| :--------------------------------------- | :---------------------------------------------------------------------- |
| `ctx:write(lines)`                       | Appends a string or array of strings to the output panel.               |
| `ctx:append(line)`                       | Appends a single line to the output panel.                              |
| `ctx:clear()`                            | Clears the output panel.                                                |
| `ctx:start_async_task(job_id, abort_fn)` | Registers a running task. `abort_fn(job_id, ctx)` is called on `<C-c>`. |
| `ctx:done()`                             | Marks the registered task as successfully finished (`[Done]` in UI).    |
| `ctx:error()`                            | Marks the registered task as failed (`[Error]` in UI).                  |
| `ctx:select(items, opts)`                | Replaces the left panel with a new list of items (Nested Menu).         |

#### Sub-selections (`ctx:select`)

Creates nested menus.

- `items`: Array of strings or Command Spec tables.
- `opts`:
  - `title` _(string)_: Title for the sub-menu.
  - `multi_select` _(boolean)_: Enable selecting multiple items with `<Tab>`.
  - `on_select` _(function)_: Callback when an item (or items) is chosen.
    Receives `(item_or_items, ctx)`.
  - `on_cancel` _(function)_: (Optional) Callback if the user presses `<Esc>`.

---

## ⌨️ Keymaps

### Input / List Panels

| Key               |      Mode       | Action                                  |
| :---------------- | :-------------: | :-------------------------------------- |
| `<C-j>` / `<C-k>` | Normal / Insert | Move selection down/up                  |
| `<Down>` / `<Up>` | Normal / Insert | Move selection down/up                  |
| `j` / `k`         |     Normal      | Move selection down/up                  |
| `<CR>`            | Normal / Insert | Execute selected item                   |
| `<Tab>`           | Normal / Insert | Toggle multi-select mark (if enabled)   |
| `<C-l>`           | Normal / Insert | Focus the right output panel            |
| `<C-c>`           | Normal / Insert | Stop / Abort the currently running task |
| `<Esc>` / `q`     | Normal / Insert | Go back (pop sub-menu) or Close UI      |

### Output Panel

| Key           |  Mode  | Action                                             |
| :------------ | :----: | :------------------------------------------------- |
| `<C-h>`       | Normal | Return focus to the left panel                     |
| `<C-c>`       | Normal | Stop / Abort the currently running task            |
| `<Esc>` / `q` | Normal | Return focus to the left panel (does not close UI) |
