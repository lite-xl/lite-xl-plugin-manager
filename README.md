# Lite XL Plugin Manager

My attempt at a lite-xl plugin manager. A standalone binary that provides an easy way of installing, and uninstalling plugins from lite-xl.

Can be used by a package manager plugin that works from inside the editor and calls this.

Releases forthcoming, should be available on Windows, Mac, Linux and FreeBSD.

Also contains a plugin_manager.lua plugin to integrate the binary with lite in the form of an easy-to-use GUI.

## Quickstart

If you have a C compiler, and `git`, and want to compile from scratch, you can do:

```
git clone git@github.com:adamharrison/lite-xl-plugin-manager.git --shallow-submodules \
  --recurse-submodules && cd lite-xl-plugin-manager && ./build.sh && ./lpm
````

If you want to build it quickly, and have the right modules installed, you can do:

```
./build.sh -lz -lssl -llibgit2
```

CI is enabled on this repository, so you can grab Windows and Linux builds from the 
`continuous` [release page](https://github.com/adamharrison/lite-xl-plugin-manager/releases/tag/continuous).

## Usage

```sh

lpm update && lpm install aligncarets
lpm uninstall aligncarets

lpm add https://github.com/lite-xl/lite-xl-plugins.git
lpm rm https://github.com/lite-xl/lite-xl-plugins.git

```

## Building

### Linux

```
./build.sh -DLPM_VERSION='"'$VERSION-x86_64-linux-`git rev-parse --short HEAD`'"'
```

### Linux to Windows

```
CC=x86_64-w64-mingw32-gcc AR=x86_64-w64-mingw32-gcc-ar WINDRES=x86_64-w64-mingw32-windres GIT2_CONFIGURE="-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY -DBUILD_CLAR=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_SYSTEM_NAME=Windows -DDLLTOOL=x86_64-w64-mingw32-dlltool" SSL_CONFIGURE=mingw ./build.sh -DLPM_VERSION='"'$VERSION-x86_64-linux-`git rev-parse --short HEAD`'"'
```
