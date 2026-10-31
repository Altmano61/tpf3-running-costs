-- TEMPORARY diagnostic (2026-10-30): how the finance category "Maintenance
-- Vehicles" (JournalEntry.Maintenance.VEHICLE_MAINTENANCE) is charged. Not part
-- of the release: delete content/maintenance_probe/ before the next upload.
function data()
	return {
		updateScript = {
			fileName = "maintenance_probe.script@update",
		},
	}
end
