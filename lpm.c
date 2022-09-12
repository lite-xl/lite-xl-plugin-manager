/* lpm.c - Core of the lite package manager. 

LPM is a package manager for `lite-xl`, written in C (and packed-in lua).

It has the following commands:

lpm add <repository remote>
lpm rm <repository remote>
lpm update [<repository remote>]
lpm install <plugin name>
lpm uninstall <plugin name>
lpm list

It stores files in a cache directory in the follwoing format:

<remote url>:<branch_name|commit_name>

*/

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

#ifdef _WIN32
  #include <direct.h>
  #include <windows.h>
  #include <fileapi.h>
#endif

/* 64bit fnv-1a hash */
typedef unsigned long long hash_t;
static char hexDigits[] = "0123456789abcdef";
#define FNV_64_PRIME ((hash_t)0x100000001b3ULL)
static int lpm_hash(lua_State* L) {
  hash_t hval = 0;
  size_t len;
  const char* data = luaL_checklstring(L, 1, &len);
  const unsigned char *bp = (unsigned char*)data;
  const unsigned char *be = data + len;
  while (bp < be) {
    hval *= FNV_64_PRIME;
    hval ^= (unsigned long long)*bp++;
  }
  char buffer[16];
  for (size_t i = 0; i < len; ++i) {
    buffer[i*2+0] = hexDigits[data[i] >> 4];
    buffer[i*2+1] = hexDigits[data[i] & 0xF];
  }
  lua_pushlstring(L, buffer, 16);
  return 1;
}

/** BEGIN STOLEN LITE CODE **/
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
    push_win32_error(L, GetLastError());
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
    push_win32_error(L, GetLastError());
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
    push_win32_error(L, GetLastError());
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


int lpm_reset(lua_State* L) {
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


int lpm_init(lua_State* L) {
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


int lpm_fetch(lua_State* L) {
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


int lpm_status(lua_State* L) {
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


static const luaL_Reg system_lib[] = {
  { "ls",    lpm_ls    }, // Returns an array of files.
  { "stat",  lpm_stat  }, // Returns info about a single file.
  { "mkdir", lpm_mkdir }, // Makes a directory.
  { "rmdir", lpm_rmdir }, // Removes a directory.
  { "hash",  lpm_hash  }, // Returns a hexhash.
  { "init",  lpm_init }, // Initializes a git repository with the specified remote.
  { "fetch",  lpm_fetch }, // Updates a git repository with the specified remote.
  { "reset",  lpm_reset }, // Updates a git repository to the specified commit/hash/branch.
  { "status", lpm_status } // Returns the git repository in question's current branch, if any, and commit hash.
};

extern const char* luafile;
int main(int argc, char* argv[]) {
  git_libgit2_init();
  lua_State* L = luaL_newstate();
  luaL_openlibs(L);
  luaL_newlib(L, system_lib); lua_setglobal(L, "system");
  lua_newtable(L);
  for (int i = 0; i < argc; ++i) {
    lua_pushstring(L, argv[i]);
    lua_rawseti(L, -2, i+1);
  }
  lua_setglobal(L, "ARGV");
  #if _WIN32 
    lua_pushliteral(L, "\\");
  #else
    lua_pushliteral(L, "/");
  #endif
  lua_setglobal(L, "PATHSEP");
  if (luaL_loadstring(L, luafile)) {
  //if (luaL_loadfile(L, "lpm.lua")) {
    fprintf(stderr, "internal error when starting the application: %s\n", lua_tostring(L, -1));
    return -1;
  }
  lua_pcall(L, 0, 1, 0);
  int status = lua_tointeger(L, -1);
  lua_close(L);
  git_libgit2_shutdown();
  return status;
}
