--[[
	Deep Tide — headless config check (assertions only; check.sh assembles the chunk).

	Runs the real Configs + ConfigCheck over the real config tables and prints the boot line
	the server would print. This is the "config check" from the scaffold's README, runnable
	without opening Studio.
]]

local failures = 0
local function check(cond, msg)
	if cond then
		print("  ok    " .. msg)
	else
		print("  FAIL  " .. msg)
		failures += 1
	end
end

print("=== 8. CONFIG CHECK (Configs + ConfigCheck) ===")
local report = ConfigCheck.run()
for _, problem in ipairs(report.problems) do
	print("  problem: " .. problem)
end
check(report.ok, ("ConfigCheck.run() reports no problems (%d found)"):format(#report.problems))
print(
	("   boot line: [Deep Tide] v0.1.0 booted — 9 services · %s · 12 remotes"):format(
		ConfigCheck.summary(report, #ConfigsTable.Fish.Order, ConfigsTable.Fish.TotalLiveAtServerStart)
	)
)

print(("=== CONFIG RESULT: %d failure(s) ==="):format(failures))
if failures > 0 then
	error("config harness failures: " .. failures)
end
