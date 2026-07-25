local M = {}

---@async
---@param npm_client table
---@param _opts { tool: string }
---@return { get_latest_version: fun(...), get_all_versions: fun(...) }
function M.apply(npm_client, _opts)
    local fetch = require "mason-core.fetch"
    local _ = require "mason-core.functional"
    local log = require "mason-core.log"
    local semver = require "mason-core.semver"

    local originals = {
        get_latest_version = npm_client.get_latest_version,
        get_all_versions = npm_client.get_all_versions,
    }

    npm_client.get_latest_version = function(pkg)
        return fetch("https://registry.npmjs.org/" .. pkg .. "/latest")
            :map_catching(vim.json.decode)
            :map(_.pick { "name", "version" })
    end

    npm_client.get_all_versions = function(pkg)
        return fetch("https://registry.npmjs.org/" .. pkg)
            :map_catching(vim.json.decode)
            :map(function(data)
                local entries = {}
                for v, _ in pairs(data.versions) do
                    local ok, sem = pcall(semver.new, v)
                    if not ok then
                        log.fmt_debug("swapson: failed to parse semver for %q", v)
                    end
                    table.insert(entries, { str = v, sem = ok and sem or nil })
                end
                table.sort(entries, function(a, b)
                    if a.sem and b.sem then
                        return b.sem < a.sem
                    end
                    return a.str > b.str
                end)
                local versions = {}
                for i, entry in ipairs(entries) do
                    versions[i] = entry.str
                end
                return versions
            end)
    end

    return originals
end

---@param npm_client table
---@param originals { get_latest_version: fun(...), get_all_versions: fun(...) }
function M.revert(npm_client, originals)
    if originals.get_latest_version then
        npm_client.get_latest_version = originals.get_latest_version
    end
    if originals.get_all_versions then
        npm_client.get_all_versions = originals.get_all_versions
    end
end

return M
