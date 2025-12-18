--!native
--!optimize 2

---- environment ----
local typeof, pcall, pairs, ipairs = typeof, pcall, pairs, ipairs
local table_insert, table_create, table_clear = table.insert, table.create, table.clear
local string_lower, string_split = string.lower, string.split
local math_floor, math_sqrt, math_min, math_max = math.floor, math.sqrt, math.min, math.max
local math_huge = math.huge
local vector_create = vector.create
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
	box_esp = false,
	health_bar = false,
	tracers = false,
	static_objects = true,
	
	exclude_players = false,
	auto_exclude_localplayer = true,
	
	name_color = Color3.new(1, 1, 1),
	box_color = Color3.new(1, 0, 0),
	tracer_color = Color3.new(0, 1, 0),
	health_bar_color = Color3.new(0, 1, 0),
	
	max_distance = 500,
	font_size = 14,
	font = "Tamzen",
	box_thickness = 2,
	tracer_thickness = 1,
	
	name_opacity = 1,
	box_opacity = 0.8,
	tracer_opacity = 0.6,
	
	fade_enabled = true,
	fade_start = 250,
	fade_end = 500,
	
	-- Performance
	max_render_objects = 200,
	batch_size = 300,
}

local PART_NAMES = {"HumanoidRootPart", "Head", "Torso", "UpperTorso"}
local SCAN_INTERVAL = 120
local CHUNK_SIZE = 256

---- variables ----
local tracked_objects = {}
local spatial_chunks = {}
local render_data = table_create(200)
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
local max_distance_sq = 250000
local process_index = 0
local all_object_ids = table_create(10000)
local object_ids_count = 0

---- cache ----
local parts_cache = table_create(20)
local corners_cache = table_create(8)
local nearby_objects = table_create(500)
local WorldToScreenPoint = nil

---- functions ----
local function deep_copy(tbl)
	local copy = table_create(10)
	for k, v in pairs(tbl) do
		copy[k] = typeof(v) == "table" and deep_copy(v) or v
	end
	return copy
end

local function get_chunk_key(pos)
	return math_floor(pos.X / CHUNK_SIZE) .. "_" .. math_floor(pos.Z / CHUNK_SIZE)
end

local function get_nearby_chunk_keys(pos, radius)
	local keys = table_create(9)
	local count = 0
	local chunk_radius = math_floor(radius / CHUNK_SIZE) + 1
	local center_x = math_floor(pos.X / CHUNK_SIZE)
	local center_z = math_floor(pos.Z / CHUNK_SIZE)
	
	for x = center_x - chunk_radius, center_x + chunk_radius do
		for z = center_z - chunk_radius, center_z + chunk_radius do
			count = count + 1
			keys[count] = x .. "_" .. z
		end
	end
	
	return keys, count
end

local function calculate_distance_sq_fast(pos)
	local dx = pos.X - camera_position.X
	local dy = pos.Y - camera_position.Y
	local dz = pos.Z - camera_position.Z
	return dx * dx + dy * dy + dz * dz
end

local function calculate_fade_opacity_inline(distance_sq)
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
	pcall(function()
		local_player = Players.LocalPlayer
		if local_player then
			local_character = local_player.Character
		end
	end)
end

local function should_track_object(obj)
	if config.auto_exclude_localplayer and obj == local_character then
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
				if part and part.Parent then
					return part.Position
				end
			end
			
			local children = obj:GetChildren()
			for i = 1, #children do
				if children[i].Parent and children[i].ClassName:find("Part") then
					return children[i].Position
				end
			end
		elseif obj.ClassName:find("Part") then
			return obj.Position
		end
		
		return nil
	end)
	
	return success and result or nil
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
					local obj_name = "Unknown"
					pcall(function()
						obj_name = obj.Name
					end)
					
					local chunk_key = get_chunk_key(position)
					
					tracked_objects[obj_id] = {
						object = obj,
						name = obj_name,
						position = position,
						chunk_key = chunk_key,
						last_seen = now,
					}
					
					if not spatial_chunks[chunk_key] then
						spatial_chunks[chunk_key] = table_create(100)
					end
					table_insert(spatial_chunks[chunk_key], obj_id)
					
					object_ids_count = object_ids_count + 1
					all_object_ids[object_ids_count] = obj_id
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
		if (current_time - data.last_seen) > 5 then
			tracked_objects[obj_id] = nil
			
			if data.chunk_key and spatial_chunks[data.chunk_key] then
				local chunk = spatial_chunks[data.chunk_key]
				for i = 1, #chunk do
					if chunk[i] == obj_id then
						table.remove(chunk, i)
						break
					end
				end
			end
		end
	end
	
	table_clear(all_object_ids)
	object_ids_count = 0
	for obj_id in pairs(tracked_objects) do
		object_ids_count = object_ids_count + 1
		all_object_ids[object_ids_count] = obj_id
	end
end

local function update_loop()
	if not config.enabled then
		return
	end
	
	frame_count = frame_count + 1
	
	pcall(function()
		camera = workspace.CurrentCamera
		if camera then
			camera_position = camera.CFrame.Position
			viewport_size = camera.ViewportSize
			screen_center = vector_create(viewport_size.X * 0.5, viewport_size.Y * 0.5, 0)
			WorldToScreenPoint = camera.WorldToScreenPoint
		end
	end)
	
	if not camera then
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
	
	local chunk_keys, chunk_count = get_nearby_chunk_keys(camera_position, config.max_distance)
	table_clear(nearby_objects)
	local nearby_count = 0
	
	for i = 1, chunk_count do
		local chunk = spatial_chunks[chunk_keys[i]]
		if chunk then
			for j = 1, #chunk do
				nearby_count = nearby_count + 1
				nearby_objects[nearby_count] = chunk[j]
			end
		end
	end
	
	local batch_start = process_index
	local batch_end = math_min(process_index + config.batch_size, nearby_count)
	
	for i = batch_start + 1, batch_end do
		local obj_id = nearby_objects[i]
		local data = tracked_objects[obj_id]
		
		if data then
			pcall(function()
				local obj = data.object
				if not obj or not obj.Parent then
					return
				end
				
				local pos = data.position
				local distance_sq = calculate_distance_sq_fast(pos)
				
				if distance_sq > max_distance_sq then
					return
				end
				
				if render_data_size >= config.max_render_objects then
					return
				end
				
				local screen, visible = WorldToScreenPoint(camera, pos)
				
				if not visible then
					return
				end
				
				local fade_opacity = calculate_fade_opacity_inline(distance_sq)
				
				if fade_opacity <= 0 then
					return
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
			end)
		end
	end
	
	process_index = batch_end
	if process_index >= nearby_count then
		process_index = 0
	end
end

local function render_loop()
	if not config.enabled or not screen_center then
		return
	end
	
	local name_enabled = config.name_esp
	local distance_enabled = config.distance_esp
	local tracers_enabled = config.tracers
	
	local name_color = config.name_color
	local name_opacity = config.name_opacity
	local font_size = config.font_size
	local font = config.font
	
	local tracer_color = config.tracer_color
	local tracer_opacity = config.tracer_opacity
	local tracer_thickness = config.tracer_thickness
	
	for i = 1, render_data_size do
		local data = render_data[i]
		local screen_pos = data.screen_pos
		local fade_opacity = data.fade_opacity
		
		if name_enabled then
			local name_text = distance_enabled 
				and data.name .. " [" .. math_floor(data.distance) .. "m]" 
				or data.name
			
			DrawingImmediate.OutlinedText(
				screen_pos,
				font_size,
				name_color,
				name_opacity * fade_opacity,
				name_text,
				true,
				font
			)
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
			table.remove(active_paths, i)
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
	spatial_chunks = {}
	render_data_size = 0
end

function ESP.get_tracked_count()
	return object_ids_count
end

return ESP
