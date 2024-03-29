# Manifest Specification

A lite-xl manifest is a JSON file containing three different keys:

* Remotes
* Addons
* Lite-XLs

## Remotes

A simple array of string repository identifiers. A repository identifier takes
the form of a git remote url, i.e. `<url>:<ref>`. An example would be:

`https://github.com/lite-xl/lite-xl-plugin-manager.git:latest`

## Addons

Addons are the primary objects specified in this specification. An addon
consists of a series of metadata, the path to the addon in this repository,
or its location on a remote repository, or a publically accessible URL, and a
set of files to be downloaded with the plugin (usually releases, but can be
data files, or fonts, or anything else).

Addons can optionally specify a type, which determines where they're
installed. Currently three types are supported:

* `library`
* `plugin`
* `color`
* `font`
* `meta`

Addons are further classified into two organizational categories.
`singleton` addons, and `complex` addons. Addons are listed a `singleton`
if and only if they consist of exactly one file, have an empty or absent
`files` specification, and do not specify a `remote`. Singleton addons
consist of exactly one `.lua` file, named after the addon. Complex addons
are contained within a folder, and have an `init.lua` or `init.so` file that
loads other components within it.

The vast majority of addons are `singleton` `plugin`s.

### Metadata

Fields that are required are bolded.

* **`id`**: The semantic id of the addon, a string only containing `[a-z0-9\-_]`.
* **`version`**: The addon's semantic version (major.minor.revision). A string that matches the regex `^[0-9]+(\.[0-9]+){0,2}$`.
* **`mod_version`**: The mod_version this addon is compatible with.
  A string that can contain `[0-9\.]`. If `type` is `library`, this field is optional.
* `type`: An optional string that specifies the addon type. Valid values are `"plugin"`
  `"library"`, `"color"`,`"font"`, or `"meta"`. Defaults to `"plugin"`.
* `name`: The optional name of the addon.
* `description`: An optional english-language description of the addon.
* `provides`: An optional array of strings that are a shorthand of functionality
 this addon provides. Can be used as a dependency.
* `replaces`: An optional array of ids that this plugin explicitly replaces. Will always
 prefer this plugin in place of those plugins, so long as version requirements are met.
* `remote`: Optional. Specifies a public https git link where this addon is located. If present,
 denotes a **stub**.
* `dependencies`: Optionally a hash of dependencies required, or optional
  for this addon.
* `conflicts`: An optional hash of addons which conflict with this one, in the same
  format as `dependencies`.
* `tags`:  Optional freeform tags that may describe attributes of the addon.
* `path`: Optional path to the addon. If omitted, will only pull the files in
  `files`. To pull the whole repository, use `"."`.
* `arch`: Optionally a list of architectures this plugin supports. If not present, and no `files` that specify arches, assumes that plugin is valid for all architectures. If not present, and at least one `files` exists that specifies an architecture, only assumed to be valid for all `arch`es specified under `files`. Can be either an array of arch names, or can be `"*"` to explicitly specify all architectures.
* `post`: Optionally a string which represents a command to run. If presented
  with a dictionary, takes `ARCH` keys, and runs a different command per `ARCH`.
* `url`: Optionally a URL which specifies a direct download link to a single lua file.
  precludes the use of `remote`, `path`. Usually a `singleton`.
* `checksum`: Provides a checksum to check against a `url`.
* `extra`: Optionally a dictionary which holds any desired extra information.

Any keys not present in this official listing render the manifest non-conforming.
Any extra keys should be placed in `extra`. An example of keys that can be placed
in `extra` that some plugin managers/displays will use are:

* `author`: The main author of the addon.
* `license`: The license under which the addon is licensed.

### Dependencies

Depedencies are specified in an object, with the key being the `id` of the
addon depended upon, or a `provides` alias.

Dependency values are an object which contain the following keys:

* `version`: A version specifier. (see below).
* `optional`: A boolean that determines whether the dependency is optional.

### Stubs

If an addon likes, it can specify a particular `remote`; a publically acessible
git repository, accessed via HTTPS, pinned at a specific commit to be used as a
source for its data. In that case, the package manager must download the repository,
and interpret the manifest file found there to determine the addon's metadata.

This is known as a stub.

### Files

Files are objects that contain at least two keys, `url`, and `checksum`. They
can also optionally contain the `arch` and `path` keys.

* `url` represents the URL to grab the particular file from.
* `checksum` is the sha256hex checksum for the file. If `"SKIP"` is specified, the
  check is skipped. This is fine for development purposes, but any publically
  accessible manifest, should specify a checksum.
* `arch` is the lite-xl/clang architecture tuple that the file is relevant for.
  if omitted, file is to be assumed to be valid for all arhcitectures. Can be an array.
* `path` is the location to install this file inside the addon's directory.
* `optional` is a boolean that determines whether the file is an optional addition;
  if omitted, the file is assumed to be required.

If a file is an archive, of either `.zip`, `.gz` or `.tar.gz`, it will automatically
be extracted inside the addon's directory.

## Lite-XLs

Lite-XLs represent different version of lite-xl that are registered in this
repository. Lite-XLs has the following metadata, as well as a `files` array.

* `version`: A version specifier. Must take the form of x(.x)\*(-suffix).
  Suffixes can be used to denote different flavours of lite-xl.
* `mod_version`: The modversion the binary corresponds to.

### Files

The files array is identical to that of the `files` array under `addons`.
Conventionally, there should be a single file per architecture that is a
`.tar.gz` or `.zip` containing all necessary files for `lite-xl` to run.

## Version Specifiers

When asking for a version, all fields can use inequality operators to specify
the version to be asked for. As an example, `>=0.1` can be used to specify
that any version greater than `0.1` can be used.

## Example File

```yaml
{
  "addons": [ # The addons array contains a list of all addons registered on this repository.
    {
      "id": "plugin_manager", # Unique name, used to reference the plugin.
      "version": "0.1", # Semantic version.
      "description": "A GUI interface to the Adam's lite plugin manager.", # English description of the plugin.
      "path": "plugins/plugin_manager", # The path to the plugin in this repository.
      "mod_version": "3", # The mod_version this plugin corresponds to.
      "provides": [ # A list of small strings that represent functionalities this plugin provides.
        "plugin-manager"
      ],
      "files": [ # A list of files (usually binaries) this plugin requires to function.
        {
          "url": "https://github.com/adamharrison/lite-xl-plugin-manager/releases/download/v0.1/lpm.x86_64-linux", # A publically accessible URL to download from.
          "arch": "x86_64-linux", # The lite-xl/clang target tuple that represents the architecture this file is for.
          "checksum": "d27f03c850bacdf808436722cd16e2d7649683e017fe6267934eeeedbcd21096" # the sha256hex checksum that corresponds to this file.
        },
        {
          "url": "https://github.com/adamharrison/lite-xl-plugin-manager/releases/download/v0.1/lpm.x86_64-windows.exe",
          "arch": "x86_64-windows",
          "checksum": "2ed993ed4376e1840b0824d7619f2d3447891d3aa234459378fcf9387c4e4680"
        }
      ],
      "dependencies": {
        "json": {} # Depeneds on `json`, can be a plugin's name or one of its `provides`.
      }
    },
    {
      "id": "RobotoMono",
      "version": "0.1",
      "type": "font",
      "description": "Roboto Mono font.",
      "files": [ # Downloads all files listed here to USERDIR/fonts.

        {
          "url": "https://github.com/googlefonts/RobotoMono/raw/26adf5193624f05ba1743797d00bcf0e6bfe624f/fonts/ttf/RobotoMono-Regular.ttf",
          "checksum": "7432e74ff02682c6e207be405f00381569ec96aa247d232762fe721ae41b39e2"
        }
      ]
    },
    {
      "id": "json",
      "version": "1.0",
      "description": "JSON support plugin, provides encoding/decoding.",
      "type": "library",
      "path": "plugins/json.lua",
      "provides": [
        "json"
      ]
    },
    {
      "tags": ["language"],
      "description": "Syntax for .gitignore, .dockerignore and some other `.*ignore` files",
      "version": "1.0",
      "mod_version": "3",
      "remote": "https://github.com/anthonyaxenov/lite-xl-ignore-syntax:2ed993ed4376e1840b0824d7619f2d3447891d3aa234459378fcf9387c4e4680", # The remote to be used for this plugin.
      "id": "language_ignore",
      "post": {"x86-linux":"cp language_ignore.lua /tmp/somewhere-else", "x86-windows":"COPY language_ignore.lua C:\\Users\\Someone\\ignore.lua"} # Post download steps to run to fully set up the plugin. Does not run by default, requires --post.
    },
    {
      "description": "Provides a GUI to manage core and plugin settings, bindings and select color theme. Depends on widget.",
      "dependencies": {
        "toolbarview": { "version": ">=1.0" },
        "widget": { "version": ">=1.0" }
      },
      "version": "1.0",
      "mod_version": "3",
      "path": "plugins/settings.lua",
      "id": "settings"
    },
    {
      "description": "Syntax for Kaitai struct files",
      "url": "https://raw.githubusercontent.com/whiteh0le/lite-plugins/main/plugins/language_ksy.lua?raw=1", # URL directly to the singleton plugin file.
      "id": "language_ksy",
      "version": "1.0",
      "mod_version": "3",
      "checksum": "08a9f8635b09a98cec9dfca8bb65f24fd7b6585c7e8308773e7ddff9a3e5a60f", # Checksum for this particular URL.
    }
  ],
  "lite-xls": [ # An array of lite-xl releases.
    {
      "version": "2.1-simplified", # The version, followed by a release suffix defining the release flavour. The only releases that are permitted to not have suffixes are official relases.
      "mod_version": "3", # The mod_version this release corresponds to.
      "files": [ # Identical to `files` under `addons`, although these are usually simply archives to be extracted.
        {
          "arch": "x86_64-linux",
          "url": "https://github.com/adamharrison/lite-xl-simplified/releases/download/v2.1/lite-xl-2.1.0-simplified-x86_64-linux.tar.gz",
          "checksum": "b5087bd03fb491c9424485ba5cb16fe3bb0a6473fdc801704e43f82cdf960448"
        },
        {
          "arch": "x86_64-windows",
          "url": "https://github.com/adamharrison/lite-xl-simplified/releases/download/v2.1/lite-xl-2.1.0-simplified-x86_64-windows.zip",
          "checksum": "f12cc1c172299dd25575ae1b7473599a21431f9c4e14e73b271ff1429913275d"
        }
      ]
    },
    {
      "version": "2.1-simplified-enhanced",
      "mod_version": "3",
      "files": [
        {
          "arch": "x86_64-linux",
          "url": "https://github.com/adamharrison/lite-xl-simplified/releases/download/v2.1/lite-xl-2.1.0-simplified-x86_64-linux-enhanced.tar.gz",
          "checksum": "4625c7aac70a2834ef5ce5ba501af2d72d203441303e56147dcf8bcc4b889e40"
        },
        {
          "arch": "x86_64-windows",
          "url": "https://github.com/adamharrison/lite-xl-simplified/releases/download/v2.1/lite-xl-2.1.0-simplified-x86_64-windows-enhanced.zip",
          "checksum": "5ac009e3d5a5c99ca7fbd4f6b5bd4e25612909bf59c0925eddb41fe294ce28a4"
        }
      ]
    }
  ],
  "remotes": [ # A list of remote specifiers. The plugin manager will pull these in and add them as additional repositories if specified to do so with a flag.
    "https://github.com/lite-xl/lite-xl-plugins.git:2.1",
    "https://github.com/adamharrison/lite-xl-simplified.git:v2.1"
  ]
}
```

