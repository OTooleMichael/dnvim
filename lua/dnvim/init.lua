local utils = require("dnvim.utils")
local parse_args = require("dnvim.parse_args")
local config_path = vim.fn.stdpath("config")
local data_path = vim.fn.stdpath("data")
local user_config = string.format("%s/dnvim.json", config_path)
local cache_config = string.format("%s/dnvim.json", data_path)
local folderPath = utils.ensure_folder(
  string.format("%s/dnvim", data_path)
)

Installer = {
  NONE = "none",
  APT = "apt",
  APK = "apk",
}

---@class BuildDesc 
---@field arch string
---@field interperter string
---@field version string
---@field luajit boolean
---@field compile_details table
---@field image_name string
BuildDesc = {}
function BuildDesc:new(arch, interperter, version, luajit, compile_details, image_name)
  local build_desc = {
    arch = arch,
    interperter = interperter,
    version = version,
    luajit = luajit,
    compile_details = compile_details,
    image_name = image_name,
  }
  setmetatable(build_desc, self)
  self.__index = self
  return build_desc
end

---@param base_path string
---@return string
function BuildDesc:path(base_path)
  return base_path .. "/" .. self.version .. "/" .. self.arch .. "-" .. self.interperter .. "/" .. self.image_name
end


---@class BuildRegistry
---@field folder_path string
---@field data BuildDesc[]
BuildRegistry = {}
---@param folder_path string
---@return BuildRegistry
function BuildRegistry:new(folder_path)
  local registry = {
    folder_path = folder_path .. "/builds",
    data = {},
  }
  setmetatable(registry, self)
  self.__index = self
  return registry
end

---@param desc BuildDesc
function BuildRegistry:add(desc)
  if self:find(desc) then
    return
  end
  table.insert(self.data, desc)
  self:save()
end

---@param desc BuildDesc
---@return BuildDesc | nil
function BuildRegistry:find(desc)
  local found = utils.find(self.data, function(value)
    return value.image_name == desc.image_name
  end)
  if found then
    return found
  end
  return utils.find(self.data, function(value)
    return value.arch == desc.arch and value.interperter == desc.interperter
  end)
end

function BuildRegistry:save()
  utils.write_json_file({
    data=self.data
  })
end

---@return string
function BuildRegistry:filepath()
  return self.folder_path .. "/data.json"
end

function BuildRegistry:clear()
  os.remove(self:filepath())
end

function BuildRegistry:load()
  local json_data = utils.read_json_file(self:filepath())
  if not json_data then
    return
  end
  self.data = {}
  for _, desc in ipairs(json_data.data) do
    table.insert(self.data, BuildDesc:new(desc.arch, desc.interperter, desc.version, desc.luajit, desc.compile_details, desc.image_name))
  end
end

function BuildRegistry:list()
  local seen_versions = {}
  if not self.data then
    print("No existing builds found")
    return
  end
  print("Images stored at " .. self.folder_path)
  print("\n")
  print("Images found:")
  for _, desc in ipairs(self.data) do
    local version_str = "v" .. desc.version .. " / " .. desc.arch .. " " .. desc.interperter
    if not seen_versions[version_str] then
      seen_versions[version_str] = true
    end
    print(" - " .. desc.image_name .. " (" .. version_str .. ")" .. " file: " .. desc:path(self.folder_path))
  end
  print("\n")
  print("Archs found:")
  for version, _ in pairs(seen_versions) do
    print(" - " .. version)
  end
end


---@class DockerContainer
---@field id string
---@field name string
---@field json_data table
DockerContainer = {}

---@param id string
---@param json_data table
function DockerContainer:new(id, json_data)
  local name = json_data.Names
  ---@cast name string
  local container = {
    id = id,
    name = name,
    json_data = json_data,
    _sys_info = nil,
  }
  setmetatable(container, self)
  self.__index = self
  return container
end

---@param command string
---@param working_dir string | nil
function DockerContainer:exec(command, working_dir)
  working_dir = working_dir or ""
  if working_dir and working_dir ~= "" then
    working_dir = " -w " .. working_dir .. " "
  end
  local exec_command = "docker exec " .. working_dir .. self.id .. " " .. command
  local output = string.gsub(
    vim.fn.system(exec_command),
    "\n$",
    ""
  )
  ---@type number
  local shell_error_code = vim.v.shell_error

  local res = {
    command = command,
    exit_code = shell_error_code or 0,
    output = output,
  }
  return res
end

function DockerContainer:store(local_destination)
  local sys_info = self:system_info()
  local from_path = sys_info.home() .. "/neovim/"
  if not self:file_exists(from_path, true) then
    return 1
  end
  utils.ensure_folder(local_destination)
  self:copy_from_docker(local_destination, from_path)
end

---@param version string | nil
---@param overwrite boolean | nil
---@return number
function DockerContainer:build_neovim(version, overwrite)
  version = version or "stable"
  overwrite = overwrite or false
  local exit_code = 0
  local sys_info = self:system_info()
  if not overwrite and sys_info.installed.nvim then
      return 1
  end
  if sys_info.install_system == Installer.APK then
    if self:install({"build-base", "coreutils", "unzip", "gettext-tiny-dev"}) ~= 0 then
      return 1
    end
  end
  exit_code = self:install({
      "gcc",
      "g++",
      "curl",
      "unzip",
      "make",
      "gettext",
      "cmake",
      "libtool",
  })
  if exit_code ~= 0 then
      return exit_code
  end
  local zip_location = "/tmp/neovim.zip"
  if not self:file_exists(zip_location, false) then
      print("Downloading Neovim " .. version)
      local download_url = string.format("https://github.com/neovim/neovim/archive/refs/tags/%s.zip", version)
      exit_code = self:exec(
          "curl -L o " .. zip_location .. " " .. download_url
      ).exit_code
      if exit_code ~= 0 then
      print("Failed to download neovim")
          return exit_code
      end
  end
  local neovim_dir = sys_info.home() .. "/neovim"
  self:exec("rm -rf " .. neovim_dir .. "/build")
  print("Building NVIM in your container, this can take a while...")
  exit_code = self:exec(
    "make CMAKE_BUILD_TYPE=Release CMAKE_EXTRA_FLAGS=\"-DCMAKE_INSTALL_PREFIX=" .. neovim_dir .. "\"",
    neovim_dir
  ).exit_code
  if exit_code ~= 0 then
    print("Failed to build neovim")
    return exit_code
  end
  print("Build complete, installing...")
  exit_code = self:exec("make install", neovim_dir).exit_code
  if exit_code ~= 0 then
    print("Failed to install neovim")
    return exit_code
  end
  print("NVIM installed")
  return 0
end

---@return table
function DockerContainer:nvim_version()
  local res = self:exec("nvim --version")
  local version_lines = utils.split_lines(res.output)
  local version = version_lines[1]
  local luajit = version_lines[3]
  local compile_details = version_lines[4]
  return {
    version = string.gmatch(version, "v(.*)$")(),
    luajit = string.gmatch(luajit, " (.*)$")(),
    compile_details = compile_details,
  }
end

---@param command ?string
---@return number
function DockerContainer:enter(command)
  print("\n")
  local program = command or (self:system_info().installed["bash"] and "bash" or "sh")
  os.execute("docker exec -it " .. self.id .. " " .. program)
  return 0
end

function DockerContainer:install_setup()
  if self._install_setup ~= nil then
    return self._install_setup
  end
  print("Install setup")
  if self:system_info().install_system == Installer.APT then
    self._install_setup = self:exec("apt-get update --fix-missing")
    if self._install_setup.exit_code ~= 0 then
      return self._install_setup
    end
    self._install_setup = self:exec("apt-get install -y apt-utils")
    return self._install_setup
  end
  self._install_setup = self:exec("apk update")
  return self._install_setup
end

function DockerContainer:install(packages, lean)
  local s_installed = self:install_setup()
  if s_installed.exit_code ~= 0 then
    return s_installed.exit_code
  end
  local sys_info = self:system_info()
  local install_system = sys_info.install_system

  local command = "apk add"
  if install_system == Installer.APT then
    command = "apt-get install -y"
  end
  command = "apt-get install -y"
  if lean and install_system == "apt-get" then
      command = command .. " --no-install-recommends"
  end

  local packages_list = table.concat(packages, " ")
  print("  installing  (this can take a while)... ", packages_list)
  local res = self:exec(command .. " " .. packages_list)
  return res.exit_code
end


---@param path string
---@param is_dir boolean
---@return boolean
function DockerContainer:file_exists(path, is_dir)
    return self:exec("test " .. utils.ternary(is_dir, "-d ", "-f ") .. path).exit_code == 0
end

---@param to_docker boolean
---@param from_path string
---@param to_path string
function DockerContainer:copy(to_docker, from_path, to_path)
    local args = {
        "docker",
        "cp",
        from_path,
        to_path,
    }
    local value = args[utils.ternary(to_docker, 4, 3)]
    args[utils.ternary(to_docker, 4, 3)] = self.id .. ":" .. value
    vim.fn.system(args)
    local exit_code = vim.v.shell_error
    return exit_code or 0
end

---@param from_path string
---@param to_path string
---@return number
function DockerContainer:copy_to_docker(from_path, to_path)
    return self:copy(true, from_path, to_path)
end

---@param from_path string
---@param to_path string
---@return number
function DockerContainer:copy_from_docker(from_path, to_path)
    return self:copy(false, from_path, to_path)
end

---@param overwrite boolean
---@return number
function DockerContainer:sync_config(overwrite)
  local sys_info = self:system_info()
  local local_home = os.getenv("HOME")
  ---@type string
  local config_folder = sys_info.home() .. "/.config"
  local exit_code = 0
  exit_code = self:exec("mkdir -p " ..config_folder).exit_code
  if exit_code ~= 0 then
      return exit_code
  end
  exit_code = self:exec("mkdir -p " .. sys_info.home() .. "/.local/share/nvim").exit_code
  if exit_code ~= 0 then
      return exit_code
  end
  if not overwrite and self:file_exists(config_folder .. "/nvim", true) then
      print("Config already exists, skipping")
      return 0
  end

  print("Removing .config/nvim")
  self:exec("rm -rf " ..config_folder .. "/nvim")
  print("Remove .local/share/nvim")
  self:exec("rm -rf " .. sys_info.home() .. "/.local/share/nvim")
  print("Syncing .config/nvim")
  local nvim_folder = local_home .. "/.config/nvim"
  exit_code = self:copy_to_docker(nvim_folder, config_folder)
  if exit_code ~= 0 then
      print("Failed to sync .config/nvim")
      return exit_code
  end
  print("Syncing .config/github-copilot")
  self:copy_to_docker(local_home .. "/.config/github-copilot", config_folder)
  return 0
end

function DockerContainer:ensure_deps()
  if self:install_setup().exit_code ~= 0 then
    return 1
  end
  local i_res = self:install(
      {
          "wget",
          "git",
          "ripgrep",
      }
  )
  if i_res ~= 0 then
      return i_res
  end
  local sys_info = self:system_info()
  if not sys_info.installed.node then
      i_res = self:install({"nodejs", "npm"}, true)
  end
  if i_res ~= 0 then
      return i_res
  end
  if not sys_info.installed.python3 then
      i_res = self:install({"python3"})
  end
  return i_res
end

---@param local_destination string
---@return number
function DockerContainer:load_build(local_destination)
  local sys_info = self:system_info()
  local docker_path = sys_info.home()
  local_destination = local_destination .. "/neovim"
  utils.ensure_folder(local_destination)
  return self:copy_to_docker(local_destination, docker_path)
end


---@return number
function DockerContainer:link_nvim()
  print("Linking NVIM")
  local nvim_bin = self:system_info().home() .. "/neovim/build/bin/nvim"
  local exit_code = self:exec("sh -c " .. vim.fn.shellescape("ln -sf " .. nvim_bin .. " /bin/nvim")).exit_code
  return exit_code or self:exec("nvim --version").exit_code
end


function DockerContainer:system_info()
  if self._sys_info then
    return self._sys_info
  end
  local arch = self:exec("uname -m").output
  local user = self:exec("whoami").output
  local install_system = Installer.NONE
  local has_apt = self:exec("which apt-get").exit_code == 0
  local has_apk = self:exec("which apk").exit_code == 0

  if has_apt then
    install_system = Installer.APT
  end
  if has_apk then
    install_system = Installer.APK
  end

  local interperter = self:exec("ls /lib").output
  local installed = {
    python3 = self:exec("which python3").exit_code == 0,
    npm = self:exec("which npm").exit_code == 0,
    node = self:exec("which node").exit_code == 0,
    nvim = self:exec("which nvim").exit_code == 0,
    bash = self:exec("which bash").exit_code == 0,
    sh = self:exec("which sh").exit_code == 0,
  }

  local envs = {}
  local env_str = self:exec("printenv").output
  for _, line in ipairs(utils.split_lines(env_str)) do
      local parts = {}
      for part in string.gmatch(line, "[^=]+") do
          parts[#parts + 1] = part
      end
      envs[parts[1]] = parts[2]:gsub("^%s*(.-)%s*$", "%1")
  end
  local find_res = string.find(interperter, "ld-linux-aarch64.so.1", 1, true)
  self._sys_info = {
    user = user,
    arch = arch,
    install_system = install_system,
    interperter = interperter,
    ld_musl_aarch64=find_res,
    installed = installed,
    envs = envs,
    ---@return string
    home = function()
      return envs.HOME
    end,
  }
  return self._sys_info
end

local docker_print_containers = function(containers)
  for _, container in ipairs(containers) do
    print(container.id, container.name)
  end
end

---@return DockerContainer[]
local docker_ps = function()
  local result = vim.fn.system("docker ps --format json")
  -- split the result by line and load the json to a table
  local lines = vim.split(result, "\n")
  local containers = {}
  for _, line in ipairs(lines) do
    if line == "" then
      goto continue
    end
    local container = vim.fn.json_decode(line)
    if container == nil then
      goto continue
    end
    local docker_container = DockerContainer:new(container.ID, container)
    table.insert(containers, docker_container)
    ::continue::
  end

  return containers
end

local function command_help(params)
  for command, command_des in pairs(CommandStructures) do
    local overview = command
    if command_des.args.key then
      overview = overview .. " <" .. command_des.args.key .. ">"
    end
    overview = overview ..  ": " .. (command_des.desc or "")
    print(overview)
    for option, option_des in pairs(command_des.options) do
      if type(option_des) == "string" then
        goto continue
      end
      local name = " --" .. option
      for _, alias in ipairs(option_des.aliases or {}) do
        alias = "-" .. alias
        name = name .. ", " .. alias
      end
      for key, value in pairs(option_des) do
        if ({aliases = 1, desc= 1, option_id=1})[key] then
          goto continue1
        end
        name = name .. " [" .. key .. ": " .. vim.inspect(value) .. "]"
        ::continue1::
      end
      print(name)
      ::continue::
    end
  end
  print("")
end

---@param name string
---@return DockerContainer | nil
local function get_conatiner_by_name(name)
  local containers = docker_ps()
  local matching_containers = utils.filter(containers, function(container)
    return string.find(container.name, name) ~= nil
  end)
  if #matching_containers == 0 then
    print("No matching containers found")
    docker_print_containers(containers)
    return
  end
  if #matching_containers > 1 then
    print("Multiple matching containers found")
    docker_print_containers(matching_containers)
    return
  end
  return matching_containers[1]
end


---@return number
local function command_run(params)
  local container = get_conatiner_by_name(params.name)
  if not container then
    return 1
  end
  local exit_code = container:ensure_deps()
  if exit_code ~= 0 then
    print("Failed to install dependencies")
    return exit_code
  end
  container:sync_config(params.sync_config or true)
  local info = container:system_info()
  local registry = BuildRegistry:new(folderPath)
  registry:load()
  local find_and_use_build = not params.build and not info.installed.nvim
  if find_and_use_build then
      local interpreter = ""
      if info.ld_musl_aarch64 then
          interpreter = "ld_musl_aarch64"
      end
      local to_find = BuildDesc:new(
          info.arch,
          interpreter,
          "",
          "",
          "",
          container.name
      )
      local desc = registry:find(to_find)
      if not desc then
          print("No matching build found, try running with --build")
          registry:list()
          return 1
      end
      exit_code = container:load_build(desc:path(registry.folder_path))
      if exit_code ~= 0 then
          print("Failed to load build")
          return exit_code
      end
      exit_code = container:link_nvim()
      if exit_code ~= 0 then
          print("Failed to link nvim")
          return exit_code
      end
  end
  if params.build then
    exit_code = container:build_neovim(nil, true)
    if exit_code ~= 0 then
        print("Failed to build neovim")
        return exit_code
    end
    local version = container:nvim_version()
    local interperter = ""
    if info.ld_musl_aarch64 then
        interperter = "ld_musl_aarch64"
    end
    local build_desc = BuildDesc:new(
        info.arch,
        interperter,
        version.version,
        version.luajit,
        version.compile_details,
        container.name
    )
    exit_code = container:store(build_desc:path(registry.folder_path))
    if exit_code ~= 0 then
        print("Failed to store build")
        return exit_code
    end
    registry:add(build_desc)
    registry:list()
  end
  return container:enter(params.program)
end

CommandStructures_ = {
  parse_args.Command:new(
    "list_builds",
    {
      desc = "List all builds",
    },
    function(params)
      local registry = BuildRegistry:new(folderPath)
      registry:load()
      registry:list()
      return 0
    end
  ),
  parse_args.Command:new(
    "run",
    {
      desc = "Ensure nvim is installed and run it in the container",
      args = {
        type = ".",
        key = "name",
      },
      options = {
        name = {
          required = true,
          aliases = {"n"},
        },
        build = {
          desc = "Build neovim in the container",
          default = false,
          aliases = {"b"},
        },
        program = {
          desc = "Command/program to run in the container",
          default = "nvim",
          aliases = {"p"},
        },
      },
    },
    function(params)
      return command_run(params)
    end
  ),
  parse_args.Command:new(
    "enter",
    {
      desc = "Enter a prepared conatiner without additional checks and loading",
      args = {
        type = ".",
        key = "name",
      },
      options = {
        name = {
          required = true,
          aliases = {"n"},
        },
        program = {
          desc = "Command/program to run in the container",
          default = "nvim",
          aliases = {"p"},
        },
      },
    },
    function(params)
      local container = get_conatiner_by_name(params.name)
      if not container then
        return 1
      end
      return container:enter(params.program)
    end
  ),
  parse_args.Command:new(
    "list",
    {
      desc = "List all running containers",
    },
    function(params)
      docker_print_containers(docker_ps())
      return 0
    end
  ),
  parse_args.Command:new(
    "help",
    {
      desc = "Show help",
    },
    function(params)
      command_help(params)
      return 0
    end
  ),
}

---@type {[string]: Command}
CommandStructures = {}
for _, command in ipairs(CommandStructures_) do
  CommandStructures[command.command_id] = command
end



local M = {}
function M.setup()
	print("hello")
end

function M.install_alias()
  local alias = M.alias_string()
  local rc_files = {"~/.zshrc", "~/.bashrc"}
  -- check each of the rc files, if they exist and don't contain the alias, add it 
  for _, rc_file in ipairs(rc_files) do
    local rc_file_path = vim.fn.expand(rc_file)
    if vim.fn.filereadable(rc_file_path) == 1 then
      local file_content = vim.fn.readfile(rc_file_path)
      local has_alias = false
      for _, line in ipairs(file_content) do
        if string.find(line, alias) then
          has_alias = true
        end
      end
      if not has_alias then
        print("Writing alias to " .. rc_file_path)
        vim.fn.writefile({alias}, rc_file_path, "a")
      end
    end
  end
end

function M.alias_string()
  return 'alias dnvim="nvim --headless -n -c \'lua require(\\"dnvim\\").cli()\' -- "'
end

function M.list_builds()
  CommandStructures.list_builds.func({})
end

function M.cli()
    local args = parse_args.get_headerless_args()
    local command_func = parse_args.parse_command(args, CommandStructures)
    if command_func == nil then
      print("Invalid command args: ")
      vim.inspect(args)
      command_help({})
      return utils.exit_with_code(1)
    end
    local exit_code = command_func:exec()
    return utils.exit_with_code(exit_code or 0)
end
return M
