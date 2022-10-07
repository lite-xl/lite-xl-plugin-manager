#!/usr/bin/env bash

: ${CC=gcc}
: ${MAKE=make}
: ${BIN=lpm}
: ${JOBS=4}

SRCS="*.c"
LDFLAGS="$LDFLAGS -lm -pthread -static-libgcc"

[[ "$@" == "clean" ]] && rm -rf lib/libgit2/build lib/zlib/build lib/openssl/build lib/curl/build lib/prefix $BIN *.exe && exit 0
[[ $OSTYPE == 'msys'* || $CC == *'mingw'* ]] && SSL_CONFIGURE="mingw64"

# Build supporting libraries, libgit2, libz, libssl (with libcrypto), libpcre
[[ "$@" != *"-lz"* ]] && CFLAGS="$CFLAGS -Ilib/zlib" && SRCS="$SRCS lib/zlib/*.c"
if [[ "$@" != *"-lz"* ]]; then
  [ ! -e "lib/zlib" ] && echo "Make sure you've cloned submodules. (git submodule update --init --depth=1)" && exit -1
  [ ! -e "lib/zlib/build" ] && cd lib/zlib && mkdir build && cd build && ../configure --prefix=`pwd`/../../prefix && $MAKE -j $JOBS && $MAKE install && cd ../../../
  LDFLAGS="$LDFLAGS -Llib/libz/build -l:libz.a" && CFLAGS="$CFLAGS -Ilib/prefix/include" && LDFLAGS="$LDFLAGS -Llib/prefix/lib -Llib/prefix/lib64"
fi
if [[ "$@" != *"-lssl"* && "$@" != *"-lcrypto"* ]]; then
  [ ! -e "lib/openssl/build" ] && cd lib/openssl && mkdir build && cd build && ../Configure --prefix=`pwd`/../../prefix $SSL_CONFIGURE && $MAKE -j $JOBS && $MAKE install_sw install_ssldirs && cd ../../../ && ln -sf lib/prefix/lib64/libcrypto.a lib/prefix/lib/libcyrpto.a
  LDFLAGS="$LDFLAGS -Llib/libz/build" && CFLAGS="$CFLAGS -Ilib/prefix/include" && LDFLAGS="$LDFLAGS -Llib/prefix/lib -Llib/prefix/lib64 -l:libssl.a -l:libcrypto.a"
fi
if [[ "$@" != *"-lgit2"* ]]; then
  [ ! -e "lib/libgit2/build" ] && cd lib/libgit2 && mkdir build && cd build && cmake .. -G="Unix Makefiles" $GIT2_CONFIGURE -DCMAKE_PREFIX_PATH=`pwd`/../../prefix -DCMAKE_INSTALL_PREFIX=`pwd`/../../prefix -DOPENSSL_ROOT_DIR=`pwd`/../../prefix -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DREGEX_BACKEND=builtin -DUSE_SSH=OFF && $MAKE -j $JOBS && $MAKE install && cd ../../../
  LDFLAGS="-Llib/libgit2/build -l:libgit2.a $LDFLAGS  -Llib/prefix/lib -Llib/prefix/lib64" && CFLAGS="$CFLAGS -Ilib/prefix/include"
fi
if [[ "$@" != *"-lcurl"* ]]; then
  [ ! -e "lib/curl/build" ] && cd lib/curl && mkdir build && cd build && cmake .. -G="Unix Makefiles" $CURL_CONFIGURE -DCURL_USE_LIBPSL=OFF -DCURL_DISABLE_LDAPS=ON -DUSE_OPENSSL=ON -DCURL_DISABLE_LDAP=ON -DCMAKE_INSTALL_PREFIX=`pwd`/../../prefix -DUSE_LIBIDN2=OFF -DENABLE_UNICODE=OFF -DBUILD_CURL_EXE=OFF -DCURL_USE_LIBSSH2=OFF -DOPENSSL_ROOT_DIR=`pwd`/../../prefix -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_LIBDIR=lib && $MAKE -j $JOBS && $MAKE install && cd ../../../
  LDFLAGS="-Llib/curl/build -Llib/prefix/lib -l:libcurl.a $LDFLAGS" && CFLAGS="$CFLAGS -Ilib/prefix/include -DCURL_STATICLIB"
fi
[[ "$@" != *"-llua"* ]] && CFLAGS="$CFLAGS -Ilib/lua -DMAKE_LIB=1" && SRCS="$SRCS lib/lua/onelua.c"

# Build the pre-packaged lua file into the executbale.
xxd -i lpm.lua > lpm.lua.c

[[ $OSTYPE != 'msys'* && $CC != *'mingw'* && $CC != "emcc" ]] && LDFLAGS=" $LDFLAGS -ldl -pthread"
[[ $OSTYPE == 'msys'* || $CC == *'mingw'* ]] && LDFLAGS="$LDFLAGS -lbcrypt -lws2_32 -lz -lwinhttp -lole32 -lcrypt32 -lrpcrt4"

[[ " $@" != *" -g"* && " $@" != *" -O"* ]] && CFLAGS="$CFLAGS -O3" && LDFLAGS="$LDFLAGS -s"
$CC $CFLAGS $SRCS $@ -o $BIN $LDFLAGS 
