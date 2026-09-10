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

--- Builds the exact shim script content for a given bun path. Single source
--- of truth used both to write the shim (M.ensure) and to verify an
--- on-disk shim still matches what we'd generate today (M.is_up_to_date).
---@param bun_path string
---@return string
local function generate_content(bun_path)
	return (
		"#!/bin/sh\n"
		.. "%s\n"
		-- `bun --version` prints bun's own version (e.g. "1.1.34"), not a Node-style
		-- "vX.Y.Z" string. Tools that shell out to `node --version` (Mason's health
		-- check among them) parse for the "v" prefix and crash on a nil match.
		-- `process.version` inside Bun's runtime IS reported in Node-compatible form,
		-- so special-case the version flags and evaluate it instead of forwarding to
		-- bun's own --version flag.
		.. 'case "$1" in\n'
		.. "  --version|-v)\n"
		.. "    exec %s -e 'console.log(process.version)'\n"
		.. "    ;;\n"
		.. "esac\n"
		.. 'exec %s "$@"\n'
	):format(SHIM_MARKER, shell_quote(bun_path), shell_quote(bun_path))
end

--- Resolves the `tool` (bun) executable path from opts, the same way
--- M.ensure and M.is_up_to_date do.
---@param opts { npm: { tool: string } }
---@return string|nil
local function resolve_tool_path(opts)
	local tool = (opts.npm or {}).tool or "bun"
	local bun_path = vim.fn.exepath(tool)
	if not bun_path or bun_path == "" then
		return nil
	end
	return bun_path
end

--- Installs a bun-backed node shim so npm-published packages that shell out
--- via `#!/usr/bin/env node` resolve to bun instead of a real node runtime.
--- This runs whenever the npm manager is enabled (see init.lua) — swapping
--- bun in for install *and* execution, not just install — regardless of
--- whether a system node is also present.
---@param opts { npm: { tool: string } }
function M.ensure(opts)
	local log = require("mason-core.log")

	local ok_settings, mason_settings = pcall(require, "mason.settings")
	if not ok_settings then
		return
	end

	local mason_bin = mason_settings.current.install_root_dir .. "/bin"
	local node_shim = mason_bin .. "/node"
	if vim.fn.executable(node_shim) == 1 then
		local status = M.is_up_to_date(opts)
		if status == "current" then
			return
		end
		if status == "foreign" then
			-- Not ours (no marker) — leave whatever's there alone rather
			-- than clobbering a real node binary or unrelated shim.
			return
		end
		-- "stale" (content drifted, e.g. bun reinstalled at a new path) or
		-- "unresolved" falls through and regenerates below.
		log.fmt_debug("swapson: node shim at %s is %s, regenerating", node_shim, status)
	end

	local bun_path = resolve_tool_path(opts)
	if not bun_path then
		return
	end

	if bun_path:find("\n") then
		log.warn(
			(
				"swapson: refused to create node shim: bun path %s contains a newline. "
				.. "LSPs relying on #!/usr/bin/env node will fail with exit 127."
			):format(bun_path)
		)
		return
	end

	vim.fn.mkdir(mason_bin, "p")
	local tmp_path = node_shim .. ".tmp." .. vim.fn.getpid()
	local ok, err = io.open(tmp_path, "w")
	if not ok then
		pcall(os.remove, tmp_path)
		log.warn(
			(
				"swapson: failed to create node shim at %s: %s. "
				.. "LSPs relying on #!/usr/bin/env node will fail with exit 127."
			):format(node_shim, err)
		)
		return
	end

	ok:write(generate_content(bun_path))
	ok:close()
	vim.fn.setfperm(tmp_path, "rwxr-xr-x")
	local rename_ok, rename_err = os.rename(tmp_path, node_shim)
	if not rename_ok then
		pcall(os.remove, tmp_path)
		log.warn(
			(
				"swapson: failed to rename temp shim %s to %s: %s. "
				.. "LSPs relying on #!/usr/bin/env node will fail with exit 127."
			):format(tmp_path, node_shim, rename_err)
		)
		return
	end

	if vim.fn.executable(node_shim) == 1 then
		log.fmt_debug("swapson: created node shim at %s -> %s", node_shim, bun_path)
	else
		log.warn(
			(
				"swapson: wrote node shim to %s but it is not executable after chmod. "
				.. "LSPs relying on #!/usr/bin/env node will fail with exit 127."
			):format(node_shim)
		)
	end
end

--- Checks whether the on-disk node shim is byte-for-byte the same script
--- M.ensure would generate right now for the currently configured tool.
--- Distinguishes "missing", "foreign" (no swapson marker — e.g. a real
--- node binary or another tool's shim), "stale" (ours, but content drifted —
--- e.g. bun was reinstalled at a different path), and "current".
---@param opts { npm: { tool: string } }
---@return "missing"|"foreign"|"stale"|"current"|"unresolved" status
---@return string|nil node_shim_path
function M.is_up_to_date(opts)
	local ok_settings, mason_settings = pcall(require, "mason.settings")
	if not ok_settings then
		return "unresolved", nil
	end

	local node_shim = mason_settings.current.install_root_dir .. "/bin/node"
	if vim.fn.filereadable(node_shim) == 0 then
		return "missing", node_shim
	end

	local ok_open, f = pcall(io.open, node_shim, "r")
	if not ok_open or not f then
		return "unresolved", node_shim
	end
	local content = f:read("*a")
	f:close()

	if not content:find(SHIM_MARKER, 1, true) then
		return "foreign", node_shim
	end

	local bun_path = resolve_tool_path(opts)
	if not bun_path then
		return "unresolved", node_shim
	end

	if content == generate_content(bun_path) then
		return "current", node_shim
	end
	return "stale", node_shim
end

--- Remove the node shim if it was created by swapson (contains the marker).
--- Best-effort and non-fatal: failures are logged, not raised.
function M.remove()
	local log = require("mason-core.log")
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
	local content = f:read("*a")
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
