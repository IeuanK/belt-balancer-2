require("objects.storage")
require("objects.balancer")
require("objects.part")
require("objects.belt")
require("helper.message-handler")
require("test")

-- on new savegame and on adding mod to existing save
script.on_init(function()
    -- set defaults and initialize values in storage table
    storage.next_balancer_unit_number = 1
    storage.next_lane_unit_number = 1
    storage.next_belt_check = nil
    storage.balancer = {}
    storage.parts = {}
    storage.belts = {}
    storage.lanes = {}
    storage.events = {}
end)

script.on_load(reregister_on_tick)

-- If some mod is changed, check if boblogistics got added and do stuff :)
script.on_configuration_changed(
    function(e)
        ---@type ModConfigurationChangedData
        local boblogistics_changes = e.mod_changes["boblogistics"]

        if boblogistics_changes and boblogistics_changes.old_version == nil and boblogistics_changes.new_version and settings.startup["bobmods-logistics-beltoverhaul"].value == true then
            -- on boblogistics got added!
            for _, force in pairs(game.forces) do
                local technologies = force.technologies
                local recipes = force.recipes

                technologies["belt-balancer-0"].researched = technologies["belt-balancer-1"].researched
                recipes["belt-balancer-basic-belt"].enabled = technologies["belt-balancer-1"].researched
            end
        end
    end
)


-- Custom command to print out some statistics
commands.add_command("belt-balancer-statistics", "", function(e)
    local balancer_amount = table_size(storage.balancer)
    local balancer_part_amount = table_size(storage.parts)
    local balancer_input_belt_amount = 0
    local balancer_output_belt_amount = 0
    local balancer_input_lane_amount = 0
    local balancer_output_lane_amount = 0

    for _, balancer in pairs(storage.balancer) do
        for _, v in pairs(balancer.parts) do
            balancer_input_belt_amount = balancer_input_belt_amount + table_size(storage.parts[v].input_belts)
            balancer_output_belt_amount = balancer_output_belt_amount + table_size(storage.parts[v].output_belts)
        end
        balancer_input_lane_amount = balancer_input_lane_amount + table_size(balancer.input_lanes)
        balancer_output_lane_amount = balancer_output_lane_amount + table_size(balancer.output_lanes)
    end

    local output = "balancers: " .. balancer_amount ..
        "\nbalancer-parts: " .. balancer_part_amount ..
        "\nbalancer_input_belts: " .. balancer_input_belt_amount ..
        "\nbalancer_output_belts: " .. balancer_output_belt_amount ..
        "\nbalancer_input_lanes: " .. balancer_input_lane_amount ..
        "\nbalancer_output_lanes: " .. balancer_output_lane_amount
    game.get_player(e.player_index).print(output)
    print(output)
end)

-- only add this command, if `debug` is available and creative-mod is activated
-- `debug` can be activated, when calling factorio with `--instrument-mod belt-balancer`
if debug and script.active_mods["creative-mod"] then
    commands.add_command("belt-balancer-test", "", function(e)
        test_mod(e.player_index)
    end)

    commands.add_command("belt-balancer-test-logic", "", function(e)
        test_mod_logic(e.player_index)
    end)

    commands.add_command("belt-balancer-print", "", function(e)
        print("Balancer:")
        print(serpent.block(storage.balancer))
        print("Parts:")
        print(serpent.block(storage.parts))
        print("Belts:")
        print(serpent.block(storage.belts))
        print("Lanes:")
        print(serpent.block(storage.lanes))
    end)
end

function built_entity(e)
    ---@type LuaEntity
    local entity

    if e.entity then
        entity = e.entity
    elseif e.created_entity then
        entity = e.created_entity
    else
        entity = e.destination -- this is the name of the entity from on_entity_cloned
    end

    if entity.name == "balancer-part" then
        part_functions.built(entity)
    end

    if entity.type == "transport-belt" then
        belt_functions.built_belt(entity)
    end

    if entity.type == "underground-belt" then
        belt_functions.built_belt(entity)
    end

    if entity.type == "splitter" then
        belt_functions.built_splitter(entity)
    end
end

script.on_event(
    {
        defines.events.on_built_entity,
        defines.events.on_robot_built_entity,
        defines.events.script_raised_built,
        defines.events.script_raised_revive,
        defines.events.on_entity_cloned -- fix compatability with region cloner
    },
    built_entity
)

function remove_entity(e)
    ---@type LuaEntity
    local entity

    if e.entity then
        entity = e.entity
    else
        entity = e.created_entity
    end

    if entity.name == "balancer-part" then
        part_functions.remove(entity, e.buffer)
    end

    if entity.type == "transport-belt" then
        belt_functions.remove_belt(entity)
    end

    if entity.type == "underground-belt" then
        belt_functions.remove_belt(entity)
    end

    if entity.type == "splitter" then
        belt_functions.remove_splitter(entity)
    end
end

script.on_event(
    {
        defines.events.on_entity_died,
        defines.events.on_player_mined_entity,
        defines.events.on_robot_mined_entity,
        defines.events.script_raised_destroy
    },
    remove_entity
)

script.on_event({ defines.events.on_player_rotated_entity },
    function(e)
        if e.entity.type == "transport-belt" then
            belt_functions.remove_belt(e.entity, e.previous_direction)
            belt_functions.built_belt(e.entity)
        end

        if e.entity.type == "underground-belt" then
            belt_functions.remove_belt(e.entity, e.previous_direction)
            belt_functions.built_belt(e.entity)

            -- Neighbour is only the other end
            local neighbour = e.entity.neighbours
            if neighbour and neighbour.valid then
                -- make neighbour also have previous_direction
                local previous_direction = (neighbour.direction + 4) % 8
                belt_functions.remove_belt(neighbour, previous_direction)
                belt_functions.built_belt(neighbour)
            end
        end

        if e.entity.type == "splitter" then
            belt_functions.remove_splitter(e.entity, e.previous_direction)
            belt_functions.built_splitter(e.entity)
        end
    end
)

script.on_event(defines.events.on_tick, function()
    local unit_number = storage.next_belt_check
    local belt = storage.belts[unit_number]

    -- check if belt direction got changed
    if belt and belt.entity.valid and belt.direction ~= belt.entity.direction then
        -- remove belt and readd it
        if belt.type == "splitter" then
            belt_functions.remove_splitter(belt.entity, belt.direction, unit_number, belt.entity.surface, belt.position)
            belt_functions.built_splitter(belt.entity)
        else
            belt_functions.remove_belt(belt.entity, belt.direction, unit_number, belt.entity.surface, belt.position)
            belt_functions.built_belt(belt.entity)
        end
    end

    storage.next_belt_check, _ = next(storage.belts, unit_number)
end)
