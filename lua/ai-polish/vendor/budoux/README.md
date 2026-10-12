# Vendored budoux.lua

The parser and the Japanese model of [delphinus/budoux.lua](https://github.com/delphinus/budoux.lua),
a Lua port of [Google BudouX](https://github.com/google/budoux), unmodified.

- Source commit: `7f23658` (2026-04-02)
- Files: `lua/budoux/init.lua` → `init.lua`, `lua/budoux/models/ja.lua` → `models/ja.lua`
- License: Apache License 2.0 (`LICENSE`, `NOTICE`)

ai-polish loads the model with `Parser.new(require("ai-polish.vendor.budoux.models.ja"))`,
since the upstream loaders require `budoux.models.*`. See `lua/ai-polish/units.lua`.

To update, copy the same files from a newer commit and change the commit above.
