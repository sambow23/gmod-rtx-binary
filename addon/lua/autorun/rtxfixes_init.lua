if (CLIENT) then
require((BRANCH == "x86-64" or BRANCH == "chromium" ) and "RTXFixesBinary" or "RTXFixesBinary_32bit")
hook.Add("PostDrawOpaqueRenderables", "rtx_fixes_render", function(depth, sky, sky3d)	--PreDrawViewModels
	RTXDrawLights()
end)
end