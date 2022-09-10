# Lite XL Plugin Manager

My attempt at a lite-xl plugin manager. A standalone binary that provides an easy way of installing, and uninstalling plugins from lite-xl.

Can be used by a package manager plugin that works from inside the editor and calls this.

Releases forthcoming, should be available on Windows, Mac, Linux and FreeBSD.

## Usage

```sh

lpm update && lpm install aligncarets
lpm uninstall aligncarets

lpm add https://github.com/lite-xl/lite-xl-plugins.git
lpm rm https://github.com/lite-xl/lite-xl-plugins.git

```
