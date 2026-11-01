-- TEMPORARY probe (not part of the mod): what the engine exposes for a road /
-- rail vehicle standing in the queue before a station. Remove before upload.
function data()
	return {
		updateScript = {
			fileName = "station_probe.script@update",
		},
	}
end
