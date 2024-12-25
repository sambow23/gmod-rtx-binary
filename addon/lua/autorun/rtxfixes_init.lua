if SERVER then
    cleanup.Register("rtx_lights")
end

if CLIENT then
    require((BRANCH == "x86-64" or BRANCH == "chromium" ) and "RTXFixesBinary" or "RTXFixesBinary_32bit")

    -- Add console command to spawn a test light
    concommand.Add("rtx_test_light", function(ply)
        local pos = ply:GetPos()
        -- More conservative test values
        local size = 25            -- Smaller size
        local brightness = 5       -- Lower brightness
        local r, g, b = 0.5, 0.5, 0.5  -- Half brightness white
        print(string.format("[RTX Debug] Attempting to create light at pos: %.2f, %.2f, %.2f", pos.x, pos.y, pos.z))
        local handle = CreateRTXLight(pos.x, pos.y, pos.z + 50, size, brightness, r, g, b)
        if handle then
            print("[RTX Debug] Successfully created test light")
        end
    end)

    -- Draw lights each frame
    hook.Add("PostDrawOpaqueRenderables", "rtx_fixes_render", function()
        local count = 0
        for _, ent in ipairs(ents.FindByClass("base_rtx_light")) do
            if IsValid(ent) and ent.rtxLightHandle then
                count = count + 1
            end
        end
        DrawRTXLights()
    end)

        -- Add cleanup hook
    hook.Add("PostCleanupMap", "rtx_fixes_cleanup", function()
        -- Cleanup all RTX lights
        for _, ent in ipairs(ents.FindByClass("base_rtx_light")) do
            if IsValid(ent) and ent.rtxLightHandle then
                pcall(function()
                    DestroyRTXLight(ent.rtxLightHandle)
                end)
                ent.rtxLightHandle = nil
            end
        end
    end)
end