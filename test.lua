--!native
--!optimize 2

---- environment ----
local assert, typeof = assert, typeof
local pcall, pairs = pcall, pairs
local table_insert, table_remove, table_create, table_clear = table.insert, table.remove, table.create, table.clear
local string_format, string_lower, string_split = string.format, string.lower, string.split
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
	profiling = false,
	static_mode = false,
	auto_static_mode = true,
	static_threshold = 1000,
	
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
local SCAN_INTERVAL = 60
local DESCENDANTS_CACHE_TIME = 2
local STALE_THRESHOLD = 3
local OBJECTS_PER_FRAME = 8
local LOD_DISTANCE_CLOSE = 200
local LOD_DISTANCE_MEDIUM = 500

local SPATIAL_GRID_SIZE = 200
local STATIC_POSITION_UPDATE_INTERVAL = 300

---- variables ----
local tracked_objects = {}
local descendants_cache = {}
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

local config = deep_copy or function(t) return t end
local frame_count = 0
local fade_range_inv = 1

local update_queue = table_create(100)
local queue_index = 1

local spatial_grid = {}
local static_positions = {}
local current_chunks = table_create(9)
local is_static_mode_active = false

---- profiling ----
local profile_event_times = {
	model = 0,
	data = 0,
	local_calc = 0,
	render = 0,
}

local profile_function_times = {
	get_position = 0,
	get_descendants = 0,
	calc_bbox = 0,
	calc_corners = 0,
	get_health = 0,
	project_screen = 0,
}

local profile_counters = {
	tracked_objects = 0,
	rendered_objects = 0,
	cache_hits = 0,
	cache_misses = 0,
	active_chunks = 0,
	objects_in_chunks = 0,
}

---- cache pools ----
local parts_cache = table_create(100)
local corners_cache = table_create(8)

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

local function get_chunk_key(x: number, z: number): string
	local chunk_x = math_floor(x / SPATIAL_GRID_SIZE)
	local chunk_z = math_floor(z / SPATIAL_GRID_SIZE)
	return chunk_x .. "_" .. chunk_z
end

local function add_to_spatial_grid(obj_id: string, position: vector)
	local chunk_key = get_chunk_key(position.X, position.Z)
	
	if not spatial_grid[chunk_key] then
		spatial_grid[chunk_key] = {}
	end
	
	spatial_grid[chunk_key][obj_id] = true
	static_positions[obj_id] = {
		chunk_key = chunk_key,
		position = position,
		last_update = frame_count,
	}
end

local function remove_from_spatial_grid(obj_id: string)
	local data = static_positions[obj_id]
	if data then
		local chunk = spatial_grid[data.chunk_key]
		if chunk then
			chunk[obj_id] = nil
		end
		static_positions[obj_id] = nil
	end
end

local function get_nearby_chunks(cam_pos: vector): {string}
	local cam_chunk_x = math_floor(cam_pos.X / SPATIAL_GRID_SIZE)
	local cam_chunk_z = math_floor(cam_pos.Z / SPATIAL_GRID_SIZE)
	
	table_clear(current_chunks)
	local count = 0
	
	for dx = -1, 1 do
		for dz = -1, 1 do
			count = count + 1
			current_chunks[count] = (cam_chunk_x + dx) .. "_" .. (cam_chunk_z + dz)
		end
	end
	
	return current_chunks
end

local function get_all_parts(obj: Instance): {Instance}
	local prof_start = config.profiling and os_clock()
	
	table_clear(parts_cache)
	
	pcall(function()
		if not obj.Parent then return end
		
		local class_name = obj.ClassName
		
		if class_name:find("Part") then
			parts_cache[1] = obj
		elseif class_name == "Model" then
			local obj_id = tostring(obj)
			local cache_entry = descendants_cache[obj_id]
			
			if cache_entry and (os_clock() - cache_entry.time) < DESCENDANTS_CACHE_TIME then
				if config.profiling then
					profile_counters.cache_hits = profile_counters.cache_hits + 1
				end
				
				for i = 1, #cache_entry.parts do
					parts_cache[i] = cache_entry.parts[i]
				end
				return
			end
			
			if config.profiling then
				profile_counters.cache_misses = profile_counters.cache_misses + 1
			end
			
			local descendants = obj:GetDescendants()
			local count = 0
			local cached_parts = table_create(50)
			
			for i = 1, #descendants do
				local child = descendants[i]
				if child.Parent and child.ClassName:find("Part") then
					count = count + 1
					parts_cache[count] = child
					cached_parts[count] = child
				end
			end
			
			descendants_cache[obj_id] = {
				parts = cached_parts,
				time = os_clock(),
			}
		end
	end)
	
	if config.profiling then
		profile_function_times.get_descendants = profile_function_times.get_descendants + (os_clock() - prof_start)
	end
	
	return parts_cache
end

local function calculate_bounding_box(parts: {Instance}): (vector?, vector?)
	local prof_start = config.profiling and os_clock()
	
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
	
	if config.profiling then
		profile_function_times.calc_bbox = profile_function_times.calc_bbox + (os_clock() - prof_start)
	end
	
	if not found_any then
		return nil, nil
	end
	
	return vector_create(min_x, min_y, min_z), vector_create(max_x, max_y, max_z)
end

local function calculate_bounding_corners(min_bound: vector, max_bound: vector): {vector}
	local prof_start = config.profiling and os_clock()
	
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
	
	if config.profiling then
		profile_function_times.calc_corners = profile_function_times.calc_corners + (os_clock() - prof_start)
	end
	
	return corners_cache
end

local function project_corners_to_screen(corners: {vector}, cam: Instance): (vector?, vector?)
	local prof_start = config.profiling and os_clock()
	
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
	
	if config.profiling then
		profile_function_times.project_screen = profile_function_times.project_screen + (os_clock() - prof_start)
	end
	
	if not any_visible then
		return nil, nil
	end
	
	return vector_create(min_x, min_y, 0), vector_create(max_x, max_y, 0)
end

local function get_object_position(obj: Instance): vector?
	local prof_start = config.profiling and os_clock()
	
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
	
	if config.profiling then
		profile_function_times.get_position = profile_function_times.get_position + (os_clock() - prof_start)
	end
	
	return success and result or nil
end

local function get_object_health(obj: Instance): (number?, number?)
	local prof_start = config.profiling and os_clock()
	
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
	
	if config.profiling then
		profile_function_times.get_health = profile_function_times.get_health + (os_clock() - prof_start)
	end
	
	return success and health or nil, success and max_health or nil
end

local function scan_path(path: Instance)
	local success, descendants = pcall(function()
		return path:GetDescendants()
	end)
	
	if not success then return end
	
	for i = 1, #descendants do
		local obj = descendants[i]
		
		if should_track_object(obj) then
			local obj_id = tostring(obj)
			
			if not tracked_objects[obj_id] then
				local position = get_object_position(obj)
				
				if position then
					local obj_name
					pcall(function()
						obj_name = obj.Name
					end)
					
					tracked_objects[obj_id] = {
						object = obj,
						name = obj_name or "Unknown",
						last_seen = os_clock(),
					}
					
					if is_static_mode_active then
						add_to_spatial_grid(obj_id, position)
					end
				end
			else
				tracked_objects[obj_id].last_seen = os_clock()
			end
		end
	end
end

local function cleanup_stale_objects()
	local current_time = os_clock()
	
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
			descendants_cache[obj_id] = nil
			
			if is_static_mode_active then
				remove_from_spatial_grid(obj_id)
			end
		end
	end
end

local function check_and_toggle_static_mode()
	if not config.auto_static_mode then return end
	
	local count = 0
	for _ in pairs(tracked_objects) do
		count = count + 1
	end
	
	local should_be_static = count >= config.static_threshold
	
	if should_be_static ~= is_static_mode_active then
		is_static_mode_active = should_be_static
		
		if is_static_mode_active then
			print(string_format("[ESP] Static mode activated - %d objects tracked", count))
			
			table_clear(spatial_grid)
			table_clear(static_positions)
			
			for obj_id, data in pairs(tracked_objects) do
				local pos = get_object_position(data.object)
				if pos then
					add_to_spatial_grid(obj_id, pos)
				end
			end
		else
			print("[ESP] Static mode deactivated - returning to normal mode")
			table_clear(spatial_grid)
			table_clear(static_positions)
		end
	end
end

---- runtime ----
RunService.PostModel:Connect(function()
			print("[DEBUG] PostModel triggered - frame:", frame_count)

	if not config or not config.enabled then return end
	
	local prof_start = config.profiling and os_clock()
	
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
		check_and_toggle_static_mode()
	end
	
	if config.profiling then
		profile_event_times.model = os_clock() - prof_start
	end
end)

RunService.PostData:Connect(function()
			print("[DEBUG] PostData triggered - frame:", frame_count)

	if not config or not config.enabled then 
		print("[DEBUG] PostData skipped - config check failed")
		return 
	end
	
	local prof_start = config.profiling and os_clock()
	
	pcall(function()
		camera = workspace.CurrentCamera
		camera_position = camera and camera.Position
	end)
	
	if not camera or not camera_position then 
		print("[DEBUG] PostData skipped - no camera")
		return 
	end
	
	if is_static_mode_active or config.static_mode then
		local chunks = get_nearby_chunks(camera_position)
		local objects_checked = 0
		
		table_clear(physics_data)
		
		print(string_format("[DEBUG] Static mode - checking %d chunks", #chunks))
		
		for i = 1, #chunks do
			local chunk = spatial_grid[chunks[i]]
			if chunk then
				local chunk_count = 0
				for _ in pairs(chunk) do chunk_count = chunk_count + 1 end
				print(string_format("[DEBUG] Chunk %s has %d objects", chunks[i], chunk_count))
				
				for obj_id in pairs(chunk) do
					objects_checked = objects_checked + 1
					
					local data = tracked_objects[obj_id]
					local static_data = static_positions[obj_id]
					
					if data and static_data then
						pcall(function()
							local pos = static_data.position
							
							if frame_count - static_data.last_update > STATIC_POSITION_UPDATE_INTERVAL then
								local obj = data.object
								if obj and obj.Parent then
									local new_pos = get_object_position(obj)
									if new_pos then
										remove_from_spatial_grid(obj_id)
										add_to_spatial_grid(obj_id, new_pos)
										pos = new_pos
									end
								end
							end
							
							local dx = pos.X - camera_position.X
							local dy = pos.Y - camera_position.Y
							local dz = pos.Z - camera_position.Z
							local distance = math_sqrt(dx * dx + dy * dy + dz * dz)
							
							if distance <= config.max_distance then
								physics_data[obj_id] = {
									name = data.name,
									position = pos,
									distance = distance,
								}
								
								if config.box_esp then
									local obj = data.object
									if obj and obj.Parent then
										if not static_data.corners or (frame_count - static_data.last_update) > STATIC_POSITION_UPDATE_INTERVAL then
											local parts = get_all_parts(obj)
											local min_bound, max_bound = calculate_bounding_box(parts)
											
											if min_bound and max_bound then
												local corners = calculate_bounding_corners(min_bound, max_bound)
												static_data.corners = table_create(8)
												for j = 1, 8 do
													static_data.corners[j] = corners[j]
												end
												physics_data[obj_id].corners = static_data.corners
											end
										else
											physics_data[obj_id].corners = static_data.corners
										end
									end
								end
								
								if config.health_bar then
									local obj = data.object
									if obj and obj.Parent then
										physics_data[obj_id].health, physics_data[obj_id].max_health = get_object_health(obj)
									end
								end
							end
						end)
					end
				end
			else
				print(string_format("[DEBUG] Chunk %s is empty", chunks[i]))
			end
		end
		
		print(string_format("[DEBUG] Static mode processed %d objects, %d in physics_data", objects_checked, 
			(function() local c = 0 for _ in pairs(physics_data) do c = c + 1 end return c end)()
		))
		
		if config.profiling then
			profile_counters.active_chunks = #chunks
			profile_counters.objects_in_chunks = objects_checked
		end
	else
		-- Normal mode unchanged...
		for obj_id, data in pairs(tracked_objects) do
			pcall(function()
				local obj = data.object
				if not obj or not obj.Parent or should_exclude_object(obj) then return end
				
				local pos = get_object_position(obj)
				if not pos then return end
				
				local dx = pos.X - camera_position.X
				local dy = pos.Y - camera_position.Y
				local dz = pos.Z - camera_position.Z
				local distance = math_sqrt(dx * dx + dy * dy + dz * dz)
				
				if distance > config.max_distance then return end
				
				if not physics_data[obj_id] then
					physics_data[obj_id] = {}
				end
				
				local phys = physics_data[obj_id]
				phys.name = data.name
				phys.position = pos
				phys.distance = distance
				
				if config.health_bar then
					phys.health, phys.max_health = get_object_health(obj)
				end
			end)
		end
		
		if frame_count % 5 == 0 then
			table_clear(update_queue)
			local idx = 0
			for obj_id in pairs(tracked_objects) do
				idx = idx + 1
				update_queue[idx] = obj_id
			end
			queue_index = 1
		end
		
		local processed = 0
		while processed < OBJECTS_PER_FRAME and queue_index <= #update_queue do
			local obj_id = update_queue[queue_index]
			queue_index = queue_index + 1
			
			local data = tracked_objects[obj_id]
			local phys = physics_data[obj_id]
			
			if data and phys and config.box_esp then
				pcall(function()
					local obj = data.object
					if not obj or not obj.Parent then return end
					
					local parts = get_all_parts(obj)
					local min_bound, max_bound = calculate_bounding_box(parts)
					
					if min_bound and max_bound then
						phys.corners = calculate_bounding_corners(min_bound, max_bound)
					end
				end)
			end
			
			processed = processed + 1
		end
	end
	
	table_clear(sorted_physics)
	sorted_count = 0
	
	for obj_id, phys in pairs(physics_data) do
		if phys.position then
			sorted_count = sorted_count + 1
			sorted_physics[sorted_count] = phys
		end
	end
	
	table.sort(sorted_physics, function(a, b)
		return a.distance < b.distance
	end)
	
	print(string_format("[DEBUG] PostData finished - sorted_count: %d", sorted_count))
	
	if config.profiling then
		profile_counters.tracked_objects = sorted_count
		profile_event_times.data = os_clock() - prof_start
	end
end)


RunService.PostLocal:Connect(function()
	if not config or not config.enabled or not camera then return end
	
	local prof_start = config.profiling and os_clock()
	
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
			
			render_data_size = render_data_size + 1
			
			if not render_data[render_data_size] then
				render_data[render_data_size] = {
					last_distance = -1,
					cached_text = "",
				}
			end
			
			local rd = render_data[render_data_size]
			local screen_x, screen_y = screen.X, screen.Y
			local distance = phys.distance
			
			rd.screen_pos = vector_create(screen_x, screen_y, 0)
			rd.fade_opacity = fade_opacity
			rd.distance = distance
			
			local is_close = distance < LOD_DISTANCE_CLOSE
			local is_medium = distance < LOD_DISTANCE_MEDIUM
			
			if config.box_esp and phys.corners then
				local box_min, box_max = project_corners_to_screen(phys.corners, camera)
				if box_min and box_max then
					rd.box_min = box_min
					rd.box_size = box_max - box_min
				else
					rd.box_min = nil
				end
			else
				rd.box_min = nil
			end
			
			local y_offset = 0
			if config.name_esp then
				local dist_floored = math_floor(distance)
				
				if dist_floored ~= rd.last_distance then
					rd.last_distance = dist_floored
					if config.distance_esp and is_medium then
						rd.cached_text = phys.name .. " [" .. dist_floored .. "m]"
					else
						rd.cached_text = phys.name
					end
				end
				
				rd.name_text = rd.cached_text
				rd.name_pos = vector_create(screen_x, screen_y - y_offset, 0)
				y_offset = y_offset + config.font_size + 2
			else
				rd.name_text = nil
			end
			
			if config.health_bar and is_medium and phys.health and phys.max_health and phys.max_health > 0 then
				local bar_width = is_close and 100 or 60
				local bar_height = 4
				local health_percent = phys.health / phys.max_health
				
				rd.bar_enabled = true
				rd.bar_pos = vector_create(screen_x - bar_width * 0.5, screen_y - y_offset, 0)
				rd.bar_bg_size = vector_create(bar_width, bar_height, 0)
				rd.bar_fill_size = vector_create(bar_width * health_percent, bar_height, 0)
				rd.bar_opacity_bg = is_close and 0.8 or 0.6
				rd.bar_opacity_fill = is_close and 0.9 or 0.7
			else
				rd.bar_enabled = false
			end
			
			rd.draw_tracer = config.tracers and is_medium
		end)
	end
	
	if config.profiling then
		profile_counters.rendered_objects = render_data_size
		profile_event_times.local_calc = os_clock() - prof_start
	end
end)

RunService.Render:Connect(function()
	if not config or not config.enabled or not viewport_size or not screen_center then return end
	
	local prof_start = config.profiling and os_clock()
	
	-- DEBUG: Print every 60 frames
	if frame_count % 60 == 0 and config.profiling then
		print(string_format("[DEBUG] Render data size: %d, Sorted count: %d, Physics data count: %d", 
			render_data_size, sorted_count, 
			(function() local c = 0 for _ in pairs(physics_data) do c = c + 1 end return c end)()
		))
	end
	
	for i = 1, render_data_size do
		local data = render_data[i]
		if not data then break end
		
		local fade = data.fade_opacity
		
		if config.box_esp and data.box_min then
			DrawingImmediate.Rectangle(
				data.box_min,
				data.box_size,
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
		
		if data.bar_enabled then
			DrawingImmediate.FilledRectangle(
				data.bar_pos,
				data.bar_bg_size,
				Color3.new(0.2, 0.2, 0.2),
				data.bar_opacity_bg * fade
			)
			
			DrawingImmediate.FilledRectangle(
				data.bar_pos,
				data.bar_fill_size,
				config.health_bar_color,
				data.bar_opacity_fill * fade
			)
		end
		
		if data.draw_tracer then
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
	
	if config.profiling then
		profile_event_times.render = os_clock() - prof_start
		
		if frame_count % 60 == 0 then
			print(string_format("\n==== ESP Performance Report ===="))
			print(string_format("Mode: %s", is_static_mode_active and "STATIC" or "NORMAL"))
			
			print(string_format("\nEvents:"))
			print(string_format("  Model:  %.4fms", profile_event_times.model * 1000))
			print(string_format("  Data:   %.4fms", profile_event_times.data * 1000))
			print(string_format("  Local:  %.4fms", profile_event_times.local_calc * 1000))
			print(string_format("  Render: %.4fms", profile_event_times.render * 1000))
			
			print(string_format("\nFunctions:"))
			print(string_format("  GetPosition:    %.4fms", profile_function_times.get_position * 1000))
			print(string_format("  GetDescendants: %.4fms", profile_function_times.get_descendants * 1000))
			print(string_format("  CalcBBox:       %.4fms", profile_function_times.calc_bbox * 1000))
			print(string_format("  CalcCorners:    %.4fms", profile_function_times.calc_corners * 1000))
			print(string_format("  ProjectScreen:  %.4fms", profile_function_times.project_screen * 1000))
			print(string_format("  GetHealth:      %.4fms", profile_function_times.get_health * 1000))
			
			print(string_format("\nStats:"))
			print(string_format("  Tracked:  %d", profile_counters.tracked_objects))
			print(string_format("  Rendered: %d", profile_counters.rendered_objects))
			
			if is_static_mode_active then
				print(string_format("  Active Chunks: %d", profile_counters.active_chunks))
				print(string_format("  Objects in Chunks: %d", profile_counters.objects_in_chunks))
			end
			
			print(string_format("  Cache Hits:   %d", profile_counters.cache_hits))
			print(string_format("  Cache Misses: %d", profile_counters.cache_misses))
			print(string_format("================================\n"))
			
			for k in pairs(profile_function_times) do
				profile_function_times[k] = 0
			end
			profile_counters.cache_hits = 0
			profile_counters.cache_misses = 0
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
	
	if config.static_mode then
		is_static_mode_active = true
	end
	
	update_local_player()
	
	print(string_format("[ESP] Initialized - Profiling: %s", config.profiling and "ENABLED" or "DISABLED"))
	
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
	print(string_format("[ESP] Added path: %s", tostring(actual_path)))
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
	elseif key == "static_mode" then
		is_static_mode_active = value
		if value then
			print("[ESP] Static mode manually enabled")
		else
			print("[ESP] Static mode manually disabled")
		end
	end
end

function ESP.get_config(key: string): any
	return config[key]
end

function ESP.enable_profiling(enabled: boolean)
	config.profiling = enabled
	print(string_format("[ESP] Profiling: %s", enabled and "ENABLED" or "DISABLED"))
end

function ESP.is_static_mode(): boolean
	return is_static_mode_active
end

function ESP.start()
	config.enabled = true
	frame_count = 0
	print("[ESP] Started")
end

function ESP.stop()
	config.enabled = false
	tracked_objects = {}
	physics_data = {}
	descendants_cache = {}
	spatial_grid = {}
	static_positions = {}
	sorted_count = 0
	render_data_size = 0
	is_static_mode_active = false
	print("[ESP] Stopped")
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
