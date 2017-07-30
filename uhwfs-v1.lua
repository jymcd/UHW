local sys = require "filesystem"

local version = "\1" --Version byte of this driver
local header = "UHWFS" .. "\0" .. version --Full header of this driver

local function doMath(drive, start) --Perform odd byte math
	local now = start --Copy start pointer for size determination
	local last = 1 --The last byte
	local running = 1 --The running size (Without multiplier, it's offset by 1)
	while true do
		local byte = drive.readByte(now) --Read the next byte
		now = now + 1 --Advance pointer
		if byte < 1 then --It the byte is less than one
			running = running + last --Add the last byte
			break --Stop counting
		end
		running = running * last --Multiply by last byte
		last = byte --Set last byte to current byte
	end
	return running, (now - start) --Return count and number of bytes to get that count by subtracting pointer by where we started
end

local function parseRecord(drive, start) --Parse individual file record
	local record = { --Construct basic record
		name = ""
		type = ""
		location = 0
		length = 0
		size = start --Set the size to the starting pointer for later calculations
	}
	while true do
		local byte = drive.readByte(start) --Read the next byte
		start = start + 1 --Advance the pointer
		if byte == 3 then --If the byte is end of text
			break --Record name is finished, continue on
		elseif byte < 32 or byte > 126 then --If the byte is out of the acceptable range
			return nil --Let's brexit our way out of this
		end
		record.name = record.name .. string.char(byte) --Append the acceptable byte onto the name
	end
	
	local typeByte = drive.readByte(start) --Read the next byte, the byte that defines the file type
	start = start + 1 --Increment pointer
	if typeByte == 1 then --If the type byte declares type 1
		record.type = "file" --Set the record type to file
	elseif typeByte == 2 then --If the type byte declares type 2
		record.type = "directory" --Set the record type to directory
	end --More types for the future include links, let's not get ahead of ourselves
	
	local result, bytes = doMath(drive, start) --"Do the math" for the location of the data and retrieve both the math and the bytes it took to do it
	record.location = result --Set the record data location to the math result
	start = start + bytes --Jump forward the number of bytes required for the maths (suddenly British)
	
	local result, bytes = doMath(drive, start) --"Do the math" for the length of the data and retrieve both the math and the bytes it took to do it
	record.length = result --Set the data length to the math result
	start = start + bytes + 1 --Jump forward the bytes required for the math (suddenly American) and add one for the end of file byte
	
	record.size = start - record.size --Set the size to the current pointer subtracted by the start location
	
	return record --Return finished record
end

local function parseTable(drive, start) --Parse record table at location
	local records = {} --Map of records keyed by name
	while true do
		local record = parseRecord(drive, start) --Parse the next record
		if record then --If record exists
			records[record.name] = record --Add record to records map
			start = start + record.size --Jump pointer forward to next record
			if drive.readByte(start) == 29 then --If the next byte is end of group
				break --Table is finished parsing
			end
		else --Record failed to parse
			local count = 0
			while true do
				local byte = drive.readByte(start) --Read the next byte
				start = start + 1 --Jump pointer forward by one
				count = count + 1 --Add another byte to counter
				if byte == 30 then --If the byte is end-of-file
					break --We've finished the record
				elseif count == 100 --If we've read 100 bytes
					error("File record tables critically damaged") --Time out, that's a lot of bytes
				end
			end
		end
	end
	return records --Return parsed map of records
end

local function downTheRabbitHole(drive, path) --Recurse down a path and the associated tables
	local segments = sys.segments(sys.canonical(path)) --Seperate path into parts using filesystem API, also patch relative paths
	
	local location = 8 --Starting location for root tables in all UHWFS drives
	for k, segment in pairs(segments) do --Loop through path segments
		local record = (parseTable(drive, location))[segment] --Parse table and grab record by name
		if not record then --If record doesn't exist
			return nil, "no such file or directory" --Failed to recurse due to missing part
		elseif record ~= "directory" and k < #segments then --If record isn't directory and we arn't at the end of the path
			return nil, "no such file or directory" --Failed to recurse due to directory mid-way in path isn't a directory
		elseif record ~= "directory" and k == #segments then --If record is last part and isn't a directory
			return nil, "last file is not directory" --Recursion succeeded but there's no where to point to
		end
		location = record.location --Point to next directory's table
	end
	
	return location --Return where the last directory in path points
end

local function defrag(drive)
	
end

local function list(drive, path) --Do the directory search
	if path == nil then --If path wasn't supplied, set a blank default
		path = ""
	end
	
	local location, err = downTheRabbitHole(drive, path) --Recurse down the path to find final directory
	
	if err == "last file is not directory" then --Last portion of path is file not directory
		return {sys.name(path)} --Return file in list alone as filesystem.list does
	elseif err then --Recursion failed due to a missing file/directory
		return nil, "no such file or directory" --Return the error
	end
	
	local count = 0 --Count of items
	local items = {} --Those items
	local records = parseTable(drive, location) --Parse table at retrieved location
	for name in pairs(records) do --Loop through records in table
		count = count + 1 --Count that record
		items[count] = name --Place the record name in the items list, count is 1 ahead already
	end
	items.n = count --According to filesystem.list, items.n should be number of items
	return items --Return list with count
end

local function exists(drive, path) --Check if file exists
	if path == nil then --If path wasn't supplied, set a blank default
		path = ""
	end
	
	local loc, err = downTheRabbitHole(drive, path) --Hack it, recurse down the path using existing function
	
	if err == "no such file or directory" then --Recursion ran into error before final portion of path
		return false --Nothing exists
	else --Recursion either found directory (returned location) or a file (returned "last file is not directory" error)
		return true --Something exists
	end
end

local function isDirectory(drive, path) --Check if file is a directory
	if path == nil then --If path wasn't supplied, set a blank default
		path = ""
	end
	
	local loc, err = downTheRabbitHole(drive, path) --Hack it, recurse down the path using existing function
	
	if loc then --If the last portion of path was a directory and is pointed to
		return true --It's a directory
	else --If it wasn't pointed to and an error occcured
		return false --It's not a directory, maybe because a path fault
	end
end

local function size(drive, path) --Find the size of a file
	if path == nil then --If path wasn't supplied
		return 0 --Root is directory, directories are 0
	end
	
	local loc, err = downTheRabbitHole(drive, sys.path(path)) --Navigate one level up from the path
	
	if err == "no such file or directory" then --If recurse failed due to a mid-way path fault
		return nil, err --Return what it gave us
	elseif err == "last file is not directory" then --If last part of recursion (second last part of path) isn't a directory
		return nil, "no such file or directory" --We can't continue so our file doesn't exist
	end
	
	local record = (parseTable(drive, loc))[sys.name(path)] --Grab the record for our file from it's parent directory
	
	if not record then --If our file's record wasn't found
		return nil, "no such file or directory" --It doesn't exist, report so
	elseif record.type == "directory" then --If our file is actually a directory
		return 0 --Filesystem size() returns 0 on directories, so shall we
	else --We found out file and it's a file
		return record.size --Return it's reported size
	end
end

function api.init(drive) --Create filesystem proxy from drive proxy
	local proxy = { 
		slot = drive.slot, --Copy component slot
		address = drive.address, --Copy component address
		type = "filesystem", --Spoof component type
		realType = "drive", --Notify wrapper aware code this is wrapped
		getLabel = drive.getLabel, --Mirror getLabel drive function
		setLabel = drive.setLabel, --Mirror setLabel drive function
		spaceTotal = drive.getCapacity, --Mirror drive's version of spaceTotal
		isReadOnly = function () --Readonly drives not supported, always return false
			return false 
		end
		
		lastModified = function () --Spoof filesystem lastModified timestamp
			return math.huge() --Return infinitely large value to prevent wrong operation
		end,
		
		defrag = function () --Add wrapper aware function to defrag drive, it gets crowded
			defrag(drive)
		end,
		
		list = function (path) --Spoof filesystem directory search
			list(drive, path)
		end,
		
		exists = function (path) --Spoof filesystem file/directory exists check
			exists(drive, path)
		end,
		
		isDirectory = function (path) --Spoof filesystem isDirectory check
			isDirectory(drive, path)
		end,
		
		size = function (path) --Spoof filesystem size grabber
			size(drive, path)
		end
	}
	
	--Implementation list:
	-- spaceUsed()		O
	-- open()			O
	-- seek()			O
	-- makeDirectory()	O
	-- exists()			X
	-- isReadOnly()		X
	-- write()			O
	-- spaceTotal()		X
	-- isDirectory()	X
	-- rename()			O
	-- list()			X
	-- lastModified()	X
	-- getLabel()		X
	-- remove()			O
	-- close()			O
	-- size()			X
	-- read()			O
	-- setLabel()		X
	-- fsnode			O WHAT IS THIS
	-- slot				X
	-- type				X
	-- address			X
	
	return proxy --Return filesystem proxy to wrapper for mounting
end