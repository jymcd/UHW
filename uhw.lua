local term = require "term"
local comp = require "component"
local sys = require "filesystem"
local event = require "event"
local dev = require "devfs"
local uuid = require "uuid"
local io = require "io"

args = {...}
version = "0.0.1"

function cleanup(addr)
	sys.umount(comp.proxy(addr))
end

function wrapper(name, addr, cType)
	local logFile = io.open("/var/log/uhw.log", "a")
	if name == "component_removed" and cType == "drive" then
		cleanup(addr)
	elseif name == "component_added" and cType == "drive" then
		if sys.exists("/mnt/"..string.sub(addr, 1, 3)) then
			logFile:write("[E] Failed to wrap "..addr..": Address is too similar\n")
		else
			local drive = comp.proxy(addr)
			logFile:write("[I] Detecting format for "..addr.."\n")
			local sect = drive.readSector(1)
			local name = sect:match("(%w+)\00")
			local vers = drive.readByte(name:len() + 2)
			vers = vers + 128 --Fix signing incompatibility
			logFile:write("[I] Loading "..name.." v"..vers.."\n")
			local driver = require(name.."-v"..vers)
			if not driver then
				logFile:write("[W] Failed to load driver\n")
				logFile:close()
				return true
			end
			logFile:write("[I] Wrapping "..addr.."\n")
			local err, prox = pcall(driver.init, drive)
			if not prox then
				logFile:write("[E] " .. err)
				logFile:close()
				return true
			end
			sys.mount(prox, addr:sub(1, 3))
		end
		logFile:close()
		return true
	elseif cType == "UHW_Killer" and addr == uuid then
		logFile:write("Hook killed\n")
		logFile:close()
		event.ignore("component_removed", wrapper)
		for drive in comp.list("drive") do
			cleanup(drive)
		end
		return false
	elseif cType == "UHW_Test" and addr == uuid then
		logFile:write("Hook check received successfully\n")
		logFile:close()
		event.push("UHW_Test_Response")
		return true
	end
end

if args[1] == "hook" then --HOOK
	if sys.exists("/mnt/.uhw") then
		io.stderr:write("UHW_NOTICE: UHW already hooked\n")
	else
		if not sys.exists("/var/") then
			sys.makeDirectory("/var/")
			sys.makeDirectory("/var/log/")
		elseif not sys.exists("/var/log/") then
			sys.makeDirectory("/var/log/")
		end
		print("Hook created")
		local logFile = io.open("/var/log/uhw.log", "a")
		if not event.listen("component_added", wrapper) then
			io.stderr:write("UHW_ERROR: Hook failed to create")
			os.exit()
		end
		logFile:write("[I] Hook created\n")
		logFile:flush()
		local hookID = uuid.next()
		event.push("component_added", hookID, "UHW_Test")
		pulled = event.pull(1, "UHW_Test_Response")
		if pulled == nil then
			io.stderr:write("UHW_ERROR: Hook failed to respond")
			logFile:write("[E] Hook failed to respond\n[I] Hook killed\n")
			logFile:close()
			event.ignore("component_added", wrapper)
			os.exit()
		end
		logFile:close()
		for component in comp.list("drive", true) do
			print("UHW_NOTICE: Wrapping all current drives.")
			io.stderr:write("UHW_WARNING: If not unhooked correctly previously, all currently wrapped drives will produce an error\n")
			event.pull(3, "SLEEP_DO_NOT_THROW")
			wrapper("component_added", component, "drive")
		end
		event.listen("component_removed", wrapper)
		local file = io.open("/mnt/.uhw", "w")
		file:write(hookID)
		file:close()
	end
elseif args[1] == "unhook" then --UNHOOK
	if not sys.exists("/mnt/.uhw") then
		io.stderr:write("UHW not hooked")
	else
		local file = io.open("/mnt/.uhw", "r")
		local hookID = file:read("*a")
		file:close()
		sys.remove("/mnt/.uhw")
		event.push("component_added", hookID, "UHW_Killer")
		print("Deleting wrapped drives (cleaning up)")
	end
elseif args[1] == "install" then --INSTALL
	proc = require "process"
	path = proc.running()
	if not sys.exists("/usr/bin/") then
		sys.makeDirectory("/usr/bin/")
	end
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
		if version ~= versSock.read(math.huge) then
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
	print("uhw hook --Wraps and adds unmanaged harddrives to the file system")
	print("uhw unhook --Unwraps harddrives and cleans up")
	print("uhw install --Moves executable to /usr/bin")
	print("uhw uninstall --Unhooks, deletes log, and prints executable location")
	print("uhw download driver_name version --Downloads the specified driver if it is offically recognized")
	print("uhw download main --Updates the UHW executable file")
end