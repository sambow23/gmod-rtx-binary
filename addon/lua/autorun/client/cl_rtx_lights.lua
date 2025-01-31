-- -- Light Visualizer by [Your Name]
-- -- Using NikNaks Library

-- local CUBE_SIZE = Vector(10, 10, 10)
-- local CUBE_OFFSET = -10 -- Distance to place cube in front of light
-- local renderBounds = Vector(256, 256, 256)
-- local maxBounds = Vector(16384, 16384, 16384)

-- local lightTypes = {
--     ["light"] = true,
--     ["light_spot"] = true,
--     ["light_environment"] = true,
--     ["light_dynamic"] = true
-- }

-- local lightCubes = {}

-- -- Calculate position for cube based on light type and properties
-- local function CalculateCubePosition(lightData)
--     local pos = lightData.origin
--     local angles = lightData.angles or angle_zero
    
--     -- For spot lights, offset in the direction they're pointing
--     if lightData.classname == "light_spot" then
--         local forward = angles:Forward()
--         return pos + (forward * CUBE_OFFSET)
--     -- For environment lights, offset upward
--     elseif lightData.classname == "light_environment" then
--         return pos + Vector(0, 0, CUBE_OFFSET)
--     -- For regular lights, offset slightly forward and up
--     else
--         return pos + Vector(CUBE_OFFSET/2, 0, CUBE_OFFSET/2)
--     end
-- end

-- -- Custom cube rendering without view frustum culling
-- local function RenderCubes()
--     cam.IgnoreZ(true)
--     render.SetBlend(0.05) -- Set global transparency to 5%
    
--     for _, cube in ipairs(lightCubes) do
--         local color = color_white
        
--         -- Different colors for different light types
--         if cube.type == "light_spot" then
--             render.SetColorModulation(1, 0.8, 0) -- Orange-yellow for spots
--         elseif cube.type == "light_environment" then
--             render.SetColorModulation(0.8, 1, 0) -- Green-yellow for environment
--         else
--             render.SetColorModulation(1, 1, 0) -- Yellow for regular lights
--         end
        
--         render.DrawBox(cube.pos, cube.angles or angle_zero, -CUBE_SIZE, CUBE_SIZE, color)
        
--         -- Draw a line from light to cube for spot lights
--         if cube.type == "light_spot" then
--             render.DrawLine(cube.originalPos, cube.pos, color_white, true)
--         end
--     end
    
--     render.SetBlend(1) -- Reset transparency
--     render.SetColorModulation(1, 1, 1)
--     cam.IgnoreZ(false)
-- end

-- -- Initialize light cubes and modify render bounds
-- local function InitializeLights()
--     lightCubes = {}
    
--     -- Get the current map data using NikNaks
--     local mapData = NikNaks.CurrentMap
--     if not mapData then return end
    
--     -- Find all light entities in the map
--     local entities = mapData:GetEntities()
    
--     for _, ent in pairs(entities) do
--         if lightTypes[ent.classname] then
--             -- Calculate the offset position for the cube
--             local cubePos = CalculateCubePosition(ent)
            
--             -- Store cube data for rendering
--             table.insert(lightCubes, {
--                 pos = cubePos,
--                 originalPos = ent.origin,
--                 type = ent.classname,
--                 angles = ent.angles
--             })
            
--             -- Find and modify the actual light entity in the game world
--             for _, worldEnt in ipairs(ents.FindByClass(ent.classname)) do
--                 if worldEnt:GetPos():DistToSqr(ent.origin) < 1 then
--                     -- Set render bounds based on light type
--                     if ent.classname == "light_environment" then
--                         worldEnt:SetRenderBounds(-maxBounds, maxBounds)
--                     else
--                         worldEnt:SetRenderBounds(-renderBounds, renderBounds)
--                     end
--                 end
--             end
--         end
--     end
-- end

-- -- Hook into the rendering system
-- hook.Add("PostDrawTranslucentRenderables", "LightVisualizer_RenderCubes", RenderCubes)

-- -- Initialize when the map loads
-- hook.Add("InitPostEntity", "LightVisualizer_Initialize", InitializeLights)

-- -- Also initialize when the script reloads
-- InitializeLights()

-- -- Add console command to reinitialize
-- concommand.Add("light_visualizer_refresh", InitializeLights)

-- -- Add console command to toggle visualization
-- local visualizerEnabled = true
-- concommand.Add("light_visualizer_toggle", function()
--     visualizerEnabled = not visualizerEnabled
--     if visualizerEnabled then
--         hook.Add("PostDrawTranslucentRenderables", "LightVisualizer_RenderCubes", RenderCubes)
--     else
--         hook.Remove("PostDrawTranslucentRenderables", "LightVisualizer_RenderCubes")
--     end
-- end)