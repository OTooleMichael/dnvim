local function ensure_folder(folderPath)
	vim.fn.mkdir(folderPath, "p")
	return folderPath
end

---@generic T
---@param cond boolean
---@param if_t T
---@param if_f T
---@return T
local ternary = function(cond, if_t, if_f)
	if cond then
		return if_t
	else
		return if_f
	end
end

local split_lines = function(str)
	local result = {}
	for s in str:gmatch("[^\r\n]+") do
		table.insert(result, s)
	end
	return result
end

---@generic T
---@param table_list T[]
---@param func fun(value: T): boolean
---@return T | nil
local function find(table_list, func)
	for _, value in ipairs(table_list) do
		if func(value) then
			return value
		end
	end
	return nil
end

---@generic T
---@param table_list T[]
---@param func fun(value: T): boolean
---@return T[]
local function filter(table_list, func)
	local result = {}
	for _, value in ipairs(table_list) do
		if func(value) then
			table.insert(result, value)
		end
	end
	return result
end

---@param exit_code ?number
local exit_with_code = function(exit_code)
	local exit_cmd = ternary(exit_code ~= 0, ":cq", ":q!")
	print("\n")
	vim.cmd(exit_cmd)
end

---@param file_path string
---@return table | nil
local function read_json_file(file_path)
	local file = io.open(file_path, "r")
	if not file then
		return nil
	end
	local data = vim.fn.json_decode(file:read("*a"))
	if not data then
		return nil
	end
	return data
end

local function write_json_file(file_path, data)
	local file = io.open(file_path, "w")
	if not file then
		return false
	end
	file:write(vim.fn.json_encode(data))
	return file:close()
end

---@generic T
---@param t1 T
---@param t2 T
---@return T
local function merge_table_impl(t1, t2)
	for k, v in pairs(t2) do
		if type(v) == "table" then
			if type(t1[k]) == "table" then
				merge_table_impl(t1[k], v)
			else
				t1[k] = v
			end
		else
			t1[k] = v
		end
	end
	return t1
end

---Merge multiple tables into one
---@generic T
---@vararg T
---@return T
local function merge_tables(...)
	local out = {}
	for i = 1, select("#", ...) do
		merge_table_impl(out, select(i, ...))
	end
	return out
end

M = {
	noop = function() end,
	merge_tables = merge_tables,
	read_json_file = read_json_file,
	write_json_file = write_json_file,
	split_lines = split_lines,
	ternary = ternary,
	ensure_folder = ensure_folder,
	find = find,
	filter = filter,
	exit_with_code = exit_with_code,
}
return M
