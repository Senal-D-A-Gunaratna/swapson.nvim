local M = {}

local SHIM_MARKER = "# swapson.nvim node shim"

--- POSIX single-quote shell escaping.
--- Wraps the string in single quotes and replaces embedded single quotes
--- with the sequence close-quote / escaped-quote / reopen-quote ('\'').
--- Safe for arbitrary strings (spaces, $, backticks, newlines, etc.).
---@param s string
---@return string
local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

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
                    if bun_path:find "\n" then
                        log.warn(
                            ("swapson: refused to create node shim: bun path %s contains a newline. "
                                .. "LSPs relying on #!/usr/bin/env node will fail with exit 127."):format(bun_path)
                        )
                        return
                    end
                    vim.fn.mkdir(mason_bin, "p")
                    local tmp_path = node_shim .. ".tmp." .. vim.fn.getpid()
                    local ok, err = io.open(tmp_path, "w")
                    if ok then
                        ok:write((
                            "#!/bin/sh\n"
                            .. "%s\n"
                            -- `bun --version` prints bun's own version (e.g. "1.1.34"), not a Node-style
                            -- "vX.Y.Z" string. Tools that shell out to `node --version` (Mason's health
                            -- check among them) parse for the "v" prefix and crash on a nil match.
                            -- `process.version` inside Bun's runtime IS reported in Node-compatible form,
                            -- so special-case the version flags and evaluate it instead of forwarding to
                            -- bun's own --version flag.
                            .. "case \"$1\" in\n"
                            .. "  --version|-v)\n"
                            .. "    exec %s -e 'console.log(process.version)'\n"
                            .. "    ;;\n"
                            .. "esac\n"
                            .. "exec %s \"$@\"\n"
                        ):format(SHIM_MARKER, shell_quote(bun_path), shell_quote(bun_path)))
                        ok:close()
                        vim.fn.setfperm(tmp_path, "rwxr-xr-x")
                        local rename_ok, rename_err = os.rename(tmp_path, node_shim)
                        if rename_ok then
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
                            pcall(os.remove, tmp_path)
                            log.warn(
                                ("swapson: failed to rename temp shim %s to %s: %s. "
                                    .. "LSPs relying on #!/usr/bin/env node will fail with exit 127."):format(
                                    tmp_path, node_shim, rename_err
                                )
                            )
                        end
                    else
                        pcall(os.remove, tmp_path)
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
