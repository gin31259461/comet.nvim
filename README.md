# ☄️ comet.nvim

A sleek, generic two-panel picker and task UI for Neovim.

**comet.nvim** provides an elegant interface featuring a searchable list on the
left and an output/preview panel on the right. It is designed for building
custom menus, task runners, build system integrations, or any workflow that
requires executing actions and displaying real-time output.

## ✨ Features

- **🌗 Two-Panel Layout**: Left panel for fuzzy-searching and selecting items;
  right panel for viewing action output.
- **📂 Nested Sub-menus**: Push sub-selections onto the left panel to create
  step-by-step interactive flows.
- **✅ Multi-select Support**: Built-in multi-select capabilities for sub-menus
  via `<Tab>`.
- **✨ Output Highlighting**: Automatically highlights specific output patterns
  (e.g., `Build succeeded`, `Error`, `✓`, `✗`) for visual feedback.
- **⌨️ Intuitive Navigation**: Navigate lists and toggle focus between the input
  and output panels.

## 💡 Use Case

For a practical implementation of **comet.nvim**, refer to
[**dotnet-cli.nvim**](https://github.com/gin31259461/dotnet-cli.nvim).

`dotnet-cli.nvim` is a .NET development plugin that utilizes `comet.nvim` as its
core UI engine to manage .NET CLI commands and display their output.

The `dotnet-cli.nvim` source code serves as a reference for structuring complex,
nested commands and utilizing the `ctx` API.

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

Basic example of configuring and opening the Comet UI:

```lua
local comet = require("comet")

local my_commands = {
  {
    name = "Run Tests",
    icon = "🧪",
    desc = "Run all unit tests",
    action = function(ctx)
      ctx.clear()
      ctx.write("$ jest --watchAll=false")
      vim.defer_fn(function()
        ctx.append("✓ Test suite passed!")
      end, 500)
    end,
  },
  {
    name = "Build Project",
    icon = "🔨",
    icon_hl = "WarningMsg",
    desc = "Compile the source code",
    action = function(ctx)
      ctx.clear()
      ctx.append("Build FAILED")
    end,
  }
}

vim.keymap.set("n", "<leader>c", function()
  comet.open(my_commands, { title = "My Tasks", insert_mode = true })
end, { desc = "Open Comet UI" })
```

---

## API & Configuration

### `require("comet").open(commands, opts)`

Opens the UI with a given set of commands.

- `commands`: An array of **Command Spec** objects.
- `opts`: Options table.
  - `title` _(string)_: Title for the left panel.
  - `insert_mode` _(boolean)_: If `true`, automatically enters insert mode in
    the search prompt.

### Command Spec

Each item in the `commands` list must follow this structure:

```lua
{
  name = "String",        -- Display name of the item
  icon = "String",        -- Icon to display next to the name
  icon_hl = "String",     -- (Optional) Highlight group for the icon. Defaults to "String".
  desc = "String",        -- (Optional) Hidden description used for fuzzy filtering.
  action = function(ctx)  -- Callback executed when the item is selected.
  end
}
```

### The `ctx` Object

When an `action` is triggered, it receives a `ctx` (context) object:

| Method                    | Description                                                     |
| :------------------------ | :-------------------------------------------------------------- |
| `ctx.write(lines)`        | Appends a string or array of strings to the output panel.       |
| `ctx.append(line)`        | Appends a single line to the output panel.                      |
| `ctx.clear()`             | Clears the output panel.                                        |
| `ctx.select(items, opts)` | Replaces the left panel with a new list of items (Nested Menu). |

#### Sub-selections (`ctx.select`)

Creates nested menus.

- `items`: Array of strings or Command Spec tables.
- `opts`:
  - `title` _(string)_: Title for the sub-menu.
  - `multi_select` _(boolean)_: Enable selecting multiple items with `<Tab>`.
  - `on_select` _(function)_: Callback when an item (or items) is chosen.
    Receives `(item_or_items, ctx)`.
  - `on_cancel` _(function)_: (Optional) Callback if the user presses `<Esc>`.

**Example:**

```lua
action = function(ctx)
  local files = { "main.lua", "utils.lua", "config.lua" }

  ctx.select(files, {
    title = "Select Files to Lint",
    multi_select = true,
    on_select = function(selected_files, sub_ctx)
      sub_ctx.clear()
      sub_ctx.write("Linting selected files...")
      for _, file in ipairs(selected_files) do
         sub_ctx.append("✓ " .. file .. " looks good!")
      end
    end
  })
end
```

---

## ⌨️ Keymaps

### Input / List Panels

| Key               |      Mode       | Action                                |
| :---------------- | :-------------: | :------------------------------------ |
| `<C-j>` / `<C-k>` | Normal / Insert | Move selection down/up                |
| `<Down>` / `<Up>` | Normal / Insert | Move selection down/up                |
| `j` / `k`         |     Normal      | Move selection down/up                |
| `<CR>`            | Normal / Insert | Execute selected item                 |
| `<Tab>`           | Normal / Insert | Toggle multi-select mark (if enabled) |
| `<C-l>`           | Normal / Insert | Focus the right output panel          |
| `<Esc>` / `q`     | Normal / Insert | Go back (pop sub-menu) or Close UI    |

### Output Panel

| Key           |  Mode  | Action                                             |
| :------------ | :----: | :------------------------------------------------- |
| `<C-h>`       | Normal | Return focus to the left panel                     |
| `<Esc>` / `q` | Normal | Return focus to the left panel (does not close UI) |
