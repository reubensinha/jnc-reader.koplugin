--[[--
Settings manager for JNC Reader.

Persists the session token and user preferences using KOReader's
LuaSettings facility. Content data is never stored here — only
auth credentials (token) and UI preferences.

@module koplugin.jnc-reader.settings
--]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger      = require("logger")

local SETTINGS_FILE = DataStorage:getDataDir() .. "/jnc-reader_settings.lua"

--- @class JNCSettings
local JNCSettings = {}
JNCSettings.__index = JNCSettings

--- Open (or create) the settings file and return a new instance.
-- @return JNCSettings
function JNCSettings:new()
    local o = {
        store = LuaSettings:open(SETTINGS_FILE),
    }
    setmetatable(o, self)
    return o
end

--- Persist the Bearer token obtained after a successful login.
-- @param token string
function JNCSettings:saveToken(token)
    self.store:saveSetting("token", token)
    self.store:flush()
    logger.dbg("JNCSettings: token saved")
end

--- Return the stored Bearer token, or nil if none is saved.
-- @return string|nil
function JNCSettings:getToken()
    return self.store:readSetting("token")
end

--- Remove the stored Bearer token (i.e. on logout).
function JNCSettings:clearToken()
    self.store:delSetting("token")
    self.store:flush()
    logger.dbg("JNCSettings: token cleared")
end

--- Save a generic UI preference.
-- @param key   string
-- @param value any  Must be a JSON-serialisable type.
function JNCSettings:savePref(key, value)
    self.store:saveSetting(key, value)
    self.store:flush()
end

--- Read a generic UI preference.
-- @param key     string
-- @param default any  Returned when the key is absent.
-- @return any
function JNCSettings:getPref(key, default)
    local val = self.store:readSetting(key)
    if val == nil then return default end
    return val
end

return JNCSettings