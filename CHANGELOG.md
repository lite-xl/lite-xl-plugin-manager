# 1.0.10

* We now fully clear bottles when reconstructing them avoiding confusion/bugs over old bottles.
* A `--config` flag has been added that allows you to specify a user config when running.

# 1.0.9

* `lpm` now automatically extracts and chmod's `.gz` files.
* Added in preprocessor guard for shallow cloning to allow non-bleeding-edge `libgit2` linkings.
* Fixed bug where dangling symlinks of lite binaries in `$PATH` would cause an error.

# 1.0.8

* Autoflush stderr, so that certain windows terminals don't get blank prompts.
* Added method to grab and install orphan plugins from one-off repos.
* Passed debug build status through to underlying libraries.
* Fixed bug where we compared sizes of folders to determined if they were the same.
* Made it so you can set the define LPM_DEFAULT_REPOSITORY if you want to build a custom manager.
* Made it so tests run more smoothly, and will always use the lpm you compiled, instead of system lpm.
* Normalized paths on windows to backslashes for consistency.

# 1.0.7

* Upgraded submodules.
* Moved mbedtls to a submodule, as there was an erroneous resaon why it wasn't, and upgraded it to fix #33, which occurs due to a clang compiler bug.
* Improved debuggability with regards to tls and the `--trace` flag.
* Fixed some small bugs with `plugin_manager` that nonetheless rendered it inoperable.
* Fixed issues with getting the absolute path of symlinks.
* Fixed issues with symlinks that are broken not getting detected at all.
* Allowed for dashes in auto-generated ids.
* Fixed a bug that stopped things form working when explicitly calling `init`.
* Allowed `run` to use `--remotes`.
* Fixed bug for auto-detecting data directories, when determining system `lite-xl`.

# 1.0.6

* Changed from full git cloning to shallow cloning.
* Fixed major bug on windows.
* Moved `json` to the `libraries` folder.

# 1.0.5

* Marked `lpm` for `plugin_manager` as optional.
* Made `--help` and `help` output on `stdout`, rather than `stderr`, following convention.
* Removed system configuration search paths for `git`.
* Removed `xxd` as a build dependency.
* Colorized some extra messages.
* Made repository fetching atomic.
* Made sure that `common.path` checked for executability and non-folderness.
* Added in meson as a build system (thank you @Jan200101).

# 1.0.4

* Added in metapackage support into manifest and SPEC.
* Fixed issue with system lite-xls not being detected correctly.
* Colorized output by default.
* Added in NO_COLOR standard.
* Updated SPEC and fixed a few spelling/grammatical errors.

# 1.0.3

* Fixed a major issue with windows that causes a crash.
* Ensured that the simplified releases are pointing to the right place.

# 1.0.2

* Suppresses the progress bar by default if we're not on a TTY.
* Added `url` as a field to `SPEC.md`.
* Modified `run` so that it'll use the system version if you don't specify one.
* Added the ability to specify a repo url as part of `run`, so you can easily test new plugin branches and their plugins without actually modifying your lpm state.
* Fixed a few typos.
* Fixed issue with `run` not handling cases where plugins were either orphaned or core plugins, which would cause the bottle to be incorrectly constructed.
* Fixed issue where you could add non-numeric lite versions.
* Fixed issue where tables generated with lpm didn't annotate non-remote url plugins with \*.
* Fixed a memory leak.
* Added in warning to let people know when stubs are mismatching versions.
* Added in warning when we cannot acquire an lpm global lock, and also made it so we do not lock upon running something.
* Better error handling for invalid manifests, specifically when paths for plugins don't exist.
* Fixed issue with permissions not being recorded correctly when extracting from a zip file.
* Added in --reinstall flag.


# 1.0.1

* Fixed an issue with --no-install-optional being non-functional.
* Modified fopen calls to use `_wfopen` where appropriate to improve UTF-8 support on windows.
* Fixed some defaults around specifiying explicit binaries and datadirs for certain pathways.
* Added this CHANGELOG.md.

# 1.0.0

Initial release of `lpm`.

```
Usage: lpm COMMAND [...ARGUMENTS] [--json] [--userdir=directory]
  [--cachedir=directory] [--quiet] [--version] [--help] [--remotes]
  [--ssl-certs=directory/file] [--force] [--arch=x86_64-linux]
  [--assume-yes] [--no-install-optional] [--verbose] [--mod-version=3]
  [--datadir=directory] [--binary=path] [--symlink] [--post]

LPM is a package manager for `lite-xl`, written in C (and packed-in lua).

It's designed to install packages from our central github repository (and
affiliated repositories), directly into your lite-xl user directory. It can
be called independently, for from the lite-xl `addon_manager` addon.

LPM will always use https://github.com/lite-xl/lite-xl-plugin-manager as its base
repository, if none are present, and the cache directory does't exist,
but others can be added, and this base one can be removed.

It has the following commands:

  lpm init [repo 1] [repo 2] [...]         Implicitly called before all commands
                                           if necessary, but can be called
                                           independently to save time later, or
                                           to set things up differently.

                                           Adds the built in repository to your
                                           repository list, and all `remotes`.

                                           If repo 1 ... is specified, uses that
                                           list of repositories as the base instead.

                                           If "none" is specified, initializes
                                           an empty repository list.

  lpm repo list                            List all extant repos.
  lpm [repo] add <repository remote>       Add a source repository.
    [...<repository remote>]
  lpm [repo] rm <repository remote>        Remove a source repository.
    [...<repository remote>]
  lpm [repo] update [<repository remote>]  Update all/the specified repos.
    [...<repository remote>]
  lpm [plugin|library|color] install       Install specific addons.
    <addon id>[:<version>]                 If installed, upgrades.
    [...<addon id>:<version>]
  lpm [plugin|library|color] uninstall     Uninstall the specific addon.
    <addon id> [...<addon id>]
  lpm [plugin|library|color] reinstall     Uninstall and installs the specific addon.
   <addon id> [...<addon id>]

  lpm [plugin|library|color] list          List all/associated addons.
   <remote> [...<remote>]

  lpm upgrade                              Upgrades all installed addons
                                           to new version if applicable.
  lpm [lite-xl] install <version>          Installs lite-xl. Infers the
    [binary] [datadir]                     paths on your system if not
                                           supplied. Automatically
                                           switches to be your system default
                                           if path auto inferred.
  lpm lite-xl add <version> <path>         Adds a local version of lite-xl to
                                           the managed list, allowing it to be
                                           easily bottled.
  lpm lite-xl remove <path>                Removes a local version of lite-xl
                                           from the managed list.
  lpm [lite-xl] switch <version> [<path>]  Sets the active version of lite-xl
                                           to be the specified version. Auto-detects
                                           current install of lite-xl; if none found
                                           path can be specified.
  lpm lite-xl list [name pattern]          Lists all installed versions of
     [...filters]                          lite-xl. Can specify the flags listed
                                           in the filtering seciton.
  lpm run <version> [...addons]            Sets up a "bottle" to run the specified
                                           lite version, with the specified addons
                                           and then opens it.
  lpm describe [bottle]                    Describes the bottle specified in the form
                                           of a list of commands, that allow someone
                                           else to run your configuration.
  lpm table <manifest path> [readme path]  Formats a markdown table of all specified
                                           addons. Dumps to stdout normally, but if
                                           supplied a readme, will remove all tables
                                           from the readme, and append the new one.

  lpm purge                                Completely purge all state for LPM.
  lpm -                                    Read these commands from stdin in
                                           an interactive print-eval loop.
  lpm help                                 Displays this help text.


Flags have the following effects:

  --json                   Performs all communication in JSON.
  --userdir=directory      Sets the lite-xl userdir manually.
                           If omitted, uses the normal lite-xl logic.
  --cachedir=directory     Sets the directory to store all repositories.
  --tmpdir=directory       During install, sets the staging area.
  --datadir=directory      Sets the data directory where core addons are located
                           for the system lite-xl.
  --binary=path            Sets the lite-xl binary path for the system lite-xl.
  --verbose                Spits out more information, including intermediate
                           steps to install and whatnot.
  --quiet                  Outputs nothing but explicit responses.
  --mod-version=version    Sets the mod version of lite-xl to install addons.
  --version                Returns version information.
  --help                   Displays this help text.
  --ssl-certs              Sets the SSL certificate store. Can be a directory,
                           or path to a certificate bundle.
  --arch=architecture      Sets the architecture (default: x86_64-linux).
  --assume-yes             Ignores any prompts, and automatically answers yes
                           to all.
  --no-install-optional    On install, anything marked as optional
                           won't prompt.
  --trace                  Dumps to STDERR useful debugging information, in
                           particular information relating to SSL connections,
                           and other network activity.
  --progress               For JSON mode, lines of progress as JSON objects.
                           By default, JSON does not emit progress lines.
  --symlink                Use symlinks where possible when installing modules.
                           If a repository contains a file of the same name as a
                           `files` download in the primary directory, will also
                           symlink that, rather than downloading.

The following flags are useful when listing plugins, or generating the plugin
table. Putting a ! infront of the string will invert the filter. Multiple
filters of the same type can be specified to create an OR relationship.

  --author=author          Only display addons by the specified author.
  --tag=tag                Only display addons with the specified tag.
  --stub=git/file/false    Only display the specified stubs.
  --dependency=dep         Only display addons that have a dependency on the
                           specified addon.
  --status=status          Only display addons that have the specified status.
  --type=type              Only display addons on the specified type.
  --name=name              Only display addons that have a name which matches the
                           specified filter.

There also several flags which are classified as "risky", and are never enabled
in any circumstance unless explicitly supplied.

  --force                  Ignores checksum inconsistencies.
  --post                   Run post-install build steps. Must be explicitly enabled.
                           Official repositories must function without this
                           flag being needed; generally they must provide
                           binaries if there is a native compilation step.
  --remotes                Automatically adds any specified remotes in the
                           repository to the end of the resolution list.
  --ssl-certs=noverify     Ignores SSL certificate validation. Opens you up to
                           man-in-the-middle attacks.

There exist also other debug commands that are potentially useful, but are
not commonly used publically.

  lpm test [test file]               Runs the specified test suite.
  lpm table <manifest> [...filters]  Generates markdown table for the given
                                     manifest. Used by repositories to build
                                     READMEs.
  lpm download <url> [target]        Downloads the specified URL to stdout,
                                     or to the specified target file.
  lpm extract <file.[tar.gz|zip]>    Extracts the specified archive at
    [target]                         target, or the current working directory.
```
