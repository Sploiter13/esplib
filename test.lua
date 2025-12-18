--!native
--!optimize 2

---- environment ----
local assert, typeof, tonumber = assert, typeof, tonumber
local pcall, pairs, ipairs = pcall, pairs, ipairs
local task_wait, task_spawn = task.wait, task.spawn
local table_find, table_insert, table_remove, table_create, table_clear = table.find, table.insert, table.remove, table.create, table.clear
local string_format, string_lower, string_split = string.format, string.lower, string.split
local math_floor, math_sqrt, math_min, math_max, math_abs = math.floor, math.sqrt, math.min, math.max, math.abs
local math_huge = math.huge
local vector_magnitude, vector_create = vector.magnitude, vector.create
local os_clock = os.clock

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
	static_objects = false,
	
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

local PART_NAMES = {"HumanoidRootPart", "Head", "Torso", "UpperTorso"}
local SCAN_INTERVAL = 30
local BBOX_UPDATE_INTERVAL = 3
local HEALTH_UPDATE_INTERVAL = 10

---- variables ----
local tracked_objects = {}
local render_data = table_create(100)
local render_data_size = 0
local active_paths = table_create(10)
local include_filter = nil
local exclude_filter = table_create(10)
local camera = nil
local camera_position = nil
local viewport_size = nil
local screen_center = nil
local render_connection = nil
local update_connection = nil
local config = {}
local local_player = nil
local local_character = nil
local frame_count = 0
local fade_range_inv = 1
local max_distance_sq = 1000000

---- cache pools ----
local parts_cache = table_create(50)
local corners_cache = table_create(8)

---- local refs ----
local WorldToScreenPoint = nil

---- functions ----
local function deep_copy(tbl)
	local copy = table_create(10)
	for k, v in pairs(tbl) do
		copy[k] = typeof(v) == "table" and deep_copy(v) or v
	end
	return copy
end

local function calculate_distance_sq(pos)
	local dx = pos.X - camera_position.X
	local dy = pos.Y - camera_position.Y
	local dz = pos.Z - camera_position.Z
	return dx * dx + dy * dy + dz * dz
end

local function calculate_fade_opacity_fast(distance_sq)
	if not config.fade_enabled then
		return 1
	end
	
	local distance = math_sqrt(distance_sq)
	
	if distance <= config.fade_start then
		return 1
	elseif distance >= config.fade_end then
		return 0
	end
	
	return 1 - ((distance - config.fade_start) * fade_range_inv)
end

local function update_local_player()
	local success, player = pcall(function()
		return Players.LocalPlayer
	end)
	
	if success and player then
		local_player = player
		pcall(function()
			local_character = player.Character
		end)
	end
end

local function is_player_character_fast(obj)
	if obj.ClassName ~= "Model" then
		return false
	end
	
	local success, is_player = pcall(function()
		local players = Players:GetPlayers()
		for i = 1, #players do
			if players[i].Character == obj then
				return true
			end
		end
		return false
	end)
	
	return success and is_player
end

local function should_track_object(obj)
	if config.auto_exclude_localplayer and obj == local_character then
		return false
	end
	
	if config.exclude_players and is_player_character_fast(obj) then
		return false
	end
	
	local success, obj_name = pcall(function()
		return obj.Name
	end)
	
	if not success then
		return false
	end
	
	local obj_name_lower = string_lower(obj_name)
	
	if include_filter then
		for i = 1, #include_filter do
			if obj_name_lower:find(string_lower(include_filter[i]), 1, true) then
				return true
			end
		end
		return false
	end
	
	for i = 1, #exclude_filter do
		if obj_name_lower:find(string_lower(exclude_filter[i]), 1, true) then
			return false
		end
	end
	
	return true
end

local function get_all_parts_fast(obj)
	table_clear(parts_cache)
	
	pcall(function()
		if not obj.Parent then
			return
		end
		
		if obj.ClassName:find("Part") then
			parts_cache[1] = obj
			return
		end
		
		if obj.ClassName == "Model" then
			local descendants = obj:GetDescendants()
			local count = 0
			for i = 1, #descendants do
				local child = descendants[i]
				if child.Parent and child.ClassName:find("Part") then
					count = count + 1
					parts_cache[count] = child
				end
			end
		end
	end)
	
	return parts_cache
end

local function calculate_bounding_box_fast(parts)
	if #parts == 0 then
		return nil, nil
	end
	
	local min_x, min_y, min_z = math_huge, math_huge, math_huge
	local max_x, max_y, max_z = -math_huge, -math_huge, -math_huge
	
	for i = 1, #parts do
		pcall(function()
			local part = parts[i]
			if not part.Parent then
				return
			end
			
			local pos = part.Position
			local size = part.Size
			local hsx, hsy, hsz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
			local px, py, pz = pos.X, pos.Y, pos.Z
			
			min_x = math_min(min_x, px - hsx)
			min_y = math_min(min_y, py - hsy)
			min_z = math_min(min_z, pz - hsz)
			max_x = math_max(max_x, px + hsx)
			max_y = math_max(max_y, py + hsy)
			max_z = math_max(max_z, pz + hsz)
		end)
	end
	
	return min_x == math_huge and nil or vector_create(min_x, min_y, min_z), 
	       min_x == math_huge and nil or vector_create(max_x, max_y, max_z)
end

local function get_bounding_box_corners_inline(min_bound, max_bound)
	local mnx, mny, mnz = min_bound.X, min_bound.Y, min_bound.Z
	local mxx, mxy, mxz = max_bound.X, max_bound.Y, max_bound.Z
	
	corners_cache[1] = vector_create(mnx, mny, mnz)
	corners_cache[2] = vector_create(mxx, mny, mnz)
	corners_cache[3] = vector_create(mxx, mny, mxz)
	corners_cache[4] = vector_create(mnx, mny, mxz)
	corners_cache[5] = vector_create(mnx, mxy, mnz)
	corners_cache[6] = vector_create(mxx, mxy, mnz)
	corners_cache[7] = vector_create(mxx, mxy, mxz)
	corners_cache[8] = vector_create(mnx, mxy, mxz)
	
	return corners_cache
end

local function get_2d_bounding_box_fast(corners_3d)
	local min_x, min_y = math_huge, math_huge
	local max_x, max_y = -math_huge, -math_huge
	local any_visible = false
	
	for i = 1, 8 do
		local screen_pos, visible = WorldToScreenPoint(camera, corners_3d[i])
		if visible then
			any_visible = true
			local sx, sy = screen_pos.X, screen_pos.Y
			min_x = math_min(min_x, sx)
			min_y = math_min(min_y, sy)
			max_x = math_max(max_x, sx)
			max_y = math_max(max_y, sy)
		end
	end
	
	return any_visible and vector_create(min_x, min_y, 0) or nil, 
	       any_visible and vector_create(max_x, max_y, 0) or nil
end

local function get_object_position_fast(obj)
	local success, result = pcall(function()
		if not obj.Parent then
			return nil
		end
		
		if obj.ClassName == "Model" then
			local primary = obj.PrimaryPart
			if primary and primary.Parent then
				return primary.Position
			end
			
			for i = 1, 4 do
				local part = obj:FindFirstChild(PART_NAMES[i])
				if part and part.Parent and part.ClassName:find("Part") then
					return part.Position
				end
			end
			
			local children = obj:GetChildren()
			for i = 1, #children do
				local child = children[i]
				if child.Parent and child.ClassName:find("Part") then
					return child.Position
				end
			end
		elseif obj.ClassName:find("Part") then
			return obj.Position
		end
		
		return nil
	end)
	
	return success and result or nil
end

local function get_object_health_fast(obj)
	local success, health, max_health = pcall(function()
		if not obj.Parent or obj.ClassName ~= "Model" then
			return nil, nil
		end
		
		local humanoid = obj:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Parent then
			return humanoid.Health, humanoid.MaxHealth
		end
		return nil, nil
	end)
	
	return success and health or nil, success and max_health or nil
end

local function scan_path(path)
	local success, children = pcall(function()
		return path:GetChildren()
	end)
	
	if not success then
		return
	end
	
	local now = os_clock()
	
	for i = 1, #children do
		local obj = children[i]
		if should_track_object(obj) then
			local obj_id = tostring(obj)
			
			if not tracked_objects[obj_id] then
				local position = get_object_position_fast(obj)
				if position then
					local parts = get_all_parts_fast(obj)
					local min_bound, max_bound = calculate_bounding_box_fast(parts)
					
					local obj_name = "Unknown"
					pcall(function()
						obj_name = obj.Name
					end)
					
					local stored_parts = table_create(#parts_cache)
					for j = 1, #parts_cache do
						stored_parts[j] = parts_cache[j]
					end
					
					tracked_objects[obj_id] = {
						object = obj,
						name = obj_name,
						position = position,
						parts = stored_parts,
						min_bound = min_bound,
						max_bound = max_bound,
						last_seen = now,
						static = config.static_objects,
					}
				end
			else
				tracked_objects[obj_id].last_seen = now
			end
		end
	end
end

local function cleanup_stale_objects()
	local current_time = os_clock()
	
	for obj_id, data in pairs(tracked_objects) do
		if (current_time - data.last_seen) > 2 then
			tracked_objects[obj_id] = nil
		else
			local invalid = false
			pcall(function()
				invalid = not data.object or not data.object.Parent
			end)
			if invalid then
				tracked_objects[obj_id] = nil
			end
		end
	end
end

local function update_loop()
	if not config.enabled then
		return
	end
	
	frame_count = frame_count + 1
	
	local cam_success = pcall(function()
		camera = workspace.CurrentCamera
		if camera then
			camera_position = camera.CFrame.Position
			viewport_size = camera.ViewportSize
			screen_center = vector_create(viewport_size.X * 0.5, viewport_size.Y * 0.5, 0)
			WorldToScreenPoint = camera.WorldToScreenPoint
		end
	end)
	
	if not cam_success or not camera then
		return
	end
	
	if frame_count % 60 == 0 then
		update_local_player()
	end
	
	if frame_count % SCAN_INTERVAL == 0 then
		for i = 1, #active_paths do
			pcall(function()
				local path = active_paths[i]
				if path and path.Parent then
					scan_path(path)
				end
			end)
		end
		cleanup_stale_objects()
	end
	
	render_data_size = 0
	
	local is_static = config.static_objects
	local update_bbox = not is_static and (frame_count % BBOX_UPDATE_INTERVAL == 0)
	local update_health = config.health_bar and (frame_count % HEALTH_UPDATE_INTERVAL == 0)
	
	for obj_id, data in pairs(tracked_objects) do
		pcall(function()
			local obj = data.object
			if not obj or not obj.Parent then
				return
			end
			
			if config.auto_exclude_localplayer and obj == local_character then
				return
			end
			
			if not is_static or not data.position then
				local pos = get_object_position_fast(obj)
				if not pos then
					return
				end
				data.position = pos
			end
			
			local pos = data.position
			local distance_sq = calculate_distance_sq(pos)
			
			if distance_sq > max_distance_sq then
				return
			end
			
			if update_bbox then
				local parts = get_all_parts_fast(obj)
				table_clear(data.parts)
				for i = 1, #parts_cache do
					data.parts[i] = parts_cache[i]
				end
				data.min_bound, data.max_bound = calculate_bounding_box_fast(data.parts)
			end
			
			local screen, visible = WorldToScreenPoint(camera, pos)
			
			if not visible then
				return
			end
			
			local fade_opacity = calculate_fade_opacity_fast(distance_sq)
			
			if fade_opacity <= 0 then
				return
			end
			
			local box_min, box_max = nil, nil
			if config.box_esp and data.min_bound and data.max_bound then
				local corners = get_bounding_box_corners_inline(data.min_bound, data.max_bound)
				box_min, box_max = get_2d_bounding_box_fast(corners)
			end
			
			local health, max_health = nil, nil
			if update_health then
				health, max_health = get_object_health_fast(obj)
				data.cached_health = health
				data.cached_max_health = max_health
			elseif config.health_bar then
				health = data.cached_health
				max_health = data.cached_max_health
			end
			
			render_data_size = render_data_size + 1
			
			if not render_data[render_data_size] then
				render_data[render_data_size] = {}
			end
			
			local rd = render_data[render_data_size]
			rd.name = data.name
			rd.screen_pos = vector_create(screen.X, screen.Y, 0)
			rd.distance = math_sqrt(distance_sq)
			rd.fade_opacity = fade_opacity
			rd.box_min = box_min
			rd.box_max = box_max
			rd.health = health
			rd.max_health = max_health
		end)
	end
end

local function render_loop()
	if not config.enabled or not screen_center then
		return
	end
	
	local box_enabled = config.box_esp
	local name_enabled = config.name_esp
	local distance_enabled = config.distance_esp
	local health_enabled = config.health_bar
	local tracers_enabled = config.tracers
	
	local box_color = config.box_color
	local box_opacity = config.box_opacity
	local box_thickness = config.box_thickness
	
	local name_color = config.name_color
	local name_opacity = config.name_opacity
	local font_size = config.font_size
	local font = config.font
	
	local health_bar_color = config.health_bar_color
	local tracer_color = config.tracer_color
	local tracer_opacity = config.tracer_opacity
	local tracer_thickness = config.tracer_thickness
	
	for i = 1, render_data_size do
		local data = render_data[i]
		local screen_pos = data.screen_pos
		local fade_opacity = data.fade_opacity
		
		if box_enabled and data.box_min and data.box_max then
			DrawingImmediate.Rectangle(
				data.box_min,
				data.box_max - data.box_min,
				box_color,
				box_opacity * fade_opacity,
				box_thickness
			)
		end
		
		local y_offset = 0
		
		if name_enabled then
			local name_text = distance_enabled 
				and data.name .. " [" .. math_floor(data.distance) .. "m]" 
				or data.name
			
			DrawingImmediate.OutlinedText(
				screen_pos - vector_create(0, y_offset, 0),
				font_size,
				name_color,
				name_opacity * fade_opacity,
				name_text,
				true,
				font
			)
			y_offset = y_offset + font_size + 2
		end
		
		if health_enabled and data.health and data.max_health and data.max_health > 0 then
			local bar_width = 100
			local bar_height = 4
			local health_percent = data.health / data.max_health
			
			local bar_pos = screen_pos - vector_create(50, y_offset, 0)
			
			DrawingImmediate.FilledRectangle(
				bar_pos,
				vector_create(bar_width, bar_height, 0),
				Color3.new(0.2, 0.2, 0.2),
				0.8 * fade_opacity
			)
			
			DrawingImmediate.FilledRectangle(
				bar_pos,
				vector_create(bar_width * health_percent, bar_height, 0),
				health_bar_color,
				0.9 * fade_opacity
			)
			
			y_offset = y_offset + bar_height + 4
		end
		
		if tracers_enabled then
			DrawingImmediate.Line(
				screen_center,
				screen_pos,
				tracer_color,
				tracer_opacity * fade_opacity,
				1,
				tracer_thickness
			)
		end
	end
end

---- module ----
local ESP = {}

function ESP.new(settings)
	settings = settings or {}
	
	config = deep_copy(DEFAULT_CONFIG)
	
	for key, value in pairs(settings) do
		if config[key] ~= nil then
			config[key] = value
		end
	end
	
	local fade_range = config.fade_end - config.fade_start
	fade_range_inv = fade_range > 0 and (1 / fade_range) or 1
	max_distance_sq = config.max_distance * config.max_distance
	
	update_local_player()
	
	return ESP
end

function ESP.add_path(path)
	local actual_path = nil
	
	if typeof(path) == "string" then
		local parts = string_split(path, ".")
		local current = workspace
		
		for i = 1, #parts do
			local success, result = pcall(function()
				return current:FindFirstChild(parts[i])
			end)
			
			if success and result then
				current = result
			else
				return false
			end
		end
		actual_path = current
	elseif typeof(path) == "Instance" then
		actual_path = path
	else
		return false
	end
	
	if not actual_path then
		return false
	end
	
	for i = 1, #active_paths do
		if active_paths[i] == actual_path then
			return true
		end
	end
	
	table_insert(active_paths, actual_path)
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
	include_filter = names
	table_clear(exclude_filter)
end

function ESP.set_exclude(names)
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
	config[key] = value
	
	if key == "fade_start" or key == "fade_end" then
		local fade_range = config.fade_end - config.fade_start
		fade_range_inv = fade_range > 0 and (1 / fade_range) or 1
	elseif key == "max_distance" then
		max_distance_sq = value * value
	end
end

function ESP.get_config(key)
	return config[key]
end

function ESP.start()
	if render_connection or update_connection then
		return
	end
	
	config.enabled = true
	frame_count = 0
	
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
	
	tracked_objects = {}
	render_data_size = 0
end

function ESP.get_tracked_count()
	local count = 0
	for _ in pairs(tracked_objects) do
		count = count + 1
	end
	return count
end

return ESP
