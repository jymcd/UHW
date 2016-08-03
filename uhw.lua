term = require "term"
device = require "computer"
comp = require "component"
sys = require "filesystem"
event = require "event"
args = {...}
version = "0.0.1"

function createFile(addr, record)
	local drive = comp.proxy(addr)
	local file = io.open("/mnt/"..string.sub(addr, 1, 3).."/"..record.path..record.name, "w")
	file:write(record.data)
	file:close()
end

function wrapper(name, addr, cType)
	local logFile = io.open("/var/log/uhw.log", "a")
	if cType == "drive" then
		if sys.exists("/mnt/"..string.sub(addr, 1, 3)) then
			logFile:write("Failed to wrap "..addr..": Address is too similar\n")
		else
			logFile:write("Detecting format for "..addr.."\n")
			local sect = comp.invoke(addr, "readSector", 1)
			local name = string.match(sect, "(%w+)\00")
			local vers = comp.invoke(addr, "readByte", string.len(name)+2)
			vers = vers + 128
			logFile:write("Loading "..name.." v"..vers.."\n")
			local driver = require name.."-v"..vers..".lua"
			logFile:write("Wrapping "..addr.."\n")
			sys.makeDirectory("/mnt/"..string.sub(addr, 1, 3))
			local files = driver.parseTable(addr)
			if type(files) == "string" then
				logFile:write("Driver Error: "..files.."\n")
				logFile.close()
				sys.remove("/mnt/"..string.sub(addr, 1, 3))
				return true
			end
			for useless, record in pairs(files) do
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
elseif args[1] == "download" then 
	if not comp.internet then
		io.stderr:write("Internet card not detected\n")
		os.exit()
	end
	if args[2] == "driver" then
		name = string.lower(args[3])
		version = tostring(tonumber(args[4]))
		internet = comp.proxy(comp.list("internet")())
		baseUrls = {
			uhwfs = "https://raw.githubusercontent.com/TYKUHN2/UHW/master/drivers/uhwfs/"
			}
		if not baseUrls[name] then
			io.stderr("Invalid driver")
			os.exit()
		end
		print("Downloading "..name.."-v"..version..".lua")
		socket = internet.request(baseUrls[name]..name.."-v"..version..".lua")
		repeat
			result, err = pcall(socket.finishConnect)
			if err then
				socket.close()
				io.stderr:write("Connection error: "..err.."\n")
				os.exit()
			end
		until result == true
		repeat
			code, data = socket.response()
		until code
		socket.close()
		if code == 404 then
			io.stderr("Driver not found")
			os.exit()
		end
		lib = io.open("/usr/lib/uhwfso.lua", "w")
		lib:write(code)
		lib:close()
	elseif args[2] == "main" then
		baseUrl = "https://raw.githubusercontent.com/TYKUHN2/UHW/master/"
		print("Checking version")
		versSock = internet.request(baseUrl.."version.txt")
		repeat
			result, err = pcall(versSock.finishConnect)
			if err then
				versSock.close()
				io.stderr:write("Connection error: "..err.."\n")
				os.exit()
			end
		until result == true
		if version != versSock.read(math.huge) then
			print("Downloading UHW Main file")
			socket = internet.request(baseUrl.."uhw.lua")
			repeat
				result, err = pcall(socket.finishConnect)
				if err then
					socket.close()
					io.stderr:write("Connection error: "..err.."\n")
					os.exit()
				end
			until result == true
			proc = require "process"
			file = io.open(proc.running(), "w")
			file:write(socket.read(math.huge))
			file:close()
			socket.close()
			print("Update complete")
		else
			print("UHW Main file is already up to date")
		end
		versSock.close()
	end
else--HELP
	print("Usages for Unmanaged Harddrive Wrapper (UHW):")
	io.stderr:write("WARNING: DOES NOT REWRITE TO HARDDRIVES CURRENTLY\n")
	print("uhw hook --Wraps and adds unmanaged harddrives to the file system")
	print("uhw unhook --Unwraps harddrives and cleans up")
	print("uhw update --All changes to wrapped files are saved to harddrive, doesn't work")
	print("uhw install --Makes a mess with various dependencies used for full functioning")
	print("uhw uninstall --Cleans up UHW mess")
	print("uhw download driver name version --Downloads the specified driver if it is offically recognized")
	print("uhw download main --Updates the UHW main lua file")
	if not sys.exists("/usr/lib/uhwfso.lua") then
		print("uhw download fso_driver --Downloads the UHW write driver")
	end
end