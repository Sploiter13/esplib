--!native
--!optimize 2

---- environment ----
local assert, typeof, tonumber = assert, typeof, tonumber
local pcall, pairs, ipairs = pcall, pairs, ipairs
local task_wait, task_spawn = task.wait, task.spawn
local table_find, table_insert, table_remove = table.find, table.insert, table.remove
local string_format, string_lower = string.format, string.lower
local math_floor, math_sqrt, math_min, math_max = math.floor, math.sqrt, math.min, math.max
local math_huge = math.huge
local vector_magnitude, vector_create = vector.magnitude, vector.create

local game = game
local workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

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
local tracked_objects = {}
local render_data = {}
local active_paths = {}
local include_filter = nil
local exclude_filter = {}
local camera = nil
local camera_position = nil
local viewport_size = nil
local render_connection = nil
local update_connection = nil
local config = {}
local local_player = nil
local local_character = nil
local frame_count = 0

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
	local success = pcall(function()
		local_player = Players.LocalPlayer
		if local_player then
			local_character = local_player.Character
		end
	end)
	
	if not success then
		local_player = nil
		local_character = nil
	end
end

local function is_player_character(obj: Instance): boolean
	if not obj or obj.ClassName ~= "Model" then
		return false
	end
	
	local success, is_player = pcall(function()
		for _, player in ipairs(Players:GetChildren()) do
			if player.Character == obj then
				return true
			end
		end
		return false
	end)
	
	return success and is_player
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

local function get_all_parts(obj: Instance): {Instance}
	local parts = {}
	
	local success = pcall(function()
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

local function calculate_bounding_box(parts: {Instance}): (vector?, vector?)
	if #parts == 0 then
		return nil, nil
	end
	
	local min_x, min_y, min_z = math_huge, math_huge, math_huge
	local max_x, max_y, max_z = -math_huge, -math_huge, -math_huge
	
	for _, part in ipairs(parts) do
		local success = pcall(function()
			local pos = part.Position
			local size = part.Size
			
			local half_size_x = size.X / 2
			local half_size_y = size.Y / 2
			local half_size_z = size.Z / 2
			
			min_x = math_min(min_x, pos.X - half_size_x)
			min_y = math_min(min_y, pos.Y - half_size_y)
			min_z = math_min(min_z, pos.Z - half_size_z)
			
			max_x = math_max(max_x, pos.X + half_size_x)
			max_y = math_max(max_y, pos.Y + half_size_y)
			max_z = math_max(max_z, pos.Z + half_size_z)
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
	
	if not any_visible or min_x == math_huge then
		return nil, nil
	end
	
	return vector_create(min_x, min_y, 0), vector_create(max_x, max_y, 0)
end

local function get_object_position(obj: Instance): vector?
	local success, result = pcall(function()
		if obj.ClassName == "Model" then
			local primary = obj.PrimaryPart
			if primary then
				return primary.Position
			end
			
			local parts = {"HumanoidRootPart", "Head", "Torso", "UpperTorso"}
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
	
	if success and result then
		return result
	end
	return nil
end

local function get_object_health(obj: Instance): (number?, number?)
	if obj.ClassName ~= "Model" then
		return nil, nil
	end
	
	local success, health, max_health = pcall(function()
		local humanoid = obj:FindFirstChildOfClass("Humanoid")
		if humanoid then
			return humanoid.Health, humanoid.MaxHealth
		end
		return nil, nil
	end)
	
	if success then
		return health, max_health
	end
	return nil, nil
end

local function scan_path(path: Instance)
	assert(typeof(path) == "Instance", "invalid path (Instance expected)")
	
	local success, children = pcall(function()
		return path:GetChildren()
	end)
	
	if not success then
		warn(`failed to scan path: {path.Name}`)
		return
	end
	
	for _, obj in ipairs(children) do
		if should_track_object(obj) then
			local obj_id = obj.Data or tostring(obj)
			
			if not tracked_objects[obj_id] then
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
				tracked_objects[obj_id].last_seen = os.clock()
			end
		end
	end
end

local function cleanup_stale_objects()
	local current_time = os.clock()
	local stale_threshold = 2
	
	for obj_id, data in pairs(tracked_objects) do
		if current_time - data.last_seen > stale_threshold then
			tracked_objects[obj_id] = nil
		elseif not data.object or not data.object.Parent then
			tracked_objects[obj_id] = nil
		end
	end
end

---- PostLocal - Scanning and ALL calculations happen here EVERY FRAME ----
local function update_loop()
	if not config.enabled then
		return
	end
	
	frame_count = frame_count + 1
	
	-- Update camera reference every frame
	local success = pcall(function()
		camera = workspace.CurrentCamera
		if camera then
			camera_position = camera.Position
			viewport_size = camera.ViewportSize
		end
	end)
	
	if not success then
		camera = nil
		camera_position = nil
		viewport_size = nil
		return
	end
	
	update_local_player()
	
	-- Scan paths every 30 frames (~0.5 seconds at 60fps)
	if frame_count % 30 == 0 then
		for _, path in ipairs(active_paths) do
			if path and path.Parent then
				scan_path(path)
			end
		end
		
		cleanup_stale_objects()
	end
	
	-- Calculate render data EVERY FRAME for smooth movement
	local new_render_data = {}
	
	for obj_id, data in pairs(tracked_objects) do
		local obj = data.object
		if obj and obj.Parent then
			if not should_exclude_object(obj) then
				-- Update position every frame
				local pos = get_object_position(obj)
				if pos then
					data.position = pos
					
					-- Recalculate bounding box every 60 frames
					if frame_count % 60 == 0 then
						local parts = get_all_parts(obj)
						data.parts = parts
						data.min_bound, data.max_bound = calculate_bounding_box(parts)
					end
					
					-- Calculate distance
					local distance = calculate_distance(pos, camera_position)
					
					if distance <= config.max_distance then
						-- World to screen
						local screen, visible = camera:WorldToScreenPoint(pos)
						
						if visible then
							local fade_opacity = calculate_fade_opacity(distance)
							
							if fade_opacity > 0 then
								-- Calculate bounding box in screen space
								local box_min, box_max = nil, nil
								if config.box_esp and data.min_bound and data.max_bound then
									local corners = get_bounding_box_corners(data.min_bound, data.max_bound)
									box_min, box_max = get_2d_bounding_box(corners, camera)
								end
								
								-- Get health
								local health, max_health = nil, nil
								if config.health_bar then
									health, max_health = get_object_health(obj)
								end
								
								-- Store pre-computed render data
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
	
	-- Swap render data
	render_data = new_render_data
end

---- Render - ONLY DRAWING ----
local function render_loop()
	if not config.enabled or not viewport_size then
		return
	end
	
	local screen_center = vector_create(viewport_size.X / 2, viewport_size.Y / 2, 0)
	
	for _, data in ipairs(render_data) do
		local screen_pos = data.screen_pos
		local fade_opacity = data.fade_opacity
		
		-- Bounding Box
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
		
		-- Name ESP
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
		
		-- Health bar
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
		
		-- Tracers
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
			local success, result = pcall(function()
				return current:FindFirstChild(part)
			end)
			
			if success and result then
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
end

function ESP.set_exclude(names: {string})
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
		warn("ESP already running")
		return
	end
	
	config.enabled = true
	frame_count = 0
	
	-- PostLocal: ALL calculations every frame
	update_connection = RunService.PostLocal:Connect(update_loop)
	
	-- Render: ONLY drawing every frame
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
	
	tracked_objects = {}
	render_data = {}
end

function ESP.get_tracked_count(): number
	local count = 0
	for _ in pairs(tracked_objects) do
		count = count + 1
	end
	return count
end

---- exports ----
return ESP
