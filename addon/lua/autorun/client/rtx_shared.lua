-- RTX Shared functionality between world and prop rendering
if not CLIENT then return end

RTX = RTX or {}
RTX.Shared = {}

-- ConVars that might be shared
RTX.ConVars = {
    ENABLED = CreateClientConVar("rtx_force_render", "1", true, false, "Forces custom rendering of map"),
    PROPS_ENABLED = CreateClientConVar("rtx_force_render_props", "1", true, false, "Forces custom rendering of static props"),
    DEBUG = CreateClientConVar("rtx_force_render_debug", "0", true, false, "Shows debug info for rendering"),
    CHUNK_SIZE = CreateClientConVar("rtx_chunk_size", "65536", true, false, "Size of chunks for mesh combining"),
    CAPTURE_MODE = CreateClientConVar("rtx_capture_mode", "0", true, false, "Toggles r_drawworld for capture mode")
}

-- Shared rendering functions
function RTX.Shared.PushMatrix(matrix)
    cam.PushModelMatrix(matrix)
end

function RTX.Shared.PopMatrix()
    cam.PopModelMatrix()
end

-- Shared mesh handling
function RTX.Shared.CreateMesh(vertices, material)
    local newMesh = Mesh(material)
    
    mesh.Begin(newMesh, MATERIAL_TRIANGLES, #vertices)
    for _, vert in ipairs(vertices) do
        mesh.Position(vert.pos)
        mesh.Normal(vert.normal)
        mesh.TexCoord(0, vert.u or 0, vert.v or 0)
        mesh.AdvanceVertex()
    end
    mesh.End()
    
    return newMesh
end

function RTX.Shared.DetermineOptimalChunkSize(totalFaces)
    local density = totalFaces / (16384 * 16384 * 16384) -- Approximate map volume
    return math.max(4096, math.min(65536, math.floor(1 / density * 32768)))
end

function RTX.Shared.GenerateVerticesForFaces(faces)
    local vertices = {}
    for _, face in ipairs(faces) do
        local faceVerts = face:GenerateVertexTriangleData()
        if faceVerts then
            for _, vert in ipairs(faceVerts) do
                table.insert(vertices, vert)
            end
        end
    end
    return #vertices > 0 and vertices or nil
end

function RTX.Shared.CreateMeshBatch(vertices, material, maxVertsPerMesh)
    local meshes = {}
    local currentVerts = {}
    local vertCount = 0
    
    for i = 1, #vertices, 3 do
        for j = 0, 2 do
            if vertices[i + j] then
                table.insert(currentVerts, vertices[i + j])
                vertCount = vertCount + 1
            end
        end
        
        if vertCount >= maxVertsPerMesh - 3 then
            local newMesh = RTX.Shared.CreateMesh(currentVerts, material)
            if newMesh then
                table.insert(meshes, newMesh)
            end
            currentVerts = {}
            vertCount = 0
        end
    end
    
    if #currentVerts > 0 then
        local newMesh = RTX.Shared.CreateMesh(currentVerts, material)
        if newMesh then
            table.insert(meshes, newMesh)
        end
    end
    
    return #meshes > 0 and meshes or nil
end

-- Shared debug functionality
RTX.Shared.RenderStats = {
    worldDraws = 0,
    propsRendered = 0,
    totalProps = 0
}

function RTX.Shared.PrintDebugInfo()
    print("\n=== RTX Debug Info ===")
    print("World Renders:", RTX.Shared.RenderStats.worldDraws)
    print("Props Rendered:", RTX.Shared.RenderStats.propsRendered)
    print("Total Props:", RTX.Shared.RenderStats.totalProps)
    print("===================\n")
end