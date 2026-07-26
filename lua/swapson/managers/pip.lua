local M = {}

M.name = "pip"
M.manager_module = "mason-core.installer.managers.pypi"
M.settings_key = "pip"

function M.check_tool(tool)
    return vim.fn.executable(tool) == 1
end

---@async
---@param pypi_manager table
---@param opts { tool: string }
---@return { init: fun(...), install: fun(...), uninstall: fun(...) }
function M.apply(pypi_manager, opts)
    local Result = require "mason-core.result"
    local installer = require "mason-core.installer"
    local log = require "mason-core.log"
    local SystemPackage = require "mason-core.system-package"

    local originals = {
        init = pypi_manager.init,
        install = pypi_manager.install,
        uninstall = pypi_manager.uninstall,
    }

    -- Patch init()
    -- Original: resolve python3, then `python3 -m venv --system-site-packages venv`,
    -- optionally upgrade pip inside venv.
    -- uv variant: `uv venv --system-site-packages venv` (skip pip upgrade — uv
    -- bundles its own pip equivalent and ensurepip is not needed).
    pypi_manager.init = function(opts_init)
        log.fmt_debug("swapson: pypi init (uv) %s", opts_init)
        local ctx = installer.context()
        ctx.stdio_sink:stdout "Creating virtual environment via uv…\n"
        -- uv uses the same venv directory structure as python -m venv, so mason's
        -- find_venv_executable continues to work after uv creates the venv.
        return ctx.spawn[opts.tool] { "venv", "--system-site-packages", "venv" }
    end

    -- Patch install()
    -- Original: `venv/bin/python -m pip --disable-pip-version-check install
    -- --no-user --ignore-installed -U [extra_args] <pkg>==<version> [extra_pkgs]`
    -- uv variant: `uv pip install --python venv -U [install_extra_args] <pkg>==<version> [extra_pkgs]`
    -- Uses --python <venv> for correct venv targeting instead of resolving
    -- the venv python interpreter path. Note: --directory has no effect in uv pip's interface.
    pypi_manager.install = function(pkg, version, install_opts)
        install_opts = install_opts or {}
        log.fmt_debug("swapson: pypi install %s %s %s", pkg, version, install_opts)
        local ctx = installer.context()
        ctx:require(SystemPackage.sfw)
        ctx.stdio_sink:stdout(("Installing pip package %s@%s via %s…\n"):format(pkg, version, opts.tool))
        return ctx.spawn[opts.tool] {
            "pip",
            "install",
            "--python",
            "venv",
            "-U",
            install_opts.install_extra_args or vim.NIL,
            install_opts.extra and ("%s[%s]==%s"):format(pkg, install_opts.extra, version)
                or ("%s==%s"):format(pkg, version),
            install_opts.extra_packages or vim.NIL,
        }
    end

    -- Patch uninstall()
    -- Original: `venv/bin/python -m pip uninstall -y <pkg>`
    -- uv variant: `uv pip uninstall --python venv <pkg>`
    -- Note: --directory has no effect in uv pip's interface; --python correctly
    -- targets the venv directory.
    pypi_manager.uninstall = function(pkg)
        log.fmt_debug("swapson: pypi uninstall %s", pkg)
        local ctx = installer.context()
        ctx.stdio_sink:stdout(("Uninstalling pip package %s via %s…\n"):format(pkg, opts.tool))
        return ctx.spawn[opts.tool] { "pip", "uninstall", "--python", "venv", pkg }
    end

    return originals
end

---@param pypi_manager table
---@param originals { init: fun(...), install: fun(...), uninstall: fun(...) }
function M.revert(pypi_manager, originals)
    if originals.init then
        pypi_manager.init = originals.init
    end
    if originals.install then
        pypi_manager.install = originals.install
    end
    if originals.uninstall then
        pypi_manager.uninstall = originals.uninstall
    end
end

return M
