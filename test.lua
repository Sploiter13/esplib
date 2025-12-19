--!native
--!optimize 2

---- environment ----
local assert, typeof = assert, typeof
local pcall, pairs = pcall, pairs
local table_insert, table_remove, table_create, table_clear = table.insert, table.remove, table.create, table.clear
local string_lower, string_split = string.lower, string.split
local math_floor, math_sqrt, math_min, math_max = math.floor, math.sqrt, math.min, math.max
local math_huge = math.huge
local vector_create = vector.create

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
	exclude_players = false,
	auto_exclude_localplayer = true,
	name_color = Color3.new(1, 1, 1),
	box_color = Color3.new(1, 0, 0),
	tracer_color = Color3.new(0, 1, 0),
	health_bar_color = Color3.new(0, 1, 0),
	max_distance = 1000,
	max_render_objects = 200,
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

local PART_NAMES = {"HumanoidRootPart", "Head", "UpperTorso", "Torso"}
local SCAN_INTERVAL = 30
local BBOX_UPDATE_INTERVAL = 3
local STALE_THRESHOLD = 2

---- variables ----
local tracked_objects = {}
local physics_data = {}
local sorted_physics = table_create(200)
local sorted_count = 0

local render_data = table_create(200)
local render_data_size = 0

local active_paths = table_create(10)
local include_filter = nil
local exclude_filter = table_create(10)

local camera = nil
local camera_position = nil
local viewport_size = nil
local screen_center = nil

local local_player = nil
local local_character = nil

local config = {}
local frame_count = 0
local fade_range_inv = 1

---- cache pools ----
local parts_cache = table_create(50)

---- functions ----
local function deep_copy(tbl: {[any]: any}): {[any]: any}
	local copy = table_create(10)
	for k, v in pairs(tbl) do
		copy[k] = typeof(v) == "table" and deep_copy(v) or v
	end
	return copy
end

local function calculate_fade_opacity(distance: number): number
	if not config.fade_enabled or distance <= config.fade_start then
		return 1
	elseif distance >= config.fade_end then
		return 0
	end
	
	return 1 - ((distance - config.fade_start) * fade_range_inv)
end

local function update_local_player()
	pcall(function()
		local_player = Players.LocalPlayer
		local_character = local_player and local_player.Character
	end)
end

local function is_player_character(obj: Instance): boolean
	if not obj or obj.ClassName ~= "Model" then
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

local function should_exclude_object(obj: Instance): boolean
	if config.auto_exclude_localplayer and obj == local_character then
		return true
	end
	
	if config.exclude_players and is_player_character(obj) then
		return true
	end
	
	return false
end

local function should_track_object(obj: Instance): boolean
	if should_exclude_object(obj) then
		return false
	end
	
	local success, obj_name = pcall(function()
		return string_lower(obj.Name)
	end)
	
	if not success then
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

local function get_all_parts(obj: Instance): {Instance}
	table_clear(parts_cache)
	
	pcall(function()
		if not obj.Parent then return end
		
		local class_name = obj.ClassName
		
		if class_name:find("Part") then
			parts_cache = obj[1]
		elseif class_name == "Model" then
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

local function calculate_bounding_box(parts: {Instance}): (vector?, vector?)
	if #parts == 0 then
		return nil, nil
	end
	
	local min_x, min_y, min_z = math_huge, math_huge, math_huge
	local max_x, max_y, max_z = -math_huge, -math_huge, -math_huge
	local found_any = false
	
	for i = 1, #parts do
		pcall(function()
			local part = parts[i]
			if not part.Parent then return end
			
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
			
			found_any = true
		end)
	end
	
	if not found_any then
		return nil, nil
	end
	
	return vector_create(min_x, min_y, min_z), vector_create(max_x, max_y, max_z)
end

local function calculate_bounding_corners(min_bound: vector, max_bound: vector): {vector}
	local mnx, mny, mnz = min_bound.X, min_bound.Y, min_bound.Z
	local mxx, mxy, mxz = max_bound.X, max_bound.Y, max_bound.Z
	
	return {
		vector_create(mnx, mny, mnz),
		vector_create(mxx, mny, mnz),
		vector_create(mxx, mny, mxz),
		vector_create(mnx, mny, mxz),
		vector_create(mnx, mxy, mnz),
		vector_create(mxx, mxy, mnz),
		vector_create(mxx, mxy, mxz),
		vector_create(mnx, mxy, mxz),
	}
end

local function project_corners_to_screen(corners: {vector}, cam: Instance): (vector?, vector?)
	local min_x, min_y = math_huge, math_huge
	local max_x, max_y = -math_huge, -math_huge
	local any_visible = false
	
	pcall(function()
		for i = 1, 8 do
			local screen_pos, visible = cam:WorldToScreenPoint(corners[i])
			if visible then
				any_visible = true
				local sx, sy = screen_pos.X, screen_pos.Y
				min_x = math_min(min_x, sx)
				min_y = math_min(min_y, sy)
				max_x = math_max(max_x, sx)
				max_y = math_max(max_y, sy)
			end
		end
	end)
	
	if not any_visible then
		return nil, nil
	end
	
	return vector_create(min_x, min_y, 0), vector_create(max_x, max_y, 0)
end

local function get_object_position(obj: Instance): vector?
	local success, result = pcall(function()
		if not obj.Parent then return nil end
		
		if obj.ClassName == "Model" then
			local primary = obj.PrimaryPart
			if primary and primary.Parent then
				return primary.Position
			end
			
			for i = 1, #PART_NAMES do
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

local function get_object_health(obj: Instance): (number?, number?)
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

local function scan_path(path: Instance)
	local success, children = pcall(function()
		return path:GetChildren()
	end)
	
	if not success then return end
	
	for i = 1, #children do
		local obj = children[i]
		
		if should_track_object(obj) then
			local obj_id = tostring(obj)
			
			if not tracked_objects[obj_id] then
				local position = get_object_position(obj)
				
				if position then
					local obj_name
					pcall(function()
						obj_name = obj.Name
					end)
					
					local parts = get_all_parts(obj)
					local parts_copy = table_create(#parts_cache)
					
					for j = 1, #parts_cache do
						parts_copy[j] = parts_cache[j]
					end
					
					tracked_objects[obj_id] = {
						object = obj,
						name = obj_name or "Unknown",
						parts = parts_copy,
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
	
	for obj_id, data in pairs(tracked_objects) do
		local should_remove = (current_time - data.last_seen) > STALE_THRESHOLD
		
		pcall(function()
			if not data.object or not data.object.Parent then
				should_remove = true
			end
		end)
		
		if should_remove then
			tracked_objects[obj_id] = nil
			physics_data[obj_id] = nil
		end
	end
end

---- runtime ----

RunService.PostModel:Connect(function()
	if not config.enabled then return end
	
	frame_count = frame_count + 1
	
	update_local_player()
	
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
end)

RunService.PostData:Connect(function()
	if not config.enabled then return end
	
	pcall(function()
		camera = workspace.CurrentCamera
		camera_position = camera and camera.Position
	end)
	
	if not camera or not camera_position then return end
	
	table_clear(sorted_physics)
	sorted_count = 0
	
	for obj_id, data in pairs(tracked_objects) do
		pcall(function()
			local obj = data.object
			if not obj or not obj.Parent or should_exclude_object(obj) then return end
			
			local pos = get_object_position(obj)
			if not pos then return end
			
			if frame_count % BBOX_UPDATE_INTERVAL == 0 then
				local parts = get_all_parts(obj)
				table_clear(data.parts)
				
				for i = 1, #parts_cache do
					data.parts[i] = parts_cache[i]
				end
			end
			
			local dx = pos.X - camera_position.X
			local dy = pos.Y - camera_position.Y
			local dz = pos.Z - camera_position.Z
			local distance = math_sqrt(dx * dx + dy * dy + dz * dz)
			
			if distance > config.max_distance then return end
			
			local corners = nil
			if config.box_esp and frame_count % BBOX_UPDATE_INTERVAL == 0 then
				local min_bound, max_bound = calculate_bounding_box(data.parts)
				if min_bound and max_bound then
					corners = calculate_bounding_corners(min_bound, max_bound)
				end
			end
			
			local health, max_health = nil, nil
			if config.health_bar then
				health, max_health = get_object_health(obj)
			end
			
			if not physics_data[obj_id] then
				physics_data[obj_id] = {}
			end
			
			local phys = physics_data[obj_id]
			phys.name = data.name
			phys.position = pos
			phys.distance = distance
			phys.health = health
			phys.max_health = max_health
			
			if corners then
				phys.corners = corners
			end
			
			sorted_count = sorted_count + 1
			sorted_physics[sorted_count] = phys
		end)
	end
	
	table.sort(sorted_physics, function(a, b)
		return a.distance < b.distance
	end)
end)

RunService.PostLocal:Connect(function()
	if not config.enabled or not camera then return end
	
	pcall(function()
		viewport_size = camera.ViewportSize
		screen_center = vector_create(viewport_size.X * 0.5, viewport_size.Y * 0.5, 0)
	end)
	
	if not viewport_size then return end
	
	render_data_size = 0
	local max_render = math_min(sorted_count, config.max_render_objects)
	
	for i = 1, max_render do
		local phys = sorted_physics[i]
		if not phys then break end
		
		pcall(function()
			local screen, visible = camera:WorldToScreenPoint(phys.position)
			if not visible then return end
			
			local fade_opacity = calculate_fade_opacity(phys.distance)
			if fade_opacity <= 0 then return end
			
			local box_min, box_max = nil, nil
			if config.box_esp and phys.corners then
				box_min, box_max = project_corners_to_screen(phys.corners, camera)
			end
			
			render_data_size = render_data_size + 1
			
			if not render_data[render_data_size] then
				render_data[render_data_size] = {}
			end
			
			local rd = render_data[render_data_size]
			rd.name = phys.name
			rd.screen_pos = vector_create(screen.X, screen.Y, 0)
			rd.distance = phys.distance
			rd.fade_opacity = fade_opacity
			rd.box_min = box_min
			rd.box_max = box_max
			rd.health = phys.health
			rd.max_health = phys.max_health
			
			-- Pre-calculate ALL drawing positions and text
			local y_offset = 0
			
			if config.name_esp then
				local name_text = phys.name
				if config.distance_esp then
					name_text = name_text .. " [" .. math_floor(phys.distance) .. "m]"
				end
				rd.name_text = name_text
				rd.name_pos = rd.screen_pos - vector_create(0, y_offset, 0)
				y_offset = y_offset + config.font_size + 2
			else
				rd.name_text = nil
			end
			
			if config.health_bar and phys.health and phys.max_health and phys.max_health > 0 then
				local bar_width = 100
				local bar_height = 4
				local health_percent = phys.health / phys.max_health
				
				rd.bar_pos = rd.screen_pos - vector_create(bar_width * 0.5, y_offset, 0)
				rd.bar_bg_size = vector_create(bar_width, bar_height, 0)
				rd.bar_fill_size = vector_create(bar_width * health_percent, bar_height, 0)
				y_offset = y_offset + bar_height + 4
			else
				rd.bar_pos = nil
			end
		end)
	end
end)

RunService.Render:Connect(function()
	if not config.enabled or not viewport_size or not screen_center then return end
	
	for i = 1, render_data_size do
		local data = render_data[i]
		if not data then break end
		
		local fade = data.fade_opacity
		
		if config.box_esp and data.box_min and data.box_max then
			DrawingImmediate.Rectangle(
				data.box_min,
				data.box_max - data.box_min,
				config.box_color,
				config.box_opacity * fade,
				config.box_thickness
			)
		end
		
		if config.name_esp and data.name_text then
			DrawingImmediate.OutlinedText(
				data.name_pos,
				config.font_size,
				config.name_color,
				config.name_opacity * fade,
				data.name_text,
				true,
				config.font
			)
		end
		
		if config.health_bar and data.bar_pos then
			DrawingImmediate.FilledRectangle(
				data.bar_pos,
				data.bar_bg_size,
				Color3.new(0.2, 0.2, 0.2),
				0.8 * fade
			)
			
			DrawingImmediate.FilledRectangle(
				data.bar_pos,
				data.bar_fill_size,
				config.health_bar_color,
				0.9 * fade
			)
		end
		
		if config.tracers then
			DrawingImmediate.Line(
				screen_center,
				data.screen_pos,
				config.tracer_color,
				config.tracer_opacity * fade,
				1,
				config.tracer_thickness
			)
		end
	end
end)

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
	
	local fade_range = config.fade_end - config.fade_start
	fade_range_inv = fade_range > 0 and (1 / fade_range) or 1
	
	update_local_player()
	
	return ESP
end

function ESP.add_path(path: Instance | string): boolean
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

function ESP.remove_path(path: Instance | string): boolean
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

function ESP.set_include(names: {string})
	assert(typeof(names) == "table", "invalid argument #1 (table expected)")
	include_filter = names
	table_clear(exclude_filter)
end

function ESP.set_exclude(names: {string})
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

function ESP.set_config(key: string, value: any)
	config[key] = value
	
	if key == "fade_start" or key == "fade_end" then
		local fade_range = config.fade_end - config.fade_start
		fade_range_inv = fade_range > 0 and (1 / fade_range) or 1
	end
end

function ESP.get_config(key: string): any
	return config[key]
end

function ESP.start()
	config.enabled = true
	frame_count = 0
end

function ESP.stop()
	config.enabled = false
	tracked_objects = {}
	physics_data = {}
	sorted_count = 0
	render_data_size = 0
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
