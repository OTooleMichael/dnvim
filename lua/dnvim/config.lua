local utils = require("dnvim.utils")
local config_path = vim.fn.stdpath("config")
local data_path = vim.fn.stdpath("data")
local user_config = string.format("%s/dnvim.json", config_path)
local cache_config = string.format("%s/dnvim.json", data_path)

---@alias Config table

DefaultConfig = {
	_is_docker = false,
	install_alias = false,
	alias_name = "dnvim",
	neovim = {
		preferred_version = "stable",
	},
	docker = {
		nvim_location = "/bin/nvim",
		copy_watcher = true,
		copy_watcher_registries = { "p" },
		default_container_name = "",
		skip_packages = {},
	},
	neovim_server = {
		host = "0.0.0.0",
		port = "7777",
		use_socat_proxy = false,
	},
}

---@param config_type string
---@return string
local get_config_path = function(config_type)
	if config_type == "user" then
		return user_config
	end
	if config_type == "cache" then
		return cache_config
	end
	if config_type == "project" then
		return string.format("%s/.nvim/dnvim.json", vim.fn.getcwd())
	end
	-- config_type == "default"
	return ""
end

-- Load the config/merge configs
-- config_type = user/cache/default/all
---@param config_type ?string
---@return Config
Load_config = function(config_type)
	config_type = config_type or "all"
	if utils.contains({ "project", "user", "cache" }, config_type) then
		return utils.read_json_file(get_config_path(config_type)) or {}
	end
	if config_type == "default" then
		return DefaultConfig
	end
	return utils.merge_tables(DefaultConfig, Load_config("cache"), Load_config("user"), Load_config("project"))
end

---@param config Config
---@param config_type ?string
local save_config = function(config, config_type)
	config_type = config_type or "cache"
	return utils.write_json_file(get_config_path(config_type), config)
end

M = {
	save_config = save_config,
	load_config = Load_config,
}
M.DefaultConfig = DefaultConfig

return M
