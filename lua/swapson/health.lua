local M = {}

local function check_tool_config(state, settings_key)
	local configured_opts = state.get_opts()
	local manager_config = (configured_opts or {})[settings_key] or {}
	local tool = manager_config.tool or (settings_key == "npm" and "bun") or "uv"
	local enabled = manager_config.enabled ~= false

	local key = settings_key
	if not configured_opts then
		vim.health.info(
			("%s: setup() has not been called — using default tool='%s', enabled=%s"):format(
				key,
				tool,
				enabled
			)
		)
	end

	local tool_path = vim.fn.exepath(tool)
	if tool_path and tool_path ~= "" then
		vim.health.ok(("%s: %s found at %s"):format(key, tool, tool_path))
	else
		vim.health.error(("%s: tool '%s' not found on $PATH"):format(key, tool))
	end

	if enabled then
		if state.has_originals(key) then
			vim.health.ok(
				("%s: mason's %s manager is currently patched to use %s"):format(key, key, tool)
			)
		else
			vim.health.info(
				("%s: not currently patched — call require('swapson').setup() in your config"):format(
					key
				)
			)
		end
	else
		vim.health.info(
			("%s: disabled in config — mason will use its default manager"):format(key)
		)
	end
end

function M.check()
	vim.health.start("swapson.nvim")

	local ok_mason, _ = pcall(require, "mason")
	if ok_mason then
		vim.health.ok("mason.nvim is installed")
	else
		vim.health.error(
			"mason.nvim is not installed or cannot be loaded. "
				.. "Add `dependencies = { 'mason-org/mason.nvim' }` to your swapson.nvim lazy.nvim spec."
		)
		return
	end

	local state = require("swapson.state")

	check_tool_config(state, "npm")
	check_tool_config(state, "pip")

	-- Node shim status
	-- The shim now installs whenever npm patching is enabled, regardless of
	-- whether a real system `node` is on $PATH — it always backs npm-installed
	-- package execution with bun now, not just as a no-node fallback.
	local configured_opts = state.get_opts()
	local npm_enabled = ((configured_opts or {}).npm or {}).enabled ~= false

	local system_node_path = vim.fn.exepath("node")
	if system_node_path and system_node_path ~= "" then
		vim.health.info(
			("system node also found at %s (not used by swapson)"):format(system_node_path)
		)
	else
		vim.health.info("no system node found on $PATH")
	end

	if not npm_enabled then
		vim.health.info("npm patching disabled — node shim will not be created")
	else
		local ok_settings, mason_settings = pcall(require, "mason.settings")
		if ok_settings then
			local node_shim = mason_settings.current.install_root_dir .. "/bin/node"
			if vim.fn.filereadable(node_shim) == 0 then
				vim.health.info("node shim not yet created (created on next setup() call)")
			elseif vim.fn.executable(node_shim) == 1 then
				vim.health.ok(
					("swapson node shim active at %s (delegating to bun)"):format(node_shim)
				)

				-- Verify the on-disk shim is still a 1:1 copy of what we'd
				-- generate today (catches e.g. bun reinstalled at a new path,
				-- or the file hand-edited).
				local node_shim_mod = require("swapson.node_shim")
				local status = node_shim_mod.is_up_to_date(configured_opts or {})
				if status == "current" then
					vim.health.ok("node shim content matches the current generated shim")
				elseif status == "stale" then
					vim.health.warn(
						(
							"node shim content is out of date (drifted from generated shim) at %s"
							.. " — call require('swapson').setup() again, or delete the file and"
							.. " restart nvim to regenerate it."
						):format(node_shim)
					)
				elseif status == "foreign" then
					vim.health.warn(
						(
							"file at %s is not a swapson-managed shim (no swapson marker found)"
							.. " — leaving it untouched."
						):format(node_shim)
					)
				elseif status == "unresolved" then
					vim.health.info("could not verify node shim content (tool not resolvable)")
				end
			else
				vim.health.error(
					(
						"node shim exists but is not executable at %s"
						.. " — LSP servers using #!/usr/bin/env node will fail with exit 127."
						.. " Delete the file and restart nvim to regenerate it."
					):format(node_shim)
				)
			end
		end
	end

	-- Version lookup patch status
	if state.has_originals("version_lookup") then
		vim.health.ok("version lookup patched — version queries use npm registry API directly")
	else
		vim.health.info('"npm view" lookups still shell out to real npm')
	end
end

return M
