#!/usr/bin/env bash

: ${CC=gcc}
: ${MAKE=make}
: ${BIN=lpm}
: ${JOBS=4}

SRCS="src/*.c"
CFLAGS="$CFLAGS -Ilib/prefix/include"
LDFLAGS="$LDFLAGS -lm -pthread -static-libgcc -Llib/prefix/lib"

[[ "$@" == "clean" ]] && rm -rf lib/libgit2/build lib/zlib/build lib/libtar/build lib/mbedtls-2.27.0/build lib/libarchive/build-tmp lib/libzip/build lib/prefix lua $BIN *.exe src/lpm.luac src/lpm.lua.c && exit 0

# Build supporting libraries, libz, libmbedtls, libmbedcrypto, libgit2, liblzma, libarchive, liblua
CMAKE_DEFAULT_FLAGS=" $CMAKE_DEFAULT_FLAGS -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=`pwd`/lib/prefix -DCMAKE_INSTALL_PREFIX=`pwd`/lib/prefix -DBUILD_SHARED_LIBS=OFF"
mkdir -p lib/prefix/include lib/prefix/lib
if [[ "$@" != *"-lz"* ]]; then
  [ ! -e "lib/zlib" ] && echo "Make sure you've cloned submodules. (git submodule update --init --depth=1)" && exit -1
  [[ ! -e "lib/zlib/build" && $OSTYPE != 'msys'* ]] && cd lib/zlib && mkdir build && cd build && ../configure --prefix=`pwd`/../../prefix && $MAKE -j $JOBS && $MAKE install && cd ../../../
  [[ ! -e "lib/zlib/build" && $OSTYPE == 'msys'* ]] && cd lib/zlib && mkdir build && $MAKE -f ../win32/Makefile.gcc -j $JOBS && cp *.a ../prefix/lib && cp *.h ../prefix/include && cd ../../
  LDFLAGS="$LDFLAGS -l:libz.a"
fi
if [[ "$@" != *"-lmbedtls"* && "$@" != *"-lmbedcrypto"* ]]; then
  [ ! -e "lib/mbedtls-2.27.0/build" ] && cd lib/mbedtls-2.27.0 && mkdir build && cd build && CFLAGS="-DMBEDTLS_MD4_C=1" cmake .. $CMAKE_DEFAULT_FLAGS  -G "Unix Makefiles" -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF $SSL_CONFIGURE && CFLAGS="-DMBEDTLS_MD4_C=1" $MAKE -j $JOBS && $MAKE install && cd ../../../
  LDFLAGS="$LDFLAGS -l:libmbedtls.a -l:libmbedx509.a -l:libmbedcrypto.a"
fi
if [[ "$@" != *"-lgit2"* ]]; then
  [ ! -e "lib/libgit2/build" ] && cd lib/libgit2 && mkdir build && cd build && cmake .. -G "Unix Makefiles" $GIT2_CONFIGURE $CMAKE_DEFAULT_FLAGS -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DREGEX_BACKEND=builtin -DUSE_SSH=OFF -DUSE_HTTPS=mbedTLS && $MAKE -j $JOBS && $MAKE install && cd ../../../
  LDFLAGS="-l:libgit2.a $LDFLAGS"
fi
if [[ "$@" != *"-lzip"* ]]; then
  [ ! -e "lib/libzip/build" ] && cd lib/libzip && mkdir build && cd build && cmake .. -G "Unix Makefiles" $CMAKE_DEFAULT_FLAGS -DBUILD_TOOLS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF -DENABLE_COMMONCRYPTO=OFF -DENABLE_GNUTLS=OFF -DENABLE_OPENSSL=OFF -DENABLE_BZIP2=OFF -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF && $MAKE -j $JOBS && $MAKE install && cd ../../../
  LDFLAGS="$LDFLAGS -l:libzip.a"
fi
if [[ "$@" != *"-ltar"* ]]; then
  [ ! -e "lib/libtar/build" ] && cd lib/libtar && mkdir build && autoreconf --force --install && cd build && ../configure --prefix=`pwd`/../../prefix && $MAKE -j $JOBS && $MAKE install && cd ../../../
  LDFLAGS="$LDFLAGS -l:libtar.a"
fi
[[ "$@" != *"-llua"* ]] && CFLAGS="$CFLAGS -Ilib/lua -DMAKE_LIB=1" && SRCS="$SRCS lib/lua/onelua.c"

# Build the pre-packaged lua file into the executbale.
[[ ! -e "lua" ]] && gcc -Ilib/lua -o lua.exe lib/lua/onelua.c -lm
./lua.exe -e 'io.open("src/lpm.luac", "wb"):write(string.dump(assert(loadfile("src/lpm.lua"))))'
xxd -i src/lpm.luac > src/lpm.lua.c

[[ $OSTYPE != 'msys'* && $CC != *'mingw'* && $CC != "emcc" ]] && LDFLAGS=" $LDFLAGS -ldl -pthread"
[[ $OSTYPE == 'msys'* || $CC == *'mingw'* ]] && LDFLAGS="$LDFLAGS -lbcrypt -lws2_32 -lz -lwinhttp -lole32 -lcrypt32 -lrpcrt4"

[[ " $@" != *" -g"* && " $@" != *" -O"* ]] && CFLAGS="$CFLAGS -O3" && LDFLAGS="$LDFLAGS -s"
$CC $CFLAGS $SRCS $@ -o $BIN $LDFLAGS 
