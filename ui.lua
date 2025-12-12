--!native
--!optimize 2

---- environment ----
local assert, typeof, tonumber = assert, typeof, tonumber
local pcall, pairs, ipairs = pcall, pairs, ipairs
local task_wait, task_spawn = task.wait, task.spawn
local table_insert, table_remove = table.insert, table.remove
local string_lower, string_sub = string.lower, string.sub
local math_floor, math_sqrt, math_min, math_max = math.floor, math.sqrt, math.min, math.max
local math_huge = math.huge
local vector_create = vector.create

local game = game
local workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local MouseService = game:GetService("MouseService")

---- severe globals guards ----
local getmouseposition_fn = getmouseposition
if typeof(getmouseposition_fn) ~= "function" then
	-- fallback: position only
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
	-- DrawingImmediate has no clipping, so do a cheap truncation.
	-- Approx char width: ~0.55 * font_size (Tamzen-ish)
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

--------------------------------------------------------------------------------
-- ESP CORE (your original module, merged + fixed set_path_rules export)
--------------------------------------------------------------------------------

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
}

---- variables ----
local tracked_objects: { [string]: any } = {}
local render_data: { any } = {}
local active_paths: { Instance } = {}
local include_filter: { string }? = nil
local exclude_filter: { string } = {}

local camera: any = nil
local camera_position: any = nil
local viewport_size: any = nil

local render_connection: any = nil
local update_connection: any = nil

local config: { [string]: any } = {}
local local_player: any = nil
local local_character: any = nil
local frame_count = 0

-- per-path include/exclude (child ids under the scanned path)
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
	local delta = pos1 - pos2
	return math_sqrt(delta.X * delta.X + delta.Y * delta.Y + delta.Z * delta.Z)
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
	if not obj or obj.ClassName ~= "Model" then
		return false
	end

	local ok, is_player = pcall(function()
		for _, player in ipairs(Players:GetChildren()) do
			if player.Character == obj then
				return true
			end
		end
		return false
	end)

	return ok and is_player
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
	assert(typeof(obj) == "Instance", "invalid argument #1 (Instance expected)")

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
		if obj.ClassName:find("Part") then
			table_insert(parts, obj)
		elseif obj.ClassName == "Model" then
			for _, child in ipairs(obj:GetDescendants()) do
				if child.ClassName:find("Part") then
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

	local min_x, min_y, min_z = math_huge, math_huge, math_huge
	local max_x, max_y, max_z = -math_huge, -math_huge, -math_huge

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

	if min_x == math_huge then
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

	if not any_visible or min_x == math_huge then
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

			local parts = { "HumanoidRootPart", "Head", "Torso", "UpperTorso" }
			for _, part_name in ipairs(parts) do
				local part = obj:FindFirstChild(part_name)
				if part and part.ClassName:find("Part") then
					return part.Position
				end
			end

			for _, child in ipairs(obj:GetChildren()) do
				if child.ClassName:find("Part") then
					return child.Position
				end
			end
		elseif obj.ClassName:find("Part") then
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

local function scan_path(path: Instance)
	assert(typeof(path) == "Instance", "invalid path (Instance expected)")

	local ok, children = pcall(function()
		return path:GetChildren()
	end)

	if not ok or not children then
		return
	end

	local rules = path_rules[get_id(path)]

	for _, obj in ipairs(children) do
		if obj and obj.Parent then
			-- per-path rules gate (exclude first, then include)
			if rules then
				local obj_id = get_id(obj)

				local ex = rules.exclude
				if ex and ex[obj_id] then
					continue
				end

				local inc = rules.include
				if inc and next(inc) ~= nil and not inc[obj_id] then
					continue
				end
			end

			if should_track_object(obj) then
				local obj_id = get_id(obj)
				local entry = tracked_objects[obj_id]

				if not entry then
					local position = get_object_position(obj)
					if position then
						local parts = get_all_parts(obj)
						local min_bound, max_bound = calculate_bounding_box(parts)

						tracked_objects[obj_id] = {
							object = obj,
							name = obj.Name,
							position = position,
							parts = parts,
							min_bound = min_bound,
							max_bound = max_bound,
							last_seen = os.clock(),
						}
					end
				else
					entry.last_seen = os.clock()
				end
			end
		end
	end
end

local function cleanup_stale_objects()
	local current_time = os.clock()
	local stale_threshold = 2

	for obj_id, data in pairs(tracked_objects) do
		if (not data.object) or (not data.object.Parent) then
			tracked_objects[obj_id] = nil
		elseif current_time - data.last_seen > stale_threshold then
			tracked_objects[obj_id] = nil
		end
	end
end

local function cleanup_dead_paths()
	-- remove deleted paths so they don't stay in active_paths forever
	for i = #active_paths, 1, -1 do
		local p = active_paths[i]
		if (not p) or (not p.Parent) then
			if p then
				path_rules[get_id(p)] = nil
			end
			table_remove(active_paths, i)
		end
	end
end

---- PostLocal: ALL ESP calculations ----
local function esp_update_loop()
	if not config.enabled then
		return
	end

	frame_count += 1

	local ok = pcall(function()
		camera = workspace.CurrentCamera
		if camera then
			camera_position = camera.Position
			viewport_size = camera.ViewportSize
		end
	end)

	if not ok then
		camera = nil
		camera_position = nil
		viewport_size = nil
		return
	end

	update_local_player()

	if frame_count % 30 == 0 then
		cleanup_dead_paths()

		for _, path in ipairs(active_paths) do
			if path and path.Parent then
				scan_path(path)
			end
		end

		cleanup_stale_objects()
	end

	local new_render_data = {}

	for _, data in pairs(tracked_objects) do
		local obj = data.object
		if obj and obj.Parent and not should_exclude_object(obj) then
			local pos = get_object_position(obj)
			if pos then
				data.position = pos

				if frame_count % 60 == 0 then
					local parts = get_all_parts(obj)
					data.parts = parts
					data.min_bound, data.max_bound = calculate_bounding_box(parts)
				end

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

---- Render: ONLY DRAWING (ESP overlay) ----
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

		if config.health_bar and data.health and data.max_health and data.max_health > 0 then
			local bar_width = 100
			local bar_height = 4
			local health_percent = data.health / data.max_health
			local bar_pos = screen_pos - vector_create(bar_width / 2, y_offset, 0)

			DrawingImmediate.FilledRectangle(bar_pos, vector_create(bar_width, bar_height, 0), Color3.new(0.2, 0.2, 0.2), 0.8 * fade_opacity)
			DrawingImmediate.FilledRectangle(bar_pos, vector_create(bar_width * health_percent, bar_height, 0), config.health_bar_color, 0.9 * fade_opacity)

			y_offset = y_offset + bar_height + 4
		end

		if config.tracers then
			DrawingImmediate.Line(screen_center, screen_pos, config.tracer_color, config.tracer_opacity * fade_opacity, 1, config.tracer_thickness)
		end
	end
end

--------------------------------------------------------------------------------
-- EXPLORER UI (draggable + minimize + custom scrollbar + esp/exclude)
--------------------------------------------------------------------------------

local UI_CFG = {
	pos = vector_create(60, 60, 0),
	size = vector_create(640, 560, 0),

	header_h = 30,
	row_h = 18,
	indent = 14,
	pad = 10,

	font = "Tamzen",
	font_size = 14,

	scroll_w = 10,
	btn_w = 82,
	btn_gap = 6,

	col_bg = Color3.fromRGB(18, 18, 22),
	col_header = Color3.fromRGB(28, 28, 34),
	col_border = Color3.fromRGB(80, 80, 92),

	col_text = Color3.fromRGB(245, 245, 245),
	col_dim = Color3.fromRGB(185, 185, 195),

	col_on = Color3.fromRGB(45, 200, 95),
	col_off = Color3.fromRGB(230, 75, 75),
	col_disabled = Color3.fromRGB(70, 70, 80),

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

local ui_dragging = false
local ui_drag_dx, ui_drag_dy = 0, 0

local sb_drag = false
local sb_drag_off = 0

local last_left = false
local scroll = 0
local content_h = 0

local expanded: { [string]: boolean } = {}
expanded[get_id(workspace)] = true

-- per-path include/exclude sets (stored by path_id)
local include_children: { [string]: { [string]: boolean } } = {}
local exclude_children: { [string]: { [string]: boolean } } = {}

-- nodes cache
local nodes: { Node } = {}
local rebuild_running = false
local rebuild_requested = true
local last_rebuild = 0

local function ui_owner_path(inst: Instance): Instance?
	local cur = inst
	while cur do
		local pid = get_id(cur)
		if pid and path_rules[pid] ~= nil then
			-- NOTE: path_rules exists for any path that had rules set; but a path can be active with no rules.
			-- So use active_paths list check:
		end
		cur = cur.Parent
	end

	-- actual check against active_paths
	cur = inst
	while cur do
		local cid = get_id(cur)
		for _, p in ipairs(active_paths) do
			if p and get_id(p) == cid then
				return cur
			end
		end
		cur = cur.Parent
	end

	return nil
end

local function is_path_active(path: Instance): boolean
	local pid = get_id(path)
	for _, p in ipairs(active_paths) do
		if p and get_id(p) == pid then
			return true
		end
	end
	return false
end

local function add_active_path(path: Instance)
	if not path or not path.Parent then
		return
	end
	if is_path_active(path) then
		return
	end

	table_insert(active_paths, path)
	-- ensure rule slot exists so UI can set rules anytime
	path_rules[get_id(path)] = path_rules[get_id(path)] or {}
end

local function remove_active_path(path: Instance)
	local pid = get_id(path)
	for i = #active_paths, 1, -1 do
		local p = active_paths[i]
		if not p or not p.Parent or get_id(p) == pid then
			table_remove(active_paths, i)
		end
	end

	include_children[pid] = nil
	exclude_children[pid] = nil
	path_rules[pid] = nil
end

local function apply_path_rules(path: Instance)
	local pid = get_id(path)
	local rules = path_rules[pid] or {}
	local inc = include_children[pid]
	local exc = exclude_children[pid]

	-- normalize empty sets -> nil
	if inc and next(inc) == nil then inc = nil end
	if exc and next(exc) == nil then exc = nil end

	rules.include = inc
	rules.exclude = exc
	path_rules[pid] = rules
end

local function ui_toggle_path_esp(inst: Instance)
	if not inst or not inst.Parent then
		return
	end

	if is_path_active(inst) then
		remove_active_path(inst)
	else
		add_active_path(inst)
	end

	rebuild_requested = true
end

local function ui_toggle_part_include(inst: Instance)
	-- If part has no active owner, activate its parent and include only this part.
	if not inst or not inst.Parent then
		return
	end

	local owner = ui_owner_path(inst)
	if not owner then
		local parent = inst.Parent
		if not parent or not parent.Parent then
			return
		end

		add_active_path(parent)
		local pid = get_id(parent)
		include_children[pid] = include_children[pid] or {}
		include_children[pid][get_id(inst)] = true
		apply_path_rules(parent)

		rebuild_requested = true
		return
	end

	-- If it has an owner, toggle include mode on that owner:
	local opid = get_id(owner)
	include_children[opid] = include_children[opid] or {}
	local cid = get_id(inst)

	include_children[opid][cid] = not include_children[opid][cid]
	apply_path_rules(owner)

	rebuild_requested = true
end

local function ui_toggle_exclude(inst: Instance)
	if not inst or not inst.Parent then
		return
	end

	local owner = ui_owner_path(inst)
	if not owner then
		return
	end

	-- Don't exclude the owner itself; turn it off via ESP button.
	if owner == inst then
		return
	end

	local opid = get_id(owner)
	exclude_children[opid] = exclude_children[opid] or {}
	local cid = get_id(inst)

	exclude_children[opid][cid] = not exclude_children[opid][cid]
	apply_path_rules(owner)

	rebuild_requested = true
end

local function ui_rebuild_nodes_async()
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
			if not inst or not inst.Parent and inst ~= workspace then
				return
			end

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

					-- yield periodically so PostLocal doesn't hitch
					if processed % 250 == 0 then
						task_wait()
					end
				end
			end
		end

		push(workspace, 0)

		nodes = out
		content_h = #nodes * UI_CFG.row_h
		last_rebuild = os.clock()

		rebuild_running = false
	end)
end

local function ui_update_loop()
	if not ui_open then
		return
	end

	-- periodic rebuild (or on demand)
	if rebuild_requested or (os.clock() - last_rebuild > 0.8) then
		ui_rebuild_nodes_async()
	end

	-- purge deleted active paths (UI-side)
	for i = #active_paths, 1, -1 do
		local p = active_paths[i]
		if not p or not p.Parent then
			table_remove(active_paths, i)
		end
	end

	local mouse = getmouseposition_fn()
	local mx, my = mouse.X, mouse.Y

	local left = isleftpressed_fn()
	local just_pressed = left and not last_left
	local just_released = (not left) and last_left
	last_left = left

	if just_released then
		ui_dragging = false
		sb_drag = false
	end

	local x0, y0 = UI_CFG.pos.X, UI_CFG.pos.Y
	local w, h = UI_CFG.size.X, UI_CFG.size.Y

	-- header controls
	local btn_min_w = 22
	local btn_min_x = x0 + w - UI_CFG.pad - btn_min_w
	local btn_min_y = y0 + 4

	if just_pressed and point_in(mx, my, btn_min_x, btn_min_y, btn_min_w, UI_CFG.header_h - 8) then
		ui_minimized = not ui_minimized
		return
	end

	-- drag by header (excluding minimize area)
	if just_pressed and point_in(mx, my, x0, y0, w, UI_CFG.header_h) and not point_in(mx, my, btn_min_x, btn_min_y, btn_min_w, UI_CFG.header_h - 8) then
		ui_dragging = true
		ui_drag_dx = mx - x0
		ui_drag_dy = my - y0
	end

	if ui_dragging and left then
		UI_CFG.pos = vector_create(mx - ui_drag_dx, my - ui_drag_dy, 0)
		return
	end

	if ui_minimized then
		return
	end

	-- content geometry
	local inner_x0 = x0 + UI_CFG.pad
	local inner_y0 = y0 + UI_CFG.header_h + UI_CFG.pad
	local inner_h = h - UI_CFG.header_h - UI_CFG.pad * 2
	local inner_w = w - UI_CFG.pad * 2 - UI_CFG.scroll_w - 6

	local max_scroll = math_max(0, content_h - inner_h)
	scroll = clamp(scroll, 0, max_scroll)

	-- scrollbar geometry
	local sb_x = x0 + w - UI_CFG.pad - UI_CFG.scroll_w
	local sb_y = inner_y0
	local sb_h = inner_h

	local thumb_h = (content_h > 0) and clamp((inner_h / content_h) * sb_h, 26, sb_h) or sb_h
	local thumb_y = sb_y + ((max_scroll > 0) and ((scroll / max_scroll) * (sb_h - thumb_h)) or 0)

	-- scrollbar thumb drag
	if just_pressed and point_in(mx, my, sb_x, thumb_y, UI_CFG.scroll_w, thumb_h) then
		sb_drag = true
		sb_drag_off = my - thumb_y
	end

	if sb_drag and left and max_scroll > 0 then
		local new_thumb_y = clamp(my - sb_drag_off, sb_y, sb_y + sb_h - thumb_h)
		local t = (new_thumb_y - sb_y) / (sb_h - thumb_h)
		scroll = t * max_scroll
	end

	-- click track paging
	if just_pressed and point_in(mx, my, sb_x, sb_y, UI_CFG.scroll_w, sb_h) and not sb_drag then
		if my < thumb_y then
			scroll = clamp(scroll - inner_h, 0, max_scroll)
		elseif my > thumb_y + thumb_h then
			scroll = clamp(scroll + inner_h, 0, max_scroll)
		end
	end

	-- row click
	if just_pressed and point_in(mx, my, inner_x0, inner_y0, inner_w, inner_h) then
		local idx = math_floor((my - inner_y0 + scroll) / UI_CFG.row_h) + 1
		local node = nodes[idx]
		if not node or not node.inst then
			return
		end

		-- if node got deleted between build and click
		if node.inst ~= workspace and (not node.inst.Parent) then
			rebuild_requested = true
			return
		end

		local row_y = inner_y0 + (idx - 1) * UI_CFG.row_h - scroll

		local exp_x = inner_x0 + node.depth * UI_CFG.indent
		local exp_w = 12

		local btn_esp_x = inner_x0 + inner_w - (UI_CFG.btn_w * 2 + UI_CFG.btn_gap)
		local btn_exc_x = inner_x0 + inner_w - UI_CFG.btn_w

		-- expand/collapse
		if node.expandable and point_in(mx, my, exp_x, row_y, exp_w, UI_CFG.row_h) then
			expanded[node.id] = not expanded[node.id]
			rebuild_requested = true
			return
		end

		-- ESP toggle
		if point_in(mx, my, btn_esp_x, row_y + 1, UI_CFG.btn_w, UI_CFG.row_h - 2) then
			if node.inst == workspace or is_container_class(node.class) then
				ui_toggle_path_esp(node.inst)
			else
				-- parts: include toggle
				ui_toggle_part_include(node.inst)
			end
			return
		end

		-- EXCLUDE toggle
		if point_in(mx, my, btn_exc_x, row_y + 1, UI_CFG.btn_w, UI_CFG.row_h - 2) then
			ui_toggle_exclude(node.inst)
			return
		end
	end
end

local function ui_render_loop()
	if not ui_open then
		return
	end

	local x0, y0 = UI_CFG.pos.X, UI_CFG.pos.Y
	local w, h = UI_CFG.size.X, UI_CFG.size.Y

	-- panel + header
	DrawingImmediate.FilledRectangle(UI_CFG.pos, vector_create(w, UI_CFG.header_h, 0), UI_CFG.col_header, 0.95)
	DrawingImmediate.Rectangle(UI_CFG.pos, vector_create(w, UI_CFG.header_h, 0), UI_CFG.col_border, 1, 1)

	DrawingImmediate.OutlinedText(
		UI_CFG.pos + vector_create(UI_CFG.pad, 7, 0),
		UI_CFG.font_size,
		UI_CFG.col_text,
		1,
		ui_minimized and "Workspace ESP Explorer (minimized)" or "Workspace ESP Explorer",
		false,
		UI_CFG.font
	)

	-- minimize button
	local btn_min_w = 22
	local btn_min_x = x0 + w - UI_CFG.pad - btn_min_w
	local btn_min_y = y0 + 4
	DrawingImmediate.FilledRectangle(vector_create(btn_min_x, btn_min_y, 0), vector_create(btn_min_w, UI_CFG.header_h - 8, 0), UI_CFG.col_border, 0.35)
	DrawingImmediate.OutlinedText(
		vector_create(btn_min_x + 7, btn_min_y + 3, 0),
		UI_CFG.font_size,
		UI_CFG.col_text,
		1,
		ui_minimized and "+" or "-",
		false,
		UI_CFG.font
	)

	if ui_minimized then
		return
	end

	-- body
	DrawingImmediate.FilledRectangle(
		UI_CFG.pos + vector_create(0, UI_CFG.header_h, 0),
		vector_create(w, h - UI_CFG.header_h, 0),
		UI_CFG.col_bg,
		0.92
	)
	DrawingImmediate.Rectangle(UI_CFG.pos, vector_create(w, h, 0), UI_CFG.col_border, 1, 1)

	local inner_x0 = x0 + UI_CFG.pad
	local inner_y0 = y0 + UI_CFG.header_h + UI_CFG.pad
	local inner_h = h - UI_CFG.header_h - UI_CFG.pad * 2
	local inner_w = w - UI_CFG.pad * 2 - UI_CFG.scroll_w - 6

	-- scrollbar
	local sb_x = x0 + w - UI_CFG.pad - UI_CFG.scroll_w
	DrawingImmediate.FilledRectangle(vector_create(sb_x, inner_y0, 0), vector_create(UI_CFG.scroll_w, inner_h, 0), UI_CFG.col_scroll_track, 0.9)

	local max_scroll = math_max(0, content_h - inner_h)
	local thumb_h = (content_h > 0) and clamp((inner_h / content_h) * inner_h, 26, inner_h) or inner_h
	local thumb_y = inner_y0 + ((max_scroll > 0) and ((scroll / max_scroll) * (inner_h - thumb_h)) or 0)
	DrawingImmediate.FilledRectangle(vector_create(sb_x, thumb_y, 0), vector_create(UI_CFG.scroll_w, thumb_h, 0), UI_CFG.col_scroll_thumb, 0.95)

	-- visible rows only
	local first = math_max(1, math_floor(scroll / UI_CFG.row_h) + 1)
	local last = math_min(#nodes, first + math_floor(inner_h / UI_CFG.row_h) + 2)

	for i = first, last do
		local n = nodes[i]
		if n and n.inst then
			local row_y = inner_y0 + (i - 1) * UI_CFG.row_h - scroll
			local depth_x = inner_x0 + n.depth * UI_CFG.indent

			-- expand glyph
			if n.expandable then
				local glyph = expanded[n.id] and "-" or "+"
				DrawingImmediate.OutlinedText(vector_create(depth_x, row_y + 1, 0), UI_CFG.font_size, UI_CFG.col_dim, 1, glyph, false, UI_CFG.font)
			end

			-- buttons x
			local btn_esp_x = inner_x0 + inner_w - (UI_CFG.btn_w * 2 + UI_CFG.btn_gap)
			local btn_exc_x = inner_x0 + inner_w - UI_CFG.btn_w

			-- label max width (avoid overflowing into buttons)
			local label_max_px = (btn_esp_x - (depth_x + 12)) - 8
			local label = `{n.name} ({n.class})`
			label = truncate_to_px(label, label_max_px, UI_CFG.font_size)
			DrawingImmediate.OutlinedText(
				vector_create(depth_x + 12, row_y + 1, 0),
				UI_CFG.font_size,
				UI_CFG.col_text,
				1,
				label,
				false,
				UI_CFG.font
			)

			-- determine owner path (closest active ancestor)
			local owner: Instance? = nil
			do
				local cur = n.inst
				while cur do
					if is_path_active(cur) then
						owner = cur
						break
					end
					cur = cur.Parent
				end
			end

			-- button states
			local esp_enabled = true
			local esp_on = false

			local exc_enabled = false
			local exc_on = false

			if n.inst == workspace or is_container_class(n.class) then
				-- containers behave exactly like add_path/remove_path
				esp_on = is_path_active(n.inst)
				exc_enabled = false
				exc_on = false
			else
				-- leaf object (part)
				if not owner or owner == n.inst then
					-- no active owner => allow ESP button (it will auto-add parent path + include self)
					esp_on = false
					exc_enabled = false
					exc_on = false
				else
					local opid = get_id(owner)
					local cid = n.id

					local inc = include_children[opid]
					local exc = exclude_children[opid]

					local is_excluded = (exc and exc[cid]) and true or false
					local inc_mode = (inc and next(inc) ~= nil) and true or false

					-- If include mode is active: ON only if included
					-- Else: ON unless excluded (because path is scanning everything)
					if inc_mode then
						esp_on = (inc[cid] and true) or false
					else
						esp_on = not is_excluded
					end

					exc_enabled = true
					exc_on = is_excluded
				end
			end

			-- draw ESP button
			local esp_col = UI_CFG.col_disabled
			local esp_txt = "ESP"

			if esp_enabled then
				esp_col = esp_on and UI_CFG.col_on or UI_CFG.col_off
				esp_txt = esp_on and "ESP ON" or "ESP OFF"
			end

			DrawingImmediate.FilledRectangle(
				vector_create(btn_esp_x, row_y + 1, 0),
				vector_create(UI_CFG.btn_w, UI_CFG.row_h - 2, 0),
				esp_col,
				0.9
			)
			DrawingImmediate.OutlinedText(
				vector_create(btn_esp_x + 10, row_y + 1, 0),
				UI_CFG.font_size,
				UI_CFG.col_text,
				1,
				esp_txt,
				false,
				UI_CFG.font
			)

			-- draw EXCLUDE button
			local exc_col = UI_CFG.col_disabled
			local exc_txt = "EXC"

			if exc_enabled then
				-- user requested: red = not excluded, green = excluded
				exc_col = exc_on and UI_CFG.col_on or UI_CFG.col_off
				exc_txt = exc_on and "EXCLUDED" or "EXCLUDE"
			end

			DrawingImmediate.FilledRectangle(
				vector_create(btn_exc_x, row_y + 1, 0),
				vector_create(UI_CFG.btn_w, UI_CFG.row_h - 2, 0),
				exc_col,
				0.9
			)
			DrawingImmediate.OutlinedText(
				vector_create(btn_exc_x + 10, row_y + 1, 0),
				UI_CFG.font_size,
				UI_CFG.col_text,
				1,
				exc_txt,
				false,
				UI_CFG.font
			)

			-- optional: show PATH tag for active container paths
			if (n.inst == workspace or is_container_class(n.class)) and is_path_active(n.inst) then
				DrawingImmediate.OutlinedText(
					vector_create(btn_esp_x - 44, row_y + 1, 0),
					UI_CFG.font_size,
					UI_CFG.col_dim,
					1,
					"PATH",
					false,
					UI_CFG.font
				)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- MODULE API (compat with your old usage)
--------------------------------------------------------------------------------

local ESP = {}

function ESP.new(settings: { [string]: any }?)
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

function ESP.set_path_rules(path: Instance, include_set: { [string]: boolean }?, exclude_set: { [string]: boolean }?)
	assert(typeof(path) == "Instance", "invalid argument #1 (Instance expected)")
	local pid = get_id(path)

	if (include_set == nil) and (exclude_set == nil) then
		path_rules[pid] = nil
		return true
	end

	path_rules[pid] = path_rules[pid] or {}
	path_rules[pid].include = include_set
	path_rules[pid].exclude = exclude_set
	return true
end

function ESP.add_path(path: Instance | string)
	-- keep your original add_path behavior for strings/instances
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

function ESP.set_config(key: string, value: any)
	assert(config[key] ~= nil, `invalid config key: {key}`)
	config[key] = value
end

function ESP.get_config(key: string): any
	return config[key]
end

function ESP.start()
	if render_connection or update_connection then
		return
	end

	config.enabled = true
	frame_count = 0
	rebuild_requested = true

	-- PostLocal: ESP compute + UI input/state
	update_connection = RunService.PostLocal:Connect(function()
		esp_update_loop()
		ui_update_loop()
	end)

	-- Render: ONLY drawing (ESP overlay + UI)
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
	active_paths = {}

	path_rules = {}

	-- UI state resets
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

return ESP

