local M = {}

local SHIM_MARKER = "# swapson.nvim node shim"

---@param opts { npm: { tool: string } }
function M.ensure(opts)
    local log = require "mason-core.log"

    if vim.fn.executable "node" == 0 then
        local ok_settings, mason_settings = pcall(require, "mason.settings")
        if ok_settings then
            local mason_bin = mason_settings.current.install_root_dir .. "/bin"
            local node_shim = mason_bin .. "/node"
            if vim.fn.executable(node_shim) == 0 then
                local tool = (opts.npm or {}).tool or "bun"
                local bun_path = vim.fn.exepath(tool)
                if bun_path and bun_path ~= "" then
                    vim.fn.mkdir(mason_bin, "p")
                    local ok, err = io.open(node_shim, "w")
                    if ok then
                        ok:write(("#!/bin/sh\n%s\nexec %q \"$@\"\n"):format(SHIM_MARKER, bun_path))
                        ok:close()
                        vim.fn.setfperm(node_shim, "rwxr-xr-x")
                        if vim.fn.executable(node_shim) == 1 then
                            log.fmt_debug("swapson: created node shim at %s -> %s", node_shim, bun_path)
                        else
                            log.warn(
                                ("swapson: wrote node shim to %s but it is not executable after chmod. "
                                    .. "LSPs relying on #!/usr/bin/env node will fail with exit 127."):format(
                                    node_shim
                                )
                            )
                        end
                    else
                        log.warn(
                            ("swapson: failed to create node shim at %s: %s. "
                                .. "LSPs relying on #!/usr/bin/env node will fail with exit 127."):format(
                                node_shim,
                                err
                            )
                        )
                    end
                end
            end
        end
    end
end

--- Remove the node shim if it was created by swapson (contains the marker).
--- Best-effort and non-fatal: failures are logged, not raised.
function M.remove()
    local log = require "mason-core.log"
    local ok_settings, mason_settings = pcall(require, "mason.settings")
    if not ok_settings then
        return
    end
    local node_shim = mason_settings.current.install_root_dir .. "/bin/node"
    if vim.fn.filereadable(node_shim) == 0 then
        return
    end
    local ok_open, f = pcall(io.open, node_shim, "r")
    if not ok_open or not f then
        return
    end
    local content = f:read "*a"
    f:close()
    if not content:find(SHIM_MARKER, 1, true) then
        return
    end
    local ok_del, err = pcall(os.remove, node_shim)
    if ok_del then
        log.fmt_debug("swapson: removed node shim at %s", node_shim)
    else
        log.warn(("swapson: failed to remove node shim at %s: %s"):format(node_shim, err))
    end
end

return M
