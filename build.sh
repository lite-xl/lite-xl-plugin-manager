#!/usr/bin/env bash

: ${CC=gcc}
: ${MAKE=make}
: ${BIN=lpm}
: ${JOBS=4}

SRCS="*.c"
LDFLAGS="$LDFLAGS -lm -pthread -static-libgcc"

[[ "$@" == "clean" ]] && rm -rf lib/libgit2/build lib/zlib/build lib/openssl/build $BIN && exit 0

# Build supporting libraries, libgit2, libz, libssl (with libcrypto), libpcre
if [[ "$@" != *"-libgit2"* ]]; then
  [ ! -e "lib/libgit2/include" ] && echo "Make sure you've cloned submodules. (git submodule update --init --depth=1)" && exit -1
  [ ! -e "lib/libgit2/build" ] && cd lib/libgit2 && mkdir build && cmake .. -DBUILD_SHARED_LIBS=OFF -DUSE_SSH=OFF && $MAKE -j $JOBS && cd ../../
  LDFLAGS="$LDFLAGS -Llib/libgit2/build -l:libgit2.a" && CFLAGS="$CFLAGS -Ilib/libgit2/build/include/git2 -Ilib/libgit2/build/include -Ilib/libgit2/include"
fi
if [[ "$@" != *"-lz"* ]]; then
  [ ! -e "lib/zlib/build" ] && cd lib/zlib && mkdir build && ../configure && $MAKE -j $JOBS && cd ../../
  LDFLAGS="$LDFLAGS -Llib/libz/build -l:libz.a" && CFLAGS="$CFLAGS -Ilib/libz"
fi
if [[ "$@" != *"-lssl"* ]]; then
  [ ! -e "lib/openssl/build" ] && cd lib/openssl && mkdir build && ../Configure && $MAKE -j $JOBS && cd ../../
  LDFLAGS="$LDFLAGS -Llib/libz/build -l:libssl.a -l:libcrypto.a" && CFLAGS="$CFLAGS -Ilib/libz"
fi
[[ "$@" != *"-llua"* ]] && CFLAGS="$CFLAGS -Ilib/lua -DMAKE_LIB=1" && SRCS="$SRCS lib/lua/onelua.c"

# Build the pre-packaged lua file into the executbale.
echo "const char* luafile = " > lpm.lua.c && cat lpm.lua | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed 's/^/"/' | sed 's/$/\\n"/' >> lpm.lua.c && echo ";" >> lpm.lua.c

[[ "$@" != *" -g "* || "$@" != *" -O"* ]] && CFLAGS="$CFLAGS -O3" && LDFLAGS="$LDFLAGS -s"
$CC $CFLAGS $SRCS $@ -o lpm $LDFLAGS -ldl  -l:libpcre.a
