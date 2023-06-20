project('lpm',
    ['c'],
    version : '1.0.4',
    license : 'LPM',
    meson_version : '>= 0.56',
)

cc = meson.get_compiler('c')

zlib_dep = dependency('zlib')
mbedtls_dep = dependency('mbedtls', required: false)
libgit2_dep = dependency('libgit2')
libzip_dep = dependency('libzip')
lua_dep = dependency('lua')
microtar_dep = dependency('microtar', required: false)

if not mbedtls_dep.found()
    mbedtls_dep = [
        cc.find_library('mbedtls'),
        cc.find_library('mbedx509'),
        cc.find_library('mbedcrypto'),
    ]
endif

if not microtar_dep.found()
    microtar_lib = static_library('microtar', files('lib/microtar/src/microtar.c'))

    microtar_dep = declare_dependency(
        link_whole: [microtar_lib],
        include_directories: ['lib/microtar/src']
    )

    message('Using git module for microtar')
endif

lpm_source = files('src/lpm.c')
cflags = []
if get_option('static')
    lua_exe = find_program('lua')

    lpm_source += configure_file(
        capture: false,
        command: [lua_exe, '-e', 'f = string.dump(assert(loadfile("@INPUT0@"))) io.open("@OUTPUT0@", "wb"):write("unsigned char lpm_luac[] = \"" .. f:gsub(".", function (c) return string.format("\\\x%02X",string.byte(c)) end) .. "\";unsigned int lpm_luac_len = " .. #f .. ";")'],
        input: files('src/lpm.lua'),
        output: 'lpm.lua.c'
    )
    cflags += '-DLPM_STATIC'
endif

executable('lpm', lpm_source, dependencies: [zlib_dep, mbedtls_dep, libgit2_dep, libzip_dep, lua_dep, microtar_dep], c_args: cflags)
