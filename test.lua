--!native
--!optimize 2

---- environment ----
local assert, typeof = assert, typeof
local pcall, pairs, ipairs = pcall, pairs, ipairs
local table_insert, table_remove = table.insert, table.remove
local string_lower, string_find = string.lower, string.find
local math_floor, math_min, math_max = math.floor, math.min, math.max
local math_huge = math.huge
local os_clock = os.clock
local vector_create, vector_magnitude = vector.create, vector.magnitude

local game = game
local workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local CollectionService = nil
pcall(function()
	CollectionService = game:GetService("CollectionService")
end)

---- constants ----
local DEFAULT_CONFIG = {
	enabled = true,

	name_esp = true,
	distance_esp = true,
	box_esp = true,
	health_bar = false,
	tracers = false,

	-- Filtering
	exclude_players = false,
	auto_exclude_localplayer = true,

	-- Colors
	name_color = Color3.new(1, 1, 1),
	box_color = Color3.new(1, 0, 0),
	tracer_color = Color3.new(0, 1, 0),
	health_bar_color = Color3.new(0, 1, 0),

	-- Settings
	max_distance = 1000,
	max_tracked = 650, -- hard cap so "everything" can't kill FPS
	font_size = 14,
	font = "Tamzen",
	box_thickness = 2,
	tracer_thickness = 1,

	-- Transparency
	name_opacity = 1,
	box_opacity = 0.8,
	tracer_opacity = 0.6,

	-- Distance fade
	fade_enabled = true,
	fade_start = 500,
	fade_end = 1000,

	-- Budgets / caching
	scan_interval = 0.35,          -- seconds between scan steps
	scan_budget_per_tick = 80,     -- how many objects to evaluate per scan tick
	stale_seconds = 2.0,           -- remove if not re-seen
	bounds_refresh_seconds = 1.0,  -- recompute bounds at most this often
	max_parts_per_object = 220,    -- cap descendants collection per object
}

-- whitelist baseparts (faster than ClassName:find("Part"))
local BASEPART: {[string]: boolean} = {
	Part = true,
	MeshPart = true,
	WedgePart = true,
	CornerWedgePart = true,
	TrussPart = true,
	Seat = true,
	VehicleSeat = true,
	UnionOperation = true,
}

---- variables ----
local config: {[string]: any} = {}

local tracked_objects: {[string]: any} = {}
local tracked_ids: {string} = {}
local tracked_index: {[string]: number} = {}
local render_data: {any} = {}

local active_paths: {Instance} = {}
local scan_cursor_path = 1
local scan_cursor_child: {[Instance]: number} = {}
local last_scan_time = 0

local include_filter: {string}? = nil
local exclude_filter: {string} = {}

-- new filters (sets)
local include_child_set: {[string]: boolean}? = nil
local exclude_child_set: {[string]: boolean}? = nil
local include_attr_set: {[string]: boolean}? = nil
local exclude_attr_set: {[string]: boolean}? = nil
local include_tag_set: {[string]: boolean}? = nil
local exclude_tag_set: {[string]: boolean}? = nil

local camera: Instance? = nil
local camera_position: vector? = nil
local viewport_size: vector? = nil

local render_connection: any = nil
local update_connection: any = nil

local local_player: Instance? = nil
local local_character: Instance? = nil

local filters_dirty = false

---- functions ----
local function deep_copy(tbl: {[any]: any}): {[any]: any}
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

local function is_basepart(inst: Instance?): boolean
	if typeof(inst) ~= "Instance" then
		return false
	end
	local cn = inst.ClassName
	if BASEPART[cn] then
		return true
	end
	-- fallback for custom classes ending in "Part"
	if #cn >= 4 and string.sub(cn, #cn - 3, #cn) == "Part" then
		return true
	end
	return false
end

local function calculate_distance(pos1: vector, pos2: vector): number
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
	else
		local range = config.fade_end - config.fade_start
		local fade_distance = distance - config.fade_start
		return 1 - (fade_distance / range)
	end
end

local function update_local_player()
	local ok = pcall(function()
		local_player = Players.LocalPlayer
		local_character = local_player and local_player.Character or nil
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

	local ok, is_plr = pcall(function()
		for _, plr in ipairs(Players:GetChildren()) do
			if plr.Character == obj then
				return true
			end
		end
		return false
	end)

	return ok and is_plr
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

local function build_set(list: {string}?): {[string]: boolean}?
	if not list then
		return nil
	end
	local set: {[string]: boolean} = {}
	for _, v in ipairs(list) do
		if typeof(v) == "string" then
			set[string_lower(v)] = true
		end
	end
	return next(set) and set or nil
end

local function has_any_named_child(obj: Instance, set: {[string]: boolean}?): boolean
	if not set then
		return true
	end
	local kids = obj:GetChildren()
	for _, c in ipairs(kids) do
		if set[string_lower(c.Name)] then
			return true
		end
	end
	return false
end

local function has_any_named_child_excluded(obj: Instance, set: {[string]: boolean}?): boolean
	if not set then
		return false
	end
	local kids = obj:GetChildren()
	for _, c in ipairs(kids) do
		if set[string_lower(c.Name)] then
			return true
		end
	end
	return false
end

local function has_any_attribute(obj: Instance, set: {[string]: boolean}?): boolean
	if not set then
		return true
	end
	for attrName in pairs(set) do
		local v = obj:GetAttribute(attrName)
		if v ~= nil then
			return true
		end
	end
	return false
end

local function has_any_attribute_excluded(obj: Instance, set: {[string]: boolean}?): boolean
	if not set then
		return false
	end
	for attrName in pairs(set) do
		local v = obj:GetAttribute(attrName)
		if v ~= nil then
			return true
		end
	end
	return false
end

local function has_any_tag(obj: Instance, set: {[string]: boolean}?): boolean
	if not set then
		return true
	end
	if not CollectionService then
		return false
	end
	for tagName in pairs(set) do
		local ok, tagged = pcall(function()
			return CollectionService:HasTag(obj, tagName)
		end)
		if ok and tagged then
			return true
		end
	end
	return false
end

local function has_any_tag_excluded(obj: Instance, set: {[string]: boolean}?): boolean
	if not set then
		return false
	end
	if not CollectionService then
		return false
	end
	for tagName in pairs(set) do
		local ok, tagged = pcall(function()
			return CollectionService:HasTag(obj, tagName)
		end)
		if ok and tagged then
			return true
		end
	end
	return false
end

local function should_track_object(obj: Instance): boolean
	assert(typeof(obj) == "Instance", "invalid argument #1 (Instance expected)")

	if should_exclude_object(obj) then
		return false
	end

	-- include rules (ALL enabled ones must pass)
	local ok = pcall(function()
		if include_child_set and (not has_any_named_child(obj, include_child_set)) then
			return false
		end
		if include_attr_set and (not has_any_attribute(obj, include_attr_set)) then
			return false
		end
		if include_tag_set and (not has_any_tag(obj, include_tag_set)) then
			return false
		end

		-- exclude rules (ANY hit rejects)
		if exclude_child_set and has_any_named_child_excluded(obj, exclude_child_set) then
			return false
		end
		if exclude_attr_set and has_any_attribute_excluded(obj, exclude_attr_set) then
			return false
		end
		if exclude_tag_set and has_any_tag_excluded(obj, exclude_tag_set) then
			return false
		end

		-- name include/exclude (existing behavior)
		local obj_name = obj.Name
		if include_filter then
			local found = false
			local lower_obj = string_lower(obj_name)
			for _, name in ipairs(include_filter) do
				if string_find(lower_obj, string_lower(name), 1, true) then
					found = true
					break
				end
			end
			if not found then
				return false
			end
		end

		local lower_obj2 = string_lower(obj_name)
		for _, name in ipairs(exclude_filter) do
			if string_find(lower_obj2, string_lower(name), 1, true) then
				return false
			end
		end

		return true
	end)

	return ok and true or false
end

local function get_object_position(obj: Instance): vector?
	local ok, result = pcall(function()
		local cn = obj.ClassName

		if cn == "Model" then
			local primary = obj.PrimaryPart
			if primary and is_basepart(primary) then
				return primary.Position
			end

			-- common character parts first
			local names = {"HumanoidRootPart", "Head", "Torso", "UpperTorso"}
			for _, part_name in ipairs(names) do
				local p = obj:FindFirstChild(part_name)
				if p and is_basepart(p) then
					return (p :: any).Position
				end
			end

			-- fallback: first BasePart child
			for _, c in ipairs(obj:GetChildren()) do
				if is_basepart(c) then
					return (c :: any).Position
				end
			end

		elseif cn == "Tool" or cn == "Accessory" or cn == "Hat" then
			local h = obj:FindFirstChild("Handle")
			if h and is_basepart(h) then
				return (h :: any).Position
			end
			for _, c in ipairs(obj:GetChildren()) do
				if is_basepart(c) then
					return (c :: any).Position
				end
			end

		elseif is_basepart(obj) then
			return (obj :: any).Position
		end

		return nil
	end)

	if ok then
		return result
	end
	return nil
end

local function collect_baseparts(root: Instance, max_parts: number): {Instance}
	local out: {Instance} = {}
	local stack: {Instance} = {root}
	local stack_i = 1

	while stack_i <= #stack and #out < max_parts do
		local node = stack[stack_i]
		stack_i += 1

		if is_basepart(node) then
			out[#out + 1] = node
		end

		-- Only expand containers that commonly contain geometry.
		local cn = node.ClassName
		if cn == "Model" or cn == "Folder" or cn == "Tool" or cn == "Accessory" or cn == "Hat" then
			local kids = node:GetChildren()
			for _, c in ipairs(kids) do
				stack[#stack + 1] = c
				if #out >= max_parts then
					break
				end
			end
		end
	end

	return out
end

local function calculate_bounding_box(parts: {Instance}): (vector?, vector?)
	if #parts == 0 then
		return nil, nil
	end

	local min_x, min_y, min_z = math_huge, math_huge, math_huge
	local max_x, max_y, max_z = -math_huge, -math_huge, -math_huge

	for _, part in ipairs(parts) do
		pcall(function()
			local pos = (part :: any).Position
			local size = (part :: any).Size

			local hx = size.X * 0.5
			local hy = size.Y * 0.5
			local hz = size.Z * 0.5

			min_x = math_min(min_x, pos.X - hx)
			min_y = math_min(min_y, pos.Y - hy)
			min_z = math_min(min_z, pos.Z - hz)

			max_x = math_max(max_x, pos.X + hx)
			max_y = math_max(max_y, pos.Y + hy)
			max_z = math_max(max_z, pos.Z + hz)
		end)
	end

	if min_x == math_huge then
		return nil, nil
	end

	return vector_create(min_x, min_y, min_z), vector_create(max_x, max_y, max_z)
end

local function get_bounding_box_corners(min_bound: vector, max_bound: vector): {vector}
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

local function get_2d_bounding_box(corners_3d: {vector}, cam: Instance): (vector?, vector?)
	local min_x, min_y = math_huge, math_huge
	local max_x, max_y = -math_huge, -math_huge
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

	if (not any_visible) or (min_x == math_huge) then
		return nil, nil
	end

	return vector_create(min_x, min_y, 0), vector_create(max_x, max_y, 0)
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

local function clear_tracked()
	tracked_objects = {}
	tracked_ids = {}
	tracked_index = {}
	render_data = {}
	scan_cursor_child = {}
end

local function track_add_or_touch(obj: Instance)
	-- stable unique id: always tostring(obj)
	local obj_id = tostring(obj)

	local existing = tracked_objects[obj_id]
	if not existing then
		-- cap tracked count
		if #tracked_ids >= config.max_tracked then
			-- remove oldest (index 1) cheaply using swap-remove logic
			local victim_id = tracked_ids[1]
			if victim_id then
				local vi = tracked_index[victim_id]
				if vi then
					local last_id = tracked_ids[#tracked_ids]
					tracked_ids[vi] = last_id
					tracked_index[last_id] = vi
					tracked_ids[#tracked_ids] = nil
					tracked_index[victim_id] = nil
				end
				tracked_objects[victim_id] = nil
			end
		end

		local pos = get_object_position(obj)
		if not pos then
			return
		end

		local parts = collect_baseparts(obj, config.max_parts_per_object)
		local min_bound, max_bound = calculate_bounding_box(parts)

		tracked_objects[obj_id] = {
			object = obj,
			name = obj.Name,
			position = pos,

			parts = parts,
			min_bound = min_bound,
			max_bound = max_bound,

			last_seen = os_clock(),
			next_bounds_update = os_clock() + config.bounds_refresh_seconds,
		}

		tracked_ids[#tracked_ids + 1] = obj_id
		tracked_index[obj_id] = #tracked_ids
	else
		existing.last_seen = os_clock()
	end
end

local function scan_step()
	if #active_paths == 0 then
		return
	end

	-- round-robin path
	if scan_cursor_path > #active_paths then
		scan_cursor_path = 1
	end

	local path = active_paths[scan_cursor_path]
	if (not path) or (not path.Parent) then
		scan_cursor_path += 1
		return
	end

	local ok, children = pcall(function()
		return path:GetChildren()
	end)
	if not ok or not children then
		scan_cursor_path += 1
		return
	end

	local start_i = scan_cursor_child[path] or 1
	local processed = 0

	for i = start_i, #children do
		local obj = children[i]
		if obj and should_track_object(obj) then
			track_add_or_touch(obj)
		end

		processed += 1
		if processed >= config.scan_budget_per_tick then
			scan_cursor_child[path] = i + 1
			return
		end
	end

	-- finished this path, move to next
	scan_cursor_child[path] = 1
	scan_cursor_path += 1
end

local function cleanup_stale_objects()
	local now = os_clock()
	local stale = config.stale_seconds

	-- iterate ids so we can swap-remove safely
	local i = 1
	while i <= #tracked_ids do
		local id = tracked_ids[i]
		local data = tracked_objects[id]

		local remove_it = false
		if not data then
			remove_it = true
		else
			local obj = data.object
			if (not obj) or (not obj.Parent) then
				remove_it = true
			elseif (now - (data.last_seen or 0)) > stale then
				remove_it = true
			else
				-- revalidate filters occasionally (cheap)
				if filters_dirty then
					if not should_track_object(obj) then
						remove_it = true
					end
				end
			end
		end

		if remove_it then
			local last_id = tracked_ids[#tracked_ids]
			tracked_ids[i] = last_id
			tracked_index[last_id] = i
			tracked_ids[#tracked_ids] = nil
			tracked_index[id] = nil
			tracked_objects[id] = nil
		else
			i += 1
		end
	end

	filters_dirty = false
end

---- PostLocal - scanning + calculations ----
local function update_loop()
	if not config.enabled then
		return
	end

	-- update camera refs
	local ok = pcall(function()
		camera = workspace.CurrentCamera
		if camera then
			camera_position = camera.Position
			viewport_size = camera.ViewportSize
		end
	end)
	if (not ok) or (not camera) or (not camera_position) or (not viewport_size) then
		camera = nil
		camera_position = nil
		viewport_size = nil
		render_data = {}
		return
	end

	update_local_player()

	-- scan step (budgeted, time-based)
	local now = os_clock()
	if (now - last_scan_time) >= config.scan_interval then
		last_scan_time = now
		pcall(scan_step)
		pcall(cleanup_stale_objects)
	end

	-- recompute render_data (bounded mostly by max_tracked)
	local new_render_data: {any} = {}

	for _, id in ipairs(tracked_ids) do
		local data = tracked_objects[id]
		if data then
			local obj = data.object
			if obj and obj.Parent and (not should_exclude_object(obj)) then
				local pos = get_object_position(obj)
				if pos then
					data.position = pos

					-- refresh bounds occasionally (time-based)
					if config.box_esp and data.next_bounds_update and now >= data.next_bounds_update then
						data.next_bounds_update = now + config.bounds_refresh_seconds
						local parts = collect_baseparts(obj, config.max_parts_per_object)
						data.parts = parts
						data.min_bound, data.max_bound = calculate_bounding_box(parts)
					end

					local distance = calculate_distance(pos, camera_position :: any)
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
	end

	render_data = new_render_data
end

---- Render - ONLY DRAWING ----
local function render_loop()
	if (not config.enabled) or (not viewport_size) then
		return
	end

	local screen_center = vector_create(viewport_size.X / 2, viewport_size.Y / 2, 0)

	for _, data in ipairs(render_data) do
		local screen_pos = data.screen_pos
		local fade_opacity = data.fade_opacity

		-- box
		if config.box_esp and data.box_min and data.box_max then
			local box_size = data.box_max - data.box_min
			DrawingImmediate.Rectangle(
				data.box_min,
				box_size,
				config.box_color,
				config.box_opacity * fade_opacity,
				config.box_thickness
			)
		end

		local y_offset = 0

		-- name + distance
		if config.name_esp then
			local name_text = data.name
			if config.distance_esp then
				name_text = `{name_text} [{math_floor(data.distance)}m]`
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

			y_offset = y_offset + config.font_size + 2
		end

		-- health bar
		if config.health_bar and data.health and data.max_health and data.max_health > 0 then
			local bar_width = 100
			local bar_height = 4
			local health_percent = data.health / data.max_health

			local bar_pos = screen_pos - vector_create(bar_width / 2, y_offset, 0)

			DrawingImmediate.FilledRectangle(
				bar_pos,
				vector_create(bar_width, bar_height, 0),
				Color3.new(0.2, 0.2, 0.2),
				0.8 * fade_opacity
			)

			DrawingImmediate.FilledRectangle(
				bar_pos,
				vector_create(bar_width * health_percent, bar_height, 0),
				config.health_bar_color,
				0.9 * fade_opacity
			)

			y_offset = y_offset + bar_height + 4
		end

		-- tracers
		if config.tracers then
			DrawingImmediate.Line(
				screen_center,
				screen_pos,
				config.tracer_color,
				config.tracer_opacity * fade_opacity,
				1,
				config.tracer_thickness
			)
		end
	end
end

---- module ----
local ESP = {}

function ESP.new(settings: {[string]: any}?): typeof(ESP)
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

function ESP.add_path(path: Instance | string)
	local actual_path: Instance? = nil

	if typeof(path) == "string" then
		local parts = string.split(path, ".")
		local current = workspace

		for _, part in ipairs(parts) do
			local ok, result = pcall(function()
				return current:FindFirstChild(part)
			end)
			if ok and result then
				current = result
			else
				warn(`failed to find path: {path}`)
				return false
			end
		end

		actual_path = current
	elseif typeof(path) == "Instance" then
		actual_path = path
	else
		error(`invalid path type: {typeof(path)}`)
	end

	assert(actual_path, `path not found: {path}`)

	for _, existing in ipairs(active_paths) do
		if existing == actual_path then
			return true
		end
	end

	table_insert(active_paths, actual_path)
	scan_cursor_child[actual_path] = 1
	return true
end

function ESP.remove_path(path: Instance | string)
	for i, existing in ipairs(active_paths) do
		if existing == path or existing.Name == path then
			table_remove(active_paths, i)
			return true
		end
	end
	return false
end

function ESP.set_include(names: {string})
	assert(typeof(names) == "table", "invalid argument #1 (table expected)")
	include_filter = names
	exclude_filter = {}
	filters_dirty = true
end

function ESP.set_exclude(names: {string})
	assert(typeof(names) == "table", "invalid argument #1 (table expected)")
	exclude_filter = names
	include_filter = nil
	filters_dirty = true
end

function ESP.set_include_if_has(names: {string})
	assert(typeof(names) == "table", "invalid argument #1 (table expected)")
	include_child_set = build_set(names)
	filters_dirty = true
end

function ESP.set_exclude_if_has(names: {string})
	assert(typeof(names) == "table", "invalid argument #1 (table expected)")
	exclude_child_set = build_set(names)
	filters_dirty = true
end

function ESP.set_include_attribute(attrs: {string})
	assert(typeof(attrs) == "table", "invalid argument #1 (table expected)")
	include_attr_set = build_set(attrs)
	filters_dirty = true
end

function ESP.set_exclude_attribute(attrs: {string})
	assert(typeof(attrs) == "table", "invalid argument #1 (table expected)")
	exclude_attr_set = build_set(attrs)
	filters_dirty = true
end

function ESP.set_include_tag(tags: {string})
	assert(typeof(tags) == "table", "invalid argument #1 (table expected)")
	include_tag_set = build_set(tags)
	filters_dirty = true
end

function ESP.set_exclude_tag(tags: {string})
	assert(typeof(tags) == "table", "invalid argument #1 (table expected)")
	exclude_tag_set = build_set(tags)
	filters_dirty = true
end

function ESP.clear_filters()
	include_filter = nil
	exclude_filter = {}

	include_child_set = nil
	exclude_child_set = nil
	include_attr_set = nil
	exclude_attr_set = nil
	include_tag_set = nil
	exclude_tag_set = nil

	filters_dirty = true
end

function ESP.set_config(key: string, value: any)
	assert(config[key] ~= nil, `invalid config key: {key}`)
	config[key] = value
end

function ESP.get_config(key: string): any
	return config[key]
end

function ESP.start()
	if render_connection or update_connection then
		warn("ESP already running")
		return
	end

	config.enabled = true
	last_scan_time = 0
	clear_tracked()

	update_connection = RunService.PostLocal:Connect(update_loop)
	render_connection = RunService.Render:Connect(render_loop)
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

	clear_tracked()
end

function ESP.get_tracked_count(): number
	return #tracked_ids
end

---- exports ----
return ESP
