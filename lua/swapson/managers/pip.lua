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
	local Result = require("mason-core.result")
	local installer = require("mason-core.installer")
	local log = require("mason-core.log")
	local providers = require("mason-core.providers")
	local SystemPackage = require("mason-core.system-package")

	local originals = {
		init = pypi_manager.init,
		install = pypi_manager.install,
		uninstall = pypi_manager.uninstall,
	}

	-- Patch init()
	-- Original: promote cwd, resolve a python3 matching the package's
	-- requires-python, then `python3 -m venv --system-site-packages venv`,
	-- optionally upgrade pip inside venv.
	-- uv variant: `uv venv --python <requires-python> --system-site-packages venv`.
	-- uv resolves the specifier itself, honouring the user's uv config
	-- (python-preference, python-downloads), and downloads a matching
	-- interpreter unless python-downloads is disabled.
	-- `--seed` maps mason's `upgrade_pip`: it installs pip, plus setuptools
	-- and wheel (which uv omits on Python 3.12+). Our own install path uses
	-- `uv pip install`, so it doesn't need pip in the venv -- the seed only
	-- matters to anything else that assumes pip is there.
	pypi_manager.init = function(opts_init)
		opts_init = opts_init or {}
		log.fmt_debug("swapson: pypi init (uv) %s", opts_init)
		local ctx = installer.context()

		-- Scripts in the venv hardcode the absolute path of the venv python, so the
		-- venv must be created at its final location, not in mason's staging dir.
		ctx:promote_cwd()

		local requires_python
		if opts_init.package then
			requires_python = providers.pypi
				.get_supported_python_versions(opts_init.package.name, opts_init.package.version)
				:get_or_nil()
		end

		local function create_venv(python)
			return ctx.spawn[opts.tool]({
				"venv",
				python and { "--python", python } or vim.NIL,
				opts_init.upgrade_pip and "--seed" or vim.NIL,
				"--system-site-packages",
				"venv",
			})
		end

		-- uv uses the same venv directory structure as python -m venv, so mason's
		-- find_venv_executable continues to work after uv creates the venv.
		if not requires_python then
			ctx.stdio_sink:stdout("Creating virtual environment via uv…\n")
			return create_venv(nil)
		end

		ctx.stdio_sink:stdout(
			("Creating virtual environment via uv (Python %s)…\n"):format(requires_python)
		)
		local result = create_venv(requires_python)
		if result:is_success() then
			return result
		end
		-- Note: uv gives no structured reason for the failure, so *any* venv
		-- error is reported as an unsatisfied specifier here -- a broken uv.toml
		-- or a full disk looks the same as "no matching interpreter". Mason,
		-- which resolves the interpreter itself, can only fail this way when the
		-- version genuinely doesn't match.
		if ctx.opts.force then
			ctx.stdio_sink:stderr(
				(
					"Warning: no Python interpreter matching %s was found."
					.. " Falling back to uv's default interpreter.\n"
				):format(requires_python)
			)
			return create_venv(nil)
		end
		ctx.stdio_sink:stderr("Run with :MasonInstall --force to bypass this version validation.\n")
		return Result.failure(
			("Failed to find a Python interpreter that meets the required versions (%s)."):format(
				requires_python
			)
		)
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
		ctx.stdio_sink:stdout(
			("Installing pip package %s@%s via %s…\n"):format(pkg, version, opts.tool)
		)
		return ctx.spawn[opts.tool]({
			"pip",
			"install",
			"--python",
			"venv",
			"-U",
			install_opts.install_extra_args or vim.NIL,
			install_opts.extra and ("%s[%s]==%s"):format(pkg, install_opts.extra, version)
				or ("%s==%s"):format(pkg, version),
			install_opts.extra_packages or vim.NIL,
		})
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
		return ctx.spawn[opts.tool]({ "pip", "uninstall", "--python", "venv", pkg })
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
