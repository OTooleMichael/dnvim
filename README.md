# DNVIM

A tool for quickly booting nvim inside dockers for better local development. Meant to allow something similar to VScode DevContainers

dnvim can be run in a new terminal booting through `nvim --headless`.

dnvim loads everything required to have nvim run in your docker and copies your own local config into the container. In addition dnvim allows you to build nvim to fit the container arch (and caches it for reuse).

## Installing

- Add dnvim to neovim via your favourite package manager eg. lazyvim

```lua
{
  "OTooleMichael/dnvim",
  config = function()
    require("dnvim").setup({
      -- Adds dnvim to your sh .rc file
      install_alias = true,
    })
  end,
}
```

- (skip if install_alias = true): Add the following to your bashrc / zshrc
  `alias dnvim="nvim --headless -n -c 'lua require(\"dnvim\").cli()' -- "`
- Open a new terminal
- Run it `dnvim --help`

Note: docker is required, and all commands expect to interact with running containers

## Builds

If you are running for the first time or want to attach to a new container you will need to get / build the correct neovim for your container
If we want to edit inside a container called "my-docker" then we would run

`dnvim run my-docker --build`

This will:

1. Pull the code for the "stable" build of neovim
2. unzip it
3. build a release version
4. create a symlink in the docker under `/bin/nvim`
5. copy the build nvim files back out and cache them for later
6. `docker -it exec $IMAGE nvim` - into a working nvim instance inside that docker

Note: everything will try to run for the current docker user, and depending on your setup additional permissions might be required

## Commands

```
run <name>: Ensure nvim is installed and run it in the container
--program, -p [default: "nvim"]
--build, -b [default: false]
--name, -n [required: true]

enter <name>: Enter a prepared container without additional checks and loading
--name, -n [required: true]
--program, -p [default: "nvim"]

list_builds: List all builds - dnvim keeps a cache of nvim instances that it built on different architectures

list: List all running containers (just docker ps)

help: Show help
```
