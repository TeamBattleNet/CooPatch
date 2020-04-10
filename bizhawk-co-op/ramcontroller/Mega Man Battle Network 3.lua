mmbn3 = {}
mmbn3.itemcount = 1 -- needed for the script to run, no clue what it does lmao

memory.usememorydomain("System Bus")
local valid_registers = emu.getregisters()

local sent_event_queue = {}
local recieved_event_queue = {}

local end_main_func_addr = 0x08000322
local give_chip_func_addr = 0x08011281
local update_library_func_addr = 0x080112B0

-- creates the events that gets added to the local player's queue
local function create_event_from_data(type, data)
    local new_event = nil
    if type == "c" then
        new_event = {
            addr=give_chip_func_addr,
            registers={["R0"]=data.id, ["R1"]=data.code, ["R2"]=data.amount}
        }
    elseif type == "l" then
        new_event = {
            addr=give_chip_func_addr,
            registers={["R0"]=data.id, ["R1"]=0, ["R2"]=0}
        }
    end
    return new_event
end

-- the idea with save_entry and load_save is to keep track of any events since the player's last ingame save
-- ideally when they load the ingame save it'll load our external save and add any events that the player has sent/recieved
-- sorta functions as an anti-cheat(?)
local save_entry = function(key, value)
    -- open file
	local file_loc = '.\\bizhawk-co-op\\savedata\\' .. gameinfo.getromname() .. '_' .. config.user .. '.dat'
	local f = io.open(file_loc, "a")

	if f then
		f:write(key .. ',' .. tabletostring(value) .. '\n')
		f:close()
	end
end

local load_save = function()
	-- open file
	local file_loc = '.\\bizhawk-co-op\\savedata\\' .. gameinfo.getromname() .. '_' .. config.user .. '.dat'
	local f = io.open(file_loc, "r")

	if f then
		for line in f:lines() do
			local splitline = strsplit(line, ',', 1)
			local key = splitline[1]
			local splitvalue = strsplit(splitline[2], ',')
			local value = stringtotable(splitvalue)

            console.log(value)

            --[[
                make events for both saved and receieved entries

                ex: player1 makes an ingame save
                    player1's local save would purge any entries in it
                    player1 picks up a 1000z mystery data and sends a zenny event to player2
                    player1 also saves that sent event in it's local save
                    player2 gets zenny event and updates it's zenny count accordingly
                    player1 soft resets and reloads it's ingame save
                    at this point, player1's gamestate wouldn't have picked up that 1000z mystery data
                    update player1's zenny count while loading the ingame save
                    
                    in this case we would also need to update player1's mystery data location to be picked up to prevent "duping"
            ]]-- 
            if key == "sent" or key == "received" then
                local new_event = create_event_from_data(value.type, value.data)
                if new_event ~= nil then
                    table.insert(recieved_event_queue, new_event)
                end
			end
		end
		f:close()
	end
end

--[[
hooks the end of the main function
code normally looks like this:
    0800031C    ldr     r0,=3006825h                        load some function addr into r0
    0800031E    mov     r14,r15                             move the PC into r14 for returning here
    08000320    bx r0                   <- hooking here     call the function loaded in r0
    08000322    b       80002B4h                            goes back to start of main loop
the idea is to call whatever function we want with r0 then rerun this code normally
--]]
local function main_hook()
    if next(recieved_event_queue) ~= nil then
        local index, event = next(recieved_event_queue)
        emu.setregister("R0", event.addr)
        emu.setregister("R14", 0x0800031C)
    end
end

-- r0 is used to call functions and as function args
-- we need to set the args manually at the beginning of functions
local function set_args(registers)
    for reg, value in pairs(registers) do
        if valid_registers[reg] ~= nil then
            emu.setregister(reg, value)
        end
    end
end

-- hooks the give_chip function
-- has 2 purposes, to create new events for other players or complete current queued events
local function give_chip_hook()
    local ret_addr = emu.getregister("R14")

    -- check if we called this function
    if ret_addr == 0x0800031C then
        local index, event = next(recieved_event_queue)
        if event ~= nil then
            set_args(event.registers)
            table.remove(recieved_event_queue, index)
        end
    else
        if config.ramconfig.chips then
            local chip_id = emu.getregister("R0")
            local chip_code = emu.getregister("R1")
            local chip_amount = emu.getregister("R2")
            local new_event = {
                type="c",
                data={
                    id=chip_id,
                    code=chip_code,
                    amount=chip_amount,
                },
            }
            console.log("Making new give_chip event with " .. chip_id)
            console.log(new_event)
            table.insert(sent_event_queue, new_event)
        end
    end
end

-- hooks the update_library function
-- this is solely to create events for any chips the player gains that aren't gotten from the hooked give_chip function
-- this is mainly for catching and updating the library when one player picks up an extrafolder
local function update_library_hook()
    local sp = emu.getregister("R13")
    local ret_addr = memory.read_u32_le(sp)

    -- check if we called the give_chip function
    -- used to prevent making update_library events for chips this player has recieved
    if ret_addr ~= 0x0800031C then
        if config.ramconfig.library then
            -- check if the last_event was a give_chip event to prevent sending 2 events
            -- the give_chip function calls the library function
            local last_event = sent_event_queue[#sent_event_queue]
            if last_event ~= nil then
                local chip_id = emu.getregister("R0")
                if last_event.data.id ~= chip_id then
                    local new_event = {
                        type="l",
                        data={
                            id=chip_id,
                        },
                    }
                    console.log("Making new update_library event with " .. chip_id)
                    console.log(new_event)
                    table.insert(sent_event_queue, new_event)
                end
            end
        end
    else
        console.log("Recieved chip so not making new update_library event")
    end
end

-- TODO: Track mystery data pickups to prevent cheating
-- TODO: Track shop stock to prevent cheating
-- TODO: Hook ingame saving (and new game?) to purge entries from the local save
-- TODO: Hook loading from title to call load_save

-- unregister any old events that may be left over from running the script previously 
event.unregisterbyname("main hook")
event.unregisterbyname("update library hook")
event.unregisterbyname("give chip hook")

event.onmemoryexecute(main_hook, end_main_func_addr, "main hook")
event.onmemoryexecute(update_library_hook, update_library_func_addr, "update library hook")
event.onmemoryexecute(give_chip_hook, give_chip_func_addr+1, "give chip hook")

-- Gets a message to send to the other player of new changes
-- Returns the message as a dictionary object
-- Returns false if no message is to be send
function mmbn3.getMessage()
    local message = {}
    if next(sent_event_queue) ~= nil then
        for index, event in pairs(sent_event_queue) do
            if message[event.type] == nil then
                message[event.type] = {}
            end

            save_entry("sent", event)
            table.insert(message[event.type], event.data)
            table.remove(sent_event_queue, index)
        end

        printOutput("Sending Message")
        return message
    else
        return false
    end
end

-- Process a message from another player and update RAM
function mmbn3.processMessage(their_user, message)
    if message["c"] then
        if config.ramconfig.chips then
            console.log("Getting Chip Message")
            for _, chip in pairs(message["c"]) do
                console.log(chip)
                save_entry("received", {type="c", data=chip})
                local new_event = create_event_from_data("c", chip)
                if new_event ~= nil then
                    table.insert(recieved_event_queue, new_event)
                end
            end
        end
    end

    if message["l"] then
        if config.ramconfig.library then
            console.log("Getting Library Message")
            for _, chip in pairs(message["l"]) do
                console.log(chip)
                save_entry("received", {type="l", data=chip})
                local new_event = create_event_from_data("l", chip)
                if new_event ~= nil then
                    table.insert(recieved_event_queue, new_event)
                end
            end
        end
    end
end

local configformState

local function configOK()
    configformState = "OK"
end
local function configCancel()
    configformState = "Cancel"
end

function mmbn3.getConfig()
    configformState = "Idle"

    forms.setproperty(mainform, "Enabled", false)

    local configform = forms.newform(150, 175, "")
    local chkChips = forms.checkbox(configform, "Chips", 10, 10)
    local chkLibrary = forms.checkbox(configform, "Library Progress", 10, 30)
    local chkZenny = forms.checkbox(configform, "Zenny", 10, 50)
    local chkBugfrags = forms.checkbox(configform, "Bugfrags", 10, 70)
    local btnOK = forms.button(configform, "OK", configOK, 10, 100, 50, 23)
    local btnCancel = forms.button(configform, "Cancel", configCancel, 70, 100, 50, 23)

    while configformState == "Idle" do
		coroutine.yield()
    end
    
    local config = {
        ['chips'] = forms.ischecked(chkChips),
        ['library'] = forms.ischecked(chkLibrary),
        ['zenny'] = forms.ischecked(chkZenny),          -- currently unimplemented
        ['bugfrags'] = forms.ischecked(chkBugfrags)     -- currently unimplemented
    }

    forms.destroy(configform)
    forms.setproperty(mainform, "Enabled", true)

    if configformState == "OK" then
        return config
    else
        return false
    end

end

return mmbn3
