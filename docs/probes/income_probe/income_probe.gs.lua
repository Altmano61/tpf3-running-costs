-- TEMPORARY probe (not part of the mod): how OnCalcTicketPrice looks for cargo
-- that was handed over between lines (warehouse / transfer chains). Remove before upload.
function data()
	return {
		handleEventScript = {
			fileName = "income_probe.script@handleEvent",
		},
	}
end
