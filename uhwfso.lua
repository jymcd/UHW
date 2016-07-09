local api = {}
local comp = require "component"
local sys = require "filesystem"

local function calculateOffset(fileTable)
	
end

function api.createTable(dir)
    local files = {}
    for file in sys.list(dir) do
        if string.sub(file, -1) ~= "/" then
            local record = {name = sys.name(file), size = sys.size(file)}
            record.recordSize = 5 + string.len(record.name) + tonumber(string.format("%d", record.size/127))
            table.insert(files, record)
        end
    end
	return calculateOffset(files)
end

function api.rewriteTable(table, drive)
    drive = comp.proxy(drive)
    place = 6
    
end

function api.writeDrive(table, dir, drive)
    drive = comp.proxy(drive)
    
end