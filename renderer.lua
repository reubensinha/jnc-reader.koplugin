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

-- Temp files live in KOReader's cache dir, not in book storage.
local TEMP_DIR = DataStorage:getDataDir() .. "/cache/jnc-reader/"

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

--- Write self-contained XHTML to a short-lived temp file and return its path.
--
-- The caller (main.lua) is responsible for deleting the file after
-- ReaderUI has opened it, using JNCRenderer:cleanupTemp().
--
-- @param xhtml    string  Self-contained XHTML (images already inlined)
-- @param part_id  string  Used to generate a deterministic filename
-- @return string|nil  Absolute path to the temp file, or nil on I/O error
-- @return string|nil  Error message on failure, nil on success
function JNCRenderer:writeTemp(xhtml, part_id)
    ensureTempDir()

    -- Sanitise part_id for use in a filename.
    local safe_id = (part_id:gsub("[^%w%-]", "_"))
    local path = TEMP_DIR .. "part_" .. safe_id .. ".xhtml"

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
-- Call this after ReaderUI has finished with the file.
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

--- Delete any leftover temp files from previous sessions.
-- Called once on plugin init as a housekeeping measure.
function JNCRenderer:cleanupStaleTemps()
    if lfs.attributes(TEMP_DIR, "mode") ~= "directory" then return end
    for file in lfs.dir(TEMP_DIR) do
        if file ~= "." and file ~= ".." then
            local path = TEMP_DIR .. file
            os.remove(path)
            logger.dbg("JNCRenderer: removed stale temp file", path)
        end
    end
end

return JNCRenderer