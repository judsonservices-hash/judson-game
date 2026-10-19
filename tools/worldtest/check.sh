#!/bin/bash
# Deep Tide — headless test rig (no Roblox, no Studio).
#
#   tools/worldtest/check.sh            run both suites
#   tools/worldtest/check.sh world      run only the world build suite
#   tools/worldtest/check.sh persist    run only the persistence suite
#
# It stubs the Roblox globals (tools/worldtest/stub.luau), then runs the *real* config
# modules, WorldService and PlayerService unmodified except for their `require(...)` lines,
# which are pointed at the stubs. Needs the Luau CLI on PATH as `luau`.
set -e
cd "$(dirname "$0")"
REPO=$(cd ../.. && pwd)
LUAU=${LUAU:-$(command -v luau || echo /tmp/bin/luau)}
WHICH=${1:-all}

patch() { # patch <file> -> stdout, with instance requires redirected to the stubs
    sed -e 's/require(ReplicatedStorage\.Packages\.Knit)/__KnitStub/' \
        -e 's/require(ReplicatedStorage\.DeepTide\.Config\.\([A-Za-z]*\))/__config("\1")/' \
        -e 's/require(ReplicatedStorage\.DeepTide\.Modules\.Types)/__config("Types")/' \
        -e 's/require(ReplicatedStorage\.DeepTide\.Modules\.Rng)/__Rng/' \
        -e 's/require(ReplicatedStorage\.DeepTide\.Modules\.Tension)/__Tension/' \
        -e 's/require(ReplicatedStorage\.DeepTide\.Modules\.Remotes)/__Remotes/' \
        -e 's/require(script\.Parent\.Parent\.Modules\.PlayerStore)/PlayerStoreModule/' \
        "$1"
}

configs() { # configs <Name>... -> wrapper chunks for the real config sources
    for name in "$@"; do
        echo "__CFG_SOURCES.$name = function()"
        cat "$REPO/src/shared/Config/$name.luau"
        echo "end"
    done
}

run_world() {
    local out=/tmp/deep-tide-worldtest.luau
    {
        cat stub.luau
        configs ZoneConfig LandmarkConfig SpawnConfig
        echo "local WorldService = (function()"
        patch "$REPO/src/server/Services/WorldService.luau"
        echo "end)()"
        cat world_harness.luau
    } > "$out"
    echo "--- world build suite ---"
    "$LUAU" "$out"
}

run_persist() {
    local out=/tmp/deep-tide-persisttest.luau
    {
        cat stub.luau
        configs EconomyConfig RodConfig GearConfig
        echo "__CFG_SOURCES.Types = function()"
        cat "$REPO/src/shared/Modules/Types.luau"
        echo "end"
        cat persist_setup.luau
        echo "local PlayerStoreModule = (function()"
        patch "$REPO/src/server/Modules/PlayerStore.luau"
        echo "end)()"
        echo "local PlayerStore = PlayerStoreModule"
        echo "local PlayerService = (function()"
        patch "$REPO/src/server/Services/PlayerService.luau"
        echo "end)()"
        cat persist_assert.luau
    } > "$out"
    echo "--- persistence suite ---"
    "$LUAU" "$out"
}

run_config() {
    local out=/tmp/deep-tide-configtest.luau
    {
        cat stub.luau
        configs FishConfig SpawnConfig LandmarkConfig RarityConfig RodConfig GearConfig DiveConfig FightConfig EconomyConfig ZoneConfig
        echo "local ConfigsTable = (function()"
        echo "script = makeInstance('ModuleScript')"
        echo "local __modules = makeInstance('Folder')"
        echo "script.Parent = __modules"
        sed -e 's/require(DeepTide\.Config\.\([A-Za-z]*\))/__config("\1")/' "$REPO/src/shared/Modules/Configs.luau"
        echo "end)()"
        echo "local ConfigCheck = (function()"
        sed -e 's/require(script\.Parent\.Configs)/ConfigsTable/' "$REPO/src/shared/Modules/ConfigCheck.luau"
        echo "end)()"
        cat config_harness.luau
    } > "$out"
    echo "--- config check suite ---"
    "$LUAU" "$out"
}

run_fish() {
    local out=/tmp/deep-tide-fishtest.luau
    {
        cat stub.luau
        configs FishConfig SpawnConfig LandmarkConfig RarityConfig RodConfig GearConfig DiveConfig FightConfig EconomyConfig ZoneConfig
        echo "__CFG_SOURCES.Types = function()"
        cat "$REPO/src/shared/Modules/Types.luau"
        echo "end"
        echo "local WorldService = (function()"
        patch "$REPO/src/server/Services/WorldService.luau"
        echo "end)()"
        echo "__Rng = (function()"
        cat "$REPO/src/shared/Modules/Rng.luau"
        echo "end)()"
        echo "__Tension = (function()"
        patch "$REPO/src/shared/Modules/Tension.luau"
        echo "end)()"
        echo "__Remotes = (function()"
        cat "$REPO/src/shared/Modules/Remotes.luau"
        echo "end)()"
        echo "local PlayerStoreModule = (function()"
        patch "$REPO/src/server/Modules/PlayerStore.luau"
        echo "end)()"
        for service in PlayerService GearService InventoryService DiveService FishService FishingService; do
            echo "local $service = (function()"
            patch "$REPO/src/server/Services/$service.luau"
            echo "end)()"
        done
        cat fish_harness.luau
    } > "$out"
    echo "--- fishing loop suite ---"
    "$LUAU" "$out"
}

# The dock economy suite: §6 (sell, shop, purchases), §5.4/§11 (the depth wall and the zone
# gate), §1 step 8 (prompt wiring) and the whole loop end to end, with a mock DataStore so a
# rejoin can be driven for real.
run_economy() {
    local out=/tmp/deep-tide-economytest.luau
    {
        cat stub.luau
        configs FishConfig SpawnConfig LandmarkConfig RarityConfig RodConfig GearConfig DiveConfig FightConfig EconomyConfig ZoneConfig
        echo "__CFG_SOURCES.Types = function()"
        cat "$REPO/src/shared/Modules/Types.luau"
        echo "end"
        cat economy_store.luau
        echo "__Rng = (function()"
        cat "$REPO/src/shared/Modules/Rng.luau"
        echo "end)()"
        echo "__Tension = (function()"
        patch "$REPO/src/shared/Modules/Tension.luau"
        echo "end)()"
        echo "__Remotes = (function()"
        cat "$REPO/src/shared/Modules/Remotes.luau"
        echo "end)()"
        echo "local WorldService = (function()"
        patch "$REPO/src/server/Services/WorldService.luau"
        echo "end)()"
        echo "local PlayerStoreModule = (function()"
        patch "$REPO/src/server/Modules/PlayerStore.luau"
        echo "end)()"
        for service in PlayerService GearService InventoryService EconomyService ShopService DiveService FishService FishingService; do
            echo "local $service = (function()"
            patch "$REPO/src/server/Services/$service.luau"
            echo "end)()"
        done
        cat economy_harness.luau
    } > "$out"
    echo "--- dock economy suite (sell / shop / depth / zone / prompts / end-to-end) ---"
    "$LUAU" "$out"
}

case "$WHICH" in
    world) run_world ;;
    persist) run_persist ;;
    config) run_config ;;
    fish) run_fish ;;
    economy) run_economy ;;
    all) run_world; run_persist; run_config; run_fish; run_economy ;;
    *) echo "usage: check.sh [world|persist|config|fish|economy|all]" >&2; exit 2 ;;
esac
