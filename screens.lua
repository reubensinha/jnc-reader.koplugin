--[[--
Full-screen UI constructors for JNC Reader.

Each function takes pre-fetched, pre-processed data and a callbacks table,
and returns a UIManager-showable widget. No network calls are made here.

@module koplugin.jnc-reader.screens
--]]--

local Device               = require("device")
local Geom                 = require("ui/geometry")
local UIManager            = require("ui/uimanager")
local FrameContainer       = require("ui/widget/container/framecontainer")
local VerticalGroup        = require("ui/widget/verticalgroup")
local ScrollableContainer  = require("ui/widget/container/scrollablecontainer")
local TitleBar             = require("ui/widget/titlebar")

local widgets = require("widgets")

local screens = {}

-- ---------------------------------------------------------------------------
-- Internal: build the common full-screen shell
-- ---------------------------------------------------------------------------

--- Return `{ screen_widget, screen_w, screen_h }`.
-- `close_callback` closes the returned screen widget.
-- Pattern: forward-declare `screen`, build TitleBar referencing it via upvalue,
-- then assign `screen`. Safe because close_callback is only called after assignment.
local function makeShell(title)
    local Device_screen = Device.screen
    local sw = Device_screen:getWidth()
    local sh = Device_screen:getHeight()

    local screen   -- forward declaration for upvalue
    local titlebar = TitleBar:new{
        title              = title,
        with_back_button   = true,
        close_callback     = function()
            UIManager:close(screen)
        end,
    }

    return titlebar, sw, sh, function(content_widget)
        -- content_widget must already have dimen set
        local outer = VerticalGroup:new{
            titlebar,
            content_widget,
        }
        screen = FrameContainer:new{
            dimen     = Geom:new{ w = sw, h = sh },
            bordersize = 0,
            padding   = 0,
            outer,
        }
        return screen
    end
end

-- ---------------------------------------------------------------------------
-- Following screen
-- ---------------------------------------------------------------------------

--- Build the "Following" cover-list screen.
--
-- @param items     table  Array of { series, agg, cover_path, parts_count }
-- @param callbacks table  { onSelect = function(series, agg) }
-- @return FrameContainer  Full-screen widget ready for UIManager:show()
function screens.makeFollowingScreen(items, callbacks)
    local titlebar, sw, sh, finish = makeShell("Following")
    local titlebar_h = titlebar:getSize().h

    local rows = VerticalGroup:new{ align = "left" }

    for _, item in ipairs(items) do
        local subtitle = tostring(item.parts_count) .. " parts available"
        rows:addWidget(widgets.makeCoverRow{
            cover_path     = item.cover_path,
            title        = item.series.title or "",
            subtitle     = subtitle,
            screen_width = sw,
            callback     = function()
                if callbacks and callbacks.onSelect then
                    callbacks.onSelect(item.series, item.agg)
                end
            end,
        })
    end

    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = sw, h = sh - titlebar_h },
        rows,
    }

    return finish(scroll)
end

-- ---------------------------------------------------------------------------
-- My Library screen
-- ---------------------------------------------------------------------------

--- Build the "My Library" cover-list screen.
--
-- @param items     table  Array of { vol, series, agg, cover_path }
-- @param callbacks table  { onSelect = function(series, agg) }
-- @return FrameContainer
function screens.makeLibraryScreen(items, callbacks)
    local titlebar, sw, sh, finish = makeShell("My Library")
    local titlebar_h = titlebar:getSize().h

    local rows = VerticalGroup:new{ align = "left" }

    for _, item in ipairs(items) do
        rows:addWidget(widgets.makeCoverRow{
            cover_path     = item.cover_path,
            title        = item.vol.title or "",
            subtitle     = item.series.title or "",
            screen_width = sw,
            callback     = function()
                if callbacks and callbacks.onSelect then
                    callbacks.onSelect(item.series, item.agg)
                end
            end,
        })
    end

    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = sw, h = sh - titlebar_h },
        rows,
    }

    return finish(scroll)
end

-- ---------------------------------------------------------------------------
-- New Releases screen
-- ---------------------------------------------------------------------------

--- Build the "New Releases" date-grouped event screen.
--
-- @param groups    table  Array of { date_label, events = { {event, cover_path}, … } }
-- @param callbacks table  { onSelect = function(event) }
-- @return FrameContainer
function screens.makeNewReleasesScreen(groups, callbacks)
    local titlebar, sw, sh, finish = makeShell("New Releases")
    local titlebar_h = titlebar:getSize().h

    local rows = VerticalGroup:new{ align = "left" }

    for _, group in ipairs(groups) do
        rows:addWidget(widgets.makeSectionHeader(group.date_label, sw))
        for _, entry in ipairs(group.events) do
            local event    = entry.event
            local cover_path = entry.cover_path
            local title    = (event.serie and event.serie.title) or ""
            -- Format launch time as "HH:MM" from "YYYY-MM-DDTHH:MM:SSZ"
            local subtitle = ""
            if event.launch then
                local h, m = event.launch:match("T(%d+):(%d+):")
                if h and m then
                    subtitle = h .. ":" .. m
                end
            end
            rows:addWidget(widgets.makeCoverRow{
                cover_path     = cover_path,
                title        = title,
                subtitle     = subtitle,
                screen_width = sw,
                callback     = function()
                    if callbacks and callbacks.onSelect then
                        callbacks.onSelect(event)
                    end
                end,
            })
        end
    end

    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = sw, h = sh - titlebar_h },
        rows,
    }

    return finish(scroll)
end

return screens
