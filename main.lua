--[[--
JNC Reader — J-Novel Club reader plugin for KOReader.

Entry point. Registers the plugin with KOReader's menu system and
orchestrates the top-level UI flow:

  Main Menu → "JNC Reader" → Login (if needed) → Home
            → New Releases / Following / My Library → Series → Reader

All screens are plain text Menus. No cover images are loaded or rendered:
on the Android 16 test device, loading the image/cover widget stack and then
performing an HTTPS request reliably aborts the process in a native
("process reaper") thread. Covers are deferred to a future version. See the
git history / PRODUCT_DESIGN_DOCUMENT.md for the full investigation.

Part content is fetched on demand and images are inlined as base64 data URIs in
memory. To display it, the part is written to a single temporary .html file in
koreader/jnc-reader-tmp/ that ReaderUI opens; that file is deleted when the reader
is closed (and any previous one is cleared on the next open). At most one part
exists on disk at a time, only while it is open.

@module koplugin.jnc-reader
--]]--

local Dispatcher      = require("dispatcher")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local NetworkMgr      = require("ui/network/manager")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Menu            = require("ui/widget/menu")
local ReaderUI        = require("apps/reader/readerui")
local logger          = require("logger")
local T               = require("ffi/util").template
local _               = require("gettext")

local JNCApi      = require("api")
local JNCSettings = require("settings")
local JNCRenderer = require("renderer")

-- ---------------------------------------------------------------------------
-- Lightweight debug logger (appends to <data>/jnc-debug.log)
--
-- Off by default. Set DEBUG = true to write verbose traces to jnc-debug.log
-- (and KOReader's log) for troubleshooting; the jnc_log() call sites throughout
-- this file then become active.
-- ---------------------------------------------------------------------------

local DEBUG       = false
local DataStorage = require("datastorage")
local _LOG_PATH   = DataStorage:getDataDir() .. "/jnc-debug.log"

local function jnc_log(...)
    if not DEBUG then return end
    local parts = { os.date("%H:%M:%S") }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    local line = table.concat(parts, " ")
    local f = io.open(_LOG_PATH, "a")
    if f then
        f:write(line .. "\n")
        f:close()
    end
    logger.info("JNC:", line)
end

-- ---------------------------------------------------------------------------
-- Content filtering
-- ---------------------------------------------------------------------------

--- JNC series carry a `type` ("NOVEL" / "MANGA" / …). This plugin supports novels
-- only. Treat an absent type as a novel so we never accidentally hide content if
-- the field is ever missing.
local function isNovel(s)
    return not (s and s.type) or s.type == "NOVEL"
end

-- ---------------------------------------------------------------------------
-- Date helpers (for the New Releases feed)
-- ---------------------------------------------------------------------------

--- Parse "YYYY-MM-DDTHH:MM:SS…" into { year, month, day, hour, min }.
local function parseLaunch(launch_str)
    if not launch_str then return nil end
    local y, mo, d, h, mi = launch_str:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+)")
    if not y then return nil end
    return {
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi),
    }
end

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

--- Relative release label: "Today" / "Yesterday" / "N days ago" / "May 25, 2026".
-- Uses noon timestamps to avoid DST edge effects; launch is UTC, compared to the
-- local calendar day, which is close enough for a "days ago" display.
local function relativeLaunch(launch_str)
    local ld = parseLaunch(launch_str)
    if not ld then return "" end
    local t          = os.date("*t")
    local launch_mid = os.time({ year = ld.year, month = ld.month, day = ld.day, hour = 12 })
    local today_mid  = os.time({ year = t.year,  month = t.month,  day = t.day,  hour = 12 })
    local days = math.floor((today_mid - launch_mid) / 86400 + 0.5)
    if days <= 0 then
        return "Today"
    elseif days == 1 then
        return "Yesterday"
    elseif days < 7 then
        return days .. " days ago"
    end
    return string.format("%s %d, %d", MONTHS[ld.month] or "?", ld.day, ld.year)
end

-- ---------------------------------------------------------------------------
-- Plugin definition
-- ---------------------------------------------------------------------------

local JNCReader = WidgetContainer:extend{
    name        = "jnc-reader",
    is_doc_only = false,
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function JNCReader:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    self.settings = JNCSettings:new()
    self.api      = JNCApi:new()
    self.renderer = JNCRenderer:new()

    -- Session-scoped caches (plain Lua tables; cleared on logout).
    self._followed_list = nil  -- array of followed series
    self._followed_ids  = {}   -- [series.id] -> true (for events filtering)
    self._agg_cache     = {}   -- [slug] -> series aggregate
    self._menus         = {}   -- JNC Menu widgets currently on screen (closed before opening the reader)

    if DEBUG then
        local lf = io.open(_LOG_PATH, "a")
        if lf then
            lf:write("\n=== JNC session start " .. os.date() .. " ===\n")
            lf:close()
        end
    end
    jnc_log("init: plugin loaded (text-only v0.2)")

    -- NOTE: do NOT clean up temp files here. The plugin re-initialises during the
    -- FileManager→Reader transition, so an init-time cleanup would delete the part
    -- file that ReaderUI is about to open (crengine then fails: "unsupported or
    -- invalid document"). Old part files are instead cleared in renderer:writeTemp
    -- when the next part is opened.

    -- Restore a saved session token so the user stays logged in across restarts.
    local saved_token = self.settings:getToken()
    if saved_token then
        self.api.token = saved_token
        logger.info("JNCReader: restored saved session token")
    end
end

-- ---------------------------------------------------------------------------
-- Dispatcher / menu registration
-- ---------------------------------------------------------------------------

function JNCReader:onDispatcherRegisterActions()
    Dispatcher:registerAction("jncreader_open", {
        category = "none",
        event    = "JNCReaderOpen",
        title    = _("JNC Reader"),
        general  = true,
    })
end

function JNCReader:addToMainMenu(menu_items)
    menu_items.jncreader = {
        text         = _("JNC Reader"),
        sorting_hint = "more_tools",
        callback     = function()
            self:onJNCReaderOpen()
        end,
    }
end

function JNCReader:onJNCReaderOpen()
    NetworkMgr:runWhenOnline(function()
        if self.api:isLoggedIn() then
            self:_showMainMenu()
        else
            self:showLogin()
        end
    end)
    return true
end

-- ---------------------------------------------------------------------------
-- Home screen — full-page navigation menu
-- ---------------------------------------------------------------------------

--- Show a JNC Menu and track it so it can be torn down before opening the reader.
function JNCReader:_pushMenu(menu)
    self._menus[#self._menus + 1] = menu
    UIManager:show(menu)
end

--- Close all tracked JNC menus (newest first). Called before ReaderUI:showReader,
-- since handing off to the reader with our menus still on the UIManager stack causes
-- crengine's document load to fail ("unsupported or invalid document" → exit).
function JNCReader:_closeMenus()
    for i = #self._menus, 1, -1 do
        UIManager:close(self._menus[i])
    end
    self._menus = {}
end

function JNCReader:_showMainMenu()
    jnc_log("_showMainMenu: showing home")
    self:_pushMenu(Menu:new{
        title         = _("JNC Reader"),
        item_table    = {
            { text = _("New Releases"), callback = function() self:showNewReleases() end },
            { text = _("Following"),    callback = function() self:showFollowing()   end },
            { text = _("My Library"),   callback = function() self:showLibrary()     end },
            { text = _("Sign out"),     callback = function() self:logout()          end },
        },
        is_borderless = true,
        show_captions = false,
        onMenuHold    = function() end,
    })
end

-- ---------------------------------------------------------------------------
-- Login screen
-- ---------------------------------------------------------------------------

function JNCReader:showLogin()
    local email_input
    email_input = InputDialog:new{
        title       = _("JNC Reader — Sign in"),
        input_hint  = _("Email or username"),
        input_type  = "text",
        description = _("Enter your J-Novel Club account credentials."),
        buttons = {{
            {
                text     = _("Cancel"),
                callback = function() UIManager:close(email_input) end,
            },
            {
                text             = _("Next"),
                is_enter_default = true,
                callback         = function()
                    local email = email_input:getInputText()
                    UIManager:close(email_input)
                    if email and email ~= "" then
                        self:_showPasswordDialog(email)
                    end
                end,
            },
        }},
    }
    UIManager:show(email_input)
end

function JNCReader:_showPasswordDialog(email)
    local pw_input
    pw_input = InputDialog:new{
        title      = _("JNC Reader — Sign in"),
        input_hint = _("Password"),
        input_type = "password",
        buttons = {{
            {
                text     = _("Back"),
                callback = function()
                    UIManager:close(pw_input)
                    self:showLogin()
                end,
            },
            {
                text             = _("Sign in"),
                is_enter_default = true,
                callback         = function()
                    local password = pw_input:getInputText()
                    UIManager:close(pw_input)
                    self:_doLogin(email, password)
                end,
            },
        }},
    }
    UIManager:show(pw_input)
end

function JNCReader:_doLogin(email, password)
    local spinner = InfoMessage:new{ text = _("Signing in…") }
    UIManager:show(spinner)
    UIManager:forceRePaint()

    local ok, err = self.api:login(email, password)
    UIManager:close(spinner)

    if ok then
        self.settings:saveToken(self.api.token)
        self:_showMainMenu()
    else
        UIManager:show(InfoMessage:new{
            text = err or _("Sign-in failed. Please try again."),
        })
    end
end

-- ---------------------------------------------------------------------------
-- Session expiry helper
-- ---------------------------------------------------------------------------

function JNCReader:_handleSessionExpired()
    self.api.token = nil
    self.settings:clearToken()
    self._followed_list = nil
    self._followed_ids  = {}
    self._agg_cache     = {}
    UIManager:show(InfoMessage:new{
        text    = _("Session expired — please sign in again."),
        timeout = 3,
    })
    UIManager:scheduleIn(3.1, function() self:showLogin() end)
end

-- ---------------------------------------------------------------------------
-- Followed-series fetch (shared by Following / My Library / New Releases)
-- ---------------------------------------------------------------------------

--- Ensure self._followed_list / self._followed_ids are populated.
-- Shows an error and returns false on failure (handling 401 → re-login).
function JNCReader:_ensureFollowedList()
    if self._followed_list then
        return true
    end

    jnc_log("_ensureFollowedList: calling getFollowedSeries")
    local series_list, code = self.api:getFollowedSeries()
    jnc_log("_ensureFollowedList: returned code:", code,
        "count:", series_list and #series_list or "nil")

    if not series_list then
        if code == 401 or code == 403 then
            self:_handleSessionExpired()
        else
            UIManager:show(InfoMessage:new{
                text = _("Could not load your series. Please check your connection and try again."),
            })
        end
        return false
    end

    -- Novels only: drop manga (and any non-novel) series here so Following,
    -- My Library, and New Releases (which filters events by _followed_ids) are all
    -- novel-only from one place.
    self._followed_list = {}
    self._followed_ids  = {}
    for _, s in ipairs(series_list) do
        if isNovel(s) then
            self._followed_list[#self._followed_list + 1] = s
            if s.id then self._followed_ids[s.id] = true end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Following screen
-- ---------------------------------------------------------------------------

function JNCReader:showFollowing()
    jnc_log("showFollowing: start")
    local spinner = InfoMessage:new{ text = _("Loading Following…") }
    UIManager:show(spinner)
    UIManager:forceRePaint()

    local ok = self:_ensureFollowedList()
    UIManager:close(spinner)
    if not ok then return end

    if #self._followed_list == 0 then
        UIManager:show(InfoMessage:new{
            text = _("You are not following any series. Visit j-novel.club to follow series."),
        })
        return
    end

    local sorted = {}
    for _, s in ipairs(self._followed_list) do sorted[#sorted + 1] = s end
    table.sort(sorted, function(a, b) return (a.title or "") < (b.title or "") end)

    local items = {}
    for _, series in ipairs(sorted) do
        items[#items + 1] = {
            text     = series.title or series.titleslug or series.id or "Unknown",
            callback = function() self:showSeries(series) end,
        }
    end

    jnc_log("showFollowing: showing", #items, "series")
    self:_pushMenu(Menu:new{
        title         = _("Following"),
        item_table    = items,
        is_borderless = true,
        show_captions = false,
        onMenuHold    = function() end,
    })
end

-- ---------------------------------------------------------------------------
-- My Library screen
--
-- Lists followed series; owned volumes are marked with ★ inside the series
-- view. (A dedicated cross-series owned-volume listing requires fetching every
-- series aggregate up front, which is deferred.)
-- ---------------------------------------------------------------------------

function JNCReader:showLibrary()
    jnc_log("showLibrary: start")
    local spinner = InfoMessage:new{ text = _("Loading My Library…") }
    UIManager:show(spinner)
    UIManager:forceRePaint()

    local ok = self:_ensureFollowedList()
    UIManager:close(spinner)
    if not ok then return end

    if #self._followed_list == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No followed series yet. Follow and purchase volumes at j-novel.club."),
        })
        return
    end

    local sorted = {}
    for _, s in ipairs(self._followed_list) do sorted[#sorted + 1] = s end
    table.sort(sorted, function(a, b) return (a.title or "") < (b.title or "") end)

    local items = {}
    for _, series in ipairs(sorted) do
        items[#items + 1] = {
            text     = series.title or series.titleslug or series.id or "Unknown",
            callback = function() self:showSeries(series) end,
        }
    end

    jnc_log("showLibrary: showing", #items, "series")
    self:_pushMenu(Menu:new{
        title         = _("My Library — tap a series to see owned volumes"),
        item_table    = items,
        is_borderless = true,
        show_captions = false,
        onMenuHold    = function() end,
    })
end

-- ---------------------------------------------------------------------------
-- New Releases screen
-- ---------------------------------------------------------------------------

function JNCReader:showNewReleases()
    jnc_log("showNewReleases: start")
    local spinner = InfoMessage:new{ text = _("Loading New Releases…") }
    UIManager:show(spinner)
    UIManager:forceRePaint()

    -- Need the followed-series IDs to filter the global events feed.
    if not self:_ensureFollowedList() then
        UIManager:close(spinner)
        return
    end

    local now_str  = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time())
    local past_str = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 30 * 24 * 60 * 60)
    jnc_log("showNewReleases: calling getEvents", past_str, "→", now_str)
    local events, code = self.api:getEvents(past_str, now_str)
    jnc_log("showNewReleases: getEvents returned code:", code,
        "count:", events and #events or "nil")
    UIManager:close(spinner)

    if not events then
        if code == 401 or code == 403 then
            self:_handleSessionExpired()
        else
            UIManager:show(InfoMessage:new{
                text = _("Could not load New Releases. Please check your connection and try again."),
            })
        end
        return
    end

    -- Keep only pre-pub novel releases for series the user follows.
    -- (_followed_ids is already novel-only; the isNovel check is a backstop.)
    local filtered = {}
    for _, ev in ipairs(events) do
        local sid = ev.serie and ev.serie.id
        local details = ev.details or ""
        if sid and self._followed_ids[sid] and details:find("Prepub", 1, true)
            and isNovel(ev.serie) then
            filtered[#filtered + 1] = ev
        end
    end
    jnc_log("showNewReleases: filtered to", #filtered, "followed pre-pub events")

    if #filtered == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No new releases from your followed series in the last 30 days."),
        })
        return
    end

    -- Most recent first.
    table.sort(filtered, function(a, b) return (a.launch or "") > (b.launch or "") end)

    -- Flat list, newest first: part name + relative release time; tap opens reader.
    local items = {}
    for _, ev in ipairs(filtered) do
        items[#items + 1] = {
            text      = self:_eventPartTitle(ev),
            mandatory = relativeLaunch(ev.launch),
            callback  = function() self:_openRelease(ev) end,
        }
    end

    jnc_log("showNewReleases: showing", #items, "rows")
    self:_pushMenu(Menu:new{
        title         = _("New Releases"),
        item_table    = items,
        is_borderless = true,
        show_captions = false,
        onMenuHold    = function() end,
    })
end

--- Part name for a release row.
-- `event.name` holds the full part title (e.g. "Proud to Be the Villainess:
-- Volume 2 Part 6"); `event.details` is just "Prepub Publishing". Fall back to
-- the series title only if `name` is somehow absent.
function JNCReader:_eventPartTitle(ev)
    if ev.name and ev.name ~= "" then
        return ev.name
    end
    return ev.title or (ev.serie and ev.serie.title) or "Unknown release"
end

--- Open a release's part directly in the reader.
-- The /events payload has no confirmed part id, so resolve the exact part via the
-- series aggregate: match by launch datetime, else fall back to the newest part.
function JNCReader:_openRelease(ev)
    local serie = ev.serie or {}
    local slug  = serie.slug or serie.titleslug or serie.id
    jnc_log("_openRelease: slug", slug, "launch", ev.launch)

    local spinner = InfoMessage:new{ text = _("Loading…") }
    UIManager:show(spinner)
    UIManager:forceRePaint()

    local agg = self._agg_cache[slug]
    if not agg then
        local code
        agg, code = self.api:getSeriesAggregate(slug)
        if not agg or not agg.volumes then
            UIManager:close(spinner)
            if code == 401 or code == 403 then
                self:_handleSessionExpired()
            else
                UIManager:show(InfoMessage:new{
                    text = _("Could not load this release. Please try again."),
                })
            end
            return
        end
        self._agg_cache[slug] = agg
    end

    -- Find the part: exact launch match first, else the newest part overall.
    local match, newest
    for _, vol_entry in ipairs(agg.volumes) do
        for _, part in ipairs(vol_entry.parts or {}) do
            if ev.launch and part.launch == ev.launch then
                match = part
            end
            if not newest or (part.launch or "") > (newest.launch or "") then
                newest = part
            end
        end
    end
    local part = match or newest

    UIManager:close(spinner)

    if not part or not part.id then
        UIManager:show(InfoMessage:new{
            text = _("Could not locate this release's part."),
        })
        return
    end

    self:openReader(part, serie.title)
end

-- ---------------------------------------------------------------------------
-- Series screen — volumes and parts
-- ---------------------------------------------------------------------------

function JNCReader:showSeries(series)
    local slug = series.slug or series.titleslug or series.id
    jnc_log("showSeries: start, slug:", slug)

    local agg = self._agg_cache[slug]
    if not agg then
        local spinner = InfoMessage:new{
            text = T(_("Loading %1…"), series.title or slug),
        }
        UIManager:show(spinner)
        UIManager:forceRePaint()

        local code
        agg, code = self.api:getSeriesAggregate(slug)
        UIManager:close(spinner)

        if not agg or not agg.volumes then
            if code == 401 or code == 403 then
                self:_handleSessionExpired()
            else
                UIManager:show(InfoMessage:new{
                    text = _("Could not load series data. Please try again."),
                })
            end
            return
        end
        self._agg_cache[slug] = agg
    end

    local items = {}
    for _, vol_entry in ipairs(agg.volumes) do
        local vol   = vol_entry.volume or {}
        local parts = vol_entry.parts or {}

        local owned = vol.owned and "  ★ owned" or ""
        items[#items + 1] = {
            text     = (vol.title or ("Volume " .. tostring(vol.number or "?"))) .. owned,
            bold     = true,
            callback = function() end,
        }

        for _, part in ipairs(parts) do
            local part_title = part.title or ("Part " .. tostring(part.number or "?"))
            items[#items + 1] = {
                text     = "    " .. part_title,
                callback = function() self:openReader(part, series.title) end,
            }
        end
    end

    if #items == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No parts are currently available for this series."),
        })
        return
    end

    jnc_log("showSeries: showing", #items, "rows")
    self:_pushMenu(Menu:new{
        title         = series.title or slug,
        item_table    = items,
        is_borderless = true,
        show_captions = false,
        onMenuHold    = function() end,
    })
end

-- ---------------------------------------------------------------------------
-- Reader — fetch + inline images → temp file → ReaderUI
-- ---------------------------------------------------------------------------

function JNCReader:openReader(part, series_title)
    local part_title = part.title or (series_title and (series_title .. " — Part") or "Part")
    jnc_log("openReader: part", part.id)

    local spinner = InfoMessage:new{ text = T(_("Loading %1…"), part_title) }
    UIManager:show(spinner)
    UIManager:forceRePaint()

    local xhtml, err = self.api:getPartContent(part.id)
    UIManager:close(spinner)

    if not xhtml then
        if err and (err:find("401") or err:find("Access denied")) then
            self:_handleSessionExpired()
        else
            UIManager:show(InfoMessage:new{
                text = err or _("Could not load part content. Please try again."),
            })
        end
        return
    end

    local path, write_err = self.renderer:writeTemp(xhtml, part.id)
    xhtml = nil -- luacheck: ignore 311

    if not path then
        UIManager:show(InfoMessage:new{
            text = write_err or _("Could not prepare content for display."),
        })
        return
    end

    -- Tear down our menus, then hand off to the reader. The temp file is deleted
    -- when the reader closes (onCloseDocument); writeTemp also clears any prior file
    -- on the next open as a safety net.
    self:_closeMenus()
    ReaderUI:showReader(path)
end

-- ---------------------------------------------------------------------------
-- Clean exit from a part we opened
-- ---------------------------------------------------------------------------

--- Fires (in the reader context) when any document is closed. For the temp parts
-- we generate, return the file browser to the home folder instead of the temp dir,
-- drop the part from the recent-files history, and delete the temp file.
-- A no-op for normal books. Must not return true (CloseDocument is a broadcast).
function JNCReader:onCloseDocument()
    local doc  = self.ui and self.ui.document
    local path = doc and doc.file
    if path and path:find("jnc-reader-tmp", 1, true) then
        -- Best-effort: send the file browser to the home folder rather than the
        -- temp dir. (Not always honoured by the plain close path — documented as a
        -- known limitation.)
        local ok_fmu, filemanagerutil = pcall(require, "apps/filemanager/filemanagerutil")
        if ok_fmu and self.ui.setLastDirForFileBrowser then
            self.ui:setLastDirForFileBrowser(filemanagerutil.getHomeFolder())
        end
        -- Drop the temp part from recent-files and delete it (anti-piracy).
        local ok_h, ReadHistory = pcall(require, "readhistory")
        if ok_h then ReadHistory:removeItemByPath(path) end
        os.remove(path)
    end
end

-- ---------------------------------------------------------------------------
-- Sign out
-- ---------------------------------------------------------------------------

function JNCReader:logout()
    self.api:logout()
    self.settings:clearToken()
    self._followed_list = nil
    self._followed_ids  = {}
    self._agg_cache     = {}
    UIManager:show(InfoMessage:new{ text = _("Signed out of JNC Reader.") })
end

return JNCReader
