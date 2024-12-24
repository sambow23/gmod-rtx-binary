if (CLIENT) then
    require((BRANCH == "x86-64" or BRANCH == "chromium" ) and "RTXFixesBinary" or "RTXFixesBinary_32bit")

    -- Store light handles for each light entity
    local lightHandles = {}

    -- Debug function
    local function DebugPrint(...)
        if GetConVar("developer"):GetBool() then
            print("[RTX Debug]", ...)
        end
    end

    -- Hook into light entity creation/updates
    hook.Add("OnEntityCreated", "rtx_fixes_light_creation", function(ent)
        if not IsValid(ent) then return end
        
        -- Wait until entity is initialized
        timer.Simple(0, function()
            if not IsValid(ent) then return end
            
            if ent:GetClass() == "light" then
                DebugPrint("Creating RTX light for entity:", ent:EntIndex())
                -- Create RTX light for this entity
                local pos = ent:GetPos()
                local brightness = ent:GetBrightness() or 1
                local size = ent:GetLightSize() or 100
                local color = ent:GetColor()
                
                -- Convert color to 0-1 range
                local r, g, b = color.r / 255, color.g / 255, color.b / 255
                
                DebugPrint("Light properties:", pos, brightness, size, color)
                
                -- Create RTX light handle
                local handle = CreateRTXLight(pos.x, pos.y, pos.z, size, brightness * 100, r, g, b)  -- Increased brightness scaling
                if handle then
                    DebugPrint("Successfully created RTX light handle")
                    lightHandles[ent:EntIndex()] = handle
                else
                    DebugPrint("Failed to create RTX light handle!")
                end
            end
        end)
    end)

    -- Add console command to print debug info
    concommand.Add("rtx_debug_lights", function()
        print("=== RTX Light Debug Info ===")
        print("Active RTX lights:", table.Count(lightHandles))
        for entIdx, handle in pairs(lightHandles) do
            local ent = Entity(entIdx)
            if IsValid(ent) then
                local pos = ent:GetPos()
                print(string.format("Light %d: Pos(%d,%d,%d)", entIdx, pos.x, pos.y, pos.z))
            end
        end
    end)

    -- Update light properties when they change
    local nextUpdate = 0
    hook.Add("Think", "rtx_fixes_light_update", function()
        -- Limit updates to every 0.1 seconds
        if CurTime() < nextUpdate then return end
        nextUpdate = CurTime() + 0.1

        for entIdx, handle in pairs(lightHandles) do
            local ent = Entity(entIdx)
            if IsValid(ent) then
                local pos = ent:GetPos()
                local brightness = ent:GetBrightness() or 1
                local size = ent:GetLightSize() or 100
                local color = ent:GetColor()
                
                -- Update RTX light properties
                local newHandle = UpdateRTXLight(handle, pos.x, pos.y, pos.z, size, brightness * 100, 
                                               color.r / 255, color.g / 255, color.b / 255)
                if newHandle then
                    lightHandles[entIdx] = newHandle
                end
            else
                DebugPrint("Removing RTX light for deleted entity:", entIdx)
                DestroyRTXLight(handle)
                lightHandles[entIdx] = nil
            end
        end
    end)

    -- Test command to spawn a bright RTX light at player position
    concommand.Add("rtx_test_light", function(ply)
        local pos = ply:GetPos()
        local handle = CreateRTXLight(pos.x, pos.y, pos.z + 50, 200, 1000, 1, 1, 1)  -- Bright white light
        if handle then
            DebugPrint("Created test light at player position")
        end
    end)

    hook.Add("PostDrawOpaqueRenderables", "rtx_fixes_render", function(depth, sky, sky3d)
        DrawRTXLights()
    end)

    DebugPrint("RTX Fixes initialized")
end