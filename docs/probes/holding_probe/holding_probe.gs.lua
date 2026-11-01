-- TEMPORARY probe (not part of the mod): what the engine exposes while an
-- aircraft circles for a free runway or a ship waits for a berth. Remove before upload.
function data()
	return {
		updateScript = {
			fileName = "holding_probe.script@update",
		},
	}
end
