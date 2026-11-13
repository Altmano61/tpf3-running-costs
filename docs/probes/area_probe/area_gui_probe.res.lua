-- TEMPORARY probe (not part of the mod): are the area-scan engine calls usable
-- from the GUI Lua state, and what do they cost there? Remove before upload.
function data()
	return {
		type = "react-plugin ::ModEntryPointExtension",
		data = { filePath = "kampfmoehre_running_costs_1::/area_probe/area_gui_probe.script@Plugin", order = 9 },
	}
end
