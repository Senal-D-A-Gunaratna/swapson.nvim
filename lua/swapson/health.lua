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
	local node_found = vim.fn.executable("node") == 1
	local node_exe = node_found and vim.fn.exepath("node") or nil
	local is_own_shim = false
	if node_found then
		local ok_read, f = pcall(io.open, node_exe, "r")
		if ok_read and f then
			local content = f:read("*a")
			f:close()
			is_own_shim = content ~= nil
				and content:find("# swapson.nvim node shim", 1, true) ~= nil
		end
	end

	if node_found and is_own_shim then
		vim.health.ok(("swapson node shim active at %s (delegating to bun)"):format(node_exe))
	elseif node_found then
		vim.health.info(
			(
				"system node found at %s"
				.. " — node shim will not be created, npm-published packages run on real node."
			):format(node_exe)
		)
	else
		vim.health.info("no system node found — swapson will create a node shim delegating to bun.")
	end

	if not node_found then
		local ok_settings, mason_settings = pcall(require, "mason.settings")
		if ok_settings then
			local node_shim = mason_settings.current.install_root_dir .. "/bin/node"
			if vim.fn.filereadable(node_shim) == 0 then
				vim.health.info("shim not yet created (created on first setup() call if node stays absent)")
			elseif vim.fn.executable(node_shim) == 1 then
				vim.health.ok(("node shim active at %s"):format(node_shim))
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
		vim.health.ok("patch_version_lookup is enabled — version queries use npm registry API directly")
	else
		vim.health.info('"npm view" lookups still shell out to real npm')
	end
end

return M
