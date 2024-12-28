local utils = require("dnvim.utils")
local config = require("dnvim.config")
local parse_args = require("dnvim.parse_args")
local data_path = vim.fn.stdpath("data")
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
    return value.arch == desc.arch and value.interperter == desc.interperter and value.version == (desc.version or value.version)
  end)
end

function BuildRegistry:save()
  utils.write_json_file(self:filepath(), {
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

---@enum Package
Package = {
  ninja_build = "ninja-build",
  build_essential = "build-essential",
  build_base = "build-base",
  cmake = "cmake",
  coreutils = "coreutils",
  curl = "curl",
  gcc = "gcc",
  gettext = "gettext",
  gettext_tiny_dev = "gettext-tiny-dev",
  git = "git",
  gpp = "g++",
  libtool = "libtool",
  make = "make",
  nodejs = "nodejs",
  npm = "npm",
  python3 = "python3",
  ripgrep = "ripgrep",
  fzf = "fzf",
  unzip = "unzip",
  wget = "wget",
}

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
---@param silent boolean | nil
function DockerContainer:exec(command, working_dir, silent)
  silent = silent or false
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
  if not silent and res.exit_code ~= 0 then
    print(vim.inspect(res))
  end
  return res
end

DnvimGroup = vim.api.nvim_create_augroup("DnvimGroup", { clear = true }) -- Create an autocommand group named "YankCopyGroup" and clear any existing autocommands in the group

function DockerContainer:ensure_copy_watcher()
  print("Start listening for copy ".. self.id .. ":" .. DNVIM_COPY_FILE)
  local docker_watch_file = DNVIM_COPY_FILE
  self:exec("sh -c " .. vim.fn.shellescape("touch " .. docker_watch_file))
  local timer = vim.loop.new_timer()
  if not timer then
    print("Failed to create dnvim copy watcher")
    return
  end
  local container = self
  local cb_pend = false
  local res = ""
  timer:start(0, 1000, vim.schedule_wrap(function()
    if cb_pend then
      return
    end
    cb_pend = true
    local value = DockerContainer.exec(container, "stat --format '%Y' " .. docker_watch_file).output
    if res == "" then
      res = value
      cb_pend = false
      return
    end
    if res == value then
      cb_pend = false
      return
    end
    res = value
    cb_pend = false
    local data = container:exec("cat " .. docker_watch_file).output
    print("\n")
    print(data)
    print("\n")
    vim.fn.system("pbcopy", data)
  end))
end

function DockerContainer:store(local_destination)
  local sys_info = self:system_info()
  local from_path = sys_info.home() .. "/neovim/"
  if not self:file_exists(from_path, true) then
    return 1
  end
  utils.ensure_folder(local_destination)
  return self:copy_from_docker(from_path, local_destination)
end

---@param version string | nil
---@param overwrite boolean | nil
---@return number
function DockerContainer:build_neovim(version, overwrite)
  -- build from source
  -- https://github.com/neovim/neovim/blob/master/BUILD.md
  version = version or "stable"
  overwrite = overwrite or false
  local exit_code = 0
  local sys_info = self:system_info()
  if not overwrite and sys_info.installed.nvim then
      return 1
  end
  if sys_info.install_system == Installer.APK then
    self:exec("apk update")
    local install_list = {
      Package.build_base,
      Package.coreutils,
      Package.unzip,
      Package.gettext_tiny_dev,
    }
    if self:install(install_list) ~= 0 then
      return 1
    end
  else
    self:exec("apt-get update")
    if self:install({ Package.gettext, Package.ninja_build, Package.build_essential }) ~= 0 then
      return 1
    end
  end
  exit_code = self:install({
      Package.gcc,
      Package.gpp,
      Package.curl,
      Package.unzip,
      Package.make,
      Package.cmake,
      Package.libtool,
  })
  if exit_code ~= 0 then
      return exit_code
  end
  local zip_location = "/tmp/neovim.zip"
  local neovim_dir = sys_info.home() .. "/neovim"
  if not self:file_exists(zip_location, false) then
      print("Downloading Neovim " .. version)
      local download_url = string.format("https://github.com/neovim/neovim/archive/refs/tags/%s.zip", version)
      exit_code = self:exec(
          "curl -Lo " .. zip_location .. " " .. download_url
      ).exit_code
      if exit_code ~= 0 then
          print("Failed to download neovim")
          return exit_code
      end
      self:exec("rm -rf " .. neovim_dir)
  end

  if not self:file_exists(neovim_dir, true) then
      local temp_dir = "/tmp/neovim"
      self:exec("rm -rf " .. temp_dir)
      exit_code = self:exec("unzip -o " .. zip_location .. " -d " .. temp_dir).exit_code
      if exit_code ~= 0 then
          print("Failed to unzip " .. zip_location)
          return exit_code
      end
      self:exec("mv /tmp/neovim/neovim-".. version .. " ".. neovim_dir)
  end

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
  self:exec("ln -sf " .. neovim_dir ..  "/build/bin/nvim /bin/nvim")
  print("NVIM installed")
  return 0
end

---@return table
function DockerContainer:nvim_version()
  local nvim_location = config.load_config().docker.nvim_location
  local res = self:exec(nvim_location .. " --version --clean --noplugin")
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
  local job_id = nil
  if config.load_config().docker.copy_watcher then
    print("Starting copy watcher: copy_listener " .. self.id)
    job_id = vim.fn.jobstart(
    "nvim --headless -n -c 'lua require(\"dnvim\").cli()' -- copy_listener " .. self.id,
    {
      on_stdout = utils.noop,
      on_stderr = utils.noop,
      stderr_buffered = false,
      stdout_buffered = false,
    })
  end
  local program = command or (self:system_info().installed["bash"] and "bash" or "sh")
  os.execute("docker exec -it " .. self.id .. " " .. program)
  if job_id then
    vim.fn.jobstop(job_id)
  end
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

---@param packages (string | Package)[] 
---@param lean ?boolean
---@return number
function DockerContainer:install(packages, lean)
  local conf = config.load_config()
  packages = utils.filter(packages, function(value)
    return not utils.find(conf.docker.skip_packages, function(skip)
      return skip == value
    end)
  end)

  if #packages == 0 then
    print("No packages to install")
    return 0
  end

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
    return self:exec(
      "test " .. utils.ternary(is_dir, "-d ", "-f ") .. path,
      nil,
      true
    ).exit_code == 0
end

---@param program string
---@return boolean
function DockerContainer:bin_exists(program)
    return self:exec(
      "which " .. program,
      nil,
      true
    ).exit_code == 0
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
    vim.print(args)
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
  exit_code = self:exec("mkdir -p " .. sys_info.home() .. "/.local/share/nvim").exit_code
  if not overwrite and self:file_exists(config_folder .. "/nvim", true) then
      print("Config already exists, skipping")
      return 0
  end

  print("Removing .config/nvim")
  self:exec("rm -rf " ..config_folder .. "/nvim")
  print("Remove .local/share/nvim")
  self:exec("rm -rf " .. sys_info.home() .. "/.local/share/nvim")
  -- self:exec("rm -rf " .. sys_info.home() .. "/lua")
  self:exec("mkdir -p " .. sys_info.home() .. "/.local/share/nvim")
  local tmp_file = "/tmp/dnvim.json"
  local _config = config.load_config("cache")
  _config._is_docker = true
  utils.write_json_file(tmp_file, _config)
  self:copy_to_docker(
    tmp_file,
    sys_info.home() .. "/.local/share/nvim/dnvim.json"
  )
  print("Syncing .config/nvim")
  local nvim_folder = local_home .. "/.config/nvim"
  exit_code = self:copy_to_docker(nvim_folder, config_folder)
  if exit_code ~= 0 then
      print("Failed to sync .config/nvim")
      return exit_code
  end
  -- self:copy_to_docker(local_home .. "/lua", sys_info.home() .. "/lua")
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
      Package.wget,
      Package.git,
      Package.ripgrep,
      Package.fzf,
    }
  )
  -- if i_res ~= 0 then
  --     return i_res
  -- end
  -- local sys_info = self:system_info()
  -- if not sys_info.installed.node then
  --     i_res = self:install({Package.nodejs, Package.npm}, true)
  -- end
  -- if i_res ~= 0 then
  --     return i_res
  -- end
  -- if not sys_info.installed.python3 then
  --     i_res = self:install({Package.python3})
  -- end
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
  local nvim_bin = self:system_info().home() .. "/neovim/build/bin/nvim"
  local nvim_location = config.load_config().docker.nvim_location
  local exit_code = self:exec("sh -c " .. vim.fn.shellescape("ln -sf " .. nvim_bin .. " " .. nvim_location)).exit_code
  return exit_code or self:exec(nvim_location .. " --version").exit_code
end


function DockerContainer:system_info()
  if self._sys_info then
    return self._sys_info
  end
  local arch = self:exec("uname -m").output
  local user = self:exec("whoami").output
  local install_system = Installer.NONE
  local has_apt = self:bin_exists("apt-get")
  local has_apk = self:bin_exists("apk")

  if has_apt then
    install_system = Installer.APT
  end
  if has_apk then
    install_system = Installer.APK
  end

  local interperter = self:exec("ls /lib").output
  local installed = {
    python3 = self:bin_exists("python3"),
    npm = self:bin_exists("npm"),
    node = self:bin_exists("node"),
    nvim = self:bin_exists("nvim"),
    bash = self:bin_exists("bash"),
    sh = self:bin_exists("sh"),
  }

  local needed_envs = {"HOME"}
  local envs = {}
  local env_str = self:exec("printenv").output
  for _, line in ipairs(utils.split_lines(env_str)) do
      local parts = {}
      for part in string.gmatch(line, "[^=]+") do
          parts[#parts + 1] = part
      end
      if utils.find(needed_envs, function(value)
          return value == parts[1]
      end) then
          envs[parts[1]] = parts[2]:gsub("^%s*(.-)%s*$", "%1")
      end
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
local function get_container_by_name(name)
  local containers = docker_ps()
  local matching_containers = utils.filter(containers, function(container)
    return string.find(container.name, name, nil, true) ~= nil or container.id == name
  end)
  if #matching_containers == 0 then
    print("No matching containers found: ", name)
    docker_print_containers(containers)
    return
  end
  if #matching_containers > 1 then
    print("Multiple matching containers found: ", name)
    docker_print_containers(matching_containers)
    return
  end
  return matching_containers[1]
end


---@return number
local function build_docker(params, skip_ensure_deps)
  local container = get_container_by_name(params.name)
  if not container then
    return 1
  end

  local exit_code = 0
  if not skip_ensure_deps then
    exit_code = container:ensure_deps()
    if exit_code ~= 0 then
      print("Failed to install dependencies")
      return exit_code
    end
  end

  container:sync_config(params.sync_config or true)
  local info = container:system_info()
  local registry = BuildRegistry:new(folderPath)
  registry:load()
  local neovim_version = config.load_config().neovim.preferred_version
  exit_code = container:build_neovim(neovim_version, true)
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
  return 0
end

---@return number
local function command_run(params)
  local container = get_container_by_name(params.name)
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
  end
  if params.build then
    local skip_ensure_deps = true
    build_docker(params, skip_ensure_deps)
  end
  exit_code = container:link_nvim()
  if exit_code ~= 0 then
      print("Failed to link nvim")
      return exit_code
  end
  return container:enter(params.program)
end


CommandStructures_ = {
  parse_args.Command:new(
    "write-config",
    {
      desc = "Write project local config",
      args = {
        type = ".",
        key = "name",
        default = function ()
          return config.load_config().docker.default_container_name
        end,
      },
      options = {
        name = {
          required = true,
          aliases = {"n"},
        },
        program = {
          desc = "Command/program to run in the container",
          default = function ()
            return config.load_config().docker.nvim_location
          end,
          aliases = {"p"},
        },
      },
    },
    function(params)
      local _config = config.load_config()
      _config.docker.default_container_name = params.name
      print(vim.inspect(_config))
      config.save_config(_config, "project")
      return 0
    end
  ),
  parse_args.Command:new(
    "cwd",
    {
      desc = "Install the dnvim alias",
    },
    function(params)
      local cwd = vim.fn.getcwd()
      -- Load a config from ./.nvim/dnvim.json if it exists
      local config_path = cwd .. "/.nvim/dnvim.json"
      if vim.fn.filereadable(config_path) ~= 1 then
        return 1
      end
      local config_data = utils.read_json_file(config_path)
      vim.print(config_data)
      return 0
    end
  ),
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
    "run_server",
    {
      desc = "Run a neovim server in the container",
      args = {
        type = ".",
        key = "name",
      },
      options = {
        name = {
          required = true,
          aliases = {"n"},
          default = function ()
            return config.load_config().docker.default_container_name
          end,
        },
        build = {
          desc = "Build neovim in the container",
          default = false,
          aliases = {"b"},
        },
        host = {
          desc = "Host to run the server on",
          default = function ()
            return config.load_config().neovim_server.host
          end,
          aliases = {"h"},
        },
        port = {
          desc = "Port to run the server on",
          default = function ()
            return config.load_config().neovim_server.port
          end,
          aliases = {"p"},
        },
        no_proxy = {
          desc = "Don't use a socat proxy. Otherswise verb/socat will be booted as a new container in the same network to proxy the connection to the container",
          default = function ()
            return config.load_config().neovim_server.use_socat_proxy
          end,
        },
      },
    },
    function(params)
      params.program = "sh -c " .. vim.fn.shellescape("nvim --headless --listen " .. params.host .. ":" .. params.port)
      local container = get_container_by_name(params.name)
      if not container then
        return 1
      end
      local docker_ip = container:exec("hostname -i").output
      print("Found IP: " .. docker_ip)
      local handle_output = function(_, data, _)
        print(data)
      end
      print(string.format("Connect to with `nvim --remote-ui --server localhost:%s`", params.port))
      print("  wait for server to be ready before connecting")
      if params.no_proxy then
        return command_run(params)
      end
      local command = "docker run --rm -p ".. params.port .. ":1234 verb/socat TCP-LISTEN:1234,fork TCP-CONNECT:" .. docker_ip .. ":" .. params.port
      print("Socat start: " .. command)
      local job_id = vim.fn.jobstart(command, {
        on_stdout = handle_output,
        on_stderr = handle_output,
        stderr_buffered = false,
        stdout_buffered = false,
      })
      command_run(params)
      vim.fn.jobstop(job_id)
      return 0
    end
  ),
  parse_args.Command:new(
    "copy_listener",
    {
      desc = "Start a copy listener in the container",
      args = {
        type = ".",
        key = "name",
      },
      options = {
        name = {
          required = true,
          aliases = {"n"},
        },
      },
    },
    function(params)
      local container = get_container_by_name(params.name)
      if not container then
        return 1
      end
      container:ensure_copy_watcher()
      return -1
    end
  ),
  parse_args.Command:new(
    "build",
    {
      desc = "Build neovim in the container",
      args = {
        type = ".",
        key = "name",
      },
      options = {
        name = {
          required = true,
          aliases = {"n"},
          default = function ()
            return config.load_config().docker.default_container_name
          end,
        },
      },
    },
    function(params)
      print("BUILD!")
      vim.inspect(params)
      return build_docker(params)
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
          default = function ()
            return config.load_config().docker.default_container_name
          end,
        },
        build = {
          desc = "Build neovim in the container",
          default = false,
          aliases = {"b"},
        },
        program = {
          desc = "Command/program to run in the container",
          default = function ()
            return config.load_config().docker.nvim_location
          end,
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
        default = function ()
          return config.load_config().docker.default_container_name
        end,
      },
      options = {
        name = {
          required = true,
          aliases = {"n"},
        },
        program = {
          desc = "Command/program to run in the container",
          default = function ()
            return config.load_config().docker.nvim_location
          end,
          aliases = {"p"},
        },
      },
    },
    function(params)
      local container = get_container_by_name(params.name)
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


DNVIM_COPY_FILE = "/tmp/dnvim_copy_watcher.txt"

local M = {}

local create_yank_listener = function()
  local _config = config.load_config()
  if not _config.docker.copy_watcher then
    return
  end
  vim.api.nvim_create_autocmd("TextYankPost", { -- Create an autocommand for the "TextYankPost" event
    pattern = "*", -- Match any pattern
    group = DnvimGroup, -- Assign the autocommand to the "YankCopyGroup" group
    callback = function()
      local match = utils.find(_config.docker.copy_watcher_registries, function(value)
        return value == vim.v.event.regname
      end)
      if not match then
        return
      end
      local data = vim.v.event.regcontents
      local bin_loc = vim.fn.system("which pbcopy")
      if bin_loc ~= "" and not _config._is_docker then
        vim.fn.system("pbcopy", data)
        return
      end
      vim.fn.writefile(data, DNVIM_COPY_FILE)
    end,
  })
end

---@param user_config ?Config
function M.setup(user_config)
  local cache = config.load_config("cache")
  user_config._is_docker = cache._is_docker
  config.save_config(user_config or {})
  local _config = config.load_config()
  if _config.install_alias then
    M.install_alias()
  end
  create_yank_listener()
end

function M.install_alias()
  local suffix = "#dnvim-alias"
  local alias = M.alias_string() .. " " .. suffix
  local rc_files = {"~/.zshrc", "~/.bashrc"}
  -- check each of the rc files, if they exist 
  -- if remove any lines that contain the suffix and then add the alias
  for _, rc_file in ipairs(rc_files) do
    local rc_file_path = vim.fn.expand(rc_file)
    if vim.fn.filereadable(rc_file_path) == 1 then
      local file_content = utils.filter(
        vim.fn.readfile(rc_file_path),
        function(line)
          return not string.find(line, suffix, nil, true)
        end
      )
      table.insert(file_content, alias)
      vim.fn.writefile(file_content, rc_file_path, "s")
    end
  end
end

function M.alias_string()
  local _config = config.load_config()
  return ('alias %s="nvim --headless -n -c \'lua require(\\"dnvim\\").cli()\' -- "'):format(_config.alias_name)
end

function M.list_builds()
  CommandStructures.list_builds.func({})
end

function M.cli()
    local args = parse_args.get_headerless_args()
    local command_func = parse_args.parse_command(args, CommandStructures)
    if command_func == nil then
      print("Invalid command args: ")
      vim.print(args)
      command_help({})
      return utils.exit_with_code(1)
    end
    local exit_code = command_func:exec()
    if exit_code < 0 then
      return
    end
    return utils.exit_with_code(exit_code or 0)
end
return M
