if not CreateRTXSphereLight then return end

-- Debug function to help visualize light positions
local function DebugDrawLight(pos, radius, r, g, b, duration)
    duration = duration or 5
    debugoverlay.Sphere(pos, radius, duration, Color(r * 255, g * 255, b * 255, 50), true)
end

local function ConvertCoordinates(sourcePos)
    -- Source: X=Forward, Y=Right, Z=Up
    -- Remix: X=Right, Y=Up, Z=Forward
    return {
        x = sourcePos.y,  -- Source Right -> Remix Right
        y = sourcePos.z,  -- Source Up -> Remix Up
        z = sourcePos.x   -- Source Forward -> Remix Forward
    }
end

local function SpawnRTXLight(ply, cmd, args)
    local trace = LocalPlayer():GetEyeTrace()
    if not trace.Hit then return end

    -- Default parameters following Remix examples
    local radius = 100
    local r, g, b = 1, 1, 1
    local intensity = 50

    -- Parse arguments
    if args[1] then radius = tonumber(args[1]) or radius end
    if args[2] and args[3] and args[4] then
        r = tonumber(args[2]) or r
        g = tonumber(args[3]) or g
        b = tonumber(args[4]) or b
    end
    if args[5] then intensity = tonumber(args[5]) or intensity end

    -- Convert coordinates
    local rtxPos = ConvertCoordinates(trace.HitPos)
    
    -- Create the light
    local lightId = CreateRTXSphereLight(
        rtxPos.x, rtxPos.y, rtxPos.z,
        radius,
        r, g, b,
        intensity
    )

    if lightId then
        print(string.format("Created RTX light #%d", lightId))
        -- Visualize the light position
        debugoverlay.Sphere(trace.HitPos, radius, 5, Color(r * 255, g * 255, b * 255, 50), true)
    else
        print("Failed to create RTX light")
    end
end

-- Register console command
concommand.Add("rtx_spawn_light", SpawnRTXLight, nil, [[
Spawns an RTX light where you're looking.
Arguments: <radius> <r> <g> <b> <intensity>
Example: rtx_spawn_light 100 1 0 0 50 (creates a red light)
]])

-- Command to remove lights
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

-- Helper command to spawn a preset light
concommand.Add("rtx_spawn_bright_light", function()
    local trace = LocalPlayer():GetEyeTrace()
    if not trace.Hit then return end
    
    local pos = trace.HitPos
    local rtxX = pos.y
    local rtxY = pos.z
    local rtxZ = pos.x
    
    local lightId = CreateRTXSphereLight(
        rtxX,    -- x
        rtxY,    -- y
        rtxZ,    -- z
        200,     -- larger radius
        1, 1, 1, -- white
        100      -- very bright
    )
    
    if lightId then
        print("Created bright RTX light #" .. lightId)
        DebugDrawLight(pos, 200, 1, 1, 1)
    end
end)