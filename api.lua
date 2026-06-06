--[[--
JNC API client for JNC Reader.

Communicates with the labs.j-novel.club v2 API.
Responses and images are handled in memory. Part content is returned to the
caller, which writes a single short-lived temp file for KOReader's reader and
deletes it when the reader closes (see renderer.lua / main.lua).

Endpoint bases (confirmed from jncep v55 source):
  API:   https://labs.j-novel.club/app/v2
  Embed: https://labs.j-novel.club/embed/v2

CDN image hosts:
  https://cdn.j-novel.club
  https://d2dq7ifhe7bu0f.cloudfront.net

@module koplugin.jnc-reader.api
--]]--

local https  = require("ssl.https")
local ltn12  = require("ltn12")
local json   = require("json")
local logger = require("logger")
local mime   = require("mime")  -- bundled with LuaSocket; used for base64

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local API_BASE   = "https://labs.j-novel.club/app/v2"
local EMBED_BASE = "https://labs.j-novel.club/embed/v2"

-- CDN hosts that serve part images (authenticated).
local CDN_HOSTS = {
    "https://cdn.j-novel.club",
    "https://d2dq7ifhe7bu0f.cloudfront.net",
}

-- Safe JSON decode. KOReader's json (rapidjson) *raises* on invalid input, so a
-- malformed body — an HTML error/gateway page, or a future API change — would crash
-- the plugin if decoded directly. Wrap it so callers just get nil and degrade.
local function decode_json(raw)
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, value = pcall(json.decode, raw)
    if ok then return value end
    logger.warn("JNCApi: JSON decode failed (got", #raw, "bytes; head:", raw:sub(1, 80), ")")
    return nil
end

-- ---------------------------------------------------------------------------
-- JNCApi class
-- ---------------------------------------------------------------------------

--- @class JNCApi
local JNCApi = {}
JNCApi.__index = JNCApi

--- Create a new API client instance.
-- @return JNCApi
function JNCApi:new()
    local o = {
        -- Bearer token set after a successful login; nil when logged out.
        token = nil,
    }
    setmetatable(o, self)
    return o
end

-- ---------------------------------------------------------------------------
-- Internal HTTP helpers
-- ---------------------------------------------------------------------------

--- Perform an authenticated HTTPS request and return the raw response body
-- and HTTP status code.
-- @param method        string      "GET" or "POST"
-- @param url           string      Full absolute URL
-- @param body          string|nil  Pre-encoded request body (POST only)
-- @param extra_headers table|nil   Additional headers to merge
-- @return string|nil, number  Raw response body (or nil on network failure), code
function JNCApi:_raw_request(method, url, body, extra_headers)
    local chunks = {}
    local headers = {
        ["Accept"]          = "application/json",
        ["Accept-Encoding"] = "identity",  -- LuaSocket can't decompress gzip/br
    }
    if self.token then
        headers["Authorization"] = "Bearer " .. self.token
    end
    if body then
        headers["Content-Type"]   = "application/json"
        headers["Content-Length"] = tostring(#body)
    end
    if extra_headers then
        for k, v in pairs(extra_headers) do
            headers[k] = v
        end
    end

    logger.dbg("JNCApi: →", method, url)
    local ok, code
    local call_ok, call_err = pcall(function()
        ok, code = https.request({
            method  = method,
            url     = url,
            headers = headers,
            source  = body and ltn12.source.string(body) or nil,
            sink    = ltn12.sink.table(chunks),
        })
    end)
    if not call_ok then
        logger.warn("JNCApi: https.request threw:", call_err, "url:", url)
        return nil, 0
    end
    logger.dbg("JNCApi: ←", code, url)

    if not ok then
        logger.warn("JNCApi: request failed:", code, "url:", url)
        return nil, 0
    end

    return table.concat(chunks), code
end

--- Perform an API request and return the decoded JSON body and HTTP code.
-- Appends ?format=json automatically; encodes the body table if provided.
-- @param method string
-- @param path   string  Path relative to API_BASE (e.g. "/auth/login")
-- @param body   table|nil
-- @return table|nil, number
function JNCApi:_json_request(method, path, body)
    local url = API_BASE .. path
    url = url .. (path:find("?") and "&" or "?") .. "format=json"

    local encoded = body and json.encode(body) or nil
    local raw, code = self:_raw_request(method, url, encoded)

    if not raw or code == 0 then
        return nil, 0
    end

    local decoded = decode_json(raw)
    if not decoded then
        return nil, code
    end

    return decoded, code
end

--- Fetch binary content from an absolute URL into memory.
-- Used for images (CDN) and the embed XHTML endpoint.
-- Nothing is written to disk.
-- @param url     string
-- @param accept  string|nil  Value for the Accept header
-- @return string|nil  Raw bytes, or nil on failure
-- @return number       HTTP status code (0 on network failure)
function JNCApi:_fetch_bytes(url, accept)
    -- Delegate to _raw_request so this path also sends Accept-Encoding: identity
    -- (the JNC server compresses by default; without it the embed XHTML / images
    -- come back gzip/Brotli-encoded and LuaSocket cannot decode them). _raw_request
    -- also adds the Bearer token, pcall safety, and returns the same (body, code).
    return self:_raw_request("GET", url, nil, { ["Accept"] = accept or "*/*" })
end

-- ---------------------------------------------------------------------------
-- Auth
-- ---------------------------------------------------------------------------

--- Authenticate with J-Novel Club and store the Bearer token.
--
-- Endpoint: POST /app/v2/auth/login
-- Payload:  { login, password, slim: true }
-- Response: { "id": "<token>", ... }
-- (Token field is "id", not "token" — confirmed from jncep v55 source.)
--
-- @param login    string  Email or username
-- @param password string
-- @return boolean, string|nil  true on success; false + error message on failure
function JNCApi:login(login, password)
    local body = { login = login, password = password, slim = true }
    local data, code = self:_json_request("POST", "/auth/login", body)

    if (code == 200 or code == 201) and data and data.id then
        self.token = data.id
        logger.info("JNCApi: login successful")
        return true, nil
    end

    local msg
    if     code == 401 then msg = "Invalid email or password."
    elseif code == 429 then msg = "Too many login attempts — please wait and try again."
    elseif code == 0   then msg = "Could not reach J-Novel Club. Check your internet connection."
    else                    msg = string.format("Login failed (HTTP %d).", code)
    end

    logger.warn("JNCApi: login failed, code:", code)
    return false, msg
end

--- Invalidate the session server-side and clear the local token.
function JNCApi:logout()
    if self.token then
        self:_json_request("POST", "/auth/logout")
        self.token = nil
        logger.info("JNCApi: logged out")
    end
end

--- Return true if a Bearer token is currently held.
-- Does not verify the token is still valid server-side.
-- @return boolean
function JNCApi:isLoggedIn()
    return self.token ~= nil
end

-- ---------------------------------------------------------------------------
-- Followed series
-- ---------------------------------------------------------------------------

--- Fetch the list of series the authenticated user is following.
--
-- Endpoint: POST /app/v2/series { only_follows: true }
-- Paginated: loops until pagination.lastPage == true, incrementing ?skip=N.
--
-- @return table|nil  Array of all followed series objects, or nil on any error
-- @return number|nil HTTP status code of the first failed request (for 401 detection)
function JNCApi:getFollowedSeries()
    local all_series = {}
    local skip = 0
    repeat
        local url = API_BASE .. "/series?format=json&skip=" .. skip
        local body = json.encode({ only_follows = true })
        local raw, code = self:_raw_request("POST", url, body)

        if code ~= 200 or not raw then
            logger.warn("JNCApi: getFollowedSeries failed, code:", code)
            return nil, code
        end

        local data = decode_json(raw)
        if not data then
            return nil, code
        end

        local page = data.series or {}
        for _, s in ipairs(page) do
            table.insert(all_series, s)
        end
        skip = skip + #page

        if data.pagination and data.pagination.lastPage then break end
        if #page == 0 then break end  -- safety guard
    until false

    return all_series, 200
end

-- ---------------------------------------------------------------------------
-- Owned library
-- ---------------------------------------------------------------------------

--- Fetch the user's owned volumes ("library").
--
-- Endpoint: GET /app/v2/me/library?format=json&skip=N
-- Returns an object: { books: [ { id, volume{...,owned}, serie{...}, ... } ], pagination }
-- Each book pairs an owned volume with its parent series, so this is a flat
-- "everything I own" list (no per-series aggregate fetch needed).
--
-- @return table|nil  Array of all book entries, or nil on error
-- @return number     HTTP status code (200 on success)
function JNCApi:getLibrary()
    if not self.token then
        return nil, 0
    end

    local all_books = {}
    local skip = 0
    repeat
        local url = API_BASE .. "/me/library?format=json&skip=" .. skip
        local raw, code = self:_raw_request("GET", url, nil)
        if not raw or code ~= 200 then
            logger.warn("JNCApi: getLibrary failed, code:", code, "skip:", skip)
            if #all_books > 0 then break end
            return nil, code or 0
        end

        local data = decode_json(raw)
        if not data then
            if #all_books > 0 then break end
            return nil, code
        end

        local page = data.books or {}
        for _, b in ipairs(page) do
            all_books[#all_books + 1] = b
        end
        skip = skip + #page

        if data.pagination and data.pagination.lastPage then break end
        if #page == 0 then break end
        if #all_books >= 5000 then break end  -- sanity cap
    until false

    return all_books, 200
end

-- ---------------------------------------------------------------------------
-- Series / volume / part metadata
-- ---------------------------------------------------------------------------

--- Fetch aggregated metadata for a series in one round-trip.
--
-- Endpoint: GET /app/v2/series/{slug}/aggregate
-- Returns an object with shape:
--   { series: {...}, volumes: [ { volume: {...}, parts: [{...}, ...] }, ... ] }
--
-- This is the most efficient way to populate the series/parts screen and is
-- the same approach used by jncep v55 (fetch_meta in core.py).
--
-- @param series_slug string  Series slug or UUID
-- @return table|nil  Aggregate object, or nil on error
function JNCApi:getSeriesAggregate(series_slug)
    local data, code = self:_json_request(
        "GET",
        "/series/" .. series_slug .. "/aggregate"
    )
    if code == 200 then
        return data, 200
    end
    logger.warn("JNCApi: getSeriesAggregate failed, code:", code, "slug:", series_slug)
    return nil, code
end

-- ---------------------------------------------------------------------------
-- Part content (streaming — nothing written to disk)
-- ---------------------------------------------------------------------------

--- Convert a JNC CDN WebP URL to its JPEG equivalent.
--
-- JNC's CDN has served WebP images by default since late 2024. KOReader
-- may not support WebP in all environments. The conversion is documented at:
--   https://forums.j-novel.club/post/374895
-- and is implemented identically in jncep v55 (webp_to_jpeg in core.py):
--   url.replace("/webp/", "/jpg/", 1)
--
-- @param url string
-- @return string  URL with the first "/webp/" segment replaced by "/jpg/"
local function webpToJpeg(url)
    return (url:gsub("/webp/", "/jpg/", 1))
end

--- Return true when the URL belongs to a known JNC CDN host.
-- @param url string
-- @return boolean
local function isCdnUrl(url)
    for _, host in ipairs(CDN_HOSTS) do
        if url:sub(1, #host) == host then
            return true
        end
    end
    return false
end

--- Extract every <img src="..."> URL from an XHTML string.
--
-- JNC embed XHTML uses absolute CDN URLs for all images (confirmed from
-- jncep source and the labs.j-novel.club forum thread). Single and double
-- quotes are both matched.
--
-- @param xhtml string
-- @return table  Array of URL strings (may be empty; duplicates removed)
local function extractImageUrls(xhtml)
    local urls = {}
    local seen = {}
    for url in xhtml:gmatch('<img[^>]+src=["\']([^"\']+)["\']') do
        if not seen[url] then
            seen[url] = true
            table.insert(urls, url)
        end
    end
    return urls
end

--- Escape all Lua pattern magic characters in a plain string.
-- Used so that CDN URLs (which contain dots, hyphens, etc.) can be passed
-- to string.gsub as a literal pattern.
-- @param s string
-- @return string
local function escapePlain(s)
    return (s:gsub("([%.%+%-%*%?%[%]%^%$%(%)%%])", "%%%1"))
end

--- Fetch an image from the CDN into memory and return a data URI string.
--
-- The WebP → JPEG URL conversion is applied before fetching.
-- Raw bytes are base64-encoded with mime.b64 (LuaSocket) and returned as:
--   "data:image/jpeg;base64,<base64>"
-- Nothing is written to disk at any point.
--
-- @param url string  Absolute CDN URL
-- @return string|nil  data URI string, or nil on failure
function JNCApi:_fetchImageAsDataUri(url)
    local jpeg_url = webpToJpeg(url)
    local bytes, code = self:_fetch_bytes(jpeg_url)

    if not bytes or #bytes == 0 or code ~= 200 then
        logger.warn("JNCApi: image fetch failed, code:", code, "url:", jpeg_url)
        return nil
    end

    -- mime.b64 wraps output at 76 chars with CRLF; strip all whitespace so
    -- the result is safe to embed inside an XML attribute value.
    local b64 = mime.b64(bytes):gsub("%s+", "")
    return "data:image/jpeg;base64," .. b64
end

--- Fetch a part's XHTML content and inline all images as base64 data URIs.
--
-- This produces a self-contained XHTML document that KOReader's HTML viewer
-- can render without any further network requests or disk access.
--
-- Flow (mirrors jncep v55 approach):
--   1. GET /embed/v2/{part_id}/data.xhtml  → XHTML with absolute CDN image URLs
--   2. Parse all <img src="..."> tags
--   3. For each CDN URL: fetch bytes → WebP→JPEG → base64 → data URI
--   4. Replace src="<cdn-url>" with src="data:image/jpeg;base64,..." in XHTML
--   5. Return the modified XHTML string (in memory only, never touches disk)
--
-- @param part_id string  Part UUID
-- @return string|nil  Self-contained XHTML ready for display, or nil on error
-- @return string|nil  Error message on failure, nil on success
-- @return number|nil  HTTP status code on failure (e.g. 401 = expired, 403 = no access)
function JNCApi:getPartContent(part_id)
    if not self.token then
        return nil, "Not logged in.", 401
    end

    -- Step 1: Fetch the XHTML.
    local xhtml_url = EMBED_BASE .. "/" .. part_id .. "/data.xhtml"
    local xhtml, code = self:_fetch_bytes(
        xhtml_url,
        "application/xhtml+xml, text/html"
    )

    if not xhtml then
        return nil, "Network error fetching part content. Check your connection.", code or 0
    end
    if code == 401 then
        -- Token expired/invalid → caller re-authenticates.
        return nil, "Your session has expired. Please sign in again.", 401
    end
    if code == 403 then
        -- Authenticated but not entitled (subscription tier / not yet available).
        return nil, "Access denied — your subscription may not cover this content.", 403
    end
    if code ~= 200 then
        return nil, string.format("Server returned HTTP %d for part content.", code), code
    end

    logger.dbg("JNCApi: fetched part", part_id, "(", #xhtml, "bytes XHTML)")

    -- Step 2: Extract image URLs.
    local img_urls = extractImageUrls(xhtml)
    logger.dbg("JNCApi: found", #img_urls, "image(s) in part", part_id)

    -- Steps 3 & 4: Fetch each image and replace its src with a data URI.
    for _, img_url in ipairs(img_urls) do
        if isCdnUrl(img_url) then
            local data_uri = self:_fetchImageAsDataUri(img_url)
            if data_uri then
                xhtml = xhtml:gsub(escapePlain(img_url), data_uri)
                logger.dbg("JNCApi: inlined image", img_url)
            else
                -- Leave the original src intact; the viewer will show a broken
                -- image rather than crashing.
                logger.warn("JNCApi: could not inline image, src left as-is:", img_url)
            end
        else
            logger.warn("JNCApi: skipping non-CDN image src:", img_url)
        end
    end

    -- Step 5: Normalise for crengine's standalone-file format detection.
    -- crengine sniffs the document format from the first bytes. A leading
    -- <?xml ...?> prolog makes it attempt XML/FB2 parsing and then fail
    -- ("unsupported or invalid document") when it finds <html> instead of
    -- <FictionBook>. Stripping the prolog makes the file begin with
    -- <!DOCTYPE html>/<html>, so it is detected and parsed as HTML.
    xhtml = xhtml:gsub("^%s*<%?xml.-%?>%s*", "")

    -- Return the self-contained HTML (entirely in memory).
    return xhtml, nil
end

-- ---------------------------------------------------------------------------
-- Events (New Releases feed)
-- ---------------------------------------------------------------------------

--- Fetch JNC events within a date range (paginated to cover the whole window).
--
-- Endpoint: GET /app/v2/events?format=json&limit=200&skip=N&start_date=X&end_date=Y
-- The endpoint caps each page at 200 events and the global feed easily exceeds that
-- over a month, so we loop on ?skip until pagination.lastPage. The API returns ALL
-- JNC events (not filtered by follows); callers filter client-side by matching
-- event.serie.id against the user's followed series.
--
-- @param start_str string  ISO 8601 UTC datetime, e.g. "2026-05-07T00:00:00Z"
-- @param end_str   string  ISO 8601 UTC datetime
-- @return table|nil  Array of all event objects in the window, or nil on error
-- @return number     HTTP status code (200 on success)
function JNCApi:getEvents(start_str, end_str)
    if not self.token then
        return nil, 0
    end

    local all_events = {}
    local skip = 0
    repeat
        local url = API_BASE
            .. "/events?format=json&limit=200&skip=" .. skip
            .. "&start_date=" .. start_str
            .. "&end_date="   .. end_str

        local raw, code = self:_raw_request("GET", url, nil)
        if not raw or code ~= 200 then
            logger.warn("JNCApi: getEvents failed, code:", code, "skip:", skip)
            -- Return what we have if we already got a page; else report the error.
            if #all_events > 0 then break end
            return nil, code or 0
        end

        local data = decode_json(raw)
        if not data then
            if #all_events > 0 then break end
            return nil, code
        end

        local page = data.events or {}
        for _, e in ipairs(page) do
            all_events[#all_events + 1] = e
        end
        skip = skip + #page

        if data.pagination and data.pagination.lastPage then break end
        if #page == 0 then break end          -- safety guard
        if #all_events >= 1000 then break end  -- sanity cap (~5 pages)
    until false

    return all_events, 200
end

return JNCApi