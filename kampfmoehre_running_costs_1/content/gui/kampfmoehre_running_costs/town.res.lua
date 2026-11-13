-- Town window (0.6.0): the "Infrastructure upkeep" card below the game's
-- "Statistics" card (hard-coded at order 60; plugins merge by order).
function data()
	return {
		type = "react-plugin ::TownEowExtensionPoint",
		data = {
			filePath = "kampfmoehre_running_costs_1::/gui/kampfmoehre_running_costs/running_costs.script@TownPlugin",
			condition = "kampfmoehre_running_costs_1::/gui/kampfmoehre_running_costs/running_costs.script@TownCondition",
			order = 70,
		}
	}
end
