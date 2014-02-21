--[[
	Program name: Lolmer's EZ-NUKE reactor control system
	Version: v0.2.5
	Programmer: Lolmer
	Last update: 2014-02-20
	Pastebin: http://pastebin.com/fguScPBQ

	Description:
	This program controls a Big Reactors nuclear reactor
	in Minecraft with a Computercraft computer, using Computercraft's
	own wired modem connected to the reactors computer control port.

	Features:
		Configurable min/max energy buffer and min/max temperature via ReactorOptions file.
		ReactorOptions is read on start and then current values are saved every program cycle.
		Rod Control value in ReactorOptions is only useful for initial start, after that the program saves the current Rod Control average over all Fuel Rods for next boot.
		Auto-adjusts individual control rods (based on hottest/coldest) to maintain temperature.
		Will display reactor data to all attached monitors of correct dimensions.

	Default values:
		Rod Control: 90% (Let's start off safe and then power up as we can)
		Minimum Energy Buffer: 15% (will power on below this value)
		Maximum Energy Buffer: 85% (will power off above this value)
		Minimum Temperature: 850^C (will raise control rods below this value)
		Maximum Temperature: 950^C (will lower control rods above this value)

	Requirements:
		Advanced Monitor size is X: 29, Y: 12 with a 3x2 size
		Computer or Advanced Computer
		Modems (not wireless) connecting each of the Computer to both the Advanced Monitor and Reactor Computer Port.

	Resources:
	This script is available from:
		http://pastebin.com/fguScPBQ
		https://github.com/sandalle/minecraft_bigreactor_control
	Start-up script is available from:
		http://pastebin.com/ZTMzRLez
		https://github.com/sandalle/minecraft_bigreactor_control
	Other reactor control program which I based my program on:
		http://pastebin.com/aMAu4X5J (ScatmanJohn)
		http://pastebin.com/HjUVNDau (version ScatmanJohn based his on)
	A simpler Big Reactor control program is available from:
		http://pastebin.com/tFkhQLYn (IronClaymore)

	Reactor Computer Port API: http://wiki.technicpack.net/Reactor_Computer_Port
	Computercraft API: http://computercraft.info/wiki/Category:APIs

	ChangeLog:
	0.2.5 - Add multi-monitor support! Sends one reactor's data to all monitors.
		print function now takes table to support optional specified monitor
		Set "numRods" every cycle for some people (mechaet)
		Don't redirect terminal output with multiple monitor support
		Log troubleshooting data to reactorcontrol.log
		FC_API no longer used
	0.2.4 - Simplify math, don't divide by a simple large number and then multiply by 100 (#/10000000*100)
		Fix direct-connected (no modem) devices. getDeviceSide -> FC_API.getDeviceSide (simple as that :))
	0.2.3 - Check bounds on reactor.setRodControlLevel(#,#), Big Reactor doesn't check for us.
	0.2.2 - Do not auto-start the reactor if it was manually powered off (autoStart=false)
	0.2.1 - Lower/raise only the hottest/coldest Control Rod while trying to control the reactor temperature.
		"<" Rod Control buttons was off by one (to the left)
	0.2.0 - Lolmer Edition :)
		Add min/max stored energy percentage (default is 15%/85%), configurable via ReactorOptions file.
		No reason to keep burning fuel if our power output is going nowhere. :)
		Use variables variable for the title and version.
		Try to keep the temperature between configured values (default is 850^C-950^C)
		Add Waste and number of Control/Fuel Rods to displayBards()

	TODO:
		Add Fuel consumption metric to display - No such API for easy access. :(
		Support multiple reactors
		- If multiple reactors, require a monitor for each reactor and display only that reactor on a monitor
		- See http://www.computercraft.info/forums2/index.php?/topic/14831-multiple-monitors/
		  and http://computercraft.info/wiki/Monitor
		- May just iterate through peripheral.getNames() looking for "monitor_#" and "BigReactors-Reactor_#"
		Add min/max RF/t output and have it override temperature concerns (maybe?)
		Add support for wireless modems, see http://computercraft.info/wiki/Modem_%28API%29, will not be secure (anyone can send/listen to your channels)!
		Add support for any sized monitor (minimum 3x3), dynamic allocation/alignment

]]--

-- Some global variables
local progVer = "0.2.5"
local progName = "EZ-NUKE ".. progVer
local xClick, yClick = 0,0
local loopTime = 1
local adjustAmount = 5
local dataLogging = false
local baseControlRodLevel = nil
local autoStart = true -- Auto-start reactor when needed (e.g. program startup) by default
local numRods = 0 -- Number of control rods at start
local curStoredEnergyPercent = 0 -- Current stored energy in %
local rodPercentage = 0 -- For checking rod control level oustide of Display Bars
local rodLastUpdate = os.time() -- Last timestamp update for rod control level update
local reactorTemp = 0 -- For checking reactor temperature outside of Display Bars
local minStoredEnergyPercent = nil -- Max energy % to store before activate
local maxStoredEnergyPercent = nil -- Max energy % to store before shutdown
local minReactorTemp = nil -- Minimum reactor temperature (^C) to maintain
local maxReactorTemp = nil -- Maximum reactor temperature (^C) to maintain
local monitorList = {} -- Empty monitor list array

print{"Initializing program..."};

-- Helper functions

-- File needs to exist for append "a" and zero it out if it already exists
logFile = fs.open("reactorcontrol.log", "w")

local function print(printParams)
	-- Default to xPos=1, yPos=1, and first monitor
	setmetatable(printParams,{__index={xPos=1, yPos=1, monitor=1}})
	local printString, xPos, yPos, monitor =
		printParams[1] or printParams.printString,
		printParams[2] or printParams.xPos,
		printParams[3] or printParams.yPos,
		printParams[4] or printParams.monitor

	-- For now, just print everything to all monitors
	for monitor = 1, #monitorList do
		monitorList[monitor].setCursorPos(xPos, yPos)
		monitorList[monitor].write(printString)
	end
end

-- Replaces the one from FC_API allowing for multi-monitor support
local function printCentered(printParams)
	-- Default to yPos=1 and first monitor
	setmetatable(printParams,{__index={yPos=1, monitor=1}})
	local printString, xPos, yPos, monitor =
		printParams[1] or printParams.printString,
		printParams[2] or printParams.xPos,
		printParams[3] or printParams.yPos,
		printParams[4] or printParams.monitor

	local width, height = monitorList[monitor].getSize()
	monitorList[monitor].setCursorPos(math.floor(width/2) - math.ceil(printString:len()/2) , yPos)
	monitorList[monitor].clearLine()
	monitorList[monitor].write(printString)
end

local function printLog(printStr)
	logFile = fs.open("reactorcontrol.log", "a") -- See http://computercraft.info/wiki/Fs.open
	if logFile then
		logFile.writeLine(printStr)
		logFile.close()
	else
		error("Cannot open logFile reactorcontrol.log for append!")
	end
end

-- End helper functions

-- Return a list of all connected (including via wired modems) devices of "deviceType"
local function getDevices(deviceType)
	local deviceName = nil
	local deviceIndex = 1
	local deviceList = {} -- Empty array, which grows as we need
	local peripheralList = peripheral.getNames() -- Get table of connected peripherals

	deviceType = deviceType:lower() -- Make sure we're matching case here

	for peripheralIndex = 1, #peripheralList do
		printLog("Found "..peripheral.getType(peripheralList[peripheralIndex]).."["..peripheralIndex.."] attached as \""..peripheralList[peripheralIndex].."\".")
		if (string.lower(peripheral.getType(peripheralList[peripheralIndex])) == deviceType) then
			printLog("Attaching "..peripheral.getType(peripheralList[peripheralIndex]).."["..peripheralIndex.."] attached as \"deviceList["..deviceIndex.."]\".")
			deviceList[deviceIndex] = peripheral.wrap(peripheralList[peripheralIndex])
			deviceIndex = deviceIndex + 1
		end
	end

	return deviceList
end

-- Then initialize the monitors
monitorList = getDevices("monitor")

for monitorIndex = 1, #monitorList do
	local monitorX, monitorY = monitorList[monitorIndex].getSize()

	-- Clear all monitors
	monitorList[monitorIndex].clear()
	monitorList[monitorIndex].setCursorPos(1,1)

	if monitorX ~= 29 or monitorY ~= 12 then
		printLog("Removing monitor "..monitorIndex.." for incorrect size")
		monitorList[monitorIndex].write("Monitor is the wrong size!")
		monitorList[monitorIndex].setCursorPos(1,2)
		monitorList[monitorIndex].write("Needs to be 3x2.")
--[[		table.remove(monitorList, monitorIndex) -- Remove invalid monitor from list
		if monitorIndex == #monitorList then	-- If we're at the end already, break from loop
			break
		else
			monitorIndex = monitorIndex - 1 -- We just removed an element
		end ]]--
	end
end

-- Let's connect to the reactor peripheral
local reactorList = getDevices("BigReactors-Reactor")
local reactor = nil
if table.getn(reactorList) == 0 then
	error("Can't find any reactors.")
else
	-- Placeholder for now
	reactor = reactorList[1]
end

--Load saved data if reactorOptions file exists
reactorOptions = fs.open("ReactorOptions", "r") -- See http://computercraft.info/wiki/Fs.open
if reactorOptions then
	baseControlRodLevel = reactorOptions.readLine()
	-- The following values were added by Lolmer
	minStoredEnergyPercent = reactorOptions.readLine()
	maxStoredEnergyPercent = reactorOptions.readLine()
	minReactorTemp = reactorOptions.readLine()
	maxReactorTemp = reactorOptions.readLine()

	-- If we succeeded in reading a string, convert it to a number
	if baseControlRodLevel ~= nil then
		baseControlRodLevel = tonumber(baseControlRodLevel)
	end

	if minStoredEnergyPercent ~= nil then
		minStoredEnergyPercent = tonumber(minStoredEnergyPercent)
	end

	if maxStoredEnergyPercent ~= nil then
		maxStoredEnergyPercent = tonumber(maxStoredEnergyPercent)
	end

	if minReactorTemp ~= nil then
		minReactorTemp = tonumber(minReactorTemp)
	end

	if maxReactorTemp ~= nil then
		maxReactorTemp = tonumber(maxReactorTemp)
	end

	reactorOptions.close()
end

-- Set default values if we failed to read any of the above
if baseControlRodLevel == nil then
	baseControlRodLevel = 90
end

if minStoredEnergyPercent == nil then
	minStoredEnergyPercent = 15
end

if maxStoredEnergyPercent == nil then
	maxStoredEnergyPercent = 85
end

if minReactorTemp == nil then
	minReactorTemp = 850
end

if maxReactorTemp == nil then
	maxReactorTemp = 950
end

--Save some stuff
local function save()
	reactorOptions = fs.open("ReactorOptions", "w") -- See http://computercraft.info/wiki/Fs.open
	reactorOptions.writeLine(rodPercentage)
	-- The following values were added by Lolmer
	reactorOptions.writeLine(minStoredEnergyPercent)
	reactorOptions.writeLine(maxStoredEnergyPercent)
	reactorOptions.writeLine(minReactorTemp)
	reactorOptions.writeLine(maxReactorTemp)
	reactorOptions.close()
end

reactor.setAllControlRodLevels(baseControlRodLevel)

printCentered{progName}

--Done initializing

local function displayBars()
	-- Draw some cool lines
	term.setBackgroundColor(colors.black)
	local width, height = term.getSize()

	for i=3, 5 do
		term.setCursorPos(22, i)
		term.write("|")
	end

	for i=1, width do
		term.setCursorPos(i, 2)
		term.write("-")
	end

	for i=1, width do
		term.setCursorPos(i, 6)
		term.write("-")
	end

	-- Draw some text

	local fuelString = "Fuel: "
	local tempString = "Temp: "
	local energyBufferString = "Producing: "

	local padding = math.max(string.len(fuelString), string.len(tempString),string.len(energyBufferString))

	local fuelPercentage = math.ceil(reactor.getFuelAmount()/reactor.getFuelAmountMax()*100)
	print{fuelString,2,3}
	print{fuelPercentage.." %",padding+2,3}

	local energyBuffer = reactor.getEnergyProducedLastTick()
	print{energyBufferString,2,4}
	print{math.ceil(energyBuffer).."RF/t",padding+2,4}

	local reactorTemp = reactor.getTemperature()
	print{tempString,2,5}
	print{reactorTemp.." C",padding+2,5}

	-- Decrease rod button: 22X, 4Y
	-- Increase rod button: 28X, 4Y

	local rodTotal = 0
	for i=0, numRods do
		rodTotal = rodTotal + reactor.getControlRodLevel(i)
	end
	rodPercentage = math.ceil(rodTotal/(numRods+1))

	print{"Control",23,3}
	print{"<     >",23,4}
	print{rodPercentage,25,4}
	print{"percent",23,5}

	if (xClick == 23  and yClick == 4) then
		--Decrease rod level by amount
		newRodPercentage = rodPercentage - adjustAmount
		if newRodPercentage < 0 then
			newRodPercentage = 0
		end

		xClick, yClick = 0,0
		reactor.setAllControlRodLevels(newRodPercentage)
	end

	if (xClick == 28  and yClick == 4) then
		--Increase rod level by amount
		newRodPercentage = rodPercentage + adjustAmount
		if newRodPercentage > 100 then
			newRodPercentage = 100
		end
		xClick, yClick = 0,0
		reactor.setAllControlRodLevels(newRodPercentage)
	end

	local energyBufferStorage = reactor.getEnergyStored()
	curStoredEnergyPercent = math.floor(energyBufferStorage/100000) -- 10000000*100
	paintutils.drawLine(2, 8, 28, 8, colors.gray)
	if curStoredEnergyPercent > 4 then
		paintutils.drawLine(2, 8, math.floor(26*curStoredEnergyPercent/100)+2, 8, colors.yellow)
	elseif curStoredEnergyPercent > 0 then
		paintutils.drawPixel(2,8,colors.yellow)
	end
	term.setBackgroundColor(colors.black)
	print{"Energy Buffer",2,7}
	print{curStoredEnergyPercent, width-(string.len(curStoredEnergyPercent)+3),7}
	print{"%",28,7}
	term.setBackgroundColor(colors.black)

	local hottestControlRod = getHottestControlRod()
	local coldestControlRod = getColdestControlRod()
	print{"Hottest Rod: "..(hottestControlRod + 1),2,10} -- numRods index starts at 0
	print{reactor.getTemperature(hottestControlRod).."^C".." "..reactor.getControlRodLevel(hottestControlRod).."%",width-(string.len(reactor.getWasteAmount())+8),10}
	print{"Coldest Rod: "..(coldestControlRod + 1),2,11} -- numRods index starts at 0
	print{reactor.getTemperature(coldestControlRod).."^C".." "..reactor.getControlRodLevel(coldestControlRod).."%",width-(string.len(reactor.getWasteAmount())+8),11}
	print{"Fuel Rods: "..(numRods + 1),2,12} -- numRods index starts at 0
	print{"Waste: "..reactor.getWasteAmount().." mB",width-(string.len(reactor.getWasteAmount())+10),12}
end


function reactorStatus()
	local width, height = term.getSize()
	local reactorStatus = ""

    numRods = reactor.getNumberOfControlRods() - 1 -- Call every time as some people modify their reactor without rebooting the computer (*cough*mechaet*cough*)

	if reactor.getConnected() then
		if reactor.getActive() then
			reactorStatus = "ONLINE"
			term.setTextColor(colors.green)
		else
			reactorStatus = "OFFLINE"
			term.setTextColor(colors.red)
		end

		if(xClick >= (width - string.len(reactorStatus) - 1) and xClick <= (width-1)) then
			if yClick == 1 then
				reactor.setActive(not reactor.getActive()) -- Toggle reactor status
				xClick, yClick = 0,0

				-- If someone offlines the reactor (offline after a status click was detected), then disable autoStart
				if not reactor.getActive() then
					autoStart = false
				end
			end
		end

	else
		reactorStatus = "DISCONNECTED"
		term.setTextColor(colors.red)
	end

	print{reactorStatus, width - string.len(reactorStatus) - 1, 1}
	term.setTextColor(colors.white)
end

-- This function was added by Lolmer
-- Return the index of the hottest Control Rod
function getColdestControlRod()
	local coldestRod = 0

	for rodIndex=0, numRods do
		if reactor.getTemperature(rodIndex) < reactor.getTemperature(coldestRod) then
			coldestRod = rodIndex
		end
	end

	return coldestRod
end

-- This function was added by Lolmer
-- Return the index of the hottest Control Rod
function getHottestControlRod()
	local hottestRod = 0

	for rodIndex=0, numRods do
		if reactor.getTemperature(rodIndex) > reactor.getTemperature(hottestRod) then
			hottestRod = rodIndex
		end
	end

	return hottestRod
end

-- This function was added by Lolmer
-- Modify reactor control rod levels to keep temperature with defined parameters, but
-- wait an in-game half-hour for the temperature to stabalize before modifying again
function temperatureControl()
	local rodTimeDiff = 0

	-- No point modifying control rod levels for temperature if the reactor is offline
	if reactor.getActive() then
		rodTimeDiff = math.abs(os.time() - rodLastUpdate) -- Difference in rod control level update timestamp and now

		-- Don't bring us to 100, that's effectively a shutdown
		if (reactorTemp > maxReactorTemp) and (rodPercentage < 99) and (rodTimeDiff > 0.2) then
			-- If more than double our maximum temperature, incrase rodPercentage faster
			if reactorTemp > (2 * maxReactorTemp) then
				local hottestControlRod = getHottestControlRod()

				-- Check bounds, Big Reactor doesn't do this for us. :)
				if (reactor.getControlRodLevel(hottestControlRod) + 10) > 99 then
					reactor.setControlRodLevel(hottestControlRod, 99)
				else
					reactor.setControlRodLevel(hottestControlRod, rodPercentage + 10)
				end
			else
				local hottestControlRod = getHottestControlRod()

				-- Check bounds, Big Reactor doesn't do this for us. :)
				if (reactor.getControlRodLevel(hottestControlRod) + 1) > 99 then
					reactor.setControlRodLevel(hottestControlRod, 99)
				else
					reactor.setControlRodLevel(hottestControlRod, rodPercentage + 1)
				end
			end

			rodLastUpdate = os.time() -- Last rod control update is now :)
		elseif (reactorTemp < minReactorTemp) and (rodTimeDiff > 0.2) then
			-- If less than half our minimum temperature, decrease rodPercentage faster
			if reactorTemp < (minReactorTemp / 2) then
				local coldestControlRod = getColdestControlRod()

				-- Check bounds, Big Reactor doesn't do this for us. :)
				if (reactor.getControlRodLevel(coldestControlRod) - 10) < 0 then
					reactor.setControlRodLevel(coldestControlRod, 0)
				else
					reactor.setControlRodLevel(coldestControlRod, rodPercentage - 10)
				end
			else
				local coldestControlRod = getColdestControlRod()

				-- Check bounds, Big Reactor doesn't do this for us. :)
				if (reactor.getControlRodLevel(coldestControlRod) - 1) < 0 then
					reactor.setControlRodLevel(coldestControlRod, 0)
				else
					reactor.setControlRodLevel(coldestControlRod, rodPercentage - 1)
				end
			end

			rodLastUpdate = os.time() -- Last rod control update is now :)
		end
	end
end


function main()
	while not finished do
		printCentered{progName}

		reactorStatus()

		if reactor.getConnected() then
			-- Shutdown reactor if current stored energy % is >= desired level, otherwise activate
			-- First pass will have curStoredEnergyPercent=0 until displayBars() is run once
			if curStoredEnergyPercent >= maxStoredEnergyPercent then
				reactor.setActive(false)
			-- Do not auto-start the reactor if it was manually powered off (autoStart=false)
			elseif (curStoredEnergyPercent <= minStoredEnergyPercent) and autoStart then
				reactor.setActive(true)
			end

			temperatureControl()
			displayBars()
			sleep(loopTime)
			save()
		end
	end
end

function eventHandler()
	while not finished do
		event, arg1, arg2, arg3 = os.pullEvent()

		if event == "monitor_touch" then
			xClick, yClick = math.floor(arg2), math.floor(arg3)
			-- Draw debug stuff
			--print{"Monitor touch X: "..xClick.." Y: "..yClick, 1, 10}
		elseif event == "mouse_click" and not monitorList[1] then
			xClick, yClick = math.floor(arg2), math.floor(arg3)
			--print{"Mouse click X: "..xClick.." Y: "..yClick, 1, 11}
		elseif event == "char" and not inManualMode then
			local ch = string.lower(arg1)
			if ch == "q" then
				finished = true
			elseif ch == "r" then
				finished = true
				os.reboot()
			end
		end
	end
end

while not finished do
	parallel.waitForAny(eventHandler, main)
	sleep(loopTime)
end

term.clear()
term.setCursorPos(1,1)
