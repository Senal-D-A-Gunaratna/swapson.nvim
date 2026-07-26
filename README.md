# swapson.nvim

## Status

**⚠️ This plugin is currently in beta**

Tested end-to-end (install + LSP attach + cold-start survival) with
[cspell-lsp](https://github.com/streetsidesoftware/cspell) (LSP server) and
[prettier](https://github.com/prettier/prettier) (formatter with native platform
binary resolution), on Arch Linux. Has zero automated test coverage

When `node` is not found on `$PATH`, swapson.nvim creates a shell wrapper at
`<mason_install_root>/bin/node` that delegates to `bun`, so npm-published
packages with `#!/usr/bin/env node` shebangs still resolve

A companion plugin for [mason.nvim](https://github.com/mason-org/mason.nvim) that
routes package installs through faster alternative package managers instead of
the defaults (npm, pip).

## Supported swaps

| mason manager | Default tool | Swapped tool |
| ------------- | ------------ | ------------ |
| npm           | npm          | **bun**      |
| pip (pypi)    | pip          | **uv**       |

## Why?

`bun add` is significantly faster than `npm install` for installing npm packages.
Since mason.nvim installs hundreds of LSP servers, linters, and formatters from
npm, using bun cuts install time dramatically on a fresh setup.

`uv pip install` is significantly faster than `pip install` for Python packages,
and `uv venv` creates virtual environments much faster than `python -m venv`.

mason.nvim's maintainers have (reasonably) declined to add native alternative
toolchain support upstream, as it would introduce dependencies on external
toolchains with overlapping but not identical semantics.

## How it works

swapson.nvim **monkeypatches** mason.nvim's internal manager modules at runtime,
replacing the `init`, `install`, and `uninstall` functions with tool-specific
alternatives.

This is the same technique used by
[mason-lspconfig.nvim](https://github.com/williamboman/mason-lspconfig.nvim)
and
[mason-tool-installer.nvim](https://github.com/WhoIsSethDaniel/mason-tool-installer.nvim)
to extend mason.nvim without forking it.

The patches are applied to the module tables cached in `package.loaded`, which
every mason.nvim internal that requires the same module path shares. No files are
modified.

## Requirements

- Neovim >= 0.7.0
- [mason.nvim](https://github.com/mason-org/mason.nvim)
- `bun` installed and on `$PATH` (for npm swaps)
- `uv` installed and on `$PATH` (for pip swaps)
- **Platform**: Linux (tested); macOS should work but is unverified; Windows is
  not currently supported (node shim is POSIX shell only)

## Installation (lazy.nvim)

The recommended shorthand is `opts = {...}`, since it's simpler when no extra
logic beyond setup() is needed:

```lua
{
  "Senal-D-A-Gunaratna/swapson.nvim",
  dependencies = {
      "mason-org/mason.nvim",
  },
  opts = {
      npm = {
          enabled = true,
          tool = "bun",
          patch_version_lookup = true,
      },
      pip = {
          enabled = true,
          tool = "uv",
      },
  },
},
```

The `opts` form is safe to use regardless of load order. swapson.nvim's
setup() includes a load-order safety guard: it checks
`require("mason").has_setup` before applying any patches. If mason.nvim has not
completed its own setup yet, swapson defers patching via `vim.schedule()` and
retries once. This ensures patches are only applied against a fully initialized
mason.nvim state.

The `dependencies` key ensures mason.nvim loads before swapson.nvim, which is
required since swapson.nvim patches mason.nvim's already-loaded modules.

Omitting any field falls back to the defaults inside `init.lua`.

## Configuration

`require("swapson").setup(opts)` accepts an optional table:

```lua
require("swapson").setup({
    npm = {
        enabled = true,       -- set false to skip npm->bun patching
        tool = "bun",          -- the bun binary name/path

        -- Whether to also patch mason's npm version-lookup client
        -- (npm view --json) — needed on systems with NO npm installed at all,
        -- since version lookups would otherwise still shell out to npm
        patch_version_lookup = true,
    },
    pip = {
        enabled = true,       -- set false to skip pip->uv patching
        tool = "uv",           -- the uv binary name/path
    },
})
```

Each manager falls back gracefully to mason's default behavior if its
configured tool is not found on `$PATH`, with a `vim.notify()` warning.

## Health check

Run `:checkhealth swapson` to diagnose your swapson.nvim setup:

- Checks that mason.nvim is installed and loadable
- Verifies `bun` and `uv` binaries are on `$PATH`
- Reports whether each manager is currently patched
- Reports whether a real `node` is available or a bun-based node shim will be created
- Inspects the node shim file for correct permissions
- Shows whether `patch_version_lookup` is active (registry API vs. shelling out to npm)

The health check is **read-only**: it never creates, modifies, or removes files.

## Reverting

Call `require("swapson").restore()` to restore all mason.nvim manager functions
to their originals. Useful for A/B testing or if a swapped install misbehaves.

## Caveats

swapson.nvim patches **private** Lua modules internal to mason.nvim
(e.g. `mason-core.installer.managers.npm`,
`mason-core.installer.managers.pypi`, and optionally
`mason.providers.client.npm`). These modules are not part of mason.nvim's
public API. Future mason.nvim releases may refactor or rename them without a
semver-major bump, which could break swapson.nvim silently.

If swapson.nvim stops working after a mason.nvim update, check
[mason.nvim's changelog](https://github.com/mason-org/mason.nvim/releases) for
internal module changes and file an issue.

## Verified packages

The following packages have been verified end-to-end (install via bun, LSP/tool
attach, cold-start survival) on Arch Linux:

- **[cspell-lsp](https://github.com/streetsidesoftware/cspell)** — LSP server,
  pure JavaScript, verifies that bun resolves `#!/usr/bin/env node` shebangs via
  the node shim and that mason's bin-linking step produces a working symlink
  chain
- **[prettier](https://github.com/prettier/prettier)** — Formatter with a native
  platform binary download step, verifies that bun handles platform-specific
  optional dependencies correctly

Packages with `node-gyp` native addons, npm-specific `postinstall` hooks, or
deep scoped dependency trees remain unverified.

## License

MIT
