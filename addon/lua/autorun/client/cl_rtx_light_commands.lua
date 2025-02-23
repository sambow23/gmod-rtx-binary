if not CreateRTXSphereLight then return end -- Only run if RTX module is loaded

local function SpawnRTXLight(ply, cmd, args)
    -- Get player's eye trace
    local trace = LocalPlayer():GetEyeTrace()
    if not trace.Hit then return end

    -- Default light parameters
    local pos = trace.HitPos
    local radius = 50        -- 50 units radius
    local r, g, b = 1, 1, 1 -- White light
    local intensity = 5      -- Medium brightness

    -- Parse arguments if provided
    if args[1] then radius = tonumber(args[1]) or radius end
    if args[2] and args[3] and args[4] then
        r = tonumber(args[2]) or r
        g = tonumber(args[3]) or g
        b = tonumber(args[4]) or b
    end
    if args[5] then intensity = tonumber(args[5]) or intensity end

    -- Create the light
    local lightId = CreateRTXSphereLight(
        pos.x,    -- x
        pos.z,    -- y (Garry's Mod Z is up)
        pos.y,    -- z
        radius,   -- radius
        r, g, b,  -- color
        intensity -- brightness
    )

    if lightId then
        print(string.format("Created RTX light #%d at %.1f %.1f %.1f", lightId, pos.x, pos.y, pos.z))
    else
        print("Failed to create RTX light")
    end
end

-- Register console command
concommand.Add("rtx_spawn_light", SpawnRTXLight, nil, "Spawns an RTX light where you're looking.\nArguments: <radius> <r> <g> <b> <intensity>")

-- Optional: Add command to remove lights
concommand.Add("rtx_remove_light", function(ply, cmd, args)
    if not args[1] then
        print("Usage: rtx_remove_light <light_id>")
        return
    end
    
    local lightId = tonumber(args[1])
    if not lightId then return end
    
    if RemoveRTXLight(lightId) then
        print("Removed RTX light #" .. lightId)
    else
        print("Failed to remove RTX light #" .. lightId)
    end
end)