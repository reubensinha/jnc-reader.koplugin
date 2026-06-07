--[[--
Update checker for JNC Reader.

Checks the plugin's GitHub Releases for a newer version than the one running and
reports it, so the user knows an update is available. Best-effort and silent on
failure.

IMPORTANT: this talks to api.github.com, NOT the J-Novel Club API. It must never
send the JNC bearer token, so it uses its own bare HTTPS request rather than
JNCApi:_raw_request (which attaches the token). GitHub requires a User-Agent header
and rate-limits unauthenticated requests to 60/hour per IP (we check at most once a
day, so that's plenty).

@module koplugin.jnc-reader.updater
--]]--

local https  = require("ssl.https")
local ltn12  = require("ltn12")
local json   = require("json")
local logger = require("logger")

local Updater = {}

local RELEASES_API = "https://api.github.com/repos/%s/releases/latest"
local TIMEOUT      = 10  -- seconds

--- Safe JSON decode (rapidjson raises on bad input).
local function decode_json(raw)
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, value = pcall(json.decode, raw)
    if ok then return value end
    return nil
end

--- Parse a version string/table into a {major, minor, patch} number array.
-- Accepts "v0.3.0", "0.3.0", "0.3", or a table like {0,3,0}.
local function parse_version(v)
    if type(v) == "table" then
        return { tonumber(v[1]) or 0, tonumber(v[2]) or 0, tonumber(v[3]) or 0 }
    end
    if type(v) ~= "string" then return nil end
    local nums = {}
    for n in v:gmatch("%d+") do
        nums[#nums + 1] = tonumber(n)
        if #nums == 3 then break end
    end
    if #nums == 0 then return nil end
    return { nums[1] or 0, nums[2] or 0, nums[3] or 0 }
end

--- Return true if version `a` is strictly older than version `b`.
local function is_older(a, b)
    for i = 1, 3 do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x < y end
    end
    return false
end

--- Fetch the latest published release tag from GitHub (e.g. "v0.3.0").
-- @param repo string  "owner/name"
-- @return string|nil  tag_name, or nil on any failure
function Updater.fetchLatestTag(repo)
    if not repo or repo == "" then return nil end
    local url = string.format(RELEASES_API, repo)
    local chunks = {}
    local ok, code
    local call_ok = pcall(function()
        ok, code = https.request({
            url     = url,
            method  = "GET",
            headers = {
                ["User-Agent"]      = "jnc-reader.koplugin",  -- GitHub requires this
                ["Accept"]          = "application/vnd.github+json",
                ["Accept-Encoding"] = "identity",
            },
            sink    = ltn12.sink.table(chunks),
        })
    end)
    if not call_ok then
        logger.dbg("Updater: request threw:", code)
        return nil
    end
    if not ok or code ~= 200 then
        logger.dbg("Updater: GitHub returned", code)
        return nil
    end
    local data = decode_json(table.concat(chunks))
    if type(data) ~= "table" then return nil end
    return data.tag_name
end

--- Check whether a newer release exists.
-- @param repo    string  "owner/name"
-- @param current string|table  current version (e.g. {0,2,0} from _meta.lua)
-- @return string|nil  the newer tag (e.g. "v0.3.0") if an update is available
-- @return boolean     whether the check completed (false = request failed; caller may retry)
function Updater.checkForUpdate(repo, current)
    local tag = Updater.fetchLatestTag(repo)
    if not tag then
        return nil, false
    end
    local latest = parse_version(tag)
    local cur    = parse_version(current)
    if not latest or not cur then
        return nil, true
    end
    if is_older(cur, latest) then
        return tag, true
    end
    return nil, true
end

return Updater
