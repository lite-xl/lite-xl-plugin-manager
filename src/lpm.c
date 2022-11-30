#include <git2.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <lua.h>
#include <lauxlib.h>
#include <ctype.h>
#include <lualib.h>
#include <dirent.h>
#include <unistd.h>
#include <archive.h>
#include <archive_entry.h>

#include <sys/stat.h>
#include <git2.h>
#include <mbedtls/sha256.h>
#include <mbedtls/x509.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/ssl.h>
#include <mbedtls/net.h>

#ifdef _WIN32
  #include <direct.h>
  #include <winsock2.h>
  #include <windows.h>
  #include <fileapi.h>
#else
  #include <netinet/in.h>
  #include <netdb.h>
  #include <sys/socket.h>
  #include <arpa/inet.h>
  #define MAX_PATH PATH_MAX
#endif


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
    FILE* file = fopen(data, "rb");
    if (!file) {
      mbedtls_sha256_free(&hash_ctx);
      return luaL_error(L, "can't open %s", data);
    }
    while (1) {
      unsigned char chunk[4096];
      size_t bytes = fread(chunk, 1, sizeof(chunk), file);
      mbedtls_sha256_update_ret(&hash_ctx, chunk, bytes);
      if (bytes < 4096)
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
  hex_buffer[digest_length*2]=0;
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
  if (chmod(luaL_checkstring(L, 1), luaL_checkinteger(L, 2)))
    return luaL_error(L, "can't chmod %s: %s", luaL_checkstring(L, 1), strerror(errno));
  return 0;
}

/** BEGIN STOLEN LITE CODE **/
#if _WIN32
static LPWSTR utfconv_utf8towc(const char *str) {
  LPWSTR output;
  int len = MultiByteToWideChar(CP_UTF8, 0, str, -1, NULL, 0);
  if (len == 0)
    return NULL;
  output = (LPWSTR) malloc(sizeof(WCHAR) * len);
  if (output == NULL)
    return NULL;
  len = MultiByteToWideChar(CP_UTF8, 0, str, -1, output, len);
  if (len == 0) {
    free(output);
    return NULL;
  }
  return output;
}

static char *utfconv_wctoutf8(LPCWSTR str) {
  char *output;
  int len = WideCharToMultiByte(CP_UTF8, 0, str, -1, NULL, 0, NULL, NULL);
  if (len == 0)
    return NULL;
  output = (char *) malloc(sizeof(char) * len);
  if (output == NULL)
    return NULL;
  len = WideCharToMultiByte(CP_UTF8, 0, str, -1, output, len, NULL, NULL);
  if (len == 0) {
    free(output);
    return NULL;
  }
  return output;
}
#endif

static int lpm_ls(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);

#ifdef _WIN32
  lua_settop(L, 1);
  lua_pushstring(L, path[0] == 0 || strchr("\\/", path[strlen(path) - 1]) != NULL ? "*" : "/*");
  lua_concat(L, 2);
  path = lua_tostring(L, -1);

  LPWSTR wpath = utfconv_utf8towc(path);
  if (wpath == NULL)
    return luaL_error(L, "can't ls %s: invalid utf8 character conversion", path);
    
  WIN32_FIND_DATAW fd;
  HANDLE find_handle = FindFirstFileExW(wpath, FindExInfoBasic, &fd, FindExSearchNameMatch, NULL, 0);
  free(wpath);
  if (find_handle == INVALID_HANDLE_VALUE)
    return luaL_error(L, "can't ls %s: %d", path, GetLastError());
  char mbpath[MAX_PATH * 4]; // utf-8 spans 4 bytes at most
  int len, i = 1;
  lua_newtable(L);

  do
  {
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
  LPWSTR wpath = utfconv_utf8towc(path);
  int deleted = RemoveDirectoryW(wpath);
  free(wpath);
  if (!deleted)
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
  LPWSTR wpath = utfconv_utf8towc(path);
  if (wpath == NULL)
    return luaL_error(L, "can't mkdir %s: invalid utf8 character conversion", path);
  int err = _wmkdir(wpath);
  free(wpath);
#else
  int err = mkdir(path, S_IRUSR|S_IWUSR|S_IXUSR|S_IRGRP|S_IXGRP|S_IROTH|S_IXOTH);
#endif
  if (err < 0) 
    return luaL_error(L, "can't mkdir %s: %s", path, strerror(errno));
  return 0;
}

static int lpm_stat(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  lua_newtable(L);
#ifdef _WIN32
  #define realpath(x, y) _wfullpath(y, x, MAX_PATH)
  struct _stat s;
  LPWSTR wpath = utfconv_utf8towc(path);
  if (wpath == NULL)
    return luaL_error(L, "can't stat %s: invalid utf8 character conversion", path);
  int err = _wstat(wpath, &s);
  LPWSTR wfullpath = realpath(wpath, NULL);
  free(wpath);
  if (!wfullpath) return 0;
  char *abs_path = utfconv_wctoutf8(wfullpath);
  free(wfullpath);
#else
  struct stat s;
  int err = lstat(path, &s);
  char *abs_path = realpath(path, NULL);
#endif
  if (err || !abs_path) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }
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


static int lpm_reset(lua_State* L) {
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


static int lpm_init(lua_State* L) {
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


static int lpm_fetch(lua_State* L) {
  git_repository* repository = luaL_checkgitrepo(L, 1);
  git_remote* remote;
  if (git_remote_lookup(&remote, repository, "origin")) {
    git_repository_free(repository);
    return luaL_error(L, "git remote fetch error: %s", git_error_last_string());
  }
  git_fetch_options fetch_opts = GIT_FETCH_OPTIONS_INIT;
  fetch_opts.download_tags = GIT_REMOTE_DOWNLOAD_TAGS_ALL;
  if (git_remote_fetch(remote, NULL, &fetch_opts, NULL)) {
    git_remote_free(remote);
    git_repository_free(repository);
    return luaL_error(L, "git remote fetch error: %s", git_error_last_string());
  }
  git_remote_free(remote);
  git_repository_free(repository);
  return 0;
}


static int has_setup_ssl = 0;
static mbedtls_x509_crt x509_certificate;
static mbedtls_entropy_context entropy_context;
static mbedtls_ctr_drbg_context drbg_context;
static mbedtls_ssl_config ssl_config;
static mbedtls_ssl_context ssl_context;


static int lpm_certs(lua_State* L) {
  const char* type = luaL_checkstring(L, 1);
  const char* path = luaL_checkstring(L, 2);
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
    return luaL_error(L, "failed to setup mbedtls_x509");
  mbedtls_ssl_config_init(&ssl_config);
  status = mbedtls_ssl_config_defaults(&ssl_config, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
  mbedtls_ssl_conf_max_version(&ssl_config, MBEDTLS_SSL_MAJOR_VERSION_3, MBEDTLS_SSL_MINOR_VERSION_3);
  mbedtls_ssl_conf_min_version(&ssl_config, MBEDTLS_SSL_MAJOR_VERSION_3, MBEDTLS_SSL_MINOR_VERSION_3);
  mbedtls_ssl_conf_authmode(&ssl_config, MBEDTLS_SSL_VERIFY_REQUIRED);
  mbedtls_ssl_conf_rng(&ssl_config, mbedtls_ctr_drbg_random, &drbg_context);
  has_setup_ssl = 1;
  if (strcmp(type, "dir") == 0) {
    git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, NULL, path);
  } else {
    if (strcmp(type, "system") == 0) {
      #if _WIN32
        FILE* file = fopen(path, "wb");
        if (!file)
          return luaL_error(L, "can't open cert store %s for writing: %s", path, strerror(errno));
        HCERTSTORE hSystemStore = CertOpenSystemStore(0,"CA");
        if (!hSystemStore)
          return luaL_error(L, "error getting system certificate store");
        PCCERT_CONTEXT pCertContext = NULL;
        while (1) {
          pCertContext = CertEnumCertificatesInStore(hSystemStore, pCertContext);
          if (!pCertContext)
            break;
          if (pCertContext->dwCertEncodingType & X509_ASN_ENCODING) {
            DWORD size = 0;
            CryptBinaryToString(pCertContext->pbCertEncoded, pCertContext->cbCertEncoded, CRYPT_STRING_BASE64HEADER, NULL, &size);
            char buffer = malloc(size);
            CryptBinaryToString(pCertContext->pbCertEncoded, pCertContext->cbCertEncoded, CRYPT_STRING_BASE64HEADER, buffer, &size);
            free(buffer);
            fwrite(buffer, sizeof(char), size, file);
          }
        }
        fclose(file);
        CertCloseStore(hSystemStore);
      #else
        return luaL_error(L, "can't use system certificates on non-windows>");
      #endif
    }
    git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, path, NULL);
    if ((status = mbedtls_x509_crt_parse_file(&x509_certificate, path)) != 0)
      return luaL_error(L, "mbedtls_x509_crt_parse_file failed to parse CA certificate (-0x%X)\n", -status);  
    mbedtls_ssl_conf_ca_chain(&ssl_config, &x509_certificate, NULL);
  }
  return 0;
}


static int lpm_extract(lua_State* L) {
  const char* src = luaL_checkstring(L, 1);
  const char* dst = luaL_optstring(L, 2, ".");

  char error_buffer[1024] = {0};
	struct archive_entry *entry;
	const void *buff;
	int flags = 0;
	int r;
	size_t size;
#if ARCHIVE_VERSION_NUMBER >= 3000000
	int64_t offset;
#else
	off_t offset;
#endif
	struct archive *ar = archive_read_new();
	struct archive *aw = archive_write_disk_new();
	archive_write_disk_set_options(aw, flags);
	archive_read_support_format_tar(ar);
	archive_read_support_format_zip(ar);
	archive_read_support_filter_gzip(ar);
	if ((r = archive_read_open_filename(ar, src, 10240))) {
    snprintf(error_buffer, sizeof(error_buffer), "error extracting archive %s: %s", src, archive_error_string(ar));
    goto cleanup;
	}
	for (;;) {
		int r = archive_read_next_header(ar, &entry);
		if (r == ARCHIVE_EOF)
			break;
		if (r != ARCHIVE_OK) {
			snprintf(error_buffer, sizeof(error_buffer), "error extracting archive %s: %s", src, archive_error_string(ar));
      goto cleanup;
		}
		char path[MAX_PATH];	
		strcpy(path, dst); strcat(path, "/");
		strncat(path, archive_entry_pathname(entry), sizeof(path) - 3); path[MAX_PATH-1] = 0;
		archive_entry_set_pathname(entry, path);
    if (archive_write_header(aw, entry) != ARCHIVE_OK) {
      snprintf(error_buffer, sizeof(error_buffer), "error extracting archive %s: %s", src, archive_error_string(aw));
      goto cleanup;
		}
		for (;;) {
      int r = archive_read_data_block(ar, &buff, &size, &offset);
      if (r == ARCHIVE_EOF) 
        break;
      if (r != ARCHIVE_OK) {
        snprintf(error_buffer, sizeof(error_buffer), "error extracting archive %s: %s", src, archive_error_string(ar));
        goto cleanup;
      }
      if (archive_write_data_block(aw, buff, size, offset) != ARCHIVE_OK) {
        snprintf(error_buffer, sizeof(error_buffer), "error extracting archive %s: %s", src, archive_error_string(aw));
        goto cleanup;
      }
    }
    if (archive_write_finish_entry(aw) != ARCHIVE_OK) {
      snprintf(error_buffer, sizeof(error_buffer), "error extracting archive %s: %s", src, archive_error_string(aw));
      goto cleanup;
    }
	}
	cleanup:
	archive_read_close(ar);
	archive_read_free(ar);
	archive_write_close(aw);
  archive_write_free(aw);
  if (error_buffer[0])
    return luaL_error(L, "error extracting archive %s: %s", src, archive_error_string(ar));
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

static int strnicmp(const char* a, const char* b, int n) {
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

static int lpm_get(lua_State* L) {
  long response_code;
  char err[1024] = {0};
  const char* protocol = luaL_checkstring(L, 1);
  const char* hostname = luaL_checkstring(L, 2);

  int s = -2;
  mbedtls_ssl_context* ssl_ctx = NULL;
  mbedtls_net_context* net_ctx = NULL;
  if (strcmp(protocol, "https") == 0) {
    int status;
    const char* port = lua_tostring(L, 3);
    // https://gist.github.com/Barakat/675c041fd94435b270a25b5881987a30
    mbedtls_net_context net_context;
    mbedtls_ssl_context ssl_context;
    ssl_ctx = &ssl_context;
    net_ctx = &net_context;
    mbedtls_ssl_init(&ssl_context);
    
    if ((status = mbedtls_ssl_setup(&ssl_context, &ssl_config)) != 0) {
      return luaL_error(L, "can't set up ssl for %s: %d", hostname, status);
    }
    mbedtls_net_init(&net_context);
    mbedtls_net_set_block(&net_context);
    mbedtls_ssl_set_bio(&ssl_context, &net_context, mbedtls_net_send, mbedtls_net_recv, NULL);
    if ((status = mbedtls_net_connect(&net_context, hostname, port, MBEDTLS_NET_PROTO_TCP)) != 0) {
      snprintf(err, sizeof(err), "can't connect to hostname %s: %d", hostname, status); goto cleanup;
    } else if ((status = mbedtls_ssl_set_hostname(&ssl_context, hostname)) != 0) {
      snprintf(err, sizeof(err), "can't set hostname %s: %d", hostname, status); goto cleanup;
    } else if ((status = mbedtls_ssl_handshake(&ssl_context)) != 0) {
      snprintf(err, sizeof(err), "can't handshake with %s: %d", hostname, status); goto cleanup;
    } else if ((status = mbedtls_ssl_get_verify_result(&ssl_context)) != 0) {
      snprintf(err, sizeof(err), "can't verify result for %s: %d", hostname, status); goto cleanup;
    }
  } else {
    int port = luaL_checkinteger(L, 3);
    struct hostent *host = gethostbyname(hostname);
    struct sockaddr_in dest_addr = {0};
    if (!host)
      return luaL_error(L, "can't resolve hostname %s", hostname);
    s = socket(AF_INET, SOCK_STREAM, 0);
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
    snprintf(err, sizeof(err), "can't write to socket %s: %s", hostname, strerror(errno)); goto cleanup;
  }
  buffer_length = lpm_socket_read(s, buffer, sizeof(buffer) - 1, ssl_ctx);
  buffer[4095] = 0;
  if (buffer_length < 0) {
    snprintf(err, sizeof(err), "can't read from socket %s: %s", hostname,strerror(errno)); goto cleanup;
  }
  const char* header_end = strstr(buffer, "\r\n\r\n");
  if (!header_end) {
    snprintf(err, sizeof(err), "can't parse response headers for %s", hostname); goto cleanup;
  }
  header_end += 4;
  const char* protocol_end = strstr(buffer, " ");
  int code = atoi(protocol_end + 1);
  if (code != 200) {
    snprintf(err, sizeof(err), "received non 200-response from %s: %d", hostname, code); goto cleanup;
  }
  const char* line_end = strstr(buffer, "\r\n");
  int content_length = -1;
  while (line_end && line_end < header_end) {
    if (strnicmp(line_end + 2, "content-length:", 15) == 0) {
      const char* offset = line_end + 17;
      while (*offset == ' ') { ++offset; }
      content_length = atoi(offset);
    }
    line_end = strstr(line_end + 2, "\r\n");
  }
  const char* path = luaL_optstring(L, 5, NULL);
  
  int body_length = buffer_length - (header_end - buffer);
  int remaining = content_length - body_length;
  if (path) {
    FILE* file = fopen(path, "wb");
    fwrite(header_end, sizeof(char), body_length, file);
    while (content_length == -1 || remaining > 0) {
      int length = lpm_socket_read(s, buffer, sizeof(buffer), ssl_ctx);
      if (length == 0) break;
      if (length < 0) {
        snprintf(err, sizeof(err), "error retrieving full response for %s: %s", hostname, strerror(errno)); goto cleanup;
      }
      fwrite(buffer, sizeof(char), length, file);
      remaining -= length;
    }
    fclose(file);
    lua_pushnil(L);
  } else {
    luaL_Buffer B;
    luaL_buffinit(L, &B);
    luaL_addlstring(&B, header_end, body_length);
    while (content_length == -1 || remaining > 0) {
      int length = lpm_socket_read(s, buffer, sizeof(buffer), ssl_ctx);
      if (length == 0) break;
      if (length < 0) {
        snprintf(err, sizeof(err), "error retrieving full response for %s: %s", hostname, strerror(errno)); goto cleanup;
      }
      luaL_addlstring(&B, buffer, length);
      remaining -= length;
    }
    luaL_pushresult(&B);
  }
  if (content_length != -1 && remaining != 0) {
    snprintf(err, sizeof(err), "error retrieving full response for %s", hostname); goto cleanup;
  }
  lua_newtable(L);
  cleanup:
    if (ssl_ctx) {
      mbedtls_ssl_free(ssl_ctx);
      mbedtls_net_free(net_ctx);
    } else if (s != -2) {
      close(s);
    }
    if (err[0])
      return luaL_error(L, "%s", err);
  return 2;
}


static const luaL_Reg system_lib[] = {
  { "ls",        lpm_ls    },   // Returns an array of files.
  { "stat",      lpm_stat  },   // Returns info about a single file.
  { "mkdir",     lpm_mkdir },   // Makes a directory.
  { "rmdir",     lpm_rmdir },   // Removes a directory.
  { "hash",      lpm_hash  },   // Returns a hex sha256 hash.
  { "symlink",   lpm_symlink }, // Creates a symlink.
  { "chmod",     lpm_chmod },   // Chmod's a file.
  { "init",      lpm_init },    // Initializes a git repository with the specified remote.
  { "fetch",     lpm_fetch },   // Updates a git repository with the specified remote.
  { "reset",     lpm_reset },   // Updates a git repository to the specified commit/hash/branch.
  { "get",       lpm_get },     // HTTP(s) GET request.
  { "extract",   lpm_extract }, // Extracts .tar.gz, and .zip files.
  { "certs",     lpm_certs },   // Sets the SSL certificate chain folder/file.
  { NULL,        NULL }
};


#ifndef LPM_VERSION
  #define LPM_VERSION "unknown"
#endif


#ifndef LITE_ARCH_TUPLE
  #if __x86_64__ || _WIN64 || __MINGW64__
    #define ARCH_PROCESSOR "x86_64"
  #else
    #define ARCH_PROCESSOR "x86"
  #endif
  #if _WIN32
    #define ARCH_PLATFORM "windows"
  #elif __linux__
    #define ARCH_PLATFORM "linux"
  #elif __APPLE__
    #define ARCH_PLATFORM "darwin"
  #else
    #error "Please define -DLITE_ARCH_TUPLE."
  #endif
  #define LITE_ARCH_TUPLE ARCH_PROCESSOR "-" ARCH_PLATFORM
#endif


extern const char src_lpm_luac[];
extern unsigned int src_lpm_luac_len;
int main(int argc, char* argv[]) {
  git_libgit2_init();
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
  #if _WIN32 
    lua_pushliteral(L, "windows");
    lua_pushliteral(L, "\\");
  #else
    lua_pushliteral(L, "posix");
    lua_pushliteral(L, "/");
  #endif
  lua_setglobal(L, "PATHSEP");
  lua_setglobal(L, "PLATFORM");
  lua_pushliteral(L, LITE_ARCH_TUPLE);
  lua_setglobal(L, "ARCH");
  #if LPM_LIVE
  if (luaL_loadfile(L, "src/lpm.lua") || lua_pcall(L, 0, 1, 0)) {
  #else
  if (luaL_loadbuffer(L, src_lpm_luac, src_lpm_luac_len, "lpm.lua") || lua_pcall(L, 0, 1, 0)) {
  #endif
    fprintf(stderr, "internal error when starting the application: %s\n", lua_tostring(L, -1));
    return -1;
  }
  int status = lua_tointeger(L, -1);
  lua_close(L);
  git_libgit2_shutdown();
  return status;
}
