--[[--
JNC Reader — J-Novel Club reader plugin for KOReader.

Entry point. Registers the plugin with KOReader's menu system and
orchestrates the top-level UI flow:

  Main Menu → "JNC Reader" → Login (if needed) → Library → Series → Reader

Content is fetched from the JNC API, images are inlined as data URIs in
memory, then written to a short-lived temp file that KOReader's ReaderUI
opens. The temp file is deleted as soon as the document is loaded.

No content is written to user-visible storage at any point.

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

    -- Clean up any temp files left over from a previous crash.
    self.renderer:cleanupStaleTemps()

    -- Restore a saved session token so the user stays logged in across
    -- KOReader restarts.
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

function JNCReader:_showMainMenu()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title   = _("JNC Reader"),
        buttons = {
            {{
                text     = _("Library"),
                callback = function()
                    UIManager:close(dialog)
                    self:showLibrary()
                end,
            }},
            {{
                text     = _("Sign out"),
                callback = function()
                    UIManager:close(dialog)
                    self:logout()
                end,
            }},
        },
    }
    UIManager:show(dialog)
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
        self:showLibrary()
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
    UIManager:show(InfoMessage:new{
        text    = _("Session expired — please sign in again."),
        timeout = 3,
    })
    UIManager:scheduleIn(3.1, function() self:showLogin() end)
end

-- ---------------------------------------------------------------------------
-- Library screen — followed series
-- ---------------------------------------------------------------------------

function JNCReader:showLibrary()
    local spinner = InfoMessage:new{ text = _("Loading library…") }
    UIManager:show(spinner)
    UIManager:forceRePaint()

    -- Fetch followed series using POST /series { only_follows: true }.
    local series_list, code = self.api:getFollowedSeries()
    UIManager:close(spinner)

    if not series_list then
        if code == 401 or code == 403 then
            self:_handleSessionExpired()
        else
            UIManager:show(InfoMessage:new{
                text = _("Could not load library. Please check your connection and try again."),
            })
        end
        return
    end

    if #series_list == 0 then
        UIManager:show(InfoMessage:new{
            text = _("You are not following any series. Visit j-novel.club to follow series."),
        })
        return
    end

    -- Sort alphabetically.
    table.sort(series_list, function(a, b)
        return (a.title or "") < (b.title or "")
    end)

    local items = {}
    for _, series in ipairs(series_list) do
        local title = series.title or series.titleslug or series.id or "Unknown"
        table.insert(items, {
            text     = title,
            callback = function()
                self:showSeries(series)
            end,
        })
    end

    local menu = Menu:new{
        title         = _("JNC Reader — Library"),
        item_table    = items,
        is_borderless = true,
        show_captions = false,
        onMenuHold    = function() end,
    }
    UIManager:show(menu)
end

-- ---------------------------------------------------------------------------
-- Series screen — volumes and parts
-- ---------------------------------------------------------------------------

function JNCReader:showSeries(series)
    local slug = series.slug or series.titleslug or series.id
    local spinner = InfoMessage:new{
        text = T(_("Loading %1…"), series.title or slug),
    }
    UIManager:show(spinner)
    UIManager:forceRePaint()

    -- One request gives us everything: series metadata + all volumes + all parts.
    local agg, code = self.api:getSeriesAggregate(slug)
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

    local items = {}
    for _, vol_entry in ipairs(agg.volumes) do
        local vol  = vol_entry.volume or {}
        local parts = vol_entry.parts or {}

        -- Volume header row.
        table.insert(items, {
            text     = vol.title or ("Volume " .. tostring(vol.number or "?")),
            bold     = true,
            callback = function() end,
        })

        for _, part in ipairs(parts) do
            local part_title = part.title or ("Part " .. tostring(part.number or "?"))
            table.insert(items, {
                text     = "  " .. part_title,
                callback = function()
                    self:openReader(part, series.title)
                end,
            })
        end
    end

    if #items == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No parts are currently available for this series."),
        })
        return
    end

    local menu = Menu:new{
        title         = series.title or slug,
        item_table    = items,
        is_borderless = true,
        show_captions = false,
        onMenuHold    = function() end,
    }
    UIManager:show(menu)
end

-- ---------------------------------------------------------------------------
-- Reader — fetch + inline images → temp file → ReaderUI
-- ---------------------------------------------------------------------------

function JNCReader:openReader(part, series_title)
    local part_title = part.title or (series_title and (series_title .. " — Part") or "Part")

    local spinner = InfoMessage:new{
        text = T(_("Loading %1…"), part_title),
    }
    UIManager:show(spinner)
    UIManager:forceRePaint()

    -- Fetch XHTML with all images already inlined as base64 data URIs.
    -- Nothing is written to disk during this step.
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

    -- Write the self-contained XHTML to a short-lived temp file in
    -- KOReader's cache directory so ReaderUI can open it.
    local path, write_err = self.renderer:writeTemp(xhtml, part.id)

    -- Release the in-memory XHTML string now that it's on disk.
    xhtml = nil -- luacheck: ignore 311

    if not path then
        UIManager:show(InfoMessage:new{
            text = write_err or _("Could not prepare content for display."),
        })
        return
    end

    -- Open with KOReader's full reader. This gives us proper XHTML rendering,
    -- font controls, pagination, and touch navigation for free.
    -- The temp file is cleaned up once the reader signals it has opened
    -- the document (via the onDocumentLoaded event below).
    ReaderUI:showReader(path)

    -- Schedule temp file cleanup. We use a short UIManager timer rather than
    -- deleting immediately, giving ReaderUI time to read the file.
    UIManager:scheduleIn(5, function()
        self.renderer:cleanupTemp()
    end)
end

-- ---------------------------------------------------------------------------
-- Sign out
-- ---------------------------------------------------------------------------

--- Sign out, clear the saved token, and show a confirmation.
-- Exposed so it can be wired up to a menu item in a future revision.
function JNCReader:logout()
    self.api:logout()
    self.settings:clearToken()
    UIManager:show(InfoMessage:new{ text = _("Signed out of JNC Reader.") })
end

return JNCReader