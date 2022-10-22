# Lite XL Plugin Manager

A standalone binary that provides an easy way of installing, and uninstalling
plugins from lite-xl, as well as different version fo lite-xl.

Can be used by a package manager plugin that works from inside the editor 
and calls this binary.

Releases forthcoming, should be available on Windows, Mac, Linux and FreeBSD.

Also contains a plugin_manager.lua plugin to integrate the binary with lite in
the form of an easy-to-use GUI.

By default in releases, `lpm` will automatically consume the specification 
in the `latest` branch of this repository.

## Specification

For details about the `manifest.json` files that `lpm` consumes, 
[see here](SPEC.md).

## Quickstart

If you have a C compiler, and `git`, and want to compile from scratch, 
you can do:

```
git clone git@github.com:adamharrison/lite-xl-plugin-manager.git \
  --shallow-submodules --recurse-submodules && cd lite-xl-plugin-manager &&\
  ./build.sh && ./lpm
````

If you want to build it quickly, and have the right modules installed, you can
do:

```
./build.sh -larchive -llzma -lz -lssl -lgit2 -lz -lcurl -lcrypto -llua
```

CI is enabled on this repository, so you can grab Windows and Linux builds from the 
`continuous` [release page](https://github.com/adamharrison/lite-xl-plugin-manager/releases/tag/continuous).

You can get a feel for how to use `lpm` by typing `./lpm --help`.

## Supporting Libraries

Unlike lite, due to the precense of the beast of a library that is OpenSSL, 
I've made no attempt to limit the amount of libraries being linked in here, 
I'm only ensuring that everything can be linked statically as much as possible.
As seen with the `lib` folder, the following external libraries are used to 
build `lpm`:

* `lua` (core program written in)
* `OpenSSL` (https/SSL support)
* `libgit2` (accessing git repositories directly)
* `liblzma` (supporting library for archives)
* `libz` (supporting library for everything)
* `libcurl` (for fetching .tar.gz and .zip files)
* `libarchive` (for unpacking .tar.gz and .zip files)

## Use in CI

To make pre-fab lite builds, you can easily use `lpm` in CI. If you had a linux build container, you could do something like:

```sh
curl https://github.com/adamharrison/lite-xl-plugin-manager/releases/download/v0.1/lpm.x86_64-linux > lpm
export LITE_USERDIR=lite-xl/data && export LPM_CACHE=/tmp/cache
./lpm add https://github.com/adamharrison/lite-xl-plugin-manager && ./lpm install plugin_manager lsp
```

## Usage

```sh
lpm install aligncarets
lpm uninstall aligncarets
```

```sh
lpm --help
```

## Building

### Linux

```
./build.sh -DLPM_VERSION='"'0.1-x86_64-linux-`git rev-parse --short HEAD`'"'
```

### Linux to Windows

```
CC=x86_64-w64-mingw32-gcc AR=x86_64-w64-mingw32-gcc-ar WINDRES=x86_64-w64-mingw32-windres LZMA_CONFIGURE="--host=x86_64-w64-mingw32" ARCHIVE_CONFIGURE="-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_SYSTEM_NAME=Windows" CURL_CONFIGURE="-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_SYSTEM_NAME=Windows" GIT2_CONFIGURE="-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY -DBUILD_CLAR=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_SYSTEM_NAME=Windows -DDLLTOOL=x86_64-w64-mingw32-dlltool" SSL_CONFIGURE=mingw ./build.sh -DLPM_VERSION='"'$VERSION-x86_64-windows-`git rev-parse --short HEAD`'"'
```

