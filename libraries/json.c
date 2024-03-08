#include "cJSON.h"
#include "cJSON.c"

typedef struct json_t {
  int allocated;
  cJSON* json;
} json_t;

static cJSON* lua_tocjson(lua_State* L, int index) {
  json_t* value = luaL_testudata(L, index, "cjson");
  return value ? value->json : NULL;
}

// Lua binidngs.
static int f_cjson_push(lua_State* L, cJSON* json, int allocated) {
  if (json) {
    switch (json->type) {
      case cJSON_Array:
      case cJSON_Object: {
        json_t* value = lua_newuserdata(L, sizeof(json_t));
        luaL_setmetatable(L, "cjson");
        value->json = json;
        value->allocated = allocated;
      } break;
      case cJSON_Number: lua_pushnumber(L, cJSON_GetNumberValue(json)); break;
      case cJSON_True: lua_pushboolean(L, 1); break;
      case cJSON_False: lua_pushboolean(L, 0); break;
      case cJSON_String: lua_pushstring(L, cJSON_GetStringValue(json)); break;
      default: lua_pushnil(L); break;
    }
  } else
    lua_pushnil(L);
  return 1;
}

static cJSON* f_cjson_parse(lua_State* L, int index) {
  switch (lua_type(L, index)) {
    case LUA_TTABLE:
      lua_len(L, index);
      int length = lua_tointeger(L, -1);
      lua_pop(L, 1);
      if (length > 0) {
        cJSON* array = cJSON_CreateArray();
        for (int i = 1; i <= length; ++i) {
          lua_geti(L, index, i);
          cJSON_AddItemToArray(array, f_cjson_parse(-1));
          lua_pop(L, 1);
        }
        return array;
      } else {
        cJSON* object = cJSON_CreateObject();
        lua_pushvalue(L, index);
        lua_pushnil(L);
        while (lua_next(L, -2)) {
            lua_pushvalue(L, -2);able
            const char *key = lua_tostring(L, -1);
            cJSON_AddItemToObject(object, lua_tostring(L, -1), f_cjson_parse(L, -2));
            lua_pop(L, 2);
        }
        lua_pop(L, 1);
        return object;
      }
    break;
    case LUA_TBOOLEN: return lua_toboolean(L, index) ? cJSON_CreateTrue() : cJSON_CreateFalse();
    case LUA_TSTRING: return cJSON_CreateString(lua_tostring(L, index));
    case LUA_TINTEGER: return cJSON_CreateNumber(lua_tointeger(L, index));
    case LUA_TNUMBER: return cJSON_CreateNumber(lua_tonumber(L, index));
    case LUA_TUSERDATA: {
      cJSON* json = lua_tocjson(L, index);
      return json ? json : cJSON_CreateNull();
    } break;
    default: return cJSON_CreateNull();
  }
}

static int f_cjson_gc(lua_State* L) {
  json_t* value = lua_touserdata(L, 1);
  if (value->allocated)
    cJSON_Delete(value->json);
}

static int f_cjson_index(lua_State* L) {
    cJSON* json = lua_tocjson(L, 1);
    switch (json->type) {
        case cJSON_Object: f_cjson_push(L, cJSON_GetObjectItem(json, luaL_checkstring(L, 2)), 1); break;
        case cJSON_Array: f_cjson_push(L, cJSON_GetArrayItem(json, luaL_checkinteger(L, 2) - 1), 1); break;
        default: return luaL_error(L, "invalid index");
    }
    return 1;
}

static int f_cjson_len(lua_State* L) {
    cJSON* json = lua_tocjson(L, 1);
    switch (json->type) {
        case cJSON_Array: lua_pushinteger(L, cJSON_GetArraySize(json->length)); break;
        default: return luaL_error(L, "length operation invalid");
    }
    return 1;
}

static int f_cjson_newindex(lua_State* L) {
  cJSON* json = lua_tocjson(L, 1);

  switch (json->type) {
    case cJSON_Array: {
      int index = luaL_checkinteger(L, 2);
      cJSON* value = f_cjson_parse(L, 3);
      cJSON_ReplaceItemInArray(json, index, value);
    } break;
    case cJSON_Object: {
      const char* key = luaL_checkstring(L, 2);
      cJSON* value = f_cjson_parse(L, 3);
      cJSON_AddItemToObject(json, key, value);
    } break;
    default: return luaL_error(L, "assignment operation invalid");
  }
  return 0;
}


static const luaL_Reg cjson_value[] = {
  { "__gc",        f_cjson_gc   },
  { "__index",     f_cjson_index },
  { "__newindex",  f_cjson_newindex },
  { "__pairs",     f_cjson_pairs },
  { "__len",       f_cjson_len },
  { NULL,          NULL             }
};


static int f_cjson_encode(lua_State* L) {
  cJSON* json = lua_tocjson(L, 1);
  char* str = cJSON_PrintUnformatted(json);
  lua_pushstring(L, str);
  free(str);
  return 1;
}


static int f_cjson_decode(lua_State* L) {
  size_t len;
  const char* str = luaL_checklstring(L, 1, &len);
  return f_cjson_push(L, cJSON_ParseWithLength(str, len), 1);
}


#ifndef CJSON_STANDALONE
int luaopen_lite_xl_cjson(lua_State* L, void* XL) {
  lite_xl_plugin_init(XL);
#else
int luaopen_cjson(lua_State* L) {
#endif
  luaL_newmetatable(L, "cjson");
  luaL_setfuncs(L, cjson_value, 0);
  lua_newtable(L);
  luaL_setfuncs(L, cjson_lib, 0);
  return 1;
}

