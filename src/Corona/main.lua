--
--  main.lua
--  Flurry Sample App
--
--  Copyright (c) 2016 Corona Labs Inc. All rights reserved.
--

local flurry = require( "plugin.flurry.analytics" )
local widget = require( "widget" )
local json = require("json")

-----------------------
-- Setup
-----------------------
local eventDataTextBox              -- text box to display event data

display.setStatusBar( display.HiddenStatusBar )
display.setDefault( "background", 1 )

local isTvOS = system.getInfo("platformName") == "tvOS"
local isAndroid = system.getInfo( "platformName" ) == "Android"

-- function for scrolling text into text box (makes new entries more obvious)
local reportEvent = function( eventData )
  reportTime = reportTime + 100

  timer.performWithDelay( reportTime - baseTime, function()
    print( eventData )
  end)
end

local processEventTable = function(event)
  local logString = json.prettify(event):gsub("\\","")
  logString = "\nPHASE: "..event.phase.." - - - - - - - - - - - -\n" .. logString
  print(logString)
  return logString
end

local flurryListener = function( event )
  local logString = processEventTable(event)
  eventDataTextBox.text = logString .. eventDataTextBox.text
end

local apiKey

if (isAndroid) then
  apiKey = "66V4Q6JWN257B7JRB5DX"
elseif (isTvOS) then
  apiKey = "YF27GWPZ7H5GX3M7XYWM"
else -- iOS
  apiKey = "P23CTV66R29QRD6G4PFS"
end

print( "Using " .. apiKey )

flurry.init(flurryListener, {
  apiKey = apiKey,
  crashReportingEnabled = true
})

-----------------------
-- UI
-----------------------
local offsetCol1X = 0
local offsetCol2X = 0
local offsetCol1Y = 0
local offsetCol2Y = 0

if (isTvOS) then
  offsetCol1X = -125
  offsetCol2X = 125
  offsetCol1Y = -10
  offsetCol2Y = -125
end

local flurryLogo = display.newImage( "flurrylogo.png" )
flurryLogo.anchorY = 0
flurryLogo.x, flurryLogo.y = display.contentCenterX, 5
flurryLogo:scale( 0.3, 0.3 )

local subTitle = display.newText {
  text = "plugin for Corona SDK",
  x = display.contentCenterX,
  y = 95,
  font = display.systemFont,
  fontSize = 20
}
subTitle:setTextColor( 0.2, 0.2, 0.2 )

eventDataTextBox = native.newTextBox( display.contentCenterX, display.contentHeight - 55, 310, 100)
eventDataTextBox.placeholder = "Event data will appear here"

-- Standard event logging
local logEvent = function( event )
  flurry.logEvent( "Entered dungeon" )
end

local standardEventButton = widget.newButton {
  id = "logEvent",
  label = "Log Event",
  width = 300,
  fontSize = 15,
  emboss = false,
  labelColor = { default={1,1,1,0.75}, over={0,0,0,0.5} },
  shape = "roundedRect",
  width = 200,
  height = 35,
  cornerRadius = 4,
  fillColor = { default = { 0.6, 0.7, 0.8, 1 }, over = { 0.4, 0.5, 0.6, 1 } },
  strokeColor = { default = { 0.4, 0.4, 0.4 }, over = { 0.4, 0.4, 0.4 } },
  strokeWidth = 2,
  onRelease = logEvent
}
standardEventButton.x = display.contentCenterX + offsetCol1X
standardEventButton.y = 150 + offsetCol1Y

-- Standard event with params
local logEventWithParams = function( event )
  flurry.logEvent( "Menu selection" , { location = "Main Menu", selection = "Multiplayer mode" } )
end

local standardEventWithParamsButton = widget.newButton {
  id = "logEventWithParams",
  label = "Log Event With Params",
  width = 300,
  fontSize = 15,
  emboss = false,
  labelColor = { default={1,1,1,0.75}, over={0,0,0,0.5} },
  shape = "roundedRect",
  width = 200,
  height = 35,
  cornerRadius = 4,
  fillColor = { default = { 0.6, 0.7, 0.8, 1 }, over = { 0.4, 0.5, 0.6, 1 } },
  strokeColor = { default = { 0.4, 0.4, 0.4 }, over = { 0.4, 0.4, 0.4 } },
  strokeWidth = 2,
  onRelease = logEventWithParams
}
standardEventWithParamsButton.x = display.contentCenterX + offsetCol1X
standardEventWithParamsButton.y = standardEventButton. y + 50

-- Start timed event logging
local startTimedEvent = function( event )
  flurry.startTimedEvent( "Level 1 (Beginner)" )
end

local timedEventButton = widget.newButton {
  id = "startTimedEvent",
  label = "Start Timed Event",
  width = 300,
  fontSize = 15,
  emboss = false,
  labelColor = { default={1,1,1,0.75}, over={0,0,0,0.5} },
  shape = "roundedRect",
  width = 200,
  height = 35,
  cornerRadius = 4,
  fillColor = { default = { 0.6, 0.7, 0.8, 1 }, over = { 0.4, 0.5, 0.6, 1 } },
  strokeColor = { default = { 0.4, 0.4, 0.4 }, over = { 0.4, 0.4, 0.4 } },
  strokeWidth = 2,
  onRelease = startTimedEvent
}
timedEventButton.x = display.contentCenterX + offsetCol2X
timedEventButton.y = standardEventWithParamsButton.y + 75 + offsetCol2Y

-- End timed event logging
local endTimedEvent = function( event )
  --flurry.endTimedEvent( "Level 1 (Beginner)" )
  flurry.openPrivacyDashboard()

end

local endTimedEventButton = widget.newButton {
  id = "endTimedEvent",
  label = "End Timed Event",
  width = 300,
  fontSize = 15,
  emboss = false,
  labelColor = { default={1,1,1,0.75}, over={0,0,0,0.5} },
  shape = "roundedRect",
  width = 200,
  height = 35,
  cornerRadius = 4,
  fillColor = { default = { 0.6, 0.7, 0.8, 1 }, over = { 0.4, 0.5, 0.6, 1 } },
  strokeColor = { default = { 0.4, 0.4, 0.4 }, over = { 0.4, 0.4, 0.4 } },
  strokeWidth = 2,
  onRelease = endTimedEvent
}
endTimedEventButton.x = display.contentCenterX + offsetCol2X
endTimedEventButton.y = timedEventButton.y + 50

-- add support for AppleTV remote
if isTvOS then
  local objects = {
    standardEventButton,
    standardEventWithParamsButton,
    timedEventButton,
    endTimedEventButton
  }
  local resetAt0 = true
  local focusedObject = 1
  local shiftedThisEvent = false
  local focusRect = display.newRect(0, 0, 0, 0)
  focusRect:setFillColor(0, 0, 0, 0.5)
  focusRect.isAnimating = false

  function focusRect:moveToPosition(object)
    focusRect.width = object.width
    focusRect.height = object.height
    focusRect.x = object.x
    focusRect.y = object.y
  end

  focusRect:moveToPosition(objects[focusedObject])

  local function onAxisEvent(event)
    local normalizedValue = event.normalizedValue

    if #objects < 1 or not event.axis or event.axis.type ~= "y" then
      return
    end

    if resetAt0 and event.normalizedValue ~= 0 then
      return
    end

    resetAt0 = false

    -- Handle swipes
    if math.abs(normalizedValue) > 0.5 then
      if normalizedValue > 0 then
        shiftedThisEvent = true
        focusedObject = focusedObject + 1
      end
      if normalizedValue < 0 then
        shiftedThisEvent = true
        focusedObject = focusedObject - 1
      end

      -- Make the butons wrap-around
      if focusedObject > #objects then
        focusedObject = 1
      elseif focusedObject < 1 then
        focusedObject = #objects
      end

      -- Move the focus rect to the correct position
      if shiftedThisEvent then
        focusRect:moveToPosition(objects[focusedObject])
      end

      resetAt0 = true
    end
  end

  Runtime:addEventListener("axis", onAxisEvent)

  onKeyEvent = function(event)
    if event.keyName == "buttonA" then
      if event.phase == "down" then
        if objects[focusedObject].id == "logEvent" then
          logEvent()
        elseif objects[focusedObject].id == "logEventWithParams" then
          logEventWithParams()
        elseif objects[focusedObject].id == "startTimedEvent" then
          startTimedEvent()
        elseif objects[focusedObject].id == "endTimedEvent" then
          endTimedEvent()
        end

        -- Animate the focus rect
        if focusRect.isAnimating == false then
          local function returnToDefault()
            transition.to(focusRect, {xScale = 1, yScale = 1, alpha = 1, time = 250, transition = easing.inOutQuad, onComplete = function()
              focusRect.isAnimating = false
            end })
          end
          transition.to(focusRect, {xScale = 1.2, yScale = 1.2, alpha = 0, time = 250, transition = easing.inOutQuad, onComplete = returnToDefault})
          focusRect.isAnimating = true
        end
      end
    end

    -- IMPORTANT! Return false to indicate that this app is NOT overriding the received key
    -- This lets the operating system execute its default handling of the key
    return false
  end

  Runtime:addEventListener("key", onKeyEvent)
end
