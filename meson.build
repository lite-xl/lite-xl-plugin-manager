project('lpm',
    ['c'],
    license : 'LPM',
    meson_version : '>= 0.56',
)

cc = meson.get_compiler('c')

zlib_dep = dependency('zlib')
lzma_dep = dependency('liblzma')
libgit2_dep = dependency('libgit2')
libzip_dep = dependency('libzip')
lua_dep = dependency('lua')
mbedtls_dep = [
    dependency('mbedtls'),
    dependency('mbedx509'),
    dependency('mbedcrypto'),
]

microtar_lib = static_library('microtar', files('lib/microtar/src/microtar.c'))
microtar_dep = declare_dependency(
    link_whole: [microtar_lib],
    include_directories: ['lib/microtar/src']
)

lpm_source = files('src/lpm.c')
cflags = []
if get_option('static')
    lua_exe = find_program('lua')

    lpm_source += configure_file(
        capture: false,
        command: [lua_exe, '-e', 'f = string.dump(assert(load(io.lines("@INPUT0@", "L"), "=lpm.lua"))) io.open("@OUTPUT0@", "wb"):write("unsigned char lpm_luac[] = \"" .. f:gsub(".", function (c) return string.format("\\\x%02X",string.byte(c)) end) .. "\";unsigned int lpm_luac_len = " .. #f .. ";")'],
        input: files('src/lpm.lua'),
        output: 'lpm.lua.c'
    )
    cflags += '-DLPM_STATIC'
endif

lpm_exe = executable('lpm',
    lpm_source,
    dependencies: [
        zlib_dep,
        lzma_dep,
        mbedtls_dep,
        libgit2_dep,
        libzip_dep,
        lua_dep,
        microtar_dep
    ],
    c_args: cflags,
    install: true,
)

if (get_option('install_plugin'))
    lite_datadir = get_option('lite_datadir')
    if lite_datadir == ''
        # No path given, assume a default
        lite_datadir = get_option('datadir') + '/lite-xl'
    endif

    install_subdir('plugins', install_dir : lite_datadir)
endif
