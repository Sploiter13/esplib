--!native
--!optimize 2

---- environment ----
local assert, typeof = assert, typeof
local pcall, pairs, ipairs = pcall, pairs, ipairs
local table_insert, table_remove, table_clear = table.insert, table.remove, table.clear
local string_lower, string_split, string_format = string.lower, string.split, string.format
local math_floor, math_sqrt, math_min, math_max = math.floor, math.sqrt, math.min, math.max
local vector_create = vector.create
local os_clock = os.clock

local game = game
local workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

---- constants ----
local DEFAULT_CONFIG = {
    enabled = false,
    Dynamic = false,
    scan_interval = 0.15,

    name_esp = true,
    distance_esp = true,
    box_esp = true,

    exclude_players = false,
    auto_exclude_localplayer = true,

    name_color = Color3.new(1, 1, 1),
    box_color = Color3.new(1, 0, 0),

    max_distance = 1000,
    max_render_objects = 200,
    font_size = 14,
    font = "Tamzen",
    box_thickness = 2,

    name_opacity = 1,
    box_opacity = 0.8,

    fade_enabled = true,
    fade_start = 500,
    fade_end = 1000,
}

local PART_NAMES = {"HumanoidRootPart", "Head", "UpperTorso", "Torso"}

---- variables ----
local config = {}
local fade_range_inv = 1

local active_paths = {}
local include_filter = nil
local exclude_filter = {}

local local_player = nil
local local_character = nil
local local_root = nil

local tracked = {} -- [key] = entry

local last_scan_time = 0
local last_dynamic_update_time = 0
local scan_connection = nil
local dynamic_connection = nil
local render_connection = nil

---- functions ----
local function deep_copy(tbl)
    local copy = {}
    for k, v in pairs(tbl) do
        if typeof(v) == "table" then
            copy[k] = deep_copy(v)
        else
            copy[k] = v
        end
    end
    return copy
end

local function update_local_player()
    pcall(function()
        local_player = Players.LocalPlayer
        local_character = local_player and local_player.Character
        local_root = local_character and local_character:FindFirstChild("HumanoidRootPart")
    end)
end

local function get_local_position()
    if local_root and local_root.Parent then
        return local_root.Position
    end
    update_local_player()
    return local_root and local_root.Parent and local_root.Position or nil
end

local function calculate_fade(distance)
    if not config.fade_enabled or distance <= config.fade_start then
        return 1
    end
    if distance >= config.fade_end then
        return 0
    end
    return 1 - ((distance - config.fade_start) * fade_range_inv)
end

local function get_object_key(obj)
    local ok, data = pcall(function()
        return (obj :: any).Data
    end)
    if ok and type(data) == "number" then
        return tostring(data)
    end
    return tostring(obj)
end

local function is_player_character(obj)
    if not obj or obj.ClassName ~= "Model" then
        return false
    end
    local ok, result = pcall(function()
        for _, player in ipairs(Players:GetPlayers()) do
            if player.Character == obj then
                return true
            end
        end
        return false
    end)
    return ok and result
end

local function should_exclude_object(obj)
    if config.auto_exclude_localplayer and obj == local_character then
        return true
    end
    if config.exclude_players and is_player_character(obj) then
        return true
    end
    return false
end

local function should_track_object(obj)
    if should_exclude_object(obj) then
        return false
    end

    local ok, obj_name = pcall(function()
        return string_lower(obj.Name)
    end)
    if not ok then
        return false
    end

    if include_filter then
        local found = false
        for i = 1, #include_filter do
            if obj_name:find(string_lower(include_filter[i]), 1, true) then
                found = true
                break
            end
        end
        if not found then
            return false
        end
    end

    for i = 1, #exclude_filter do
        if obj_name:find(string_lower(exclude_filter[i]), 1, true) then
            return false
        end
    end

    return true
end

local function get_object_position(obj)
    if not obj or not obj.Parent then
        return nil
    end

    if obj.ClassName == "Tool" then
        local handle = obj:FindFirstChild("Handle")
        if handle and handle.Parent and (handle.ClassName:find("Part") or handle.ClassName:find("Union")) then
            return handle.Position
        end
    end

    if obj.ClassName == "Model" then
        local primary = obj.PrimaryPart
        if primary and primary.Parent then
            return primary.Position
        end
        local hrp = obj:FindFirstChild("HumanoidRootPart")
        if hrp and hrp.Parent and hrp.ClassName:find("Part") then
            return hrp.Position
        end
        for i = 1, #PART_NAMES do
            local part = obj:FindFirstChild(PART_NAMES[i])
            if part and part.Parent and part.ClassName:find("Part") then
                return part.Position
            end
        end
        local ok, bb_cframe = pcall(function()
            return obj:GetBoundingBox()
        end)
        if ok and bb_cframe then
            return bb_cframe.Position
        end
    end

    if obj.ClassName:find("Part") then
        return obj.Position
    end

    return nil
end

local function build_box_corners(cframe, size)
    local hx = size.X * 0.5
    local hy = size.Y * 0.5
    local hz = size.Z * 0.5

    local right = cframe.RightVector
    local up = cframe.UpVector
    local look = cframe.LookVector
    local pos = cframe.Position

    return {
        pos + right * -hx + up * -hy + look * -hz,
        pos + right *  hx + up * -hy + look * -hz,
        pos + right *  hx + up * -hy + look *  hz,
        pos + right * -hx + up * -hy + look *  hz,
        pos + right * -hx + up *  hy + look * -hz,
        pos + right *  hx + up *  hy + look * -hz,
        pos + right *  hx + up *  hy + look *  hz,
        pos + right * -hx + up *  hy + look *  hz,
    }
end

local function get_box_for_object(obj)
    if not obj or not obj.Parent then
        return nil
    end

    if obj.ClassName == "Model" then
        local ok, cf, sz = pcall(function()
            return obj:GetBoundingBox()
        end)
        if ok and cf and sz then
            return build_box_corners(cf, sz)
        end
        local primary = obj.PrimaryPart
        if primary then
            return build_box_corners(primary.CFrame, primary.Size)
        end
    end

    if obj.ClassName:find("Part") then
        return build_box_corners(obj.CFrame, obj.Size)
    end

    if obj.ClassName == "Tool" then
        local handle = obj:FindFirstChild("Handle")
        if handle and handle.Parent and handle.ClassName:find("Part") then
            return build_box_corners(handle.CFrame, handle.Size)
        end
    end

    return nil
end

local function project_box(corners, cam)
    local min_x, min_y = math_huge, math_huge
    local max_x, max_y = -math_huge, -math_huge
    local any_visible = false

    for i = 1, 8 do
        local sp, vis = cam:WorldToScreenPoint(corners[i])
        if vis then
            any_visible = true
            local sx, sy = sp.X, sp.Y
            min_x = math_min(min_x, sx)
            min_y = math_min(min_y, sy)
            max_x = math_max(max_x, sx)
            max_y = math_max(max_y, sy)
        end
    end

    if not any_visible then
        return nil, nil
    end

    return vector_create(min_x, min_y, 0), vector_create(max_x, max_y, 0)
end

local function destroy_dynamic_entry(entry)
    if not entry then return end
    if entry.cluster then
        pcall(function() entry.cluster:Destroy() end)
    end
    if entry.point_box then
        pcall(function() entry.point_box:Destroy() end)
    end
    if entry.point_text then
        pcall(function() entry.point_text:Destroy() end)
    end
    if entry.drawings then
        for i = 1, #entry.drawings do
            pcall(function()
                entry.drawings[i]:Remove()
            end)
        end
    end
end

local function create_dynamic_entry(obj, name)
    local drawings = {}
    local attach = {}

    local point_box = nil
    local point_text = nil

    if obj.ClassName == "Model" then
        if PointModel then
            point_box = PointModel.new(obj)
        end
        local hrp = obj:FindFirstChild("HumanoidRootPart")
        if hrp and hrp.Parent and hrp.ClassName:find("Part") then
            point_text = PointInstance.new(hrp)
        elseif PointModel then
            point_text = point_box
        end
    elseif obj.ClassName == "Tool" then
        local handle = obj:FindFirstChild("Handle")
        if handle and handle.Parent and handle.ClassName:find("Part") then
            point_box = PointInstance.new(handle)
            point_text = point_box
        end
    elseif obj.ClassName:find("Part") then
        point_box = PointInstance.new(obj)
        point_text = point_box
    end

    if config.box_esp and point_box then
        local box = Drawing.new("Square")
        box.Visible = true
        box.Filled = false
        box.Color = config.box_color
        box.Thickness = config.box_thickness
        box.Opacity = config.box_opacity
        drawings[#drawings + 1] = box
        attach[box] = {
            Link = point_box,
            Size = UDim2.fromScale(1, 1),
            AnchorPoint = Vector2.new(0.5, 0.5),
        }
    end

    if config.name_esp and point_text then
        local text = Drawing.new("Text")
        text.Visible = true
        text.Color = config.name_color
        text.Size = config.font_size
        text.Center = true
        text.Outline = true
        text.Opacity = config.name_opacity
        local font_value = config.font
        if typeof(font_value) ~= "number" then
            font_value = 2
        end
        text.Font = font_value
        drawings[#drawings + 1] = text
        attach[text] = {
            Link = point_text,
            Size = UDim2.fromOffset(0, 0),
            AnchorPoint = Vector2.new(0.5, 1),
        }
    end

    if #drawings == 0 then
        if point_box then pcall(function() point_box:Destroy() end) end
        if point_text and point_text ~= point_box then pcall(function() point_text:Destroy() end) end
        return nil
    end

    local cluster = Drawing.attach(attach)

    return {
        object = obj,
        name = name,
        point_box = point_box,
        point_text = point_text,
        drawings = drawings,
        cluster = cluster,
    }
end

local function update_dynamic_entry(entry, distance, fade, name_text)
    for i = 1, #entry.drawings do
        local d = entry.drawings[i]
        if d.ClassName == "Square" then
            d.Visible = config.box_esp and fade > 0
            d.Color = config.box_color
            d.Thickness = config.box_thickness
            d.Opacity = config.box_opacity * fade
        elseif d.ClassName == "Text" then
            d.Visible = config.name_esp and name_text ~= nil and fade > 0
            if name_text then
                d.Text = name_text
            end
            d.Color = config.name_color
            d.Size = config.font_size
            d.Opacity = config.name_opacity * fade
        end
    end
end

local function scan_paths()
    local seen = {}
    local now = os_clock()

    for i = 1, #active_paths do
        local path = active_paths[i]
        if not path or not path.Parent then
            continue
        end

        local children = path:GetChildren()
        for j = 1, #children do
            local obj = children[j]
            if should_track_object(obj) then
                local pos = get_object_position(obj)
                if pos then
                    local key = get_object_key(obj)
                    seen[key] = true
                    local entry = tracked[key]
                    if entry then
                        entry.object = obj
                        entry.name = obj.Name
                    else
                        tracked[key] = { object = obj, name = obj.Name, dynamic = nil }
                    end
                end
            end
        end
    end

    for key, entry in pairs(tracked) do
        if not seen[key] then
            if entry.dynamic then
                destroy_dynamic_entry(entry.dynamic)
            end
            tracked[key] = nil
        end
    end

    if config.Dynamic then
        for key, entry in pairs(tracked) do
            if not entry.dynamic then
                entry.dynamic = create_dynamic_entry(entry.object, entry.name)
            end
        end
    end
end

local function update_dynamic()
    if not config.Dynamic then return end

    local now = os_clock()
    local interval = config.dynamic_update_interval or DEFAULT_CONFIG.dynamic_update_interval
    if (now - last_dynamic_update_time) < interval then
        return
    end
    last_dynamic_update_time = now

    local local_pos = get_local_position()
    if not local_pos then return end

    for _, entry in pairs(tracked) do
        local obj = entry.object
        if not obj or not obj.Parent then
            if entry.dynamic then
                destroy_dynamic_entry(entry.dynamic)
                entry.dynamic = nil
            end
        else
            if entry.dynamic then
                local pos = get_object_position(obj)
                if pos then
                    local dx = pos.X - local_pos.X
                    local dy = pos.Y - local_pos.Y
                    local dz = pos.Z - local_pos.Z
                    local distance = math_sqrt(dx * dx + dy * dy + dz * dz)
                    if distance <= config.max_distance then
                        local fade = calculate_fade(distance)
                        local name_text = nil
                        if config.name_esp then
                            local dist_f = math_floor(distance)
                            if config.distance_esp then
                                name_text = entry.name .. " [" .. dist_f .. "m]"
                            else
                                name_text = entry.name
                            end
                        end
                        update_dynamic_entry(entry.dynamic, distance, fade, name_text)
                    else
                        update_dynamic_entry(entry.dynamic, distance, 0, nil)
                    end
                end
            end
        end
    end
end

local function render_immediate()
    if not config.enabled or config.Dynamic then return end

    local cam = workspace.CurrentCamera
    if not cam then return end

    local local_pos = get_local_position()
    if not local_pos then return end

    local render_count = 0

    for _, entry in pairs(tracked) do
        if render_count >= config.max_render_objects then
            break
        end

        local obj = entry.object
        if not obj or not obj.Parent then
            continue
        end

        local pos = get_object_position(obj)
        if not pos then
            continue
        end

        local dx = pos.X - local_pos.X
        local dy = pos.Y - local_pos.Y
        local dz = pos.Z - local_pos.Z
        local distance = math_sqrt(dx * dx + dy * dy + dz * dz)
        if distance > config.max_distance then
            continue
        end

        local screen, visible = cam:WorldToScreenPoint(pos)
        if not visible then
            continue
        end

        local fade = calculate_fade(distance)
        if fade <= 0 then
            continue
        end

        render_count = render_count + 1

        if config.box_esp then
            local corners = get_box_for_object(obj)
            if corners then
                local box_min, box_max = project_box(corners, cam)
                if box_min and box_max then
                    local size = box_max - box_min
                    DrawingImmediate.Rectangle(
                        box_min,
                        size,
                        config.box_color,
                        config.box_opacity * fade,
                        config.box_thickness
                    )
                end
            end
        end

        if config.name_esp then
            local dist_f = math_floor(distance)
            local text = entry.name
            if config.distance_esp then
                text = text .. " [" .. dist_f .. "m]"
            end
            DrawingImmediate.OutlinedText(
                vector_create(screen.X, screen.Y, 0),
                config.font_size,
                config.name_color,
                config.name_opacity * fade,
                text,
                true,
                config.font
            )
        end
    end
end

---- module ----
local ESP = {}

function ESP.new(settings)
    config = deep_copy(DEFAULT_CONFIG)
    if settings then
        for key, value in pairs(settings) do
            if config[key] ~= nil then
                config[key] = value
            end
        end
    end

    local fade_range = config.fade_end - config.fade_start
    fade_range_inv = fade_range > 0 and (1 / fade_range) or 1

    update_local_player()

    return ESP
end

function ESP.add_path(path)
    local actual = nil
    if typeof(path) == "string" then
        local parts = string_split(path, ".")
        local current = workspace
        for i = 1, #parts do
            local ok, result = pcall(function()
                return current:FindFirstChild(parts[i])
            end)
            if ok and result then
                current = result
            else
                return false
            end
        end
        actual = current
    elseif typeof(path) == "Instance" then
        actual = path
    else
        return false
    end

    for i = 1, #active_paths do
        if active_paths[i] == actual then
            return true
        end
    end

    table_insert(active_paths, actual)
    return true
end

function ESP.remove_path(path)
    for i = 1, #active_paths do
        local existing = active_paths[i]
        local match = false
        pcall(function()
            match = (existing == path) or (existing.Name == path)
        end)
        if match then
            table_remove(active_paths, i)
            return true
        end
    end
    return false
end

function ESP.set_include(names)
    assert(typeof(names) == "table", "invalid argument #1 (table expected)")
    include_filter = names
    table_clear(exclude_filter)
end

function ESP.set_exclude(names)
    assert(typeof(names) == "table", "invalid argument #1 (table expected)")
    table_clear(exclude_filter)
    for i = 1, #names do
        exclude_filter[i] = names[i]
    end
    include_filter = nil
end

function ESP.clear_filters()
    include_filter = nil
    table_clear(exclude_filter)
end

function ESP.set_config(key, value)
    if config[key] == nil then
        return
    end

    config[key] = value

    if key == "fade_start" or key == "fade_end" then
        local fade_range = config.fade_end - config.fade_start
        fade_range_inv = fade_range > 0 and (1 / fade_range) or 1
    end

    if key == "Dynamic" then
        if value then
            for _, entry in pairs(tracked) do
                if not entry.dynamic then
                    entry.dynamic = create_dynamic_entry(entry.object, entry.name)
                end
            end
        else
            for _, entry in pairs(tracked) do
                if entry.dynamic then
                    destroy_dynamic_entry(entry.dynamic)
                    entry.dynamic = nil
                end
            end
        end
    end
end

function ESP.get_config(key)
    return config[key]
end

function ESP.start()
    if config.enabled then return end

    if not config.Dynamic then
        config = deep_copy(DEFAULT_CONFIG)
        local fade_range = config.fade_end - config.fade_start
        fade_range_inv = fade_range > 0 and (1 / fade_range) or 1
        update_local_player()
    end

    config.enabled = true

    scan_connection = RunService.PostModel:Connect(function()
        local now = os_clock()
        if (now - last_scan_time) >= config.scan_interval then
            last_scan_time = now
            scan_paths()
        end
    end)

    dynamic_connection = RunService.PostLocal:Connect(function()
        update_dynamic()
    end)

    render_connection = RunService.Render:Connect(function()
        render_immediate()
    end)
end

function ESP.stop()
    config.enabled = false

    if scan_connection then
        scan_connection:Disconnect()
        scan_connection = nil
    end
    if dynamic_connection then
        dynamic_connection:Disconnect()
        dynamic_connection = nil
    end
    if render_connection then
        render_connection:Disconnect()
        render_connection = nil
    end

    for _, entry in pairs(tracked) do
        if entry.dynamic then
            destroy_dynamic_entry(entry.dynamic)
        end
    end

    table_clear(tracked)
end

function ESP.get_tracked_count()
    local count = 0
    for _ in pairs(tracked) do
        count = count + 1
    end
    return count
end

return ESP
