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

Each manager (npm, pip) is designed to fully override its legacy tool —
controlled by a single `enabled` toggle in your plugin opts/config. When
`npm.enabled = true`, mason's npm install/uninstall calls go through bun
entirely, and npm-installed packages also run on bun via the node shim (see
below) rather than a system node runtime. Same idea for pip/uv, though pip's
swap is install-time only — Python packages still run on the venv's own
interpreter, since there's no equivalent "python shim" concept here. The only
time the legacy tool runs instead is the automatic fallback: if the
configured tool isn't found on `$PATH`, swapson notifies you and lets mason
fall back to its default — that's a safety net, not the intended mode of
operation.

`bun add` is significantly faster than `npm install` for installing npm packages.
Since mason.nvim installs hundreds of LSP servers, linters, and formatters from
npm, using bun cuts install time dramatically on a fresh setup

`uv pip install` is significantly faster than `pip install` for Python packages,
and `uv venv` creates virtual environments much faster than `python -m venv`

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

> **Note — the node shim**: When npm patching is enabled, swapson.nvim creates
> a shell wrapper at `<mason_install_root>/bin/node` that delegates to `bun`,
> so npm-published packages with `#!/usr/bin/env node` shebangs run on bun
> instead of a real node runtime. This installs regardless of whether a
> system `node` is also present — the swap now covers execution as well as
> install, not just install. It's gated on `npm.enabled` (the same toggle
> that controls the install/uninstall patch), not on a separate opt: set
> `npm.enabled = false` if you want npm-sourced packages to install _and_
> run on stock npm/node. Setting `npm.enabled = false` and calling `setup()`
> again (e.g. after a config change + restart) automatically removes a
> previously-created shim, not just `restore()`

## Requirements

- Neovim >= 0.7.0
- [mason.nvim](https://github.com/mason-org/mason.nvim)
- `bun` installed and on `$PATH` (for npm swaps)
- `uv` installed and on `$PATH` (for pip swaps)
- **Platform**: Linux (tested); macOS should work but is unverified; Windows is
  not supported (node shim is POSIX shell only)

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
          enabled = true,  -- turn the npm -> bun patch on/off
          tool = "bun",    -- binary name/path swapson calls instead of npm
      },
      pip = {
          enabled = true,  -- turn the pip -> uv patch on/off
          tool = "uv",     -- binary name/path swapson calls instead of pip
      },
  },
},
```

- `dependencies` isn't a swapson option — it's a lazy.nvim spec field that
  guarantees mason.nvim loads before swapson.nvim, which is required since
  swapson patches mason's already-loaded internal modules
- `npm.enabled` now controls the whole npm swap as one unit: install/uninstall,
  version lookups (`get_latest_version`/`get_all_versions`, which normally
  shell out to `npm view --json`, are replaced with direct HTTPS requests to
  `registry.npmjs.org`), and the node shim. There's no separate toggle for any
  of these — this matters specifically if you have **no npm installed at
  all**, since without the version-lookup swap, lookups would still shell out
  to npm even with everything else patched

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
        enabled = true,       -- set false to skip npm->bun patching entirely
        tool = "bun",          -- the bun binary name/path
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
- Reports whether a system `node` is present (informational only — it
  no longer affects shim creation) and whether the bun-based node shim
  is active
- Verifies the on-disk node shim content still matches what would be
  generated today (byte-for-byte drift check against the current
  `bun` path/tool config), distinguishing a shim that's missing,
  foreign (no swapson marker), stale (drifted), or current
- Shows whether version lookups are patched (registry API vs. shelling out to npm)

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
