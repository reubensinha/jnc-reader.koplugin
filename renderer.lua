--[[--
Content renderer for JNC Reader.

Prepares the self-contained XHTML returned by JNCApi:getPartContent() for
display in KOReader. Because getPartContent() has already inlined all images
as base64 data URIs, the XHTML is a complete, standalone document.

KOReader can render XHTML/HTML directly via its ReaderUI (the same engine
used for sideloaded EPUBs). This module writes the XHTML to a temporary file
in KOReader's cache directory so ReaderUI can open it, then cleans it up
when the reader is closed.

PRIVACY / ANTI-PIRACY NOTE:
  The temp file is placed in KOReader's own cache directory and is deleted
  immediately after ReaderUI signals it has loaded the document. Its lifetime
  is measured in seconds. We never write to user-visible directories
  (the Device's book storage), so the content cannot be "found" by
  a file browser. A motivated user could theoretically copy it during that
  window, but that is true of any streaming reader — the goal is to avoid
  providing a deliberate save path, not to enforce DRM.

@module koplugin.jnc-reader.renderer
--]]--

local DataStorage = require("datastorage")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")

-- Temp files live in a dedicated dir under the KOReader data dir — deliberately
-- NOT under cache/. Opening a document from inside KOReader's own cache directory
-- makes crengine's document-load fail ("unsupported or invalid document"). The same
-- file opens fine from this non-cache location.
local TEMP_DIR = DataStorage:getDataDir() .. "/jnc-reader-tmp/"

--- @class JNCRenderer
local JNCRenderer = {}
JNCRenderer.__index = JNCRenderer

--- Create a new renderer instance.
-- @return JNCRenderer
function JNCRenderer:new()
    local o = {
        -- Path of the most recently written temp file, for cleanup.
        _current_temp = nil,
    }
    setmetatable(o, self)
    return o
end

--- Ensure the temp directory exists.
local function ensureTempDir()
    if lfs.attributes(TEMP_DIR, "mode") ~= "directory" then
        lfs.mkdir(TEMP_DIR)
    end
end

--- Write self-contained HTML to a temp file for the reader and return its path.
--
-- Any previously written part file is deleted first (so at most one exists), but
-- the file just written is left in place: crengine needs it for the whole reading
-- session, and it is replaced on the next openReader() call. Do NOT delete it from
-- plugin init — the plugin re-initialises during the FileManager→Reader transition,
-- which would wipe the file mid-open.
--
-- @param xhtml    string  Self-contained HTML (images already inlined)
-- @param part_id  string  Used to generate a deterministic filename
-- @return string|nil  Absolute path to the temp file, or nil on I/O error
-- @return string|nil  Error message on failure, nil on success
function JNCRenderer:writeTemp(xhtml, part_id)
    ensureTempDir()

    -- Sanitise part_id for use in a filename.
    -- Use a .html extension: KOReader's DocumentRegistry recognises .html via
    -- crengine's HTML parser, which handles the XHTML content fine.
    local safe_id  = (part_id:gsub("[^%w%-]", "_"))
    local filename = "part_" .. safe_id .. ".html"
    local path     = TEMP_DIR .. filename

    -- Clean up previously written part files BEFORE writing the new one — but
    -- never the file we're about to write. We deliberately do NOT delete the
    -- active file on a timer or at init: crengine needs it for the whole reading
    -- session, and the plugin re-initialises during the FileManager→Reader
    -- transition (an init-time delete would wipe the file mid-open).
    for file in lfs.dir(TEMP_DIR) do
        if file ~= "." and file ~= ".." and file ~= filename then
            os.remove(TEMP_DIR .. file)
        end
    end

    local f, err = io.open(path, "w")
    if not f then
        logger.warn("JNCRenderer: failed to open temp file:", path, err)
        return nil, "Could not create temporary file: " .. tostring(err)
    end

    f:write(xhtml)
    f:close()

    self._current_temp = path
    logger.dbg("JNCRenderer: wrote temp file", path, "(", #xhtml, "bytes)")
    return path, nil
end

--- Delete the most recently written temp file and clear the reference.
-- Not currently called (the active file is left in place for the whole reading
-- session and the previous file is cleared by writeTemp on the next open).
-- Intended for the future "delete the part file when the reader closes" feature.
function JNCRenderer:cleanupTemp()
    if self._current_temp then
        local ok, err = os.remove(self._current_temp)
        if ok then
            logger.dbg("JNCRenderer: deleted temp file", self._current_temp)
        else
            logger.warn("JNCRenderer: failed to delete temp file:",
                self._current_temp, err)
        end
        self._current_temp = nil
    end
end

return JNCRenderer