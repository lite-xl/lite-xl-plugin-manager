#ifdef _WIN32
  #include <direct.h>
  #include <winsock2.h>
  #include <windows.h>
  #include <fileapi.h>
#else
  #include <netdb.h>
  #include <sys/socket.h>
  #include <arpa/inet.h>
  #define MAX_PATH PATH_MAX
#endif

#include <git2.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <ctype.h>
#include <dirent.h>
#include <unistd.h>
#include <fcntl.h>

#include <sys/stat.h>
#include <sys/file.h>
#include <git2.h>
#include <mbedtls/sha256.h>
#include <mbedtls/x509.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/ssl.h>
#include <mbedtls/error.h>
#include <mbedtls/net.h>
#ifdef MBEDTLS_DEBUG_C
  #include <mbedtls/debug.h>
#endif

#include <zlib.h>
#include <microtar.h>
#include <zip.h>

#ifdef __APPLE__
  #include <Security/Security.h>
#endif


#if _WIN32
static LPCWSTR lua_toutf16(lua_State* L, const char* str) {
  if (str && str[0] == 0)
    return L"";
  int len = MultiByteToWideChar(CP_UTF8, 0, str, -1, NULL, 0);
  if (len > 0) {
    LPWSTR output = (LPWSTR) malloc(sizeof(WCHAR) * len);
    if (output) {
      len = MultiByteToWideChar(CP_UTF8, 0, str, -1, output, len);
      if (len > 0) {
        lua_pushlstring(L, (char*)output, len * 2);
        free(output);
        return (LPCWSTR)lua_tostring(L, -1);
      }
      free(output);
    }
  }
  luaL_error(L, "can't convert utf8 string");
  return NULL;
}

static const char* lua_toutf8(lua_State* L, LPCWSTR str) {
  int len = WideCharToMultiByte(CP_UTF8, 0, str, -1, NULL, 0, NULL, NULL);
  if (len > 0) {
    char* output = (char *) malloc(sizeof(char) * len);
    if (output) {
      len = WideCharToMultiByte(CP_UTF8, 0, str, -1, output, len, NULL, NULL);
      if (len) {
        lua_pushlstring(L, output, len);
        free(output);
        return lua_tostring(L, -1);
      }
      free(output);
    }
  }
  luaL_error(L, "can't convert utf16 string");
  return NULL;
}
#endif

static FILE* lua_fopen(lua_State* L, const char* path, const char* mode) {
  #ifdef _WIN32
    FILE* file = _wfopen(lua_toutf16(L, path), lua_toutf16(L, mode));
    lua_pop(L, 2);
    return file;
  #else
    return fopen(path, mode);
  #endif
}

static char hex_digits[] = "0123456789abcdef";
static int lpm_hash(lua_State* L) {
  size_t len;
  const char* data = luaL_checklstring(L, 1, &len);
  const char* type = luaL_optstring(L, 2, "string");
  static const int digest_length = 32;
  unsigned char buffer[digest_length];
  mbedtls_sha256_context hash_ctx;
  mbedtls_sha256_init(&hash_ctx);
  mbedtls_sha256_starts_ret(&hash_ctx, 0);
  if (strcmp(type, "file") == 0) {
    FILE* file = lua_fopen(L, data, "rb");
    if (!file) {
      mbedtls_sha256_free(&hash_ctx);
      return luaL_error(L, "can't open %s", data);
    }
    while (1) {
      unsigned char chunk[4096];
      size_t bytes = fread(chunk, 1, sizeof(chunk), file);
      mbedtls_sha256_update_ret(&hash_ctx, chunk, bytes);
      if (bytes < sizeof(chunk))
        break;
    }
    fclose(file);
  } else {
    mbedtls_sha256_update_ret(&hash_ctx, data, len);
  }
  mbedtls_sha256_finish_ret(&hash_ctx, buffer);
  mbedtls_sha256_free(&hash_ctx);
  char hex_buffer[digest_length * 2 + 1];
  for (size_t i = 0; i < digest_length; ++i) {
    hex_buffer[i*2+0] = hex_digits[buffer[i] >> 4];
    hex_buffer[i*2+1] = hex_digits[buffer[i] & 0xF];
  }
  lua_pushlstring(L, hex_buffer, digest_length * 2);
  return 1;
}


int lpm_symlink(lua_State* L) {
  #ifndef _WIN32
    if (symlink(luaL_checkstring(L, 1), luaL_checkstring(L, 2)))
      return luaL_error(L, "can't create symlink %s: %s", luaL_checkstring(L, 2), strerror(errno));
    return 0;
  #else
    return luaL_error(L, "can't create symbolic link %s: your operating system sucks", luaL_checkstring(L, 2));
  #endif
}

int lpm_chmod(lua_State* L) {
  #ifdef _WIN32
    if (_wchmod(lua_toutf16(L, luaL_checkstring(L, 1)), luaL_checkinteger(L, 2)))
  #else
    if (chmod(luaL_checkstring(L, 1), luaL_checkinteger(L, 2)))
  #endif
      return luaL_error(L, "can't chmod %s: %s", luaL_checkstring(L, 1), strerror(errno));
  return 0;
}

static int lpm_ls(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);

#ifdef _WIN32
  lua_settop(L, 1);
  lua_pushstring(L, path[0] == 0 || strchr("\\/", path[strlen(path) - 1]) != NULL ? "*" : "\\*");
  lua_concat(L, 2);
  path = lua_tostring(L, -1);

  WIN32_FIND_DATAW fd;
  HANDLE find_handle = FindFirstFileExW(lua_toutf16(L, path), FindExInfoBasic, &fd, FindExSearchNameMatch, NULL, 0);
  if (find_handle == INVALID_HANDLE_VALUE)
    return luaL_error(L, "can't ls %s: %d", path, GetLastError());
  char mbpath[MAX_PATH * 4]; // utf-8 spans 4 bytes at most
  int len, i = 1;
  lua_newtable(L);

  do {
    if (wcscmp(fd.cFileName, L".") == 0) { continue; }
    if (wcscmp(fd.cFileName, L"..") == 0) { continue; }

    len = WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, mbpath, MAX_PATH * 4, NULL, NULL);
    if (len == 0) { break; }
    lua_pushlstring(L, mbpath, len - 1); // len includes \0
    lua_rawseti(L, -2, i++);
  } while (FindNextFileW(find_handle, &fd));

  int err = GetLastError();
  FindClose(find_handle);
  if (err != ERROR_NO_MORE_FILES)
    return luaL_error(L, "can't ls %s: %d", path, GetLastError());
  return 1;
#else
  DIR *dir = opendir(path);
  if (!dir)
    return luaL_error(L, "can't ls %s: %d", path, strerror(errno));
  lua_newtable(L);
  int i = 1;
  struct dirent *entry;
  while ( (entry = readdir(dir)) ) {
    if (strcmp(entry->d_name, "." ) == 0) { continue; }
    if (strcmp(entry->d_name, "..") == 0) { continue; }
    lua_pushstring(L, entry->d_name);
    lua_rawseti(L, -2, i);
    i++;
  }
  closedir(dir);
  return 1;
#endif
}

static int lpm_rmdir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
#ifdef _WIN32
  if (!RemoveDirectoryW(lua_toutf16(L, path)))
    return luaL_error(L, "can't rmdir %s: %d", path, GetLastError());
#else
  if (remove(path))
    return luaL_error(L, "can't rmdir %s: %s", path, strerror(errno));
#endif
  return 0;
}

static int lpm_mkdir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
#ifdef _WIN32
  int err = _wmkdir(lua_toutf16(L, path));
#else
  int err = mkdir(path, S_IRUSR|S_IWUSR|S_IXUSR|S_IRGRP|S_IXGRP|S_IROTH|S_IXOTH);
#endif
  if (err < 0)
    return luaL_error(L, "can't mkdir %s: %s", path, strerror(errno));
  return 0;
}

static int lpm_stat(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  char fullpath[MAX_PATH];
#ifdef _WIN32
  struct _stat s;
  LPCWSTR wpath = lua_toutf16(L, path);
  int err = _wstat(wpath, &s);
  LPCWSTR wfullpath = _wfullpath(fullpath, wpath, MAX_PATH);
  if (!wfullpath) return 0;
  const char *abs_path = lua_toutf8(L, wfullpath);
#else
  struct stat s;
  int err = lstat(path, &s);
  const char *abs_path = !err ? realpath(path, fullpath) : NULL;
#endif
  if (err || !abs_path) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }
  lua_newtable(L);
  lua_pushstring(L, abs_path); lua_setfield(L, -2, "abs_path");
  lua_pushvalue(L, 1); lua_setfield(L, -2, "path");

#if __linux__
  if (S_ISLNK(s.st_mode)) {
    char buffer[PATH_MAX];
    ssize_t len = readlink(path, buffer, sizeof(buffer));
    if (len < 0)
      return 0;
    lua_pushlstring(L, buffer, len);
  } else
    lua_pushnil(L);
  lua_setfield(L, -2, "symlink");
  if (S_ISLNK(s.st_mode))
    err = stat(path, &s);
  if (err)
    return 1;
#endif
  lua_pushinteger(L, s.st_mtime); lua_setfield(L, -2, "modified");
  lua_pushinteger(L, s.st_size); lua_setfield(L, -2, "size");
  lua_pushinteger(L, s.st_mode); lua_setfield(L, -2, "mode");
  if (S_ISREG(s.st_mode)) {
    lua_pushstring(L, "file");
  } else if (S_ISDIR(s.st_mode)) {
    lua_pushstring(L, "dir");
  } else {
    lua_pushnil(L);
  }
  lua_setfield(L, -2, "type");
  return 1;
}
/** END STOLEN LITE CODE **/

static const char* git_error_last_string() {
  const git_error* last_error = git_error_last();
  return last_error->message;
}

static int git_get_id(git_oid* commit_id, git_repository* repository, const char* name) {
  int length = strlen(name);
  int is_hex = length == 40;
  for (int i = 0; is_hex && i < length; ++i)
    is_hex = isxdigit(name[i]);
  if (!is_hex)
    return git_reference_name_to_id(commit_id, repository, name);
  return git_oid_fromstr(commit_id, name);
}

static git_repository* luaL_checkgitrepo(lua_State* L, int index) {
  const char* path = luaL_checkstring(L, index);
  git_repository* repository;
  if (git_repository_open(&repository, path))
    return (void*)(long long)luaL_error(L, "git open error: %s", git_error_last_string());
  return repository;
}


static git_commit* git_retrieve_commit(git_repository* repository, const char* commit_name) {
  git_oid commit_id;
  git_commit* commit;
  if (git_get_id(&commit_id, repository, commit_name) || git_commit_lookup(&commit, repository, &commit_id))
    return NULL;
  return commit;
}

// We move this out of main, because this is a significantly expensive function,
// and we don't need to call it every time we run lpm.
static int git_initialized = 0;
static int git_cert_type = 0;
static char git_cert_path[MAX_PATH];
static void git_init() {
  if (!git_initialized) {
    git_libgit2_init();
    if (git_cert_type)
      git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, git_cert_type == 2 ? git_cert_path : NULL, git_cert_type == 1 ? git_cert_path : NULL);
    git_initialized = 1;
  }
}


static int lpm_reset(lua_State* L) {
  git_init();
  git_repository* repository = luaL_checkgitrepo(L, 1);
  const char* commit_name = luaL_checkstring(L, 2);
  const char* type = luaL_checkstring(L, 3);
  git_commit* commit = git_retrieve_commit(repository, commit_name);
  if (!commit) {
    git_repository_free(repository);
    return luaL_error(L, "git retrieve commit error: %s", git_error_last_string());
  }
  git_reset_t reset_type = GIT_RESET_SOFT;
  if (strcmp(type, "mixed") == 0)
    reset_type = GIT_RESET_MIXED;
  else if (strcmp(type, "hard") == 0)
    reset_type = GIT_RESET_HARD;
  int result = git_reset(repository, (git_object*)commit, reset_type, NULL);
  git_commit_free(commit);
  git_repository_free(repository);
  if (result)
    return luaL_error(L, "git reset error: %s", git_error_last_string());
  return 0;
}

static int lpm_revparse(lua_State* L) {
  git_init();
  git_repository* repository = luaL_checkgitrepo(L, 1);
  git_oid commit_id;
  int got_commit = git_get_id(&commit_id, repository, "HEAD");
  git_repository_free(repository);
  if (got_commit)
    return luaL_error(L, "git retrieve commit error: %s", git_error_last_string());
  int digest_length = sizeof(commit_id.id);
  char hex_buffer[digest_length * 2];
  for (size_t i = 0; i < digest_length; ++i) {
    hex_buffer[i*2+0] = hex_digits[commit_id.id[i] >> 4];
    hex_buffer[i*2+1] = hex_digits[commit_id.id[i] & 0xF];
  }
  lua_pushlstring(L, hex_buffer, digest_length * 2);
  return 1;
}

static int lpm_init(lua_State* L) {
  git_init();
  const char* path = luaL_checkstring(L, 1);
  const char* url = luaL_checkstring(L, 2);
  git_repository* repository;
  if (git_repository_init(&repository, path, 0))
    return luaL_error(L, "git init error: %s", git_error_last_string());
  git_remote* remote;
  if (git_remote_create(&remote, repository, "origin", url)) {
    git_repository_free(repository);
    return luaL_error(L, "git remote add error: %s", git_error_last_string());
  }
  git_remote_free(remote);
  git_repository_free(repository);
  return 0;
}

static int no_verify_ssl, has_setup_ssl, print_trace;
static mbedtls_x509_crt x509_certificate;
static mbedtls_entropy_context entropy_context;
static mbedtls_ctr_drbg_context drbg_context;
static mbedtls_ssl_config ssl_config;
static mbedtls_ssl_context ssl_context;

static int lpm_git_transport_certificate_check_cb(struct git_cert *cert, int valid, const char *host, void *payload) {
  return 0; // If no_verify_ssl is enabled, basically always return 0 when this is set as callback.
}

static int lpm_git_transfer_progress_cb(const git_transfer_progress *stats, void *payload) {
  lua_State* L = payload;
  lua_pushvalue(L, 2);
  lua_pushinteger(L, stats->received_bytes);
  lua_pushinteger(L, stats->total_objects);
  lua_pushinteger(L, stats->indexed_objects);
  lua_pushinteger(L, stats->received_objects);
  lua_pushinteger(L, stats->local_objects);
  lua_pushinteger(L, stats->total_deltas);
  lua_pushinteger(L, stats->indexed_deltas);
  lua_call(L, 7, 1);
  int value = lua_tointeger(L, -1);
  lua_pop(L, 1);
  return value;
}

static int lpm_fetch(lua_State* L) {
  git_init();
  git_repository* repository = luaL_checkgitrepo(L, 1);
  git_remote* remote;
  if (git_remote_lookup(&remote, repository, "origin")) {
    git_repository_free(repository);
    return luaL_error(L, "git remote fetch error: %s", git_error_last_string());
  }
  git_fetch_options fetch_opts = GIT_FETCH_OPTIONS_INIT;
  fetch_opts.download_tags = GIT_REMOTE_DOWNLOAD_TAGS_ALL;
  fetch_opts.callbacks.payload = L;
  if (no_verify_ssl)
    fetch_opts.callbacks.certificate_check = lpm_git_transport_certificate_check_cb;
  if (lua_type(L, 2) == LUA_TFUNCTION)
    fetch_opts.callbacks.transfer_progress = lpm_git_transfer_progress_cb;
  if (git_remote_fetch(remote, NULL, &fetch_opts, NULL)) {
    git_remote_free(remote);
    git_repository_free(repository);
    return luaL_error(L, "git remote fetch error: %s", git_error_last_string());
  }
  git_remote_free(remote);
  git_repository_free(repository);
  if (lua_type(L, 2) == LUA_TFUNCTION) {
    lua_pushvalue(L, 2);
    lua_pushboolean(L, 1);
    lua_call(L, 1, 0);
  }
  return 0;
}

static int mbedtls_snprintf(int mbedtls, char* buffer, int len, int status, const char* str, ...) {
  char mbed_buffer[256];
  mbedtls_strerror(status, mbed_buffer, sizeof(mbed_buffer));
  int error_len = mbedtls ? strlen(mbed_buffer) : strlen(strerror(status));
  va_list va;
  int offset = 0;
  va_start(va, str);
    offset = vsnprintf(buffer, len, str, va);
  va_end(va);
  if (offset < len - 2) {
    strcat(buffer, ": ");
    if (offset < len - error_len - 2)
      strcat(buffer, mbedtls ? mbed_buffer : strerror(status));
  }
  return strlen(buffer);
}

static int luaL_mbedtls_error(lua_State* L, int code, const char* str, ...) {
  char vsnbuffer[1024];
  char mbed_buffer[128];
  mbedtls_strerror(code, mbed_buffer, sizeof(mbed_buffer));
  va_list va;
  va_start(va, str);
      vsnprintf(vsnbuffer, sizeof(vsnbuffer), str, va);
  va_end(va);
  return luaL_error(L, "%s: %s", vsnbuffer, mbed_buffer);
}

static void lpm_tls_debug(void *ctx, int level, const char *file, int line, const char *str) {
  fprintf(stderr, "%s:%04d: |%d| %s", file, line, level, str);
  fflush(stderr);
}

static void lpm_libgit2_debug(git_trace_level_t level, const char *msg) {
  fprintf(stderr, "[libgit2]: %s\n", msg);
  fflush(stderr);
}

static int lpm_trace(lua_State* L) {
  print_trace = lua_toboolean(L, 1) ? 1 : 0;
  return 0;
}

static int lpm_certs(lua_State* L) {
  const char* type = luaL_checkstring(L, 1);
  int status;
  if (has_setup_ssl) {
    mbedtls_ssl_config_free(&ssl_config);
    mbedtls_ctr_drbg_free(&drbg_context);
    mbedtls_entropy_free(&entropy_context);
    mbedtls_x509_crt_free(&x509_certificate);
  }
  mbedtls_x509_crt_init(&x509_certificate);
  mbedtls_entropy_init(&entropy_context);
  mbedtls_ctr_drbg_init(&drbg_context);
  if ((status = mbedtls_ctr_drbg_seed(&drbg_context, mbedtls_entropy_func, &entropy_context, NULL, 0)) != 0)
    return luaL_mbedtls_error(L, status, "failed to setup mbedtls_x509");
  mbedtls_ssl_config_init(&ssl_config);
  status = mbedtls_ssl_config_defaults(&ssl_config, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
  if (status)
    return luaL_mbedtls_error(L, status, "can't set ssl_config defaults");
  mbedtls_ssl_conf_max_version(&ssl_config, MBEDTLS_SSL_MAJOR_VERSION_3, MBEDTLS_SSL_MINOR_VERSION_3);
  mbedtls_ssl_conf_min_version(&ssl_config, MBEDTLS_SSL_MAJOR_VERSION_3, MBEDTLS_SSL_MINOR_VERSION_3);
  mbedtls_ssl_conf_authmode(&ssl_config, MBEDTLS_SSL_VERIFY_REQUIRED);
  mbedtls_ssl_conf_rng(&ssl_config, mbedtls_ctr_drbg_random, &drbg_context);
  mbedtls_ssl_conf_read_timeout(&ssl_config, 5000);
  #if defined(MBEDTLS_DEBUG_C)
  if (print_trace) {
    mbedtls_debug_set_threshold(5);
    mbedtls_ssl_conf_dbg(&ssl_config, lpm_tls_debug, NULL);
    git_init();
    git_trace_set(GIT_TRACE_TRACE, lpm_libgit2_debug);
  }
  #endif
  has_setup_ssl = 1;
  if (strcmp(type, "noverify") == 0) {
    no_verify_ssl = 1;
    mbedtls_ssl_conf_authmode(&ssl_config, MBEDTLS_SSL_VERIFY_OPTIONAL);
  } else {
    const char* path = luaL_checkstring(L, 2);
    if (strcmp(type, "dir") == 0) {
      git_cert_type = 1;
      if (git_initialized)
        git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, NULL, path);
      strncpy(git_cert_path, path, MAX_PATH);
    } else {
      if (strcmp(type, "system") == 0) {
        #if _WIN32
          FILE* file = lua_fopen(L, path, "wb");
          if (!file)
            return luaL_error(L, "can't open cert store %s for writing: %s", path, strerror(errno));
          HCERTSTORE hSystemStore = CertOpenSystemStore(0, TEXT("ROOT"));
          if (!hSystemStore) {
            fclose(file);
            return luaL_error(L, "error getting system certificate store");
          }
          PCCERT_CONTEXT pCertContext = NULL;
          while (1) {
            pCertContext = CertEnumCertificatesInStore(hSystemStore, pCertContext);
            if (!pCertContext)
              break;
            BYTE keyUsage[2];
            if (pCertContext->dwCertEncodingType & X509_ASN_ENCODING && (CertGetIntendedKeyUsage(pCertContext->dwCertEncodingType, pCertContext->pCertInfo, keyUsage, sizeof(keyUsage)) && (keyUsage[0] & CERT_KEY_CERT_SIGN_KEY_USAGE))) {
              DWORD size = 0;
              CryptBinaryToString(pCertContext->pbCertEncoded, pCertContext->cbCertEncoded, CRYPT_STRING_BASE64HEADER, NULL, &size);
              char* buffer = malloc(size);
              CryptBinaryToString(pCertContext->pbCertEncoded, pCertContext->cbCertEncoded, CRYPT_STRING_BASE64HEADER, buffer, &size);
              fwrite(buffer, sizeof(char), size, file);
              free(buffer);
            }
          }
          fclose(file);
          CertCloseStore(hSystemStore, 0);
        #elif __APPLE__ // https://developer.apple.com/forums/thread/691009; see also curl's mac version
          return luaL_error(L, "can't use system on mac yet");
        #else
          return luaL_error(L, "can't use system certificates except on windows or mac");
        #endif
      }
      git_cert_type = 2;
      if (git_initialized)
        git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, path, NULL);
      strncpy(git_cert_path, path, MAX_PATH);
      if ((status = mbedtls_x509_crt_parse_file(&x509_certificate, path)) != 0)
        return luaL_mbedtls_error(L, status, "mbedtls_x509_crt_parse_file failed to parse CA certificate %s", path);
      mbedtls_ssl_conf_ca_chain(&ssl_config, &x509_certificate, NULL);
    }
  }
  return 0;
}


static int mkdirp(char* path, int len) {
  for (int i = 0; i < len; ++i) {
    if (path[i] == '/' && i > 0) {
      path[i] = 0;
      #ifndef _WIN32
        if (mkdir(path, S_IRUSR|S_IWUSR|S_IXUSR|S_IRGRP|S_IXGRP|S_IROTH|S_IXOTH) && errno != EEXIST)
      #else
        if (mkdir(path) && errno != EEXIST)
      #endif
        return -1;
      path[i] = '/';
    }
  }
  return 0;
}

static int gzip_read(mtar_t* tar, void* data, unsigned int size) { return gzread(tar->stream, data, size) >= 0 ? MTAR_ESUCCESS : -1; }
static int gzip_seek(mtar_t* tar, unsigned int pos) { return gzseek(tar->stream, pos, SEEK_SET) >= 0 ? MTAR_ESUCCESS : -1; }
static int gzip_close(mtar_t* tar) { return gzclose(tar->stream) == Z_OK ? MTAR_ESUCCESS : -1; }

#define FA_RDONLY       0x01            // FILE_ATTRIBUTE_READONLY
#define FA_DIREC        0x10            // FILE_ATTRIBUTE_DIRECTORY

static int lpm_extract(lua_State* L) {
  const char* src = luaL_checkstring(L, 1);
  const char* dst = luaL_checkstring(L, 2);

  if (strstr(src, ".zip")) {
    int zip_error_code;
    zip_t* archive = zip_open(src, ZIP_RDONLY, &zip_error_code);
    if (!archive) {
      zip_error_t zip_error;
      zip_error_init_with_code(&zip_error, zip_error_code);
      lua_pushfstring(L, "can't open zip archive %s: %s", src, zip_error_strerror(&zip_error));
      zip_error_fini(&zip_error);
      return lua_error(L);
    }
    zip_int64_t entries = zip_get_num_entries(archive, 0);
    for (zip_int64_t i = 0; i < entries; ++i) {
      zip_file_t* zip_file = zip_fopen_index(archive, i, 0);
      const char* zip_name = zip_get_name(archive, i, ZIP_FL_ENC_GUESS);
      if (!zip_file) {
        lua_pushfstring(L, "can't read zip archive file %s: %s", zip_name, zip_strerror(archive));
        zip_close(archive);
        return lua_error(L);
      }
      char target[MAX_PATH];
      int target_length = snprintf(target, sizeof(target), "%s/%s", dst, zip_name);
      if (mkdirp(target, target_length)) {
        zip_fclose(zip_file);
        zip_close(archive);
        return luaL_error(L, "can't extract zip archive file %s, can't create directory %s: %s", src, target, strerror(errno));
      }
      if (target[target_length-1] != '/') {
        FILE* file = lua_fopen(L, target, "wb");
        if (!file) {
          zip_fclose(zip_file);
          zip_close(archive);
          return luaL_error(L, "can't write file %s: %s", target, strerror(errno));
        }

        mode_t m = S_IRUSR | S_IRGRP | S_IROTH;
        zip_uint8_t os;
        zip_uint32_t attr;
        zip_file_get_external_attributes(archive, i, 0, &os, &attr);
        if (os == ZIP_OPSYS_DOS) {
          if (0 == (attr & FA_RDONLY))
              m |= S_IWUSR | S_IWGRP | S_IWOTH;
          if (attr & FA_DIREC)
              m = (S_IFDIR | (m & ~S_IFMT)) | S_IXUSR | S_IXGRP | S_IXOTH;
        } else {
          m = (attr >> 16);
        }
        if (chmod(target, m)) {
          zip_fclose(zip_file);
          zip_close(archive);
          return luaL_error(L, "can't chmod file %s: %s", target, strerror(errno));
        }
        while (1) {
          char buffer[8192];
          zip_int64_t length = zip_fread(zip_file, buffer, sizeof(buffer));
          if (length == -1) {
            lua_pushfstring(L, "can't read zip archive file  %s: %s", zip_name, zip_file_strerror(zip_file));
            zip_fclose(zip_file);
            zip_close(archive);
            return lua_error(L);
          }
          if (length == 0) break;
          fwrite(buffer, sizeof(char), length, file);
        }
        fclose(file);
      }
      zip_fclose(zip_file);
    }
    zip_close(archive);
  } else if (strstr(src, ".tar")) {
    mtar_t tar = {0};
    int err;
    char actual_src[PATH_MAX];
    if (strstr(src, ".gz")) {
      gzFile gzfile = gzopen(src, "rb");
      if (!gzfile)
        return luaL_error(L, "can't open tar.gz archive %s: %s", src, strerror(errno));
      /* It's increidbly slow to do it this way, probably because of all the seeking.
      For now, just gunzip the whole file at once, and then untar it.
      tar.read = gzip_read;
      tar.seek = gzip_seek;
      tar.close = gzip_close;*/
      char buffer[8192];
      int len = strlen(src) - 3;
      strncpy(actual_src, src, len < PATH_MAX ? len : PATH_MAX);
      actual_src[len] = 0;
      FILE* file = lua_fopen(L, actual_src, "wb");
      if (!file) {
        gzclose(gzfile);
        return luaL_error(L, "can't open %s for writing: %s", actual_src, strerror(errno));
      }
      while (1) {
        int length = gzread(gzfile, buffer, sizeof(buffer));
        if (length == 0)
          break;
        fwrite(buffer, sizeof(char), length, file);
      }
      char error[128];
      error[0] = 0;
      if (!gzeof(gzfile)) {
        int error_number;
        strncpy(error, gzerror(gzfile, &error_number), sizeof(error));
        error[sizeof(error)-1] = 0;
      }
      fclose(file);
      gzclose(gzfile);
      if (error[0])
        return luaL_error(L, "can't unzip tar archive %s: %s", src, error);
    } else {
      strcpy(actual_src, src);
    }
    if ((err = mtar_open(&tar, actual_src, "r")))
      return luaL_error(L, "can't open tar archive %s: %s", src, mtar_strerror(err));
    mtar_header_t h;
    while ((mtar_read_header(&tar, &h)) != MTAR_ENULLRECORD ) {
      if (h.type == MTAR_TREG) {
        char target[MAX_PATH];
        int target_length = snprintf(target, sizeof(target), "%s/%s", dst, h.name);
        if (mkdirp(target, target_length)) {
          mtar_close(&tar);
          return luaL_error(L, "can't extract tar archive file %s, can't create directory %s: %s", src, target, strerror(errno));
        }
        char buffer[8192];
        FILE* file = fopen(target, "wb");
        if (!file) {
          mtar_close(&tar);
          return luaL_error(L, "can't extract tar archive file %s, can't create file %s: %s", src, target, strerror(errno));
        }
        if (chmod(target, h.mode))
           return luaL_error(L, "can't extract tar archive file %s, can't chmod file %s: %s", src, target, strerror(errno));
        int remaining = h.size;
        while (remaining > 0) {
          int read_size = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
          if (mtar_read_data(&tar, buffer, read_size) != MTAR_ESUCCESS) {
            fclose(file);
            mtar_close(&tar);
            return luaL_error(L, "can't write file %s: %s", target, strerror(errno));
          }
          fwrite(buffer, sizeof(char), read_size, file);
          remaining -= read_size;
        }
        fclose(file);
      }
      mtar_next(&tar);
    }
    mtar_close(&tar);
    if (strstr(src, ".gz"))
      unlink(actual_src);
  } else
    return luaL_error(L, "unrecognized archive format %s", src);
  return 0;
}


static int lpm_socket_write(int fd, const char* buf, int len, mbedtls_ssl_context* ctx) {
  if (ctx)
    return mbedtls_ssl_write(ctx, buf, len);
  return write(fd, buf, len);
}

static int lpm_socket_read(int fd, char* buf, int len, mbedtls_ssl_context* ctx) {
  if (ctx)
    return mbedtls_ssl_read(ctx, buf, len);
  return read(fd, buf, len);
}

static int strncicmp(const char* a, const char* b, int n) {
  for (int i = 0; i < n; ++i) {
    if (a[i] == 0 && b[i] != 0) return -1;
    if (a[i] != 0 && b[i] == 0) return 1;
    int lowera = tolower(a[i]), lowerb = tolower(b[i]);
    if (lowera == lowerb) continue;
    if (lowera < lowerb) return -1;
    return 1;
  }
  return 0;
}

static const char* get_header(const char* buffer, const char* header, int* len) {
  const char* line_end = strstr(buffer, "\r\n");
  const char* header_end = strstr(buffer, "\r\n\r\n");
  int header_len = strlen(header);
  while (line_end && line_end < header_end) {
    if (strncicmp(line_end + 2, header, header_len) == 0) {
      const char* offset = line_end + header_len + 3;
      while (*offset == ' ') { ++offset; }
      const char* end = strstr(offset, "\r\n");
      if (len)
        *len = end - offset;
      return offset;
    }
    line_end = strstr(line_end + 2, "\r\n");
  }
  return NULL;
}

static int lpm_get(lua_State* L) {
  long response_code;
  char err[1024] = {0};
  const char* protocol = luaL_checkstring(L, 1);
  const char* hostname = luaL_checkstring(L, 2);

  int s = -2;
  mbedtls_net_context net_context;
  mbedtls_ssl_context ssl_context;
  mbedtls_ssl_context* ssl_ctx = NULL;
  mbedtls_net_context* net_ctx = NULL;
  if (strcmp(protocol, "https") == 0) {
    int status;
    const char* port = lua_tostring(L, 3);
    // https://gist.github.com/Barakat/675c041fd94435b270a25b5881987a30
    ssl_ctx = &ssl_context;
    mbedtls_ssl_init(&ssl_context);
    if ((status = mbedtls_ssl_setup(&ssl_context, &ssl_config)) != 0) {
      mbedtls_snprintf(1, err, sizeof(err), status, "can't set up ssl for %s: %d", hostname, status); goto cleanup;
    }
    net_ctx = &net_context;
    mbedtls_net_init(&net_context);
    mbedtls_net_set_block(&net_context);
    mbedtls_ssl_set_bio(&ssl_context, &net_context, mbedtls_net_send, NULL, mbedtls_net_recv_timeout);
    if ((status = mbedtls_net_connect(&net_context, hostname, port, MBEDTLS_NET_PROTO_TCP)) != 0) {
      mbedtls_snprintf(1, err, sizeof(err), status, "can't connect to hostname %s", hostname); goto cleanup;
    } else if ((status = mbedtls_ssl_set_hostname(&ssl_context, hostname)) != 0) {
      mbedtls_snprintf(1, err, sizeof(err), status, "can't set hostname %s", hostname); goto cleanup;
    } else if ((status = mbedtls_ssl_handshake(&ssl_context)) != 0) {
      mbedtls_snprintf(1, err, sizeof(err), status, "can't handshake with %s", hostname); goto cleanup;
    } else if (((status = mbedtls_ssl_get_verify_result(&ssl_context)) != 0) && !no_verify_ssl) {
      mbedtls_snprintf(1, err, sizeof(err), status, "can't verify result for %s", hostname); goto cleanup;
    }
  } else {
    int port = luaL_checkinteger(L, 3);
    struct hostent *host = gethostbyname(hostname);
    struct sockaddr_in dest_addr = {0};
    if (!host)
      return luaL_error(L, "can't resolve hostname %s", hostname);
    s = socket(AF_INET, SOCK_STREAM, 0);
    #ifdef _WIN32
      DWORD timeout = 5 * 1000;
      setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&timeout, sizeof timeout);
    #else
      struct timeval tv;
      tv.tv_sec = 5;
      tv.tv_usec = 0;
      setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof tv);
    #endif
    dest_addr.sin_family = AF_INET;
    dest_addr.sin_port = htons(port);
    dest_addr.sin_addr.s_addr = *(long*)(host->h_addr);
    const char* ip = inet_ntoa(dest_addr.sin_addr);
    if (connect(s, (struct sockaddr *) &dest_addr, sizeof(struct sockaddr)) == -1 ) {
      close(s);
      return luaL_error(L, "can't connect to host %s [%s] on port %d", hostname, ip, port);
    }
  }

  const char* rest = luaL_checkstring(L, 4);
  char buffer[4096];
  int buffer_length = snprintf(buffer, sizeof(buffer), "GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", rest, hostname);
  buffer_length = lpm_socket_write(s, buffer, buffer_length, ssl_ctx);
  if (buffer_length < 0) {
    mbedtls_snprintf(ssl_ctx ? 1 : 0, err, sizeof(err), ssl_ctx ? buffer_length : errno, "can't write to socket %s", hostname); goto cleanup;
  }
  int bytes_read = 0;
  const char* header_end = NULL;
  while (!header_end && bytes_read < sizeof(buffer)) {
    buffer_length = lpm_socket_read(s, &buffer[bytes_read], sizeof(buffer) - bytes_read - 1, ssl_ctx);
    if (buffer_length < 0) {
      mbedtls_snprintf(ssl_ctx ? 1 : 0, err, sizeof(err), ssl_ctx ? buffer_length : errno, "can't read from socket %s", hostname); goto cleanup;
    }
    bytes_read += buffer_length;
    buffer[bytes_read] = 0;
    header_end = strstr(buffer, "\r\n\r\n");
  }
  if (!header_end) {
    snprintf(err, sizeof(err), "can't parse response headers for %s%s", hostname, rest); goto cleanup;
  }
  header_end += 4;
  const char* protocol_end = strstr(buffer, " ");
  int code = atoi(protocol_end + 1);
  if (code != 200) {
    if (code >= 301 && code <= 303) {
      int len;
      const char* location = get_header(buffer, "location", &len);
      if (location) {
        lua_pushnil(L);
        lua_newtable(L);
        lua_pushlstring(L, location, len);
        lua_setfield(L, -2, "location");
      } else
        snprintf(err, sizeof(err), "received invalid %d-response from %s%s: %d", code, hostname, rest, code);
      goto cleanup;
    } else {
      snprintf(err, sizeof(err), "received non 200-response from %s%s: %d", hostname, rest, code); goto cleanup;
    }
  }
  const char* content_length_value = get_header(buffer, "content-length", NULL);
  int content_length = -1;
  if (content_length_value)
    content_length = atoi(content_length_value);
  const char* path = luaL_optstring(L, 5, NULL);
  int callback_function = lua_type(L, 6) == LUA_TFUNCTION ? 6 : 0;

  int body_length = buffer_length - (header_end - buffer);
  int total_downloaded = body_length;
  int remaining = content_length - body_length;
  if (path) {
    FILE* file = lua_fopen(L, path, "wb");
    if (!file) {
      snprintf(err, sizeof(err), "can't open file %s: %s", path, strerror(errno)); goto cleanup;
    }
    fwrite(header_end, sizeof(char), body_length, file);
    while (content_length == -1 || remaining > 0) {
      int length = lpm_socket_read(s, buffer, sizeof(buffer), ssl_ctx);
      if (length == 0 || (ssl_ctx && content_length == -1 && length == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY)) break;
      if (length < 0) {
        mbedtls_snprintf(ssl_ctx ? 1 : 0, err, sizeof(err), ssl_ctx ? length : errno, "error retrieving full response for %s%s", hostname, rest); goto cleanup;
      }
      if (callback_function) {
        lua_pushvalue(L, callback_function);
        lua_pushinteger(L, total_downloaded);
        lua_pushinteger(L, content_length);
        lua_call(L, 2, 0);
      }
      fwrite(buffer, sizeof(char), length, file);
      remaining -= length;
      total_downloaded += length;
    }
    fclose(file);
    lua_pushnil(L);
  } else {
    luaL_Buffer B;
    luaL_buffinit(L, &B);
    luaL_addlstring(&B, header_end, body_length);
    while (content_length == -1 || remaining > 0) {
      int length = lpm_socket_read(s, buffer, sizeof(buffer), ssl_ctx);
      if (length == 0 || (ssl_ctx && content_length == -1 && length == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY)) break;
      if (length < 0) {
        mbedtls_snprintf(ssl_ctx ? 1 : 0, err, sizeof(err), ssl_ctx ? length : errno, "error retrieving full response for %s%s", hostname, rest); goto cleanup;
      }
      if (callback_function) {
        lua_pushvalue(L, callback_function);
        lua_pushinteger(L, total_downloaded);
        lua_call(L, 1, 0);
      }
      luaL_addlstring(&B, buffer, length);
      remaining -= length;
      total_downloaded += length;
    }
    luaL_pushresult(&B);
  }
  if (content_length != -1 && remaining != 0) {
    snprintf(err, sizeof(err), "error retrieving full response for %s%s", hostname, rest); goto cleanup;
  }
  if (callback_function) {
    lua_pushvalue(L, callback_function);
    lua_pushboolean(L, 1);
    lua_call(L, 1, 0);
  }
  lua_newtable(L);
  cleanup:
    if (ssl_ctx)
      mbedtls_ssl_free(ssl_ctx);
    if (net_ctx)
      mbedtls_net_free(net_ctx);
    if (s != -2)
      close(s);
    if (err[0])
      return luaL_error(L, "%s", err);
  return 2;
}

static int lpm_chdir(lua_State* L) {
  #ifdef _WIN32
    if (_wchdir(lua_toutf16(L, luaL_checkstring(L, 1))))
  #else
    if (chdir(luaL_checkstring(L, 1)))
  #endif
      return luaL_error(L, "error chdiring: %s", strerror(errno));
  return 0;
}

static int lpm_pwd(lua_State* L) {
  #ifdef _WIN32
    wchar_t buffer[MAX_PATH];
    if (!_wgetcwd(buffer, sizeof(buffer)))
      return luaL_error(L, "error getcwd: %s", strerror(errno));
    lua_toutf8(L, buffer);
  #else
    char buffer[MAX_PATH];
    if (!getcwd(buffer, sizeof(buffer)))
      return luaL_error(L, "error getcwd: %s", strerror(errno));
    lua_pushstring(L, buffer);
  #endif
  return 1;
}

int lpm_flock(lua_State* L) {
  const char* path = luaL_checkstring(L, 1);
  luaL_checktype(L, 2, LUA_TFUNCTION);
  int error_handler = lua_type(L, 3) == LUA_TFUNCTION ? 3 : 0;
  int warning_handler = lua_type(L, 4) == LUA_TFUNCTION ? 4 : 0;
  #ifdef _WIN32
    HANDLE file = CreateFileW(lua_toutf16(L, path), FILE_SHARE_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
    if (!file || file == INVALID_HANDLE_VALUE)
      return luaL_error(L, "can't open for flock %s: %d", path, GetLastError());
    OVERLAPPED overlapped = {0};
    if (!LockFileEx(file, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 0, 1, &overlapped)) {
      if (GetLastError() == ERROR_IO_PENDING && warning_handler) {
        lua_pushvalue(L, warning_handler);
        lua_pcall(L, 0, 0, 0);
      }
      if (!LockFileEx(file, LOCKFILE_EXCLUSIVE_LOCK, 0, 0, 1, &overlapped)) {
        CloseHandle(file);
        return luaL_error(L, "can't flock %s: %d", path, GetLastError());
      }
    }
  #else
    int fd = open(path, 0);
    if (fd == -1)
      return luaL_error(L, "can't flock %s: %s", path, strerror(errno));
    if (flock(fd, LOCK_EX | LOCK_NB) == -1) {
      if (errno == EWOULDBLOCK && warning_handler) {
        lua_pushvalue(L, warning_handler);
        lua_pcall(L, 0, 0, 0);
      }
      if (flock(fd, LOCK_EX) == -1) {
        close(fd);
        return luaL_error(L, "can't acquire exclusive lock on %s: %s", strerror(errno));
      }
    }
  #endif
  lua_pushvalue(L, 2);
  lua_pushvalue(L, 1);
  int err = lua_pcall(L, 1, 0, error_handler);
  #ifdef _WIN32
    UnlockFile(file, 0, 0, 1, 0);
    CloseHandle(file);
  #else
    flock(fd, LOCK_UN);
    close(fd);
  #endif
  if (err)
    return lua_error(L);
  return 0;
}

double get_time() {
   #if _WIN32 // Fuck I hate windows jesus chrsit.
    LARGE_INTEGER LoggedTime, Frequency;
    QueryPerformanceFrequency(&Frequency);
    QueryPerformanceCounter(&LoggedTime);
    return LoggedTime.QuadPart / (double)Frequency.QuadPart;
  #else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1000000000.0;
  #endif
}

int lpm_time(lua_State* L) {
  lua_pushnumber(L, get_time());
  return 1;
}

static const luaL_Reg system_lib[] = {
  { "ls",        lpm_ls    },    // Returns an array of files.
  { "stat",      lpm_stat  },    // Returns info about a single file.
  { "mkdir",     lpm_mkdir },    // Makes a directory.
  { "rmdir",     lpm_rmdir },    // Removes a directory.
  { "hash",      lpm_hash  },    // Returns a hex sha256 hash.
  { "symlink",   lpm_symlink },  // Creates a symlink.
  { "chmod",     lpm_chmod },    // Chmod's a file.
  { "init",      lpm_init },     // Initializes a git repository with the specified remote.
  { "fetch",     lpm_fetch },    // Updates a git repository with the specified remote.
  { "reset",     lpm_reset },    // Updates a git repository to the specified commit/hash/branch.
  { "revparse",  lpm_revparse }, // Gets a commit id.
  { "get",       lpm_get },      // HTTP(s) GET request.
  { "extract",   lpm_extract },  // Extracts .tar.gz, and .zip files.
  { "trace",     lpm_trace },    // Sets trace bit.
  { "certs",     lpm_certs },    // Sets the SSL certificate chain folder/file.
  { "chdir",     lpm_chdir },    // Changes directory. Only use for --post actions.
  { "pwd",       lpm_pwd },      // Gets existing directory. Only use for --post actions.
  { "flock",     lpm_flock },    // Locks a file.
  { "time",      lpm_time },     // Get high-precision system time.
  { NULL,        NULL }
};


#ifndef LPM_VERSION
  #define LPM_VERSION "unknown"
#endif


#ifndef ARCH_PROCESSOR
  #if defined(__x86_64__) || defined(_M_AMD64) || defined(__MINGW64__)
    #define ARCH_PROCESSOR "x86_64"
  #elif defined(__i386__) || defined(_M_IX86) || defined(__MINGW32__)
    #define ARCH_PROCESSOR "x86"
  #elif defined(__aarch64__) || defined(_M_ARM64) || defined (_M_ARM64EC)
    #define ARCH_PROCESSOR "aarch64"
  #elif defined(__arm__) || defined(_M_ARM)
    #define ARCH_PROCESSOR "arm"
  #elif defined(__riscv_xlen) && __riscv_xlen == 32
    #define ARCH_PROCESSOR "riscv32"
  #elif defined(__riscv_xlen) && __riscv_xlen == 64
    #define ARCH_PROCESSOR "riscv64"
  #else
    #error "Please define -DARCH_PROCESSOR."
  #endif
#endif
#ifndef ARCH_PLATFORM
  #if _WIN32
    #define ARCH_PLATFORM "windows"
  #elif __ANDROID__
    #define ARCH_PLATFORM "android"
  #elif __linux__
    #define ARCH_PLATFORM "linux"
  #elif __APPLE__
    #define ARCH_PLATFORM "darwin"
  #else
    #error "Please define -DARCH_PLATFORM."
  #endif
#endif
#ifndef LITE_ARCH_TUPLE
  #define LITE_ARCH_TUPLE ARCH_PROCESSOR "-" ARCH_PLATFORM
#endif


#ifdef LPM_STATIC
  extern const char src_lpm_luac[];
  extern unsigned int src_lpm_luac_len;
#endif

int main(int argc, char* argv[]) {
  lua_State* L = luaL_newstate();
  luaL_openlibs(L);
  luaL_newlib(L, system_lib);
  lua_setglobal(L, "system");
  lua_newtable(L);
  for (int i = 0; i < argc; ++i) {
    lua_pushstring(L, argv[i]);
    lua_rawseti(L, -2, i+1);
  }
  lua_setglobal(L, "ARGV");
  lua_pushliteral(L, LPM_VERSION);
  lua_setglobal(L, "VERSION");
  lua_pushliteral(L, ARCH_PLATFORM);
  lua_setglobal(L, "PLATFORM");
  lua_pushboolean(L, isatty(fileno(stdout)));
  lua_setglobal(L, "TTY");
  #if _WIN32
    lua_pushliteral(L, "\\");
  #else
    lua_pushliteral(L, "/");
  #endif
  lua_setglobal(L, "PATHSEP");
  lua_pushliteral(L, LITE_ARCH_TUPLE);
  lua_setglobal(L, "ARCH");
  #ifndef LPM_STATIC
  if (luaL_loadfile(L, "src/lpm.lua") || lua_pcall(L, 0, 1, 0)) {
  #else
  if (luaL_loadbuffer(L, src_lpm_luac, src_lpm_luac_len, "lpm.lua") || lua_pcall(L, 0, 1, 0)) {
  #endif
    fprintf(stderr, "internal error when starting the application: %s\n", lua_tostring(L, -1));
    return -1;
  }
  int status = lua_tointeger(L, -1);
  lua_close(L);
  if (git_initialized)
    git_libgit2_shutdown();
  return status;
}
