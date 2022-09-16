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

#include <sys/stat.h>
#include <git2.h>
#include <openssl/evp.h>
#include <curl/curl.h>

#ifdef _WIN32
  #include <direct.h>
  #include <windows.h>
  #include <fileapi.h>
#endif

static char hex_digits[] = "0123456789abcdef";
static int lpm_hash(lua_State* L) {
  size_t len;
  const char* data = luaL_checklstring(L, 1, &len);
  const char* type = luaL_optstring(L, 2, "string");
  unsigned char buffer[EVP_MAX_MD_SIZE];
  EVP_MD_CTX* c = EVP_MD_CTX_new();
  EVP_MD_CTX_init(c);
  EVP_DigestInit_ex(c, EVP_sha256(), NULL);
  if (strcmp(type, "file") == 0) {
    FILE* file = fopen(data, "rb");
    if (!file) {
      EVP_DigestFinal(c, buffer, NULL);
      return luaL_error(L, "can't open %s", data);
    }
    while (1) {
      unsigned char chunk[4096];
      size_t bytes = fread(chunk, 1, sizeof(chunk), file);
      EVP_DigestUpdate(c, chunk, bytes);
      if (bytes < 4096)
        break;
    }
    fclose(file);
  } else {
    EVP_DigestUpdate(c, data, len);
  }
  int digest_length;
  EVP_DigestFinal(c, buffer, &digest_length);
  EVP_MD_CTX_free(c);
  char hex_buffer[EVP_MAX_MD_SIZE * 2];
  for (size_t i = 0; i < digest_length; ++i) {
    hex_buffer[i*2+0] = hex_digits[buffer[i] >> 4];
    hex_buffer[i*2+1] = hex_digits[buffer[i] & 0xF];
  }
  lua_pushlstring(L, hex_buffer, digest_length * 2);
  hex_buffer[digest_length*2]=0;
  return 1;
}

/** BEGIN STOLEN LITE CODE **/

#if _WIN32
#define UTFCONV_ERROR_INVALID_CONVERSION "Input contains invalid byte sequences."
static LPWSTR utfconv_utf8towc(const char *str) {
  LPWSTR output;
  int len;

  // len includes \0
  len = MultiByteToWideChar(CP_UTF8, 0, str, -1, NULL, 0);
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
  int len;

  // len includes \0
  len = WideCharToMultiByte(CP_UTF8, 0, str, -1, NULL, 0, NULL, NULL);
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
  if (strchr("\\/", path[strlen(path) - 2]) != NULL)
    lua_pushstring(L, "*");
  else
    lua_pushstring(L, "/*");

  lua_concat(L, 2);
  path = lua_tostring(L, -1);

  LPWSTR wpath = utfconv_utf8towc(path);
  if (wpath == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, UTFCONV_ERROR_INVALID_CONVERSION);
    return 2;
  }

  WIN32_FIND_DATAW fd;
  HANDLE find_handle = FindFirstFileExW(wpath, FindExInfoBasic, &fd, FindExSearchNameMatch, NULL, 0);
  free(wpath);
  if (find_handle == INVALID_HANDLE_VALUE) {
    lua_pushnil(L);
    lua_pushinteger(L, GetLastError());
    return 2;
  }

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

  if (GetLastError() != ERROR_NO_MORE_FILES) {
    lua_pushnil(L);
    lua_pushinteger(L, GetLastError());
    FindClose(find_handle);
    return 2;
  }

  FindClose(find_handle);
  return 1;
#else
  DIR *dir = opendir(path);
  if (!dir) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }

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
  if (deleted > 0) {
    lua_pushboolean(L, 1);
  } else {
    lua_pushboolean(L, 0);
    lua_pushinteger(L, GetLastError());
    return 2;
  }
#else
  int deleted = remove(path);
  if(deleted < 0) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, strerror(errno));

    return 2;
  } else {
    lua_pushboolean(L, 1);
  }
#endif

  return 1;
}

static int lpm_mkdir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);

#ifdef _WIN32
  LPWSTR wpath = utfconv_utf8towc(path);
  if (wpath == NULL) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, UTFCONV_ERROR_INVALID_CONVERSION);
    return 2;
  }

  int err = _wmkdir(wpath);
  free(wpath);
#else
  int err = mkdir(path, S_IRUSR|S_IWUSR|S_IXUSR|S_IRGRP|S_IXGRP|S_IROTH|S_IXOTH);
#endif
  if (err < 0) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, strerror(errno));
    return 2;
  }

  lua_pushboolean(L, 1);
  return 1;
}

static int lpm_stat(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);

#ifdef _WIN32
  struct _stat s;
  LPWSTR wpath = utfconv_utf8towc(path);
  if (wpath == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, UTFCONV_ERROR_INVALID_CONVERSION);
    return 2;
  }
  int err = _wstat(wpath, &s);
  free(wpath);
#else
  struct stat s;
  int err = stat(path, &s);
#endif
  if (err < 0) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }

  lua_newtable(L);
  lua_pushinteger(L, s.st_mtime);
  lua_setfield(L, -2, "modified");

  lua_pushinteger(L, s.st_size);
  lua_setfield(L, -2, "size");

  if (S_ISREG(s.st_mode)) {
    lua_pushstring(L, "file");
  } else if (S_ISDIR(s.st_mode)) {
    lua_pushstring(L, "dir");
  } else {
    lua_pushnil(L);
  }
  lua_setfield(L, -2, "type");

#if __linux__
  if (S_ISDIR(s.st_mode)) {
    if (lstat(path, &s) == 0) {
      lua_pushboolean(L, S_ISLNK(s.st_mode));
      lua_setfield(L, -2, "symlink");
    }
  }
#endif
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
  if (git_get_id(&commit_id, repository, commit_name))
    return NULL;
  if (git_commit_lookup(&commit, repository, &commit_id))
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
  if (git_repository_init(&repository, path, 0) != 0)
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
  if (git_remote_fetch(remote, NULL, &fetch_opts, NULL)) {
    git_remote_free(remote);
    git_repository_free(repository);
    return luaL_error(L, "git remote fetch error: %s", git_error_last_string());
  }
  git_remote_free(remote);
  git_repository_free(repository);
  return 0;
}


static CURL *curl;
static int lpm_certs(lua_State* L) {
  const char* type = luaL_checkstring(L, 1);
  const char* path = luaL_checkstring(L, 2);
  if (strcmp(type, "dir") == 0) {
    git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, NULL, path);
    curl_easy_setopt(curl, CURLOPT_CAINFO, path);
  } else {
    git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, path, NULL);
    curl_easy_setopt(curl, CURLOPT_CAPATH, path);
  }
  return 0;
}

static int lpm_status(lua_State* L) {
  const char* path = luaL_checkstring(L, 1);
  git_repository* repository;
  if (git_repository_open(&repository, path))
    return luaL_error(L, "git open error: %s", git_error_last_string());
  git_repository_free(repository);
  lua_newtable(L);
  lua_pushnil(L);
  lua_setfield(L, -2, "commit");
  lua_pushnil(L);
  lua_setfield(L, -2, "branch");
  return 1;
}


static size_t lpm_curl_write_callback(char *ptr, size_t size, size_t nmemb, void *BL) {
  luaL_Buffer* B = BL;
  luaL_addlstring(B, ptr, size*nmemb);
  return size*nmemb;
}


static int lpm_get(lua_State* L) {
  const char* url = luaL_checkstring(L, 1);
  const char* path = luaL_optstring(L, 2, NULL);
  // curl_easy_reset(curl);
  curl_easy_setopt(curl, CURLOPT_URL, url);
  if (path) {
    FILE* file = fopen(path, "wb");
    if (!file)
      return luaL_error(L, "error opening file %s: %s", path, strerror(errno));
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, fwrite);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, file);
    CURLcode res = curl_easy_perform(curl);
    if (res != CURLE_OK) {
      fclose(file);
      return luaL_error(L, "curl error: %d", res);
    }
    fclose(file);
    lua_pushnil(L);
    lua_newtable(L);
    return 2;
  } else {
    luaL_Buffer B;
    luaL_buffinit(L, &B);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, lpm_curl_write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &B);
    CURLcode res = curl_easy_perform(curl);
    if (res != CURLE_OK)
      return luaL_error(L, "curl error: %d", res);
    luaL_pushresult(&B);
    lua_newtable(L);
  }
  return 2;
}


static const luaL_Reg system_lib[] = {
  { "ls",        lpm_ls    }, // Returns an array of files.
  { "stat",      lpm_stat  }, // Returns info about a single file.
  { "mkdir",     lpm_mkdir }, // Makes a directory.
  { "rmdir",     lpm_rmdir }, // Removes a directory.
  { "hash",      lpm_hash  }, // Returns a hex sha256 hash.
  { "init",      lpm_init }, // Initializes a git repository with the specified remote.
  { "fetch",     lpm_fetch }, // Updates a git repository with the specified remote.
  { "reset",     lpm_reset }, // Updates a git repository to the specified commit/hash/branch.
  { "status",    lpm_status }, // Returns the git repository in question's current branch, if any, and commit hash.
  { "get",       lpm_get }, // HTTP(s) GET request.
  { "certs",     lpm_certs } // Sets the SSL certificate chain folder/file.
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


extern const char lpm_lua[];
extern unsigned int lpm_lua_len;
int main(int argc, char* argv[]) {
  curl = curl_easy_init();
  if (!curl)
    return -1;
  git_libgit2_init();
  lua_State* L = luaL_newstate();
  luaL_openlibs(L);
  luaL_newlib(L, system_lib); lua_setglobal(L, "system");
  lua_newtable(L);
  for (int i = 0; i < argc; ++i) {
    lua_pushstring(L, argv[i]);
    lua_rawseti(L, -2, i+1);
  }
  lua_pushliteral(L, LPM_VERSION);
  lua_setglobal(L, "VERSION");
  lua_setglobal(L, "ARGV");
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
  if (luaL_loadfile(L, "lpm.lua")) {
  #else
  if (luaL_loadbuffer(L, lpm_lua, lpm_lua_len, "lpm.lua")) {
  #endif
    fprintf(stderr, "internal error when starting the application: %s\n", lua_tostring(L, -1));
    return -1;
  }
  lua_pcall(L, 0, 1, 0);
  int status = lua_tointeger(L, -1);
  lua_close(L);
  git_libgit2_shutdown();
  curl_easy_cleanup(curl);
  return status;
}
