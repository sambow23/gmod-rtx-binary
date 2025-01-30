if not CLIENT then return end

-- ConVars
local cv_enabled = CreateClientConVar("fr_enabled", "1", true, false, "Enable RTX frustum optimization")
local cv_static_props = CreateClientConVar("fr_static_props", "1", true, false, "Enable optimization for static props")
local cv_debug_cubes = CreateClientConVar("fr_debug_light_cubes", "0", true, false, "Show debug cubes for light optimization")

-- Special entities that should always be visible
local SPECIAL_ENTITIES = {
    ["hdri_cube_editor"] = true,
    ["rtx_lightupdater"] = true,
    ["rtx_lightupdatermanager"] = true
}

-- Cache for managed entities
local managedEntities = {}
local staticProps = {}
local debugLightCubes = {}

local function GetLightType(light)
    -- Base light types
    if light.style then
        if light.style ~= "0" then
            return "Dynamic Light"
        end
    end
    
    if light.classname == "light" then
        return "Point Light"
    elseif light.classname == "light_spot" then
        return "Spot Light"
    elseif light.classname == "light_environment" then
        return "Environment Light"
    elseif light.classname == "light_dynamic" then
        return "Dynamic Light"
    end
    
    return "Unknown Light"
end

local function FormatVector(vec)
    if not vec then return "0.0 0.0 0.0" end
    if type(vec) == "string" then
        -- Some map entities store vectors as strings like "0 0 0"
        return vec
    end
    -- Convert string vector format to actual Vector if needed
    if not vec.x then
        local x, y, z = string.match(tostring(vec), "([-0-9.]+) ([-0-9.]+) ([-0-9.]+)")
        if x and y and z then
            return string.format("%.1f %.1f %.1f", tonumber(x), tonumber(y), tonumber(z))
        end
        return "0.0 0.0 0.0"
    end
    return string.format("%.1f %.1f %.1f", vec.x, vec.y, vec.z)
end

local function CreateLightCube(lightData)
    if not lightData.origin then return end
    
    local cube = ClientsideModel("models/hunter/blocks/cube025x025x025.mdl")
    if not IsValid(cube) then return end
    
    -- Set position and properties
    cube:SetPos(lightData.origin)
    cube:SetAngles(Angle(0, 0, 0))
    cube:SetColor(Color(255, 255, 255, 1)) -- Almost invisible
    cube:SetRenderMode(RENDERMODE_TRANSALPHA)
    cube:SetModelScale(0.1) -- Make it small
    
    -- Set different render bounds based on light type
    if lightData.classname == "light_environment" then
        local bounds = Vector(32768, 32768, 32768) -- Very large bounds for environment lights
        cube:SetRenderBounds(-bounds, bounds)
    else
        local bounds = Vector(256, 256, 256) -- Standard size for other lights
        cube:SetRenderBounds(-bounds, bounds)
    end
    
    return cube
end

local function CleanupDebugCubes()
    for _, cube in pairs(debugLightCubes) do
        if IsValid(cube) then
            cube:Remove()
        end
    end
    debugLightCubes = {}
end

local function SetupDebugCubes()
    -- Clean up existing cubes first
    CleanupDebugCubes()
    
    -- Only create if debug cubes are enabled
    if not cv_debug_cubes:GetBool() then return end
    
    if not NikNaks.CurrentMap then
        print("No map data available!")
        return
    end

    local lightClasses = {
        "light",
        "light_spot",
        "light_environment",
        "light_dynamic",
        "light_directional",
        "light_point",
        "light_glspot"
    }

    -- Create cubes for all lights
    for _, className in ipairs(lightClasses) do
        local found = NikNaks.CurrentMap:FindByClass(className)
        for _, light in ipairs(found) do
            local cube = CreateLightCube(light)
            if cube then
                table.insert(debugLightCubes, cube)
            end
        end
    end
    
    print("Created " .. #debugLightCubes .. " light debug cubes")
end

-- Helper function to identify RTX-related entities
local function IsRTXEntity(ent)
    if not IsValid(ent) then return end
    return SPECIAL_ENTITIES[ent:GetClass()]
end

-- Set entity visibility state
local function SetEntityVisibility(ent, enable)
    if not IsValid(ent) then return end
    
    if enable then
        -- Basic visibility flags that won't interfere with RTX
        ent:AddEFlags(EFL_FORCE_CHECK_TRANSMIT)
        ent:SetRenderMode(RENDERMODE_NORMAL)
        ent:DrawShadow(true)
    else
        ent:RemoveEFlags(EFL_FORCE_CHECK_TRANSMIT)
    end
end

-- Handle static props
local function SetupStaticProps()
    -- Clear existing static props
    for prop in pairs(staticProps) do
        if IsValid(prop) then
            prop:Remove()
        end
    end
    staticProps = {}

    -- Only proceed if enabled and NikNaks is available
    if not cv_enabled:GetBool() or not cv_static_props:GetBool() or not NikNaks or not NikNaks.CurrentMap then return end

    local props = NikNaks.CurrentMap:GetStaticProps()
    for _, propData in pairs(props) do
        local prop = ClientsideModel(propData:GetModel())
        if IsValid(prop) then
            prop:SetPos(propData:GetPos())
            prop:SetAngles(propData:GetAngles())
            prop:SetColor(propData:GetColor())
            prop:SetModelScale(propData:GetScale())
            
            -- Set large render bounds
            local bounds = Vector(32768, 32768, 32768)
            prop:SetRenderBounds(-bounds, bounds)
            
            staticProps[prop] = true
            managedEntities[prop] = true
        end
    end
end

-- Hook for new entities
hook.Add("OnEntityCreated", "RTX_PVS_Optimization", function(ent)
    if not IsValid(ent) then return end
    
    timer.Simple(0, function()
        if not IsValid(ent) or not cv_enabled:GetBool() then return end
        
        if IsRTXEntity(ent) then
            SetEntityVisibility(ent, true)
            managedEntities[ent] = true
        end
    end)
end)

cvars.AddChangeCallback("fr_debug_light_cubes", function(_, _, new)
    if tobool(new) then
        SetupDebugCubes()
    else
        CleanupDebugCubes()
    end
end)

-- Add cleanup to map changes
hook.Add("OnReloaded", "CleanupLightDebugCubes", function()
    timer.Simple(1, function()
        if cv_debug_cubes:GetBool() then
            SetupDebugCubes()
        end
    end)
end)

-- Add to initial setup
hook.Add("InitPostEntity", "InitialLightDebugCubes", function()
    timer.Simple(1, function()
        if cv_debug_cubes:GetBool() then
            SetupDebugCubes()
        end
    end)
end)

-- Entity cleanup
hook.Add("EntityRemoved", "RTX_PVS_Cleanup", function(ent)
    managedEntities[ent] = nil
    staticProps[ent] = nil
end)

-- Map cleanup/reload handler
hook.Add("OnReloaded", "RefreshStaticProps", function()
    timer.Simple(1, SetupStaticProps)
end)

-- Initial setup
hook.Add("InitPostEntity", "InitialRTXSetup", function()
    timer.Simple(1, SetupStaticProps)
end)

-- ConVar change handlers
cvars.AddChangeCallback("fr_enabled", function(_, _, new)
    local enabled = tobool(new)
    for ent in pairs(managedEntities) do
        if IsValid(ent) then
            SetEntityVisibility(ent, enabled)
        end
    end
    
    if enabled and cv_static_props:GetBool() then
        SetupStaticProps()
    end
end)

cvars.AddChangeCallback("fr_static_props", function(_, _, new)
    local enabled = tobool(new)
    if enabled and cv_enabled:GetBool() then
        SetupStaticProps()
    else
        for prop in pairs(staticProps) do
            if IsValid(prop) then
                prop:Remove()
            end
        end
        staticProps = {}
    end
end)

-- Refresh command
concommand.Add("fr_refresh", function()
    if cv_enabled:GetBool() then
        for ent in pairs(managedEntities) do
            if IsValid(ent) then
                SetEntityVisibility(ent, true)
            end
        end
        if cv_static_props:GetBool() then
            SetupStaticProps()
        end
        if cv_debug_cubes:GetBool() then
            SetupDebugCubes()
        end
        print("Refreshed RTX optimization")
    end
end)

-- Settings panel
hook.Add("PopulateToolMenu", "RTXOptimizationMenu", function()
    spawnmenu.AddToolMenuOption("Utilities", "User", "RTX_OPT", "#RTX Optimization", "", "", function(panel)
        panel:ClearControls()
        
        panel:CheckBox("Enable RTX Optimization", "fr_enabled")
        panel:ControlHelp("Optimize entity visibility for RTX")
        
        panel:Help("")
        
        panel:CheckBox("Enable Static Props Optimization", "fr_static_props")
        panel:ControlHelp("Apply optimization to map's static props")
        
        panel:Help("")
        
        panel:CheckBox("Show Light Debug Cubes", "fr_debug_light_cubes")
        panel:ControlHelp("Show debug cubes for light optimization")
        
        panel:Help("")
        
        local refreshBtn = panel:Button("Refresh")
        function refreshBtn.DoClick()
            RunConsoleCommand("fr_refresh")
            surface.PlaySound("buttons/button14.wav")
        end
        
        local debugBtn = panel:Button("Debug Info")
        function debugBtn.DoClick()
            local rtxCount = 0
            local propCount = 0
            local cubeCount = #debugLightCubes
            
            for ent in pairs(managedEntities) do
                if IsValid(ent) then
                    if staticProps[ent] then
                        propCount = propCount + 1
                    else
                        rtxCount = rtxCount + 1
                    end
                end
            end
            
            print("\nRTX Optimization Status:")
            print("Enabled:", cv_enabled:GetBool())
            print("Static Props Enabled:", cv_static_props:GetBool())
            print("Debug Cubes Enabled:", cv_debug_cubes:GetBool())
            print("RTX Entities:", rtxCount)
            print("Static Props:", propCount)
            print("Light Debug Cubes:", cubeCount)
        end
    end)
end)

concommand.Add("show_map_lights", function(ply, cmd, args)
    if not NikNaks.CurrentMap then
        print("No map data available!")
        return
    end

    local lightClasses = {
        "light",
        "light_spot",
        "light_environment",
        "light_dynamic",
        "light_directional",
        "light_point",
        "light_glspot"
    }

    local lights = {}
    local totalLights = 0

    -- Gather all lights
    for _, className in ipairs(lightClasses) do
        local found = NikNaks.CurrentMap:FindByClass(className)
        for _, light in ipairs(found) do
            totalLights = totalLights + 1
            table.insert(lights, light)
        end
    end

    -- Print header
    print("\n=== Map Lights Information ===")
    print("Total Lights Found: " .. totalLights)
    print("---------------------------")

    -- Print each light's information
    for i, light in ipairs(lights) do
        print("\nLight #" .. i)
        print("Type: " .. GetLightType(light))
        
        -- Safely handle origin
        if light.origin then
            print("Position: " .. FormatVector(light.origin))
        else
            print("Position: Not specified")
        end
        
        -- Print brightness/color if available
        if light._light then
            print("Light Value: " .. tostring(light._light))
        end
        
        -- Safely handle rendercolor
        if light.rendercolor then
            print("Color: " .. FormatVector(light.rendercolor))
        end
        
        -- Print spot light specific info
        if light.classname == "light_spot" then
            if light.angles then
                print("Angles: " .. FormatVector(light.angles))
            end
            if light._cone then
                print("Cone: " .. tostring(light._cone))
            end
            if light._inner_cone then
                print("Inner Cone: " .. tostring(light._inner_cone))
            end
        end
    end

    print("\n=== End of Light Information ===")
end)