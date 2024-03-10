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
	},
	neovim_server = {
		host = "0.0.0.0",
		port = "7777",
		use_socat_proxy = false,
	},
}

-- Load the config/merge configs
-- config_type = user/cache/default/all
---@param config_type ?string
---@return Config
Load_config = function(config_type)
	config_type = config_type or "all"
	if config_type == "user" then
		return utils.read_json_file(user_config) or {}
	end
	if config_type == "cache" then
		return utils.read_json_file(cache_config) or {}
	end
	if config_type == "default" then
		return DefaultConfig
	end
	return utils.merge_tables(DefaultConfig, Load_config("cache"), Load_config("user"))
end

---@param config Config
---@param config_type ?string
local save_config = function(config, config_type)
	config_type = config_type or "cache"
	return utils.write_json_file(cache_config, config)
end

M = {
	save_config = save_config,
	load_config = Load_config,
}
M.DefaultConfig = DefaultConfig

return M
