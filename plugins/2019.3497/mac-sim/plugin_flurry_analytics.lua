-- Flurry plugin

local Library = require "CoronaLibrary"

-- Create library
local lib = Library:new{ name='plugin.flurry.analytics', publisherId='com.coronalabs' }

-------------------------------------------------------------------------------
-- BEGIN
-------------------------------------------------------------------------------

-- This sample implements the following Lua:
-- 
--    local PLUGIN_NAME = require "plugin_PLUGIN_NAME"
--    PLUGIN_NAME:showPopup()
--    

local function showWarning()
    print( 'WARNING: The Flurry plugin is only supported on Android & iOS devices. Please build for device' );
end

function lib.init()
    showWarning()
end

function lib.logEvent()
    showWarning()
end

function lib.startTimedEvent()
    showWarning()
end

function lib.endTimedEvent()
    showWarning()
end

-------------------------------------------------------------------------------
-- END
-------------------------------------------------------------------------------

-- Return an instance
return lib
