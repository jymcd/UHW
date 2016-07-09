term = require "term"
device = require "computer"
comp = require "component"
sys = require "filesystem"
event = require "event"
args = {...}

function populateFileTable(addr, logFile)
	local drive = comp.proxy(addr)
	local sect = drive.readSector(1)
	if string.sub(sect, 1, 5) == "UHWFS" then
		local files = {}
		local place = 6
		while true do
			local start = place
			local name = ""
			while true do
				local bit = drive.readByte(place) --Shut up people sensitive about the use of bit here :)
				place = place + 1
				if bit == 30 and string.len(name) > 0 then
					start = place
					break
				end
				if bit > 33 and bit < 126 then --No extended ascii :( not even sure if OC supports it (and normal fs). Will implement if it does
					name = name..string.char(bit)
				elseif bit == 0 then
					logFile:write("File record ("..start..") corrupted, unable to parse table\n")
					return false
				else
					logFile:write("File record ("..start..") corrupted\n")
					name = nil
					start = place
					break
				end
			end
			if name ~= nil then
				local loc = 1
				local lastNum = 0
				while true do
					local bit = drive.readByte(place)
					place = place + 1
					if bit < 0 and lastNum ~= 0 then
						loc = loc / lastNum
						loc = loc + lastNum
						break
					elseif bit < 0 and lastNum == 0 then
						logFile:write("File record ("..start..") corrupted\n")
						name = nil
						loc = nil
						break
					elseif bit == 0 then
						logFile:write("File record ("..start..") corrupted, unable to parse table\n")
						return false
					end
					loc = loc * bit
					lastNum = bit
				end
				lastNum = nil
				if name ~= nil then
					local length = 1
					local lastNum = 0
					while true do
						local bit = drive.readByte(place)
						place = place + 1
						if bit < 0 and lastNum ~= 0 then
							length = length / lastNum
							length = length + lastNum
							break
						elseif bit < 0 and lastNum == 0 then
							logFile:write("File record ("..start..") corrupted\n")
							name = nil
							length = nil
							break
						elseif bit == 0 then
							logFile:write("File record ("..start..") corrupted, unable to parse table\n")
							return false
						end
						length = length * bit
						lastNum = bit
					end
					lastNum = nil
					if length ~= nil then
						table.insert(files, {name = name, loc = loc, length = length})
						place = place + 1
					else
						while true do
							local bit = drive.readByte(place)
							place = place + 1
							if bit == 28 then
								break
							elseif bit == 0 then
								logFile:write("Previous file record ("..start..") suddenly ended, unable to parse table\n")
								return false
							end
						end
					end
				else
					while true do
						local bit = drive.readByte(place)
						place = place + 1
						if bit == 28 then
							break
						elseif bit == 0 then
							logFile:write("Previous file record ("..start..") suddenly ended, unable to parse table\n")
							return false
						end
					end
				end
			else
				while true do
					local bit = drive.readByte(place)
					place = place + 1
					if bit == 28 then
						break
					elseif bit == 0 then
						logFile:write("Previous file record ("..start..") suddenly ended, unable to parse table\n")
						return false
					end
				end
			end
			if drive.readByte(place) == 4 then
				return files
			end
		end
	end
	return false
end

function createFile(addr, record)
	local drive = comp.proxy(addr)
	local data = ""
	for i = 0, record.length-1 do
		data = data..string.char(drive.readByte(record.loc+i))
	end
	local file = io.open("/mnt/"..string.sub(addr, 1, 3).."/"..record.name, "w")
	file:write(data)
	file:close()
end

function wrapper(name, addr, cType)
	local logFile = io.open("/var/log/uhw.log", "a")
	if cType == "drive" then
		if sys.exists("/mnt/"..string.sub(addr, 1, 3)) then
			logFile:write("Failed to wrap "..addr..": Address is too similar\n")
		else
			logFile:write("Wrapping "..addr.."\n")
			sys.makeDirectory("/mnt/"..string.sub(addr, 1, 3))
			local files = populateFileTable(addr, logFile)
			if files == false then
				logFile:write("Error reading drive "..addr.."\n")
				sys.remove("/mnt/"..string.sub(addr, 1, 3))
				logFile:close()
				return true
			end
			for useless, record in ipairs(files) do
				logFile:write("Creating file "..record.name)
				createFile(addr, record)
			end
		end
		logFile:close()
		return true
	elseif cType == "UHW_Killer" and addr == uuid then
		logFile:write("Hook killed\n")
		logFile:close()
		return false
	elseif cType == "UHW_Test" and addr == uuid then
		logFile:write("Hook check received successfully\n")
		logFile:close()
		device.pushSignal("UHW_Test_Response")
		return true
	end
end

function installDriver()
	internet = comp.proxy(comp.list("internet")())
	print("Connecting to Github")
	socket = internet.request("https://raw.githubusercontent.com/TYKUHN2/UHW/master/uhwfso.lua", nil, {User-Agent = "OpenComputers Script ( oc.cil.li )"})
	repeat
		result, err = pcall(socket.finishConnect)
		if err then
			io.stderr:write("Connection error: "..err.."\n")
			print("Installation complete")
			os.exit()
		end
	until result == true
	repeat
		code = socket.read()
	until string.len(code) > 0
	socket.close()
	lib = io.open("/usr/lib/uhwfso.lua", "w")
	lib:write(code)
	lib:close()
end

if args[1] == "hook" then --HOOK
	if sys.exists("/mnt/.uhw") then
		io.stderr:write("UHW already hooked\n")
	else
		if not sys.exists("/var/") then
			sys.makeDirectory("/var/")
			sys.makeDirectory("/var/log/")
		elseif not sys.exists("/var/log/") then
			sys.makeDirectory("/var/log/")
		end
		uuid = ""
		local base64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz1234567890!#"
		for i = 1, 32 do
			local rand = math.random(1, 64)
			uuid = uuid..string.sub(base64, rand, rand)
			if i == 8 or i == 12 or i ==16 or i == 20 then
				uuid = uuid.."-"
			end
		end
		print("Hook created")
		local logFile = io.open("/var/log/uhw.log", "a")
		if not event.listen("component_added", wrapper) then
			io.stderr:write("Hook failed to create")
			os.exit()
		end
		logFile:write("Hook created\n")
		logFile:flush()
		device.pushSignal("component_added", uuid, "UHW_Test")
		pulled = event.pull(1, "UHW_Test_Response")
		if pulled == nil then
			io.stderr:write("Hook failed to respond")
			logFile:write("Hook failed to respond\nHook killed\n")
			logFile:close()
			event.ignore("component_added", wrapper)
			os.exit()
		end
		logFile:close()
		for component in comp.list("drive") do
			print("UHW_NOTICE: Wrapping all current drives.")
			io.stderr:write("UHW_WARNING: If not unhooked, all currently wrapped drives will produce an error\n")
			event.pull(3, "SLEEP_DO_NOT_THROW")
			wrapper("component_added", component, "drive")
		end
		local file = io.open("/mnt/.uhw", "w")
		file:write(uuid)
		file:close()
	end
elseif args[1] == "update" then --UPDATE
	if sys.exists("/usr/lib/uhwfso.lua") then
		fso = require "uhwfso.lua"
		for drive in comp.list("drive") do
			name = string.sub(drive, 1, 3).."/"
			if sys.exists("/mnt/"..name) then
				fileTable = fso.createTable("/mnt/"..name)
				fso.rewriteTable(fileTable, drive)
				fso.writeDrive(fileTable, "/mnt/"..name, drive)
			end
		end
	else
		io.stderr:write("Error: Unable to locate write driver")
	end
elseif args[1] == "unhook" then --UNHOOK
	if not sys.exists("/mnt/.uhw") then
		io.stderr:write("UHW not hooked")
	else
		local file = io.open("/mnt/.uhw", "r")
		local uuid = file:read("*a")
		file:close()
		sys.remove("/mnt/.uhw")
		device.pushSignal("component_added", uuid, "UHW_Killer")
		print("Deleting wrapped drives (cleaning up)")
		for component in comp.list("drive") do
			if sys.exists("/mnt/"..string.sub(component, 1, 3)) then
				sys.remove("/mnt/"..string.sub(component, 1, 3))
			end
		end
	end
elseif args[1] == "install" then --INSTALL
	proc = require "process"
	path = proc.running()
	if not sys.exists("/usr/bin/") then
		sys.makeDirectory("/usr/bin/")
	end
	file = io.open("/usr/man/uhw", "w")
	file:write("Help is internal to UHW. Execute without parameters")
	file:close()
	if path ~= "/usr/bin/uhw.lua" then
		sys.copy(path, "/usr/bin/uhw.lua")
		sys.remove(path)
	end
	if comp.internet then
		print("Would you like to download the write driver? (Y)/N")
		if string.lower(string.sub(io.read(), 1, 1)) == "n" then
			print("Installation complete")
			os.exit()
		end
		installDriver()
	end
	print("Installation complete")
elseif args[1] == "uninstall" then --UNINSTALL
	proc = require "process"
	if sys.exists("/mnt/.uhw") then
		local shell = require "shell"
		shell.execute("uhw unhook")
	end
	pcall(sys.remove("/usr/man/uhw"))
	pcall(sys.remove("/var/log/uhw.log"))
	print("Executable currently located at "..proc.running())
elseif args[1] == "download" and args[2] == "fso_driver" then --DOWNLOAD FSO_DRIVER
	if not comp.internet then
		io.stderr:write("Internet card not detected\n")
		os.exit()
	end
	installDriver()
else--HELP
	print("Usages for Unmanaged Harddrive Wrapper (UHW):")
	io.stderr:write("WARNING: DOES NOT REWRITE TO HARDDRIVES CURRENTLY\n")
	print("uhw hook --Wraps and adds unmanaged harddrives to the file system")
	print("uhw unhook --Unwraps harddrives and cleans up")
	print("uhw update --All changes to wrapped files are saved to harddrive, doesn't work")
	print("uhw install --Makes a mess with various dependencies used for full functioning")
	print("uhw uninstall --Cleans up UHW mess")
	if not sys.exists("/usr/lib/uhwfso.lua") then
		print("uhw download fso_driver --Downloads the UHW write driver")
	end
end