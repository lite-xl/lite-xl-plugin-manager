#!/usr/bin/env bash

: ${CC=gcc}
: ${MAKE=make}
: ${BIN=lpm}
: ${JOBS=4}

SRCS="*.c"
LDFLAGS="$LDFLAGS -lm -pthread -static-libgcc"

[[ "$@" == "clean" ]] && rm -rf lib/libgit2/build lib/zlib/build lib/openssl/build lib/prefix $BIN *.exe && exit 0
[[ $OSTYPE == 'msys'* || $CC == *'mingw'* ]] && SSL_CONFIGURE="mingw64"

# Build supporting libraries, libgit2, libz, libssl (with libcrypto), libpcre
if [[ "$@" != *"-lz"* ]]; then
  [ ! -e "lib/zlib/build" ] && cd lib/zlib && mkdir build && cd build && ../configure --prefix=`pwd`/../../prefix && $MAKE -j $JOBS && $MAKE install && cd ../../../
  LDFLAGS="$LDFLAGS -Llib/libz/build -l:libz.a" && CFLAGS="$CFLAGS -Ilib/prefix/include" && LDFLAGS="$LDFLAGS -Llib/prefix/lib -Llib/prefix/lib64"
fi
if [[ "$@" != *"-lssl"* && "$@" != *"-lcrypto"* ]]; then
  [ ! -e "lib/openssl/build" ] && cd lib/openssl && mkdir build && cd build && ../Configure --prefix=`pwd`/../../prefix $SSL_CONFIGURE && $MAKE -j $JOBS && $MAKE install && cd ../../../ && ln -sf lib/prefix/lib64/libcrypto.a lib/prefix/lib/libcyrpto.a
  LDFLAGS="$LDFLAGS -Llib/libz/build" && CFLAGS="$CFLAGS -Ilib/prefix/include" && LDFLAGS="$LDFLAGS -Llib/prefix/lib -Llib/prefix/lib64 -l:libssl.a -l:libcrypto.a"
fi
if [[ "$@" != *"-lgit2"* ]]; then
  [ ! -e "lib/libgit2/include" ] && echo "Make sure you've cloned submodules. (git submodule update --init --depth=1)" && exit -1
  [ ! -e "lib/libgit2/build" ] && cd lib/libgit2 && mkdir build && cd build && cmake .. $GIT2_CONFIGURE -DCMAKE_PREFIX_PATH=`pwd`/../../prefix -DCMAKE_INSTALL_PREFIX=`pwd`/../../prefix -DOPENSSL_ROOT_DIR=`pwd`/../../prefix -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DREGEX_BACKEND=builtin -DUSE_SSH=OFF && $MAKE -j $JOBS && $MAKE install && cd ../../../
  LDFLAGS="-Llib/libgit2/build -l:libgit2.a $LDFLAGS" && CFLAGS="$CFLAGS -Ilib/prefix/include" && LDFLAGS="$LDFLAGS -Llib/prefix/lib -Llib/prefix/lib64"
fi
[[ "$@" != *"-llua"* ]] && CFLAGS="$CFLAGS -Ilib/lua -DMAKE_LIB=1" && SRCS="$SRCS lib/lua/onelua.c"

# Build the pre-packaged lua file into the executbale.
xxd -i lpm.lua > lpm.lua.c

[[ $OSTYPE != 'msys'* && $CC != *'mingw'* && $CC != "emcc" ]] && LDFLAGS=" $LDFLAGS -ldl -pthread -lz"
[[ $OSTYPE == 'msys'* || $CC == *'mingw'* ]] && LDFLAGS="$LDFLAGS -lws2_32 -lz -lwinhttp -lole32 -lcrypt32 -lrpcrt4"

[[ "$@" != *" -g "* || "$@" != *" -O"* ]] && CFLAGS="$CFLAGS -O3" && LDFLAGS="$LDFLAGS -s"
$CC $CFLAGS $SRCS $@ -o lpm $LDFLAGS 
