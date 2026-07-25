local M = {}

--- Map from manager name to { module = table, originals = table }
local patches = {}
local patched = false
local opts = nil

function M.is_patched()
    return patched
end

---@param manager string
---@param entry { module: table, originals: table }
function M.set_originals(manager, entry)
    patches[manager] = entry
end

---@param manager string
---@return { module: table, originals: table }|nil
function M.get_originals(manager)
    return patches[manager]
end

---@param manager string
---@return boolean
function M.has_originals(manager)
    return patches[manager] ~= nil
end

function M.get_all_patches()
    return patches
end

function M.clear_patches()
    patches = {}
    patched = false
end

---@param new_opts table
function M.set_opts(new_opts)
    opts = new_opts
end

---@return table|nil
function M.get_opts()
    return opts
end

function M.mark_patched()
    patched = true
end

--- Restore all mason.nvim manager patches to their original state.
function M.restore()
    for name, entry in pairs(patches) do
        local strategy_ok, strategy = pcall(require, ("swapson.managers.%s"):format(name))
        if strategy_ok and strategy.revert then
            strategy.revert(entry.module, entry.originals)
        end
    end

    require("swapson.node_shim").remove()

    M.clear_patches()
end

return M
