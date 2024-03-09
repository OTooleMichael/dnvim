---@param args table
---@return table | nil
local parse_positional = function(args)
	local command = args[1]
	if command == nil then
		return nil
	end

	if command == "help" or command == "--help" or command == "-h" then
		return {
			command = "help",
			args = {},
			options = {},
		}
	end

	if not CommandStructures[command] then
		return nil
	end
	local output = {
		command = command,
		args = {},
		options = {},
	}
	local pending_option = nil
	for i = 2, #args do
		local arg = args[i]
		if string.sub(arg, 1, 1) == "-" then
			-- strip leading -- and assign to pending_option
			pending_option = string.gsub(arg, "^-+", "")
			output.options[pending_option] = true
			goto continue
		end
		if pending_option then
			output.options[pending_option] = arg
			pending_option = nil
			goto continue
		end
		table.insert(output.args, arg)
		::continue::
	end
	return output
end
-- Takes buffers passed to a headerless nvim and cleans them up
-- Returns the args passes
---@return string[]
local get_headerless_args = function()
	local valid_args = {}
	local double_dash_found = false
	for _, arg in ipairs(vim.v.argv) do
		if double_dash_found then
			table.insert(valid_args, arg)
		end
		if arg == "--" then
			double_dash_found = true
		end
	end
	-- We passed our own flags and they were understood as buffers by neovim
	-- so we need to close them, and don't want them to end up in swapfiles
	local buffer_list = vim.fn.getbufinfo({ buflisted = 1 })
	vim.cmd("set nohidden")
	vim.cmd(":enew")
	for _, buf in ipairs(buffer_list) do
		vim.cmd("bdelete " .. buf.bufnr)
	end
	return valid_args
end

---@class Command
---@field aliases {[string]: string}
---@field options table
---@field args table
---@field desc string | nil
---@field params table | nil
---@field command_id string
---@field func fun(params: table): number
Command = {}

---@param command_id string
---@param payload table
---@param func fun(params: table): number
---@return Command
function Command:new(command_id, payload, func)
	local options = {}
	local aliases = {}
	local p_opts = payload.options or {}
	for key, value in pairs(p_opts) do
		local _aliases = value.aliases or {}
		for _, alias in ipairs(_aliases) do
			aliases[alias] = key
		end
		value["option_id"] = key
		options[key] = value
	end
	local data = {
		command_id = command_id,
		args = payload.args or {},
		desc = payload.desc,
		options = options,
		aliases = aliases,
		params = nil,
		func = func,
	}
	setmetatable(data, self)
	self.__index = self
	return data
end

function Command:parse_args(parsed_args)
	local params = {
		command = parsed_args.command,
	}
	local args_type = self.args.type
	if args_type == "." then
		params[self.args.key] = parsed_args.args[1]
	end
	if args_type == "*" then
		params[self.args.key] = parsed_args.args
	end
	for option_name, value in pairs(parsed_args.options) do
		local option_des = self:get_option(option_name)
		if option_des == nil then
			return 1
		end
		params[option_des.option_id] = value
	end
	for option_name, value in pairs(self.options) do
		if value.default and not params[option_name] then
			params[option_name] = value.default
		end
	end
	self.params = params
	return 0
end

---@return number
function Command:exec()
	if self.params == nil then
		return 1
	end
	return self.func(self.params)
end

---@param name_or_alias string
---@return table | nil
function Command:get_option(name_or_alias)
	local true_name = self.aliases[name_or_alias]
	if true_name then
		return self.options[true_name]
	end
	return self.options[name_or_alias]
end

---@param args string[]
---@param commands {[string]: Command}
---@return Command | nil
local parse_command = function(args, commands)
	local parsed_args = parse_positional(args)
	if parsed_args == nil then
		return nil
	end
	local command_des = commands[parsed_args.command]
	if command_des == nil then
		return nil
	end
	command_des:parse_args(parsed_args)
	return command_des
end

M = {
	Command = Command,
	get_headerless_args = get_headerless_args,
	parse_command = parse_command,
}
return M
