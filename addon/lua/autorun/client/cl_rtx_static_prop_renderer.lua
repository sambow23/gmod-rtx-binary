-- RTX Static Prop Renderer
if not CLIENT then return end
require("niknaks")

-- Cache and state management
local isEnabled = false
local propCache = {
    meshes = {}, -- Key: model path, Value: array of meshes
    materials = {} -- Key: material path, Value: IMaterial
}

-- Initialization function to build mesh cache
local function BuildPropCache()
    if not NikNaks or not NikNaks.CurrentMap then return end
    
    print("[RTX Props] Building static prop cache...")
    local startTime = SysTime()
    
    -- Clear existing cache
    for _, meshGroup in pairs(propCache.meshes) do
        for _, meshData in ipairs(meshGroup) do
            if meshData.mesh and meshData.mesh.Destroy then
                meshData.mesh:Destroy()
            end
        end
    end
    propCache.meshes = {}
    propCache.materials = {}
    
    -- Get all static props from the map
    local staticProps = NikNaks.CurrentMap:GetStaticProps()
    RTX.Shared.RenderStats.totalProps = #staticProps
    
    -- Build cache for each unique model
    for _, prop in pairs(staticProps) do
        local modelPath = prop:GetModel()
        if not propCache.meshes[modelPath] then
            local meshes = util.GetModelMeshes(modelPath)
            if meshes then
                propCache.meshes[modelPath] = {}
                for _, meshData in ipairs(meshes) do
                    if not meshData.verticies or #meshData.verticies == 0 then continue end
                    
                    -- Cache material
                    local materialPath = meshData.material
                    if not propCache.materials[materialPath] then
                        propCache.materials[materialPath] = Material(materialPath)
                    end
                    
                    -- Create and store mesh
                    local propMesh = RTX.Shared.CreateMesh(meshData.verticies, propCache.materials[materialPath])
                    
                    table.insert(propCache.meshes[modelPath], {
                        mesh = propMesh,
                        material = materialPath
                    })
                end
            end
        end
    end
    
    print(string.format("[RTX Props] Built prop cache in %.2f seconds", SysTime() - startTime))
end

-- Rendering function
local function RenderProp(prop)
    local modelPath = prop:GetModel()
    local meshGroup = propCache.meshes[modelPath]
    if not meshGroup then return end
    
    -- Setup transform matrix
    local matrix = Matrix()
    matrix:SetTranslation(prop:GetPos())
    matrix:SetAngles(prop:GetAngles())
    local scale = prop:GetScale()
    if scale ~= 1 then
        matrix:Scale(Vector(scale, scale, scale))
    end
    
    -- Apply transform
    RTX.Shared.PushMatrix(matrix)
    
    -- Render each mesh with its material
    for _, meshData in ipairs(meshGroup) do
        local material = propCache.materials[meshData.material]
        if material and meshData.mesh then
            render.SetMaterial(material)
            meshData.mesh:Draw()
        end
    end
    
    RTX.Shared.PopMatrix()
    RTX.Shared.RenderStats.propsRendered = RTX.Shared.RenderStats.propsRendered + 1
end

-- Main render hook
local function RenderStaticProps()
    if not isEnabled then return end
    RTX.Shared.RenderStats.propsRendered = 0
    
    if RTX.ConVars.DEBUG:GetBool() then
        render.SetColorMaterial()
    end
    
    for _, prop in pairs(NikNaks.CurrentMap:GetStaticProps()) do
        RenderProp(prop)
    end
end

-- Debug command
concommand.Add("rtx_props_debug", function()
    local props = NikNaks.CurrentMap:GetStaticProps()
    print("\n=== RTX Props Debug ===")
    print("Enabled:", isEnabled)
    print("Total Props:", RTX.Shared.RenderStats.totalProps)
    print("Props Rendered Last Frame:", RTX.Shared.RenderStats.propsRendered)
    print("Unique Models:", table.Count(propCache.meshes))
    print("Cached Materials:", table.Count(propCache.materials))
    print("\nProp List:")
    
    local modelCounts = {}
    for _, prop in pairs(props) do
        local model = prop:GetModel()
        modelCounts[model] = (modelCounts[model] or 0) + 1
    end
    
    for model, count in pairs(modelCounts) do
        local cached = propCache.meshes[model] and "Cached" or "Not Cached"
        print(string.format("%s: %d instances (%s)", model, count, cached))
    end
    print("=====================\n")
end)

-- Enable/Disable functions
local function EnableCustomRendering()
    if isEnabled then return end
    isEnabled = true
    
    hook.Add("PreDrawOpaqueRenderables", "RTXCustomProps", RenderStaticProps)
end

local function DisableCustomRendering()
    if not isEnabled then return end
    isEnabled = false
    
    hook.Remove("PreDrawOpaqueRenderables", "RTXCustomProps")
end

-- Initialization
hook.Add("InitPostEntity", "RTXPropsInit", function()
    local success, err = pcall(BuildPropCache)
    if not success then
        ErrorNoHalt("[RTX Props] Failed to build prop cache: " .. tostring(err) .. "\n")
        return
    end
    
    if RTX.ConVars.PROPS_ENABLED:GetBool() then
        EnableCustomRendering()
    end
end)

-- Cleanup
hook.Add("ShutDown", "RTXCustomProps", function()
    DisableCustomRendering()
    for _, meshGroup in pairs(propCache.meshes) do
        for _, meshData in ipairs(meshGroup) do
            if meshData.mesh and meshData.mesh.Destroy then
                meshData.mesh:Destroy()
            end
        end
    end
    propCache.meshes = {}
    propCache.materials = {}
end)

-- ConVar Changes
cvars.AddChangeCallback("rtx_force_render_props", function(_, _, new)
    if tobool(new) then
        EnableCustomRendering()
    else
        DisableCustomRendering()
    end
end)