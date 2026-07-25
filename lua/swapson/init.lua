local M = {}

local defaults = {
    npm = { enabled = true, tool = "bun", patch_version_lookup = false },
    pip = { enabled = true, tool = "uv" },
}

--- Restore all mason.nvim manager modules to their original (unpatched) state.
function M.restore()
    require("swapson.state").restore()
end

---@param opts? { npm?: { enabled?: boolean, tool?: string, patch_version_lookup?: boolean }, pip?: { enabled?: boolean, tool?: string } }
function M.setup(opts)
    opts = vim.tbl_deep_extend("keep", opts or {}, defaults)

    local ok, _ = pcall(require, "mason")
    if not ok then
        vim.notify(
            "swapson.nvim: mason.nvim is not installed or cannot be loaded. "
                .. "Add `dependencies = { 'mason-org/mason.nvim' }` to your swapson.nvim lazy.nvim spec.",
            vim.log.levels.ERROR
        )
        return
    end

    local state = require "swapson.state"
    state.set_opts(opts)

    if state.is_patched() then
        return
    end

    local managers = {
        require("swapson.managers.npm"),
        require("swapson.managers.pip"),
    }

    for _, manager in ipairs(managers) do
        local config = opts[manager.settings_key]
        if config and config.enabled then
            if not manager.check_tool(config.tool) then
                vim.notify(
                    ("swapson.nvim: %s is enabled but %q is not found on $PATH. "
                        .. "Skipping %s patch — mason will use its default manager."):format(
                        manager.name, config.tool, manager.name
                    ),
                    vim.log.levels.WARN
                )
            else
                local ok_mod, mod = pcall(require, manager.manager_module)
                if ok_mod and type(mod) == "table" then
                    local originals = manager.apply(mod, config)
                    state.set_originals(manager.name, { module = mod, originals = originals })
                else
                    vim.notify(
                        ("swapson.nvim: failed to load %s. "
                            .. "This is a private mason.nvim internal module — it may have moved or been renamed. "
                            .. "Skipping %s patch."):format(manager.manager_module, manager.name),
                        vim.log.levels.ERROR
                    )
                end
            end
        end
    end

    -- npm-specific: optional version lookup patch
    local npm_config = opts.npm
    if npm_config and npm_config.enabled and npm_config.patch_version_lookup then
        local ok_client, npm_client = pcall(require, "mason.providers.client.npm")
        if ok_client and type(npm_client) == "table" then
            local version_lookup = require "swapson.version_lookup"
            local version_originals = version_lookup.apply(npm_client, { tool = npm_config.tool })
            state.set_originals("version_lookup", { module = npm_client, originals = version_originals })
        else
            vim.notify(
                "swapson.nvim: patch_version_lookup=true but mason.providers.client.npm not found. "
                    .. "This private internal module may have moved; skipping version lookup patch.",
                vim.log.levels.WARN
            )
        end
    end

    require("swapson.node_shim").ensure(opts)

    state.mark_patched()
end

return M
