-- TEMPORARY probe (not part of the mod): infrastructure upkeep per town area
-- (Voronoi cell). Remove before upload.
function data()
	return {
		updateScript = {
			fileName = "area_probe.script@update",
		},
	}
end
