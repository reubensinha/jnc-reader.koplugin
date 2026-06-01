--[[--
Reusable UI widgets for JNC Reader.

Provides cover-image list row and section-header constructors used by
screens.lua. No network calls are made here; all data is pre-fetched.

@module koplugin.jnc-reader.widgets
--]]--

local Device          = require("device")
local Geom            = require("ui/geometry")
local Font            = require("ui/font")
local InputContainer  = require("ui/widget/container/inputcontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local VerticalGroup   = require("ui/widget/verticalgroup")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local LineWidget      = require("ui/widget/linewidget")
local ImageWidget     = require("ui/widget/imagewidget")
local Blitbuffer      = require("ffi/blitbuffer")
local GestureRange    = require("ui/gesturerange")

local widgets = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local TITLE_FONT_SIZE    = 18
local SUBTITLE_FONT_SIZE = 14
local MIN_ROW_HEIGHT     = 60   -- px; satisfies 7 mm tap-target on 167 DPI

--- Build a grey placeholder FrameContainer for missing cover images.
local function makePlaceholder(w, h)
    return FrameContainer:new{
        width     = w,
        height    = h,
        bordersize = 1,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        padding   = 0,
    }
end

-- ---------------------------------------------------------------------------
-- CoverRow widget (InputContainer subclass)
-- ---------------------------------------------------------------------------

local CoverRow = InputContainer:extend{}

function CoverRow:init()
    local padding   = self.padding or 8
    local cover_w   = self.cover_w or 80
    local cover_h   = self.cover_h or 112
    local sw        = self.screen_width or Device.screen:getWidth()
    local row_h     = math.max(cover_h + 2 * padding, MIN_ROW_HEIGHT)
    local text_w    = sw - cover_w - 3 * padding

    -- Cover image (from a temp JPEG file) or grey placeholder.
    -- Using file = path defers JPEG decoding to render time, which avoids
    -- the libturbojpeg thread-pool crash that occurs when many images are
    -- decoded in rapid succession during the loading loop.
    local cover_widget
    if self.cover_path then
        cover_widget = ImageWidget:new{
            file         = self.cover_path,
            width        = cover_w,
            height       = cover_h,
            scale_factor = 0,
        }
    else
        cover_widget = makePlaceholder(cover_w, cover_h)
    end

    -- Text column
    local title_face    = Font:getFace("cfont", TITLE_FONT_SIZE)
    local subtitle_face = Font:getFace("cfont", SUBTITLE_FONT_SIZE)

    local title_widget = TextBoxWidget:new{
        text  = self.title or "",
        face  = title_face,
        width = text_w,
        bold  = true,
    }

    local text_group = VerticalGroup:new{
        align = "left",
        title_widget,
    }

    if self.subtitle and self.subtitle ~= "" then
        local subtitle_widget = TextBoxWidget:new{
            text  = self.subtitle,
            face  = subtitle_face,
            width = text_w,
        }
        text_group:addWidget(subtitle_widget)
    end

    -- Row layout: [padding] [cover] [padding] [text]
    local row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = padding },
        cover_widget,
        HorizontalSpan:new{ width = padding },
        text_group,
    }

    -- Wrap in a FrameContainer to set a fixed row height
    local row_frame = FrameContainer:new{
        width     = sw,
        height    = row_h,
        bordersize = 0,
        padding   = 0,
        row,
    }

    self.dimen = Geom:new{ w = sw, h = row_h + 1 }  -- +1 for separator line

    self[1] = VerticalGroup:new{
        row_frame,
        LineWidget:new{ dimen = Geom:new{ w = sw, h = 1 } },
    }

    self.ges_events = {
        TapSelectItem = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
    }
end

function CoverRow:onTapSelectItem()
    if self.callback then
        self.callback()
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Public constructors
-- ---------------------------------------------------------------------------

--- Build a tappable list row with an optional cover thumbnail.
--
-- @param opts table
--   cover_path    string|nil       Path to a JPEG file; nil shows a placeholder
--   cover_w       number           Thumbnail width in px (default 80)
--   cover_h       number           Thumbnail height in px (default 112)
--   title         string           Primary text (word-wrapped)
--   subtitle      string|nil       Secondary text line
--   callback      function         Called on tap
--   screen_width  number|nil       Defaults to Device.screen:getWidth()
--   padding       number|nil       Horizontal padding in px (default 8)
-- @return InputContainer
function widgets.makeCoverRow(opts)
    return CoverRow:new(opts)
end

--- Build a non-tappable section-header divider (for date groups in New Releases).
--
-- @param text         string  Header label (e.g. "Today", "Yesterday", "May 25")
-- @param screen_width number  Screen pixel width
-- @return FrameContainer
function widgets.makeSectionHeader(text, screen_width)
    local face = Font:getFace("cfont", SUBTITLE_FONT_SIZE)
    local sw   = screen_width or Device.screen:getWidth()
    local padding = 8

    local label = TextWidget:new{
        text = text,
        face = face,
        bold = true,
    }

    local content = VerticalGroup:new{
        FrameContainer:new{
            width     = sw,
            bordersize = 0,
            padding   = padding,
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            label,
        },
        LineWidget:new{ dimen = Geom:new{ w = sw, h = 1 } },
    }

    return content
end

return widgets
