--!native
--!optimize 2

---- environment ----
local assert, typeof, tonumber = assert, typeof, tonumber
local pcall, pairs, ipairs = pcall, pairs, ipairs
local task_wait, task_spawn = task.wait, task.spawn
local table_insert, table_remove = table.insert, table.remove
local string_lower, string_sub = string.lower, string.sub
local math_floor, math_min, math_max = math.floor, math.min, math.max
local vector_magnitude, vector_create = vector.magnitude, vector.create

local game = game
local workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local MouseService = game:GetService("MouseService")

---- severe globals guards ----
local getmouseposition_fn = getmouseposition
if typeof(getmouseposition_fn) ~= "function" then
	getmouseposition_fn = function()
		return MouseService:GetMouseLocation()
	end
end

local isleftpressed_fn = isleftpressed
assert(typeof(isleftpressed_fn) == "function", "Missing isleftpressed() in this environment")
assert(typeof(DrawingImmediate) == "table", "Missing DrawingImmediate")

---- helpers ----
local function clamp(x: number, a: number, b: number): number
	return math_max(a, math_min(b, x))
end

local function point_in(px: number, py: number, x: number, y: number, w: number, h: number): boolean
	return (px >= x and px <= x + w and py >= y and py <= y + h)
end

local function get_id(obj: Instance): string
	return (obj and obj.Data) or tostring(obj)
end

local function is_container_class(class: string): boolean
	return (class == "Folder") or (class == "Model")
end

local function is_part_class(class: string): boolean
	return class:find("Part") ~= nil
end

local function get_children_safe(inst: Instance): { Instance }
	local ok, res = pcall(function()
		return inst:GetChildren()
	end)
	if ok and res then
		return res
	end
	return {}
end

local function truncate_to_px(text: string, max_px: number, font_size: number): string
	local char_w = math_max(6, math_floor(font_size * 0.55))
	local max_chars = math_max(0, math_floor(max_px / char_w))

	if #text <= max_chars then
		return text
	end
	if max_chars <= 3 then
		return string_sub(text, 1, max_chars)
	end
	return string_sub(text, 1, max_chars - 3) .. "..."
end

local function resolve_position_ref(obj: Instance): Instance?
    if not obj or not obj.Parent then return nil end

    if is_part_class(obj.ClassName) then
        return obj
    end

    if obj.ClassName == "Model" then
        local primary = obj.PrimaryPart
        if primary and primary.Parent then
            return primary
        end

        local prefer = { "HumanoidRootPart", "Head", "Torso", "UpperTorso" }
        for _, n in ipairs(prefer) do
            local p = obj:FindFirstChild(n)
            if p and p.Parent and is_part_class(p.ClassName) then
                return p
            end
        end

        -- last fallback: first part child
        for _, child in ipairs(obj:GetChildren()) do
            if child and child.Parent and is_part_class(child.ClassName) then
                return child
            end
        end
    end

    return nil
end


--------------------------------------------------------------------------------
-- ESP CORE
--------------------------------------------------------------------------------

---- constants ----
local DEFAULT_CONFIG = {
	enabled = true,

	name_esp = true,
	distance_esp = true,
	box_esp = true,
	health_bar = false,
	tracers = false,

	exclude_players = false,
	auto_exclude_localplayer = true,

	name_color = Color3.new(1, 1, 1),
	box_color = Color3.new(1, 0, 0),
	tracer_color = Color3.new(0, 1, 0),
	health_bar_color = Color3.new(0, 1, 0),

	max_distance = 1000,
	font_size = 14,
	font = "Tamzen",
	box_thickness = 2,
	tracer_thickness = 1,

	name_opacity = 1,
	box_opacity = 0.8,
	tracer_opacity = 0.6,

	fade_enabled = true,
	fade_start = 500,
	fade_end = 1000,
}

---- variables ----
local tracked_objects: { [string]: any } = {}
local render_data: { any } = {}

local active_paths_list: { Instance } = {}
local active_paths_set: { [string]: boolean } = {}

local include_filter: { string }? = nil
local exclude_filter: { string } = {}

local camera: any = nil
local camera_position: vector? = nil
local viewport_size: vector? = nil

local render_connection: any = nil
local update_connection: any = nil

local config: { [string]: any } = {}
local local_player: any = nil
local local_character: any = nil
local frame_count = 0

-- per-path rules used by UI toggles
local path_rules: { [string]: { include: { [string]: boolean }?, exclude: { [string]: boolean }? } } = {}

---- functions ----
local function deep_copy(tbl: { [any]: any }): { [any]: any }
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

local function calculate_distance(pos1: vector, pos2: vector): number
	-- use Severe vector lib magnitude (consistent + fast path)
	return vector_magnitude(pos1 - pos2)
end

local function calculate_fade_opacity(distance: number): number
	if not config.fade_enabled then
		return 1
	end
	if distance <= config.fade_start then
		return 1
	elseif distance >= config.fade_end then
		return 0
	end
	local range = config.fade_end - config.fade_start
	if range <= 0 then
		return 1
	end
	return 1 - ((distance - config.fade_start) / range)
end

local function update_local_player()
	local ok = pcall(function()
		local_player = Players.LocalPlayer
		if local_player then
			local_character = local_player.Character
		end
	end)
	if not ok then
		local_player = nil
		local_character = nil
	end
end

local function is_player_character(obj: Instance): boolean
	if (not obj) or obj.ClassName ~= "Model" then
		return false
	end
	local ok, res = pcall(function()
		for _, player in ipairs(Players:GetChildren()) do
			if player.Character == obj then
				return true
			end
		end
		return false
	end)
	return ok and res
end

local function should_exclude_object(obj: Instance): boolean
	if config.auto_exclude_localplayer and local_character and obj == local_character then
		return true
	end
	if config.exclude_players and is_player_character(obj) then
		return true
	end
	return false
end

local function should_track_object(obj: Instance): boolean
	if typeof(obj) ~= "Instance" then
		return false
	end

	if should_exclude_object(obj) then
		return false
	end

	local obj_name = obj.Name

	if include_filter then
		local found = false
		for _, name in ipairs(include_filter) do
			if string_lower(obj_name):find(string_lower(name), 1, true) then
				found = true
				break
			end
		end
		if not found then
			return false
		end
	end

	for _, name in ipairs(exclude_filter) do
		if string_lower(obj_name):find(string_lower(name), 1, true) then
			return false
		end
	end

	return true
end

local function get_all_parts(obj: Instance): { Instance }
	local parts = {}

	pcall(function()
		if is_part_class(obj.ClassName) then
			table_insert(parts, obj)
		elseif obj.ClassName == "Model" then
			for _, child in ipairs(obj:GetDescendants()) do
				if is_part_class(child.ClassName) then
					table_insert(parts, child)
				end
			end
		end
	end)

	return parts
end

local function calculate_bounding_box(parts: { Instance }): (vector?, vector?)
	if #parts == 0 then
		return nil, nil
	end

	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

	for _, part in ipairs(parts) do
		pcall(function()
			local pos = part.Position
			local size = part.Size

			local hx = size.X / 2
			local hy = size.Y / 2
			local hz = size.Z / 2

			min_x = math_min(min_x, pos.X - hx)
			min_y = math_min(min_y, pos.Y - hy)
			min_z = math_min(min_z, pos.Z - hz)

			max_x = math_max(max_x, pos.X + hx)
			max_y = math_max(max_y, pos.Y + hy)
			max_z = math_max(max_z, pos.Z + hz)
		end)
	end

	if min_x == math.huge then
		return nil, nil
	end

	return vector_create(min_x, min_y, min_z), vector_create(max_x, max_y, max_z)
end

local function get_bounding_box_corners(min_bound: vector, max_bound: vector): { vector }
	return {
		vector_create(min_bound.X, min_bound.Y, min_bound.Z),
		vector_create(max_bound.X, min_bound.Y, min_bound.Z),
		vector_create(max_bound.X, min_bound.Y, max_bound.Z),
		vector_create(min_bound.X, min_bound.Y, max_bound.Z),
		vector_create(min_bound.X, max_bound.Y, min_bound.Z),
		vector_create(max_bound.X, max_bound.Y, min_bound.Z),
		vector_create(max_bound.X, max_bound.Y, max_bound.Z),
		vector_create(min_bound.X, max_bound.Y, max_bound.Z),
	}
end

local function get_2d_bounding_box(corners_3d: { vector }, cam: any): (vector?, vector?)
	local min_x, min_y = math.huge, math.huge
	local max_x, max_y = -math.huge, -math.huge
	local any_visible = false

	for _, corner in ipairs(corners_3d) do
		local screen_pos, visible = cam:WorldToScreenPoint(corner)
		if visible then
			any_visible = true
			min_x = math_min(min_x, screen_pos.X)
			min_y = math_min(min_y, screen_pos.Y)
			max_x = math_max(max_x, screen_pos.X)
			max_y = math_max(max_y, screen_pos.Y)
		end
	end

	if (not any_visible) or min_x == math.huge then
		return nil, nil
	end

	return vector_create(min_x, min_y, 0), vector_create(max_x, max_y, 0)
end

local function get_object_position(obj: Instance): vector?
	local ok, result = pcall(function()
		if obj.ClassName == "Model" then
			local primary = obj.PrimaryPart
			if primary then
				return primary.Position
			end

			local prefer = { "HumanoidRootPart", "Head", "Torso", "UpperTorso" }
			for _, part_name in ipairs(prefer) do
				local part = obj:FindFirstChild(part_name)
				if part and is_part_class(part.ClassName) then
					return part.Position
				end
			end

			for _, child in ipairs(obj:GetChildren()) do
				if is_part_class(child.ClassName) then
					return child.Position
				end
			end
			return nil
		end

		if is_part_class(obj.ClassName) then
			return obj.Position
		end

		return nil
	end)

	if ok and result then
		return result
	end
	return nil
end

local function get_object_health(obj: Instance): (number?, number?)
	if obj.ClassName ~= "Model" then
		return nil, nil
	end

	local ok, health, max_health = pcall(function()
		local humanoid = obj:FindFirstChildOfClass("Humanoid")
		if humanoid then
			return humanoid.Health, humanoid.MaxHealth
		end
		return nil, nil
	end)

	if ok then
		return health, max_health
	end
	return nil, nil
end

local function add_tracked(obj: Instance)
	if (not obj) or (obj ~= workspace and not obj.Parent) then
		return
	end

	local obj_id = get_id(obj)
	local entry = tracked_objects[obj_id]
	if entry then
		entry.last_seen = os.clock()
		return
	end

	local pos_ref = resolve_position_ref(obj)
	if not pos_ref then return end
	local pos = pos_ref.Position

	local parts = get_all_parts(obj)
	local min_bound, max_bound = calculate_bounding_box(parts)

	tracked_objects[obj_id] = {
		object = obj,
		name = obj.Name,
		position = pos,
		pos_ref = pos_ref,
		parts = parts,
		min_bound = min_bound,
		max_bound = max_bound,
		last_seen = os.clock(),
	}
end

-- scan rules:
-- - Part path => track itself
-- - Model path => track the model only
-- - Folder/Workspace path => track child Models + loose Parts (skip Parts inside Models)
local function scan_path(path: Instance)
	if (not path) or (path ~= workspace and not path.Parent) then
		return
	end

	local rules = path_rules[get_id(path)]

	if is_part_class(path.ClassName) then
		if should_track_object(path) then
			if rules and rules.exclude and rules.exclude[get_id(path)] then
				return
			end
			add_tracked(path)
		end
		return
	end

	if path.ClassName == "Model" then
		if should_track_object(path) then
			if rules and rules.exclude and rules.exclude[get_id(path)] then
				return
			end
			add_tracked(path)
		end
		return
	end

	local ok, children = pcall(function()
		return path:GetChildren()
	end)
	if not ok or not children then
		return
	end

	for _, obj in ipairs(children) do
		if obj and obj.Parent then
			if is_part_class(obj.ClassName) and obj.Parent and obj.Parent.ClassName == "Model" then
				continue
			end

			if not (obj.ClassName == "Model" or is_part_class(obj.ClassName)) then
				continue
			end

			if rules then
				local oid = get_id(obj)

				local ex = rules.exclude
				if ex and ex[oid] then
					continue
				end

				local inc = rules.include
				if inc and next(inc) ~= nil and not inc[oid] then
					continue
				end
			end

			if should_track_object(obj) then
				add_tracked(obj)
			end
		end
	end
end

local function cleanup_stale_objects()
	local current_time = os.clock()
	local stale_threshold = 2

	for obj_id, data in pairs(tracked_objects) do
		if (not data.object) or (data.object ~= workspace and not data.object.Parent) then
			tracked_objects[obj_id] = nil
		elseif current_time - data.last_seen > stale_threshold then
			tracked_objects[obj_id] = nil
		end
	end
end

local function cleanup_dead_paths()
	for i = #active_paths_list, 1, -1 do
		local p = active_paths_list[i]
		if (not p) or (p ~= workspace and not p.Parent) then
			if p then
				active_paths_set[get_id(p)] = nil
				path_rules[get_id(p)] = nil
			end
			table_remove(active_paths_list, i)
		end
	end
end

local function esp_update_loop()
	if not config.enabled then
		return
	end

	frame_count += 1

	local ok = pcall(function()
		camera = workspace.CurrentCamera
		if camera then
			local cf = camera.CFrame
			camera_position = (cf and cf.Position) or camera.Position
			viewport_size = camera.ViewportSize
		end
	end)

	if (not ok) or (not camera) or (not camera_position) or (not viewport_size) then
		camera = nil
		camera_position = nil
		viewport_size = nil
		return
	end

	update_local_player()

	if frame_count % 30 == 0 then
		cleanup_dead_paths()
		for _, path in ipairs(active_paths_list) do
			if path and (path == workspace or path.Parent) then
				scan_path(path)
			end
		end
		cleanup_stale_objects()
	end

	local new_render_data = {}

	for _, data in pairs(tracked_objects) do
		local obj = data.object
		if obj and (obj == workspace or obj.Parent) and not should_exclude_object(obj) then
			local pos_ref = data.pos_ref
			if (not pos_ref) or (not pos_ref.Parent) then
				pos_ref = resolve_position_ref(obj)
				data.pos_ref = pos_ref
			end
			if not pos_ref then
				continue
			end
			local pos = pos_ref.Position
			if pos then
				data.position = pos				
					local parts = get_all_parts(obj)
					data.parts = parts
					data.min_bound, data.max_bound = calculate_bounding_box(parts)
				local distance = calculate_distance(pos, camera_position)
				if distance <= config.max_distance then
					local screen, visible = camera:WorldToScreenPoint(pos)
					if visible then
						local fade_opacity = calculate_fade_opacity(distance)
						if fade_opacity > 0 then
							local box_min, box_max = nil, nil
							if config.box_esp and data.min_bound and data.max_bound then
								local corners = get_bounding_box_corners(data.min_bound, data.max_bound)
								box_min, box_max = get_2d_bounding_box(corners, camera)
							end

							local health, max_health = nil, nil
							if config.health_bar then
								health, max_health = get_object_health(obj)
							end

							table_insert(new_render_data, {
								name = data.name,
								screen_pos = vector_create(screen.X, screen.Y, 0),
								distance = distance,
								fade_opacity = fade_opacity,
								box_min = box_min,
								box_max = box_max,
								health = health,
								max_health = max_health,
							})
						end
					end
				end
			end
		end
	end

	render_data = new_render_data
end

local function esp_render_loop()
	if not config.enabled or not viewport_size then
		return
	end

	local screen_center = vector_create(viewport_size.X / 2, viewport_size.Y / 2, 0)

	for _, data in ipairs(render_data) do
		local screen_pos = data.screen_pos
		local fade_opacity = data.fade_opacity

		if config.box_esp and data.box_min and data.box_max then
			local box_size = data.box_max - data.box_min
			DrawingImmediate.Rectangle(data.box_min, box_size, config.box_color, config.box_opacity * fade_opacity, config.box_thickness)
		end

		local y_offset = 0

		if config.name_esp then
			local name_text = data.name
			if config.distance_esp then
				-- studs (accurate) but keep label
				name_text = `{name_text} [{math_floor(data.distance)}]`
			end

			DrawingImmediate.OutlinedText(
				screen_pos - vector_create(0, y_offset, 0),
				config.font_size,
				config.name_color,
				config.name_opacity * fade_opacity,
				name_text,
				true,
				config.font
			)

			y_offset += config.font_size + 2
		end

		if config.health_bar and data.health and data.max_health and data.max_health > 0 then
			local bar_w = 100
			local bar_h = 4
			local pct = data.health / data.max_health
			local bar_pos = screen_pos - vector_create(bar_w / 2, y_offset, 0)

			DrawingImmediate.FilledRectangle(bar_pos, vector_create(bar_w, bar_h, 0), Color3.new(0.2, 0.2, 0.2), 0.8 * fade_opacity)
			DrawingImmediate.FilledRectangle(bar_pos, vector_create(bar_w * pct, bar_h, 0), config.health_bar_color, 0.9 * fade_opacity)

			y_offset += bar_h + 4
		end

		if config.tracers then
			DrawingImmediate.Line(screen_center, screen_pos, config.tracer_color, config.tracer_opacity * fade_opacity, 1, config.tracer_thickness)
		end
	end
end

--------------------------------------------------------------------------------
-- EXPLORER UI + SETTINGS
--------------------------------------------------------------------------------

local UI = {
	pos = vector_create(60, 60, 0),
	size = vector_create(700, 560, 0),

	header_h = 30,
	row_h = 18,
	indent = 14,
	pad = 10,

	font = "Tamzen",
	font_size = 14,

	scroll_w = 10,
	btn_w = 90,

	col_bg = Color3.fromRGB(18, 18, 22),
	col_header = Color3.fromRGB(28, 28, 34),
	col_border = Color3.fromRGB(80, 80, 92),

	col_text = Color3.fromRGB(245, 245, 245),
	col_dim = Color3.fromRGB(185, 185, 195),

	col_on = Color3.fromRGB(45, 200, 95),
	col_off = Color3.fromRGB(230, 75, 75),

	col_scroll_track = Color3.fromRGB(30, 30, 38),
	col_scroll_thumb = Color3.fromRGB(135, 135, 150),
}

type Node = {
	inst: Instance,
	id: string,
	name: string,
	class: string,
	depth: number,
	expandable: boolean,
}

local ui_open = true
local ui_minimized = false
local settings_open = false

local dragging = false
local drag_dx, drag_dy = 0, 0

local sb_drag = false
local sb_drag_off = 0

local last_left = false
local scroll = 0
local content_h = 0

local expanded: { [string]: boolean } = {}
expanded[get_id(workspace)] = true

-- internal per-path toggles:
local include_children: { [string]: { [string]: boolean } } = {}
local exclude_children: { [string]: { [string]: boolean } } = {}

local nodes: { Node } = {}
local rebuild_running = false
local rebuild_requested = true
local last_rebuild = 0

-- settings layout (single source of truth for draw + click)
type SettingItem =
	{ kind: "toggle", label: string, key: string }
	| { kind: "step", label: string, key: string, step: number, minv: number?, maxv: number? }

local SETTINGS: { SettingItem } = {
	{ kind = "toggle", label = "Name ESP", key = "name_esp" },
	{ kind = "toggle", label = "Distance ESP", key = "distance_esp" },
	{ kind = "toggle", label = "Box ESP", key = "box_esp" },
	{ kind = "toggle", label = "Health bar", key = "health_bar" },
	{ kind = "toggle", label = "Tracers", key = "tracers" },
	{ kind = "toggle", label = "Fade", key = "fade_enabled" },
	{ kind = "toggle", label = "Exclude players", key = "exclude_players" },

	{ kind = "step", label = "Max distance", key = "max_distance", step = 50, minv = 0, maxv = 100000 },
	{ kind = "step", label = "Font size", key = "font_size", step = 1, minv = 8, maxv = 32 },
	{ kind = "step", label = "Box thickness", key = "box_thickness", step = 1, minv = 1, maxv = 10 },
	{ kind = "step", label = "Tracer thickness", key = "tracer_thickness", step = 1, minv = 1, maxv = 10 },
	{ kind = "step", label = "Fade start", key = "fade_start", step = 50, minv = 0, maxv = 100000 },
	{ kind = "step", label = "Fade end", key = "fade_end", step = 50, minv = 0, maxv = 100000 },
}

local function is_path_active(path: Instance): boolean
	return active_paths_set[get_id(path)] == true
end

local function add_active_path(path: Instance)
	if not path then
		return
	end
	if path ~= workspace and not path.Parent then
		return
	end

	local pid = get_id(path)
	if active_paths_set[pid] then
		return
	end

	active_paths_set[pid] = true
	table_insert(active_paths_list, path)
	path_rules[pid] = path_rules[pid] or {}
end

local function remove_active_path(path: Instance)
	if not path then
		return
	end

	local pid = get_id(path)

	active_paths_set[pid] = nil
	include_children[pid] = nil
	exclude_children[pid] = nil
	path_rules[pid] = nil

	for i = #active_paths_list, 1, -1 do
		local p = active_paths_list[i]
		if (not p) or (p ~= workspace and not p.Parent) or get_id(p) == pid then
			table_remove(active_paths_list, i)
		end
	end
end

local function apply_path_rules(path: Instance)
	local pid = get_id(path)
	local rules = path_rules[pid] or {}

	local inc = include_children[pid]
	local exc = exclude_children[pid]

	if inc and next(inc) == nil then inc = nil end
	if exc and next(exc) == nil then exc = nil end

	rules.include = inc
	rules.exclude = exc
	path_rules[pid] = rules
end

local function find_controlling_path(inst: Instance): (Instance?, boolean)
	-- returns (path, explicit) where explicit means inst itself is the active path
	local cur = inst
	while cur do
		if is_path_active(cur) then
			return cur, (cur == inst)
		end
		cur = cur.Parent
	end
	return nil, false
end

local function effective_state(inst: Instance): (boolean, boolean, Instance?)
	-- returns (on, inherited, path)
	local path, explicit = find_controlling_path(inst)
	if not path then
		return false, false, nil
	end
	if explicit then
		return true, false, path
	end

	local pid = get_id(path)
	local iid = get_id(inst)

	local inc = include_children[pid]
	if inc and next(inc) ~= nil then
		return (inc[iid] and true) or false, true, path
	end

	local exc = exclude_children[pid]
	if exc and exc[iid] then
		return false, true, path
	end

	return true, true, path
end

local function toggle_instance(inst: Instance)
	if not inst then
		return
	end
	if inst ~= workspace and not inst.Parent then
		rebuild_requested = true
		return
	end

	-- parts under models: control the model (no per-part inside model)
	if is_part_class(inst.ClassName) and inst.Parent and inst.Parent.ClassName == "Model" then
		inst = inst.Parent
	end

	local path, explicit = find_controlling_path(inst)

	if explicit then
		-- turning off a path
		remove_active_path(inst)
		rebuild_requested = true
		return
	end

	if not path then
		-- no inherited path => create a path on click
		if inst == workspace or is_container_class(inst.ClassName) or is_part_class(inst.ClassName) then
			add_active_path(inst)
		else
			local parent = inst.Parent
			if parent then
				add_active_path(parent)
				local pid = get_id(parent)
				include_children[pid] = include_children[pid] or {}
				include_children[pid][get_id(inst)] = true
				apply_path_rules(parent)
			end
		end
		rebuild_requested = true
		return
	end

	-- inherited: single button acts as on/off by using include/exclude rules
	local pid = get_id(path)
	local iid = get_id(inst)

	local inc = include_children[pid]
	if inc and next(inc) ~= nil then
		inc[iid] = not inc[iid]
		apply_path_rules(path)
		rebuild_requested = true
		return
	end

	exclude_children[pid] = exclude_children[pid] or {}
	exclude_children[pid][iid] = not exclude_children[pid][iid]
	apply_path_rules(path)

	rebuild_requested = true
end

local function rebuild_nodes_async()
	if rebuild_running then
		rebuild_requested = true
		return
	end

	rebuild_running = true
	rebuild_requested = false

	task_spawn(function()
		local out: { Node } = {}
		local processed = 0

		local function push(inst: Instance, depth: number)
			if not inst then return end
			if inst ~= workspace and not inst.Parent then return end

			local class = inst.ClassName
			local show = (inst == workspace) or is_container_class(class) or is_part_class(class)

			if show then
				table_insert(out, {
					inst = inst,
					id = get_id(inst),
					name = inst.Name,
					class = class,
					depth = depth,
					expandable = (inst == workspace) or is_container_class(class),
				})
			end

			if not expanded[get_id(inst)] then
				return
			end

			for _, child in ipairs(get_children_safe(inst)) do
				local c = child.ClassName
				if is_container_class(c) or is_part_class(c) then
					push(child, depth + 1)
					processed += 1
					if processed % 350 == 0 then
						task_wait()
					end
				end
			end
		end

		push(workspace, 0)

		nodes = out
		content_h = #nodes * UI.row_h
		last_rebuild = os.clock()
		rebuild_running = false
	end)
end

local function settings_click(rel_x: number, rel_y: number, panel_w: number)
	-- shared layout: must match draw exactly
	local y = 10 + 22 -- title spacing
	local row_h = 22

	for _, item in ipairs(SETTINGS) do
		if item.kind == "toggle" then
			local rx, ry, rw, rh = 8, y, panel_w - 16, row_h
			if point_in(rel_x, rel_y, rx, ry, rw, rh) then
				local k = item.key
				if typeof(config[k]) == "boolean" then
					config[k] = not config[k]
					return true
				end
			end
			y += row_h
		else
			local rx, ry, rw, rh = 8, y, panel_w - 16, row_h
			local minus_x, plus_x = panel_w - 60, panel_w - 30

			if point_in(rel_x, rel_y, minus_x, ry + 3, 20, 16) or point_in(rel_x, rel_y, plus_x, ry + 3, 20, 16) then
				local k = item.key
				local v = tonumber(config[k]) or 0
				local step = item.step

				if point_in(rel_x, rel_y, minus_x, ry + 3, 20, 16) then
					v -= step
				else
					v += step
				end

				if item.minv then v = math_max(item.minv, v) end
				if item.maxv then v = math_min(item.maxv, v) end
				config[k] = v
				return true
			end

			if point_in(rel_x, rel_y, rx, ry, rw, rh) then
				return true
			end

			y += row_h
		end
	end

	return false
end

local function ui_update_loop()
	if not ui_open then
		return
	end

	if rebuild_requested or (os.clock() - last_rebuild > 0.9) then
		rebuild_nodes_async()
	end

	local mouse = getmouseposition_fn()
	local mx, my = mouse.X, mouse.Y

	local left = isleftpressed_fn()
	local just_pressed = left and not last_left
	local just_released = (not left) and last_left
	last_left = left

	if just_released then
		dragging = false
		sb_drag = false
	end

	local x0, y0 = UI.pos.X, UI.pos.Y
	local w, h = UI.size.X, UI.size.Y

	-- header buttons: settings + minimize
	local btn_w = 22
	local btn_min_x = x0 + w - UI.pad - btn_w
	local btn_set_x = btn_min_x - 6 - btn_w
	local btn_y = y0 + 4
	local btn_h = UI.header_h - 8

	if just_pressed and point_in(mx, my, btn_min_x, btn_y, btn_w, btn_h) then
		ui_minimized = not ui_minimized
		return
	end
	if just_pressed and point_in(mx, my, btn_set_x, btn_y, btn_w, btn_h) then
		settings_open = not settings_open
		return
	end

	-- drag header (avoid buttons)
	if just_pressed and point_in(mx, my, x0, y0, w, UI.header_h)
		and not point_in(mx, my, btn_set_x, btn_y, btn_w, btn_h)
		and not point_in(mx, my, btn_min_x, btn_y, btn_w, btn_h)
	then
		dragging = true
		drag_dx = mx - x0
		drag_dy = my - y0
	end

	if dragging and left then
		UI.pos = vector_create(mx - drag_dx, my - drag_dy, 0)
		return
	end

	if ui_minimized then
		return
	end

	-- content geometry
	local inner_x0 = x0 + UI.pad
	local inner_y0 = y0 + UI.header_h + UI.pad
	local inner_h = h - UI.header_h - UI.pad * 2
	local inner_w = w - UI.pad * 2 - UI.scroll_w - 6

	-- settings panel geometry (overlay)
	local set_w = 260
	local set_x0 = x0 + w - UI.pad - set_w
	local set_y0 = inner_y0
	local set_h = inner_h

	-- settings click
	if settings_open and just_pressed and point_in(mx, my, set_x0, set_y0, set_w, set_h) then
		local rx = mx - set_x0
		local ry = my - set_y0
		settings_click(rx, ry, set_w)
		return
	end

	-- scroll
	local max_scroll = math_max(0, content_h - inner_h)
	scroll = clamp(scroll, 0, max_scroll)

	local sb_x = x0 + w - UI.pad - UI.scroll_w
	local sb_y = inner_y0
	local sb_h = inner_h

	local thumb_h = (content_h > 0) and clamp((inner_h / content_h) * sb_h, 26, sb_h) or sb_h
	local thumb_y = sb_y + ((max_scroll > 0) and ((scroll / max_scroll) * (sb_h - thumb_h)) or 0)

	-- scroll thumb drag
	if just_pressed and point_in(mx, my, sb_x, thumb_y, UI.scroll_w, thumb_h) then
		sb_drag = true
		sb_drag_off = my - thumb_y
	end

	if sb_drag and left and max_scroll > 0 then
		local new_thumb_y = clamp(my - sb_drag_off, sb_y, sb_y + sb_h - thumb_h)
		local t = (new_thumb_y - sb_y) / (sb_h - thumb_h)
		scroll = t * max_scroll
	end

	-- track paging
	if just_pressed and point_in(mx, my, sb_x, sb_y, UI.scroll_w, sb_h) and not sb_drag then
		if my < thumb_y then
			scroll = clamp(scroll - inner_h, 0, max_scroll)
		elseif my > thumb_y + thumb_h then
			scroll = clamp(scroll + inner_h, 0, max_scroll)
		end
	end

	-- explorer click (ignore clicks under settings overlay)
	local view_w = inner_w
	if settings_open then
		view_w = math_max(120, (set_x0 - inner_x0) - 10)
	end

	if just_pressed and point_in(mx, my, inner_x0, inner_y0, view_w, inner_h) then
		local idx = math_floor((my - inner_y0 + scroll) / UI.row_h) + 1
		local node = nodes[idx]
		if not node or not node.inst then
			return
		end

		if node.inst ~= workspace and not node.inst.Parent then
			rebuild_requested = true
			return
		end

		local row_y = inner_y0 + (idx - 1) * UI.row_h - scroll
		local exp_x = inner_x0 + node.depth * UI.indent
		local exp_w = 12

		-- expand/collapse
		if node.expandable and point_in(mx, my, exp_x, row_y, exp_w, UI.row_h) then
			expanded[node.id] = not expanded[node.id]
			rebuild_requested = true
			return
		end

		-- button
		local btn_x = inner_x0 + view_w - UI.btn_w
		if point_in(mx, my, btn_x, row_y + 1, UI.btn_w, UI.row_h - 2) then
			toggle_instance(node.inst)
			return
		end
	end
end

local function ui_render_loop()
	if not ui_open then
		return
	end

	local x0, y0 = UI.pos.X, UI.pos.Y
	local w, h = UI.size.X, UI.size.Y

-- header (ONLY)
DrawingImmediate.FilledRectangle(UI.pos, vector_create(w, UI.header_h, 0), UI.col_header, 0.95)
DrawingImmediate.Rectangle(UI.pos, vector_create(w, UI.header_h, 0), UI.col_border, 1, 1)

DrawingImmediate.OutlinedText(
    UI.pos + vector_create(UI.pad, 7, 0),
    UI.font_size,
    UI.col_text,
    1,
    ui_minimized and "Workspace ESP Explorer (minimized)" or "Workspace ESP Explorer",
    false,
    UI.font
)

-- header buttons (draw even when minimized)
local btn_w = 22
local btn_min_x = x0 + w - UI.pad - btn_w
local btn_set_x = btn_min_x - 6 - btn_w
local btn_y = y0 + 4
local btn_h = UI.header_h - 8

DrawingImmediate.FilledRectangle(vector_create(btn_set_x, btn_y, 0), vector_create(btn_w, btn_h, 0), UI.col_border, 0.35)
DrawingImmediate.OutlinedText(vector_create(btn_set_x + 6, btn_y + 3, 0), UI.font_size, UI.col_text, 1, "S", false, UI.font)

DrawingImmediate.FilledRectangle(vector_create(btn_min_x, btn_y, 0), vector_create(btn_w, btn_h, 0), UI.col_border, 0.35)
DrawingImmediate.OutlinedText(vector_create(btn_min_x + 7, btn_y + 3, 0), UI.font_size, UI.col_text, 1, ui_minimized and "+" or "-", false, UI.font)

-- EARLY RETURN: nothing else is drawn when minimized
if ui_minimized then
    return
end

-- body (ONLY when not minimized)
DrawingImmediate.FilledRectangle(
    UI.pos + vector_create(0, UI.header_h, 0),
    vector_create(w, h - UI.header_h, 0),
    UI.col_bg,
    0.92
)
DrawingImmediate.Rectangle(UI.pos, vector_create(w, h, 0), UI.col_border, 1, 1)


	-- content geometry
	local inner_x0 = x0 + UI.pad
	local inner_y0 = y0 + UI.header_h + UI.pad
	local inner_h = h - UI.header_h - UI.pad * 2
	local inner_w = w - UI.pad * 2 - UI.scroll_w - 6

	-- settings overlay
	local set_w = 260
	local set_x0 = x0 + w - UI.pad - set_w
	local set_y0 = inner_y0
	local set_h = inner_h

	if settings_open then
		DrawingImmediate.FilledRectangle(vector_create(set_x0, set_y0, 0), vector_create(set_w, set_h, 0), Color3.fromRGB(22, 22, 28), 0.95)
		DrawingImmediate.Rectangle(vector_create(set_x0, set_y0, 0), vector_create(set_w, set_h, 0), UI.col_border, 1, 1)

		DrawingImmediate.OutlinedText(vector_create(set_x0 + 10, set_y0 + 8, 0), UI.font_size, UI.col_text, 1, "Settings", false, UI.font)

		local y = 10 + 22
		local row_h = 22

		for _, item in ipairs(SETTINGS) do
			if item.kind == "toggle" then
				local on = config[item.key] and true or false
				local col = on and UI.col_on or UI.col_off

				DrawingImmediate.OutlinedText(vector_create(set_x0 + 12, set_y0 + y + 2, 0), UI.font_size, UI.col_text, 1, item.label, false, UI.font)
				DrawingImmediate.FilledRectangle(vector_create(set_x0 + set_w - 70, set_y0 + y + 3, 0), vector_create(58, 16, 0), col, 0.9)
				DrawingImmediate.OutlinedText(vector_create(set_x0 + set_w - 56, set_y0 + y + 2, 0), UI.font_size, UI.col_text, 1, on and "ON" or "OFF", false, UI.font)

				y += row_h
			else
				local v = tonumber(config[item.key]) or 0
				DrawingImmediate.OutlinedText(vector_create(set_x0 + 12, set_y0 + y + 2, 0), UI.font_size, UI.col_text, 1, `{item.label}: {v}`, false, UI.font)

				DrawingImmediate.FilledRectangle(vector_create(set_x0 + set_w - 60, set_y0 + y + 3, 0), vector_create(20, 16, 0), UI.col_border, 0.35)
				DrawingImmediate.FilledRectangle(vector_create(set_x0 + set_w - 30, set_y0 + y + 3, 0), vector_create(20, 16, 0), UI.col_border, 0.35)

				DrawingImmediate.OutlinedText(vector_create(set_x0 + set_w - 55, set_y0 + y + 2, 0), UI.font_size, UI.col_text, 1, "-", false, UI.font)
				DrawingImmediate.OutlinedText(vector_create(set_x0 + set_w - 25, set_y0 + y + 2, 0), UI.font_size, UI.col_text, 1, "+", false, UI.font)

				y += row_h
			end
		end
	end

	-- scrollbar
	local sb_x = x0 + w - UI.pad - UI.scroll_w
	DrawingImmediate.FilledRectangle(vector_create(sb_x, inner_y0, 0), vector_create(UI.scroll_w, inner_h, 0), UI.col_scroll_track, 0.9)

	local max_scroll = math_max(0, content_h - inner_h)
	local thumb_h = (content_h > 0) and clamp((inner_h / content_h) * inner_h, 26, inner_h) or inner_h
	local thumb_y = inner_y0 + ((max_scroll > 0) and ((scroll / max_scroll) * (inner_h - thumb_h)) or 0)
	DrawingImmediate.FilledRectangle(vector_create(sb_x, thumb_y, 0), vector_create(UI.scroll_w, thumb_h, 0), UI.col_scroll_thumb, 0.95)

	-- explorer view width (avoid under settings overlay)
	local view_w = inner_w
	if settings_open then
		view_w = math_max(120, (set_x0 - inner_x0) - 10)
	end

	local btn_x = inner_x0 + view_w - UI.btn_w

	-- visible rows only
	local first = math_max(1, math_floor(scroll / UI.row_h) + 1)
	local last = math_min(#nodes, first + math_floor(inner_h / UI.row_h) + 2)

	for i = first, last do
		local n = nodes[i]
		if n and n.inst then
			local row_y = inner_y0 + (i - 1) * UI.row_h - scroll
			local depth_x = inner_x0 + n.depth * UI.indent

			if n.expandable then
				local glyph = expanded[n.id] and "-" or "+"
				DrawingImmediate.OutlinedText(vector_create(depth_x, row_y + 1, 0), UI.font_size, UI.col_dim, 1, glyph, false, UI.font)
			end

			local label_max_px = (btn_x - (depth_x + 12)) - 8
			local label = truncate_to_px(`{n.name} ({n.class})`, label_max_px, UI.font_size)
			DrawingImmediate.OutlinedText(vector_create(depth_x + 12, row_y + 1, 0), UI.font_size, UI.col_text, 1, label, false, UI.font)

			local on, inherited = false, false
			do
				local a, b = effective_state(n.inst)
				on, inherited = a, b
			end

			local col = on and UI.col_on or UI.col_off
			local txt = on and "ESP ON" or "ESP OFF"

			DrawingImmediate.FilledRectangle(vector_create(btn_x, row_y + 1, 0), vector_create(UI.btn_w, UI.row_h - 2, 0), col, 0.9)
			DrawingImmediate.OutlinedText(vector_create(btn_x + 10, row_y + 1, 0), UI.font_size, UI.col_text, 1, txt, false, UI.font)

			if inherited then
				DrawingImmediate.OutlinedText(vector_create(btn_x - 50, row_y + 1, 0), UI.font_size, UI.col_dim, 1, "INH", false, UI.font)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- MODULE API + RUNTIME
--------------------------------------------------------------------------------

local ESP = {}

function ESP.new(settings: { [string]: any }?): typeof(ESP)
	settings = settings or {}
	config = deep_copy(DEFAULT_CONFIG)

	for key, value in pairs(settings) do
		if config[key] ~= nil then
			config[key] = value
		end
	end

	update_local_player()
	return ESP
end

function ESP.add_path(path: Instance)
	assert(typeof(path) == "Instance", "invalid argument #1 (Instance expected)")
	add_active_path(path)
end

function ESP.remove_path(path: Instance)
	assert(typeof(path) == "Instance", "invalid argument #1 (Instance expected)")
	remove_active_path(path)
end

function ESP.set_include(names: { string })
	assert(typeof(names) == "table", "invalid argument #1 (table expected)")
	include_filter = names
	exclude_filter = {}
end

function ESP.set_exclude(names: { string })
	assert(typeof(names) == "table", "invalid argument #1 (table expected)")
	exclude_filter = names
	include_filter = nil
end

function ESP.clear_filters()
	include_filter = nil
	exclude_filter = {}
end

function ESP.start()
	if render_connection or update_connection then
		return
	end

	config.enabled = true
	frame_count = 0
	rebuild_requested = true

	update_connection = RunService.PostLocal:Connect(function()
		esp_update_loop()
		ui_update_loop()
	end)

	render_connection = RunService.Render:Connect(function()
		esp_render_loop()
		ui_render_loop()
	end)
end

function ESP.stop()
	config.enabled = false

	if render_connection then
		render_connection:Disconnect()
		render_connection = nil
	end
	if update_connection then
		update_connection:Disconnect()
		update_connection = nil
	end

	tracked_objects = {}
	render_data = {}

	active_paths_list = {}
	active_paths_set = {}

	include_children = {}
	exclude_children = {}
	path_rules = {}

	nodes = {}
	content_h = 0
	scroll = 0
	rebuild_requested = true
end

function ESP.get_tracked_count(): number
	local count = 0
	for _ in pairs(tracked_objects) do
		count += 1
	end
	return count
end

task_spawn(function()
	pcall(function()
		if typeof(config.enabled) ~= "boolean" then
			ESP.new({})
		end
		ESP.start()
	end)
end)

return ESP
