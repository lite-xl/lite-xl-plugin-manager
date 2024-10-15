project('lpm',
    ['c'],
    license : 'LPM',
    meson_version : '>= 0.56',
)

cc = meson.get_compiler('c')

zlib_dep = dependency('zlib')
lzma_dep = dependency('liblzma')
mbedtls_dep = dependency('mbedtls', version: '<3', required: false)
libgit2_dep = dependency('libgit2')
libzip_dep = dependency('libzip')
lua_dep = dependency('lua')

if mbedtls_dep.found()
    mbedtls_dep = [
        mbedtls_dep,
        dependency('mbedx509', version: '<3', required: true),
        dependency('mbedcrypto', version: '<3', required: true),
    ]
else
    # Using has_headers to distinguish between mbedtls2 and mbedtls3
    _mbedtls_dep = cc.find_library('mbedtls', has_headers: 'mbedtls/net.h', required: false)
    if _mbedtls_dep.found()
        mbedtls_dep = [
            _mbedtls_dep,
            cc.find_library('mbedx509'),
            cc.find_library('mbedcrypto'),
        ]
    else
        # In some cases we need to manually specify where to find mbedtls2
        message('Using fallback mbedtls definition')
        mbedtls_dep = declare_dependency(
            include_directories: ['/usr/include/mbedtls2/'],
            link_args: ['-L/usr/lib/mbedtls2', '-lmbedtls', '-lmbedx509', '-lmbedcrypto']
        )
    endif
endif

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

executable('lpm', lpm_source, dependencies: [zlib_dep, lzma_dep, mbedtls_dep, libgit2_dep, libzip_dep, lua_dep, microtar_dep], c_args: cflags)
