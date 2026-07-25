local M = {}

M.name = "npm"
M.manager_module = "mason-core.installer.managers.npm"
M.settings_key = "npm"

function M.check_tool(tool)
    return vim.fn.executable(tool) == 1
end

---@async
---@param npm_manager table
---@param opts { tool: string }
---@return { init: fun(...), install: fun(...), uninstall: fun(...) }
function M.apply(npm_manager, opts)
    local Result = require "mason-core.result"
    local installer = require "mason-core.installer"
    local log = require "mason-core.log"
    local SystemPackage = require "mason-core.system-package"

    local originals = {
        init = npm_manager.init,
        install = npm_manager.install,
        uninstall = npm_manager.uninstall,
    }

    npm_manager.init = function()
        log.debug "swapson: npm init (no-op — bun add creates package.json automatically)"
        local ctx = installer.context()
        return Result.try(function(_try)
            ctx.stdio_sink:stdout "Skipped npm init (bun add handles package.json creation).\n"
        end)
    end

    npm_manager.install = function(pkg, version, install_opts)
        install_opts = install_opts or {}
        log.fmt_debug("swapson: npm install %s %s %s", pkg, version, install_opts)
        local ctx = installer.context()
        ctx:require(SystemPackage.sfw)
        ctx.stdio_sink:stdout(("Installing npm package %s@%s via %s…\n"):format(pkg, version, opts.tool))
        return ctx.spawn[opts.tool] {
            "add",
            ("%s@%s"):format(pkg, version),
            install_opts.extra_packages or vim.NIL,
            install_opts.install_extra_args or vim.NIL,
            firewall = true,
        }
    end

    npm_manager.uninstall = function(pkg)
        local ctx = installer.context()
        ctx.stdio_sink:stdout(("Uninstalling npm package %s via %s…\n"):format(pkg, opts.tool))
        return ctx.spawn[opts.tool] { "remove", pkg }
    end

    return originals
end

---@param npm_manager table
---@param originals { init: fun(...), install: fun(...), uninstall: fun(...) }
function M.revert(npm_manager, originals)
    if originals.init then
        npm_manager.init = originals.init
    end
    if originals.install then
        npm_manager.install = originals.install
    end
    if originals.uninstall then
        npm_manager.uninstall = originals.uninstall
    end
end

return M
