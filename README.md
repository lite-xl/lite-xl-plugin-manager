# Lite XL Plugin Manager (lpm)

![image](https://user-images.githubusercontent.com/1034518/216748882-3ae8c8d4-a767-4d97-acc4-c1cde7e3e331.png)

A standalone binary that provides an easy way of installing, and uninstalling
plugins from lite-xl, as well as different version of lite-xl.

Can be used by a package manager plugin that works from inside the editor
and calls this binary.

Releases forthcoming, should be available on Windows, Mac, Linux and FreeBSD.

Also contains a plugin_manager.lua plugin to integrate the binary with lite in
the form of an easy-to-use GUI.

By default in releases, `lpm` will automatically consume the `manifest.json`
in the `latest` branch of this repository, which corresponds to the most
recent versioned release.

Conforms to [SCPS3](https://github.com/adamharrison/straightforward-c-project-standard#SCPS3).

## Status

Please note that `lpm` has currently not reached version 1.0. As such, it is still heavily in flux, and may change without notice.

Once 1.0 is released, changleogs will be produced, and a more stable process that uses semver will be used.

## Specification

For details about the `manifest.json` files that `lpm` consumes,
[see here](SPEC.md).

## Quickstart

The fastest way to get started with lpm is to simply pull a release.

```
wget https://github.com/lite-xl/lite-xl-plugin-manager/releases/download/latest/lpm.x86_64-linux -O lpm && chmod +x lpm
```

If you have a C compiler, and `git`, and want to compile from scratch,
you can do:

```
git clone git@github.com:lite-xl/lite-xl-plugin-manager.git \
  --shallow-submodules --recurse-submodules && cd lite-xl-plugin-manager &&\
  ./build.sh -DLPM_STATIC && ./lpm
````

If you want to build it quickly, and have the right modules installed, you can
do:

```
./build.sh -lgit2 -lzip -llua -lm -lmbedtls -lmbedx509 -lmbedcrypto -lz -DLPM_STATIC
```

OR

```
gcc src/lpm.c lib/microtar/src/microtar.c -Ilib/microtar/src -lz -lgit2 \
  -lzip -llua -lm -lmbedtls -lmbedx509 -lmbedcrypto -o lpm
```

CI is enabled on this repository, so you can grab Windows and Linux builds from the
`continuous` [release page](https://github.com/lite-xl/lite-xl-plugin-manager/releases/tag/continuous),
which is a nightly, or the `latest` [release page](https://github.com/lite-xl/lite-xl-plugin-manager/releases/tag/latest),
which holds the most recent released version.

There are also tagged releases, for specified versions.

You can get a feel for how to use `lpm` by typing `./lpm --help`.

## Supporting Libraries

As seen in the `lib` folder, the following external libraries are used to
build `lpm`:

* `lua` (core program written in)
* `mbedtls` (https/SSL support)
* `libgit2` (accessing git repositories directly)
* `libz` (supporting library for everything)
* `libzip` (for unpacking .zip files)
* `libmicrotar` (for unpacking .tar.gz files)

## Supported Platforms

`lpm` should work on all platforms `lite-xl` works on; but releases are offered for the following:

* Windows x86_64
* Linux x86_64
* MacOS x86_64
* MacOS aarch64
* Android x86_64
* Android x86
* Android aarch64
* Android armv7a

Experimental support (i.e. doesn't work) exists for the following platforms:

* Linux riscv64

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

## Building & Running

### Linux & MacOS & Windows MSYS

```
./build.sh clean && ./build.sh -DLPM_STATIC && ./lpm
```

### Linux -> Windows

```
./build.sh clean && CC=x86_64-w64-mingw32-gcc AR=x86_64-w64-mingw32-gcc-ar WINDRES=x86_64-w64-mingw32-windres \
CMAKE_DEFAULT_FLAGS="-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER\ -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=NEVER -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=NEVER -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_INCLUDE_PATH=/usr/share/mingw-w64/include"\
  GIT2_CONFIGURE="-DDLLTOOL=x86_64-w64-mingw32-dlltool" ./build.sh -DLPM_STATIC -DLPM_VERSION='"'$VERSION-x86_64-windows-`git rev-parse --short HEAD`'"'
```

## Tests

To run the test suite, you can use `lpm` to execute the test by doing `./lpm test t/run.lua`. use `FAST=1 ./lpm test t/run.lua` to avoid the costs of tearing down and building up suites each time.

## Bugs

If you find a bug, please create an issue with the following information:

* Your operating system.
* The commit or version of LPM you're using (`lpm --version` for releases).
* The exact steps to reproduce in LPM invocations, if possible from a fresh LPM install (targeting an empty folder with `--userdir`).
