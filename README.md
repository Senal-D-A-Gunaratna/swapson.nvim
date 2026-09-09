# swapson.nvim

A companion plugin for [mason.nvim](https://github.com/mason-org/mason.nvim) that
routes package installs through faster alternative package managers instead of
the defaults (npm, pip)

## Supported swaps

| mason manager | Default tool | Swapped tool |
| ------------- | ------------ | ------------ |
| npm           | npm          | **bun**      |
| pip (pypi)    | pip          | **uv**       |

## Why?

Each manager (npm, pip) is designed to fully override its legacy tool — not
partially speed it up — controlled by a single `enabled` toggle in your plugin
opts/config. When `npm.enabled = true`, mason's npm calls go through bun
entirely, not npm. Same for pip/uv. The only time the legacy tool runs instead
is the automatic fallback: if the configured tool isn't found on `$PATH`,
swapson notifies you and lets mason fall back to its default — that's a safety
net, not the intended mode of operation.

`bun add` is significantly faster than `npm install` for installing npm packages.
Since mason.nvim installs hundreds of LSP servers, linters, and formatters from
npm, using bun cuts install time dramatically on a fresh setup

`uv pip install` is significantly faster than `pip install` for Python packages,
and `uv venv` creates virtual environments much faster than `python -m venv`

Note that this speeds up _installing_ packages — it does not make already-installed
npm packages run faster. Once a package is installed, it still executes via
whatever runtime it normally uses (typically `node`)

mason.nvim's maintainers have (reasonably) declined to add native alternative
toolchain support upstream, as it would introduce dependencies on external
toolchains with overlapping but not identical semantics

## How it works

swapson.nvim **monkeypatches** mason.nvim's internal manager modules at runtime,
replacing the `init`, `install`, and `uninstall` functions with tool-specific
alternatives

This is the same technique used by
[mason-lspconfig.nvim](https://github.com/williamboman/mason-lspconfig.nvim)
and
[mason-tool-installer.nvim](https://github.com/WhoIsSethDaniel/mason-tool-installer.nvim)
to extend mason.nvim without forking it

The patches are applied to the module tables cached in `package.loaded`, which
every mason.nvim internal that requires the same module path shares. No files are
modified

> **Note — the node shim**: If `node` is not found on `$PATH` (but `bun` is),
> swapson.nvim creates a shell wrapper at `<mason_install_root>/bin/node` that
> delegates to `bun`, so npm-published packages with `#!/usr/bin/env node`
> shebangs still resolve instead of failing with exit 127. This is a
> compatibility fallback, not a speed feature — but it's the difference between
> "LSPs and formatters just work" and "nothing installed via npm runs at all"
> on a machine with no Node.js installed. The shim only appears when `node` is
> genuinely missing; if `node` is on `$PATH`, installed packages keep running
> through it as normal.

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
      "mason-org/mason.nvim", -- lazy.nvim spec field: ensures mason loads first
  },
  opts = {
      npm = {
          enabled = true,           -- turn the npm -> bun patch on/off
          tool = "bun",             -- binary name/path swapson calls instead of npm
          patch_version_lookup = true, -- see note below (default is false)
      },
      pip = {
          enabled = true,           -- turn the pip -> uv patch on/off
          tool = "uv",              -- binary name/path swapson calls instead of pip
      },
  },
},
```

- `dependencies` isn't a swapson option — it's a lazy.nvim spec field that
  guarantees mason.nvim loads before swapson.nvim, which is required since
  swapson patches mason's already-loaded internal modules
- `patch_version_lookup` defaults to `false`. When `true`, it additionally
  replaces mason's version-lookup calls (`get_latest_version`/`get_all_versions`,
  which normally shell out to `npm view --json`) with direct HTTPS requests to
  `registry.npmjs.org`. This matters specifically if you have **no npm
  installed at all** — without it, version lookups would still shell out to
  npm even with the install/uninstall patch active

The `opts` form is safe to use regardless of load order. swapson.nvim's
setup() includes a load-order safety guard: it checks
`require("mason").has_setup` before applying any patches. If mason.nvim has not
completed its own setup yet, swapson defers patching via `vim.schedule()` and
retries once. This ensures patches are only applied against a fully initialized
mason.nvim state.

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
        -- since version lookups would otherwise still shell out to npm.
        -- Default: true
        patch_version_lookup = true,
    },
    pip = {
        enabled = true,       -- set false to skip pip->uv patching
        tool = "uv",           -- the uv binary name/path
    },
})
```

Each manager falls back gracefully to mason's default behavior if its
configured tool is not found on `$PATH`, with a `vim.notify()` warning

## Health check

Run `:checkhealth swapson` to diagnose your swapson.nvim setup:

- Checks that mason.nvim is installed and loadable
- Verifies `bun` and `uv` binaries are on `$PATH`
- Reports whether each manager is currently patched
- Reports whether a real `node` is available or a bun-based node shim will be created
- Inspects the node shim file for correct permissions
- Shows whether `patch_version_lookup` is active (registry API vs. shelling out to npm)

The health check is **read-only**: it never creates, modifies, or removes files

## Reverting

Call `require("swapson").restore()` to restore all mason.nvim manager functions
to their originals. Useful for A/B testing or if a swapped install misbehaves

## Caveats

swapson.nvim patches **private** Lua modules internal to mason.nvim
(e.g. `mason-core.installer.managers.npm`,
`mason-core.installer.managers.pypi`, and optionally
`mason.providers.client.npm`). These modules are not part of mason.nvim's
public API. Future mason.nvim releases may refactor or rename them without a
semver-major bump, which could break the patch — swapson will `vim.notify()`
an error if the module can't be loaded, rather than failing silently, but the
patch itself won't apply until swapson is updated to match

bun's and uv's behavior isn't a drop-in match for npm/pip in every case:

- **npm side**: packages with `node-gyp` native addons, npm-specific
  `postinstall` hooks, or deep scoped dependency trees are the most likely to
  behave differently under bun than under npm
- **pip side**: swapson's uv-based `init` skips the pip-upgrade step entirely
  (uv bundles its own pip equivalent), which is a behavior difference from
  stock mason.nvim even though it's intentional

This is expected to affect a small minority of packages, and the `enabled`
flags or `require("swapson").restore()` are there for exactly this case — if a
specific package misbehaves, you can revert to npm/pip for that install

If swapson.nvim stops working after a mason.nvim update, check
[mason.nvim's changelog](https://github.com/mason-org/mason.nvim/releases) for
internal module changes and file an issue

## License

MIT
