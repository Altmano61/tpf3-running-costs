-- Loads the GUI script once per loaded game (UI root), so its wrappers
-- (balance card, airport card) are installed before any window opens; the
-- plugins of the vehicle / line / depot windows load it lazily otherwise.
function data()
	return {
		type = "react-plugin ::ModEntryPointExtension",
		data = {
			filePath = "kampfmoehre_running_costs_1::/gui/kampfmoehre_running_costs/running_costs.script@EntryPlugin",
			order = 0,
		}
	}
end
