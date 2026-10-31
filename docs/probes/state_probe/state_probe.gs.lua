-- TEMPORARY probe (not part of the mod): measures what a game script's
-- state:get()/state:set() cost for different table shapes. Remove before upload.
function data()
	return {
		updateScript = {
			fileName = "state_probe.script@update",
		},
	}
end
