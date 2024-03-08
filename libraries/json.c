#include "cJSON.h"
#include "cJSON.c"

// Lua binidngs.
static void f_cjson_push(lua_State* L, cJSON* json, int value) {
    if (json) {
        switch (json->type) {
            case cJSON_Array:
            case cJSON_Object: {
                cJSON** value = lua_newuserdata(L, sizeof(cJSON*));
                luaL_setmetatable(L, value ? "cjson_value" : "cjson_object");
                *value = *json;
            } break;
            case cJSON_NULL: lua_pushnil(L); break;
            case cJSON_Number: lua_pushnumber(L, json->number); break;
            case cJSON_String: lua_pushlstring(L, json_string(json), json->length); break;
        }
    } else
        lua_pushnil(L);
}


static int f_cjson_object_gc(lua_State* L) {
    cJSON** data = lua_touserdata(L, 1);
    cJSON_free(*data);
}

static int f_cjson_object_index(lua_State* L) {
    cJSON* json = *(cJSON**)lua_touserdata(L, 1);
    switch (json->type) {
        case cJSON_Object: f_cjson_push(L, cJSON_GetObjectItem(json, luaL_checkstring(L, 2)), 1); break;
        case cJSON_Array: f_cjson_push(L, cJSON_GetArrayItem(json, luaL_checkinteger(L, 2) - 1), 1); break;
        default: return luaL_error(L, "invalid index");
    }
    return 1;
}

static int f_cjson_object_len(lua_State* L) {
    cJSON* json = *(cJSON**)lua_touserdata(L, 1);
    switch (json->type) {
        case cJSON_Array: lua_pushinteger(L, cJSON_GetArraySize(json->length)); break;
        default: return luaL_error(L, "length operation invalid");
    }
    return 1;
}


static const luaL_Reg cjson_value[] = {
    { "__index",     f_cjson_object_index },
    { "__newindex",  f_cjson_object_newindex },
    { "__pairs",     f_cjson_object_pairs },
    { "__len",       f_cjson_object_len },
    { NULL,          NULL             }
};

static const luaL_Reg cjson_object[] = {
    { "__gc",        f_cjson_object_gc   },
    { "__index",     f_cjson_object_index },
    { "__newindex",  f_cjson_object_newindex },
    { "__pairs",     f_cjson_object_pairs },
    { "__len",       f_cjson_object_len },
    { NULL,          NULL             }
};


static int f_cjson_encode(lua_State* L) {
    cJSON** data = lua_touserdata(L, 1);
    char* str = cJSON_PrintUnformatted(*data);
    lua_pushstring(L, str);
    free(str);
    return 1;
}


static int f_cjson_decode(lua_State* L) {
    size_t len;
    const char* str = luaL_checklstring(L, 1, &len);
    cJSON* value = cJSON_ParseWithLength(str, len);
    cJSON** data = lua_newuserdata(L, sizeof(cJSON*));
    luaL_setmetatable(L, "cjson_object");
    *data = value;
    return 1;
}

#ifndef CJSON_STANDALONE
int luaopen_lite_xl_cjson(lua_State* L, void* XL) {
  lite_xl_plugin_init(XL);
#else
int luaopen_cjson(lua_State* L) {
#endif
    luaL_newmetatable(L, "cjson_object");
    luaL_setfuncs(L, cjson_object, 0);
    luaL_newmetatable(L, "cjson_value");
    luaL_setfuncs(L, cjson_value, 0);
    lua_newtable(L);
    luaL_setfuncs(L, cjson_lib, 0);
    return 1;
}

