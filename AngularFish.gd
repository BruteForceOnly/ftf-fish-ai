extends KinematicBody2D

var death_anim_r = preload("res://DeadFishRight.tscn")

const MODE_REST = 5
const MODE_GOING_HOME = 4
const MODE_DETECTED_FOOD = 3
const MODE_AVOIDANCE = 2
const MODE_SWARM = 1
const MODE_RANDOM_MOVE = 0

#distance to feel safe from predators
const COMFORTABLE_DIST_PREDATORS = 200

#hunger and tiredness
const ENERGY_HIGH = 60
const ENERGY_MED = 40
const ENERGY_LOW = 20
const ENERGY_VLOW = 10
const SATIATION_LOW = 20

var my_id = ""
var is_alive = true

var current_mode = MODE_RANDOM_MOVE
var neighbours = {}
var predators = {}
var food = {}
var cover_areas = {}

var mode_locked = false
var targetting_locked = false

#fish cannot determine its own movement
var disabled = false
#fish is resting
var resting = false
var want_to_rest = false
#fish feeling restless
var feeling_restless = false
var restless_dest_set = false
#fish was caught by predator
var caught = false
#fish is hidden by the terrain
var hidden = false
var hiding_depth = 0

var velocity = Vector2()
var target_pos
export var max_speed = 150
#var speed = 200
export var max_energy = 100
var energy = 50

var poop_counter = 0
var poop_amount = 20

#energy recovered by resting is capped by satiation
var max_satiation = 100
var satiation = 50

#some things are affected by the fish's size
#newly hatched fish starts at -1
var fish_size = -1

#for keeping a comfortable distance away from other fish
var fish_radius

var food_in_mouth = {}
var chewing = false

#object you collided with in the most recent collision
#variable is reset when the ResumeActionTimer expires
var prev_collider

#to remember the direction in which you should flee
var flee_destination = Vector2()

#for limiting calls to calculate_target()
var time_of_last_target_change = 0


# Called when the node enters the scene tree for the first time.
func _ready():
	add_to_group("fish")
	add_to_group("angufish")
	
	$EIPivot/ResourceNotifier.setup(Constants.RESOURCES_GENERATED_ANGULARFISH)
	
	scale_body_parts(1 + (0.25 * fish_size) )
	#bigger fish are drawn behind smaller fish
	set_z_index(Constants.Z_INDEX_ANGULAR - fish_size)
	
	#set defaults
	target_pos = self.position
	current_mode = MODE_RANDOM_MOVE
	
	#for random action resume times
	randomize()


#for positioning fish before they are added to the scene
func teleport_to(x,y):
	target_pos = Vector2(x,y)
	position = Vector2(x,y)

func temp_disable(base_time_seconds):
	disabled = true
	
	#visual indication of confusion
	$Sprite.flip_v = not($Sprite.flip_v)
	#actions resume after random amount of time
	$ResumeActionTimer.start( base_time_seconds + ((randi() % 4) * 0.1) )

func _on_ResumeActionTimer_timeout():
	if not caught:
		disabled = false
	
	#reset behaviours
	mode_locked = false
	targetting_locked = false
	resting = false
	feeling_restless = false
	
	#reset record of previous collision
	prev_collider = null



# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	#fish dies of starvation
	if satiation <= 0:
		Globals.num_deaths_starvation += 1
		die()
	
	#visual update of energy indicator
	var updatedEIText = str(floor(energy))
	$EIPivot/EnergyIndicator.text = updatedEIText
	
	#handle visual sprite flipping
	if not disabled:
		#rotate to face target
		look_at(target_pos)
		
		#handle sprite flipping
		if (target_pos.x - position.x) < 0:
			$Sprite.flip_v = true
			$EIPivot.scale.y = -1
			$EIPivot.scale.x = -1
		elif (target_pos.x - position.x) > 0:
			$Sprite.flip_v = false
			$EIPivot.scale.y = 1
			$EIPivot.scale.x = 1
		
	
	#passive behaviours (that don't require calculations)
	#struggle animation
	if caught:
		if $AnimationPlayer.get_current_animation() != "struggle":
			$AnimationPlayer.stop()
			$AnimationPlayer.play("struggle")
	#eat when you have food in range
	elif not food_in_mouth.empty():
		if not chewing and not disabled:#$ChewingTimer.is_stopped():
			$ChewingTimer.start()
			chewing = true
			eat_food_in_mouth()
			if $AnimationPlayer.get_current_animation() != "eat":
				$AnimationPlayer.stop()
				$AnimationPlayer.play("eat")
			
	#default animation
	else:
		if (not $AnimationPlayer.is_playing() ):
			$AnimationPlayer.play("swim")
		
	
	
	#adjust speed based on energy remaining
	var speed = calc_speed()
	
	if disabled:
		#let outside forces determine movement
		#simulate drag force from water
		velocity = velocity / (1 + (3 * delta))
	elif position.distance_squared_to(target_pos) > 25:
		#try to move towards your target
		velocity = (target_pos - position).normalized() * speed
	else:
		#you've reached the target so stop
		velocity = Vector2()
	
	
	var collision = move_and_collide(velocity * delta)
	
	#movement takes energy; resting recovers energy
	calc_energy(delta)
	
	#deal with hunger
	var main_node = get_tree().get_root().get_node("Main")
	if main_node.game_mode == Constants.GAME_MODE_SURVIVAL:
		calc_satiation(delta)
	elif main_node.game_mode == Constants.GAME_MODE_SCREENSAVER:
		pass
	
	#notify if dangerously hungry
	if satiation < SATIATION_LOW:
		$EIPivot/EnergyIndicator.set("custom_colors/font_color", Color(1,0,0))
		$Sprite.set("self_modulate", Color(1, 0.5, 0.5) )
	else:
		$EIPivot/EnergyIndicator.set("custom_colors/font_color", Color(1,1,1))
		$Sprite.set("self_modulate", Color(1, 1, 1) )
	
	#check if you should grow bigger or not
	if energy == max_energy:
		grow()
	
	#try to keep fishies moving
	if velocity == Vector2() and not resting:
		if $RestlessnessTimer.get_time_left() == 0:
			$RestlessnessTimer.start()
	else:
		$RestlessnessTimer.stop()
	
	#floor bounce
	handle_floor_collision(collision)
	#neighbour bounce
	handle_neighbour_collision(collision)
	
	


#bounce when hitting the floor
func handle_floor_collision(collision):
	if collision != null:
		if collision.get_collider().get_collision_layer_bit(0):
			velocity = Vector2(velocity.x, -velocity.y)
			temp_disable(0.5)
		
	

#bounce against neighbours
func handle_neighbour_collision(collision):
	#prevent multiple collision on the same 2 objects too soon
	if (collision != null) and (prev_collider != collision.get_collider()):
		#only applies to other fish
		if( not collision.get_collider().is_in_group("fish") ):
			return
		
		#the "other" object in the collision
		var other = collision.get_collider()
		
		#points in the collision system
		var c1 = Vector2(self.position.x, self.position.y)
		var v1 = c1 + self.velocity
		
		var c2 = Vector2(other.position.x, other.position.y)
		var v2 = c2 + other.velocity
		
		var point_of_collision = collision.position
		
		#translate and rotate system so that the normal is on the x-axis
		#the collision point will be moved to the origin
		var poc_translation = collision.position
		#move all points
		c1 -= poc_translation
		v1 -= poc_translation
		c2 -= poc_translation
		v2 -= poc_translation
		point_of_collision -= poc_translation
		
		#find angle to rotate by
		var csqrd = point_of_collision.distance_to(c1)
		var rot_amount = acos(c1.x/csqrd)
		
		var sin_val = sin(rot_amount)
		var cos_val = cos(rot_amount)
		
		#rotate
		c1 = Vector2( (c1.x * cos_val - c1.y * sin_val), (c1.y * cos_val + c1.x * sin_val) )
		c2 = Vector2( (c2.x * cos_val - c2.y * sin_val), (c2.y * cos_val + c2.x * sin_val) )
		v1 = Vector2( (v1.x * cos_val - v1.y * sin_val), (v1.y * cos_val + v1.x * sin_val) )
		v2 = Vector2( (v2.x * cos_val - v2.y * sin_val), (v2.y * cos_val + v2.x * sin_val) )
		
		#find velocity to be directed to the OTHER object
		#mass weighting applied here as well
		var w1 = 1 + (0.25 * self.fish_size)
		var w2 = 1 + (0.25 * other.fish_size)
		var t1 = (v1.x - c1.x) * w1/w2
		var t2 = (v2.x - c2.x) * w2/w1
		
		#the velocity to be added
		#relative to the translated/rotated system
		var delta_v1 = Vector2(t2, c1.y)
		var delta_v2 = Vector2(t1, c2.y)
		
		#rotate the new points back to original system
		sin_val = sin(-rot_amount)
		cos_val = cos(-rot_amount)
		
		delta_v1 = Vector2( (delta_v1.x * cos_val - delta_v1.y * sin_val), (delta_v1.y * cos_val + delta_v1.x * sin_val) )
		delta_v2 = Vector2( (delta_v2.x * cos_val - delta_v2.y * sin_val), (delta_v2.y * cos_val + delta_v2.x * sin_val) )
		
		#apply the force to each object
		self.velocity = delta_v1
		other.velocity = delta_v2
		
		#temporarily disable the fish that collided
		#be at least twice the weight/size of the other to not be affected
		if w1 / w2 < 2:
			self.temp_disable(0.1)
		if w2 / w1 < 2:
			other.temp_disable(0.1)
		
		#save previous collision to prevent collision with same object multiple times
		self.prev_collider = other
		other.prev_collider = self
	
	

func calc_satiation(delta):
	if satiation > 0:
		satiation -= 0.5 * delta
		if satiation < 0:
			satiation = 0
		
	
	if satiation > max_satiation:
		satiation = max_satiation
	

func add_to_poop_counter(amount):
	poop_counter += amount
	
	if poop_counter >= poop_amount:
		poop()
	

func poop():
	poop_counter -= poop_amount
	
	var entity_manager = get_tree().get_root().get_node("Main/EntityManager")
	entity_manager.create_entity(Constants.ENTITY_TYPE_ID_POOP, self.get_global_position())

func calc_energy(delta):
	if not ( resting or velocity == Vector2() or (disabled and not caught) ):
		#lose energy
		if energy > 0:
			energy -= 1 * delta
			#handle pooping
			var main_node = get_tree().get_root().get_node("Main")
			if main_node.game_mode == Constants.GAME_MODE_SURVIVAL:
				add_to_poop_counter(1 * delta)
		if energy < 0:
			energy = 0
	else:
		if energy < max_energy:
			#gain energy from resting/not moving
			#recover energy faster than is lost to minimize downtime
			if energy < satiation:
				energy += 2 * delta
			
		
	
	#cap energy at max_energy
	if energy > max_energy:
		energy = max_energy
	
	#energy is capped by satiation
	if energy > satiation:
		energy = satiation
	

func calc_speed():
	var new_speed = max_speed
	
	if energy < ENERGY_MED:
		new_speed -= max_speed * 0.1
	if energy < ENERGY_LOW:
		new_speed -= max_speed * 0.2
	if energy < ENERGY_VLOW:
		new_speed -= max_speed * 0.3
	
	return new_speed


func is_feeling_rested():
	#reached max energy that resting allows
	if energy >= ENERGY_HIGH:
		return true
	#reached max energy limited by satiation
	if (energy >= satiation and energy > ENERGY_LOW):
		return true
	
	return false

func handle_mode_target_locks():
	
	if current_mode == MODE_RANDOM_MOVE:
		if feeling_restless and restless_dest_set:
			if position.distance_squared_to(target_pos) < 25:
				mode_locked = false
				feeling_restless = false
				restless_dest_set = false
				#print("reset restlessness")
		elif position.distance_squared_to(target_pos) < 25:
			targetting_locked = false
		
	
	if current_mode == MODE_GOING_HOME:
		if position.distance_squared_to(Vector2(Globals.screen_size_x/2, Globals.screen_size_y/2)) < 25:
			mode_locked = false
			targetting_locked = false
		
	
	if current_mode == MODE_REST:
		if is_feeling_rested():
			want_to_rest = false
		if is_feeling_rested() or (not predators.empty()) or (not food.empty()):
			resting = false
			mode_locked = false
			targetting_locked = false
		
	
	if current_mode == MODE_AVOIDANCE:
		if position.distance_squared_to(flee_destination) < 25 or out_of_bounds():
			mode_locked = false
		
	
	


func determine_mode():
	if mode_locked:
		return
	
	var new_mode
	
	#stay within the visible screen
	if out_of_bounds():
		new_mode = MODE_GOING_HOME
		
	#check what's within range
	#if there's an enemy, run 
	elif not predators.empty():
		new_mode = MODE_AVOIDANCE
		
	#if it's food, lock onto the food
	elif not food.empty():
		new_mode = MODE_DETECTED_FOOD
		
	#starting to feel tired, time to rest
	elif energy < ENERGY_LOW or want_to_rest:
		new_mode = MODE_REST
		
	#keep fishies moving
	elif feeling_restless:
		new_mode = MODE_RANDOM_MOVE
		
	#go follow your buddies if you can see them
	elif not neighbours.empty():
		new_mode = MODE_SWARM
		
	#otherwise, move around randomly
	else:
		new_mode = MODE_RANDOM_MOVE
	
	#reset targetting locked state if switching modes
	if new_mode != current_mode:
		targetting_locked = false
	
	current_mode = new_mode

func out_of_bounds():
	if position.x < 0 or position.x > Globals.screen_size_x:
		return true
	elif position.y < 0 or position.y > Globals.screen_size_y:
		return true
	else:
		return false


func calculate_target(mode):
	if OS.get_system_time_msecs() - time_of_last_target_change < 100:
		return
	
	if targetting_locked:
		return
	
	time_of_last_target_change = OS.get_system_time_msecs()
	
	if current_mode == MODE_SWARM:
		swarm()
	elif current_mode == MODE_RANDOM_MOVE:
		random_target()
	elif current_mode == MODE_GOING_HOME:
		go_home()
	elif current_mode == MODE_REST:
		find_resting_spot()
	elif current_mode == MODE_DETECTED_FOOD:
		food_lock_on()
	elif current_mode == MODE_AVOIDANCE:
		flee()
	else:
		pass
	

func find_resting_spot():
	want_to_rest = true
	
	if cover_areas.empty():
		target_pos = adjust_movement_to_floor( Vector2(position.x, Globals.screen_size_y) )
	else:
		#find the closest cover area to hide
		var min_dist = INF
		var closest_cover = self.position
		
		for cover in cover_areas.values():
			if is_instance_valid(cover):
				var cover_location = cover.get_node("SafeArea").get_global_position()
				var dist_to_cover = self.position.distance_squared_to(cover_location)
				if  dist_to_cover < min_dist:
					min_dist = dist_to_cover
					closest_cover = cover_location
				
			
		
		target_pos = adjust_movement_to_floor(closest_cover)
	
	
	#CONSIDER separating into new function called rest
	if position.distance_squared_to(target_pos) < 25:
		#adjust where you're looking (not at the ground) to increase awareness
		var left_or_right = 1 - ( 2 * (randi() % 2) )
		target_pos = Vector2(self.position.x + left_or_right, self.position.y)
		
		resting = true
		targetting_locked = true
		mode_locked = true
	

func go_home():
	var home_target = Vector2(Globals.screen_size_x/2, Globals.screen_size_y/2)
	target_pos = home_target
	mode_locked = true
	targetting_locked = true
	

func random_target():
	#select new random target
	var random_x = rand_range(0, Globals.screen_size_x)
	var random_y = rand_range(0, Globals.screen_size_y - Constants.ocean_floor_height)
	var random_location = Vector2(random_x, random_y)
	target_pos = random_location
	targetting_locked = true
	
	if feeling_restless:
		mode_locked = true
		restless_dest_set = true
	

#note: currently does not take into account the size of the predator's collider
func flee():
	#you've made it to somewhere safe so stay put
	if hidden:
		flee_destination = self.position
		target_pos = flee_destination
		return
	
	#predators are not in range, but still scared and running
	if predators.empty() == true:
		target_pos = flee_destination
		return
	
	var avoidance_vector = self.position
	var num_predators = 0
	for k in predators:
		if (predators[k].get_ref() != null):
			var diff_in_pos = self.position.distance_to(predators[k].get_ref().position)
			var diff_in_pos_vector = predators[k].get_ref().position - self.position
			
			#the closer you are to the predator, the further you need to run (to feel safe)
			#also limit/scale the fleeing distance to COMFORTABLE_DIST_PREDATORS
			var multiplier = (COMFORTABLE_DIST_PREDATORS - diff_in_pos) / COMFORTABLE_DIST_PREDATORS
			var added_flee_vector = multiplier * diff_in_pos_vector.normalized() * COMFORTABLE_DIST_PREDATORS
			
			avoidance_vector += -(diff_in_pos_vector + added_flee_vector)
			num_predators += 1
		
	
	#get the average best place to flee
	var avg_avoidance_vector = avoidance_vector / num_predators
	
	#avoid ramming into the floor
	var adjusted_avoidance_vector = adjust_movement_to_floor(avg_avoidance_vector)
	
	#set the target
	target_pos = adjusted_avoidance_vector
	mode_locked = true
	
	#remember where you are running to
	flee_destination = adjusted_avoidance_vector
	


func swarm():
	var separation = calc_separation_vector()
	var alignment = calc_alignment_vector()
	var cohesion = calc_cohesion_vector()
	
	#calculate combined vector and apply weights
#	var swarm_vector = (0.69 * separation) + (0.3 * alignment) + (0.01 * cohesion)
	var wS = 0.6; var wA = 0.3; var wC = 0.1
	var adjusted_wC = calc_weight_cohesion(wC)
	var adjusted_wA = calc_weight_alignment(wA, wC, adjusted_wC)
	var swarm_vector = redistribute_weights(wS, separation, adjusted_wA, alignment, adjusted_wC, cohesion)
	
	var adjusted_swarm_vector = adjust_movement_to_floor(swarm_vector)
	
	#only change target if you're gonna actually move towards it (prevent some flailing?)
	if self.position.distance_squared_to(adjusted_swarm_vector) > 25:
		target_pos = adjusted_swarm_vector
	
	

#to help stop the fish from getting stuck by adjusting cohesion
func calc_weight_cohesion(base_coh):
	var new_wC = base_coh
	
	#set the new weight
	if neighbours.size() >= 10:
		new_wC = 0.5 * base_coh
	if neighbours.size() >= 20:
		new_wC = 0.1 * base_coh
	
	return new_wC

#changes to the base cohesion weight (0.1) are added to the alignment weight
func calc_weight_alignment(base_ali, base_coh, new_coh):
	var new_wA = base_ali
	
	var diff = base_coh - new_coh
	new_wA += diff
	
	return new_wA

#changes to the base cohesion weight (0.1) are added to the separation weight
func calc_weight_separation(base_sep, base_coh, new_coh):
	var new_wS = base_sep
	
	var diff = base_coh - new_coh
	new_wS += diff
	
	return new_wS

#ignore vectors that don't contribute to movement
#returns the total average movement vector (aka swarm vector)
func redistribute_weights(wS, vS, wA, vA, wC, vC):
	#unchanged original swarm vector
	var distilled_vector = (wS * vS) + (wA * vA) + (wC * vC)
	
	var separation_struct = {id=0, is_removed=false, weight=wS, vector=vS}
	var alignment_struct = {id=1, is_removed=false, weight=wA, vector=vA}
	var cohesion_struct = {id=2, is_removed=false, weight=wC, vector=vC}
	var list_of_structs = [separation_struct, alignment_struct, cohesion_struct]
	
	var num_remaining = list_of_structs.size()
	
	for this_struct in list_of_structs:
		#check if you should be removed
		if this_struct.vector == self.position:
			this_struct.is_removed = true
			num_remaining -= 1
			if num_remaining == 0:
				return self.position
			
			var gifting_weight_amount = this_struct.weight / num_remaining
			for other_struct in list_of_structs:
				#make sure it's not yourself
				if this_struct.id != other_struct.id:
					#distribute some of the weight
					other_struct.weight += gifting_weight_amount
				
			
		
	
	var new_summed_vector = Vector2()
	for struct in list_of_structs:
		if not struct.is_removed:
			new_summed_vector += struct.weight * struct.vector
		
	
	distilled_vector = new_summed_vector
	
	return distilled_vector


func calc_separation_vector():
	var total_movement = Vector2()
	var num_neighbours = 0
	for k in neighbours:
		if (neighbours[k].get_ref() != null):
			var comfortable_dist = 20 + self.fish_radius + neighbours[k].get_ref().fish_radius
			
			var dist_sqrd_to_neighbour = self.position.distance_squared_to(neighbours[k].get_ref().position)
			if dist_sqrd_to_neighbour < pow(comfortable_dist, 2):
				#get the difference in positions
				var diff_in_pos_vector = neighbours[k].get_ref().position - self.position
				#head in the opposite direction and scale by closeness
				#you want to be a comfortable distance away from everyone
				var multiplier = (comfortable_dist - sqrt(dist_sqrd_to_neighbour)) / comfortable_dist
				var scaled_diff_vector = multiplier * diff_in_pos_vector.normalized() * comfortable_dist
				
				total_movement += -(scaled_diff_vector)
				num_neighbours += 1
			
		
	
	if num_neighbours == 0:
		return self.position
	else:
		#find best average position
		var average_movement = self.position
		average_movement = total_movement / num_neighbours
		return self.position + average_movement
	

func calc_alignment_vector():
	var sum_of_velocities = Vector2()
	var num_neighbours = 0
	for k in neighbours:
		if (neighbours[k].get_ref() != null):
			#ignore those that aren't moving...use if need to increase activity
			if neighbours[k].get_ref().velocity != Vector2():
				sum_of_velocities += neighbours[k].get_ref().velocity
				num_neighbours += 1
		
	var average_velocity = sum_of_velocities / num_neighbours
	
	if num_neighbours == 0:
		return self.position
	else:
		return self.position + (average_velocity)
	

func calc_cohesion_vector():
	var sum_of_pos = Vector2()
	var num_neighbours = 0
	for k in neighbours:
		#get the average position of your neighbours
		if (neighbours[k].get_ref() != null):
			sum_of_pos += neighbours[k].get_ref().position
			num_neighbours += 1
		
	
	#find the average position of your neighbours
	if num_neighbours == 0:
		#no one to compare to
		return self.position
	else:
		#you have some neighbours
		var average_pos = sum_of_pos / num_neighbours
		return average_pos
	


func food_lock_on():
	#prioritize food already in mouth
	if not food_in_mouth.empty():
		target_pos = food_in_mouth.values()[0].get_ref().get_global_position()
		return
	
	#otherwise, go to the closest one
	var closest_food_location
	var closest_dist = INF
	if not food.empty():
		for k in food:
			if (food[k].get_ref() != null):
				var food_location = food[k].get_ref().get_global_position()
				var current_dist = self.position.distance_squared_to(food_location)
				if current_dist < closest_dist:
					closest_dist = current_dist
					closest_food_location = food_location
				
			
		
	if closest_food_location != null:
		target_pos = closest_food_location
	

func adjust_movement_to_floor(movement_vector):
	var adjusted_movement_vector = movement_vector
	
	#avoid ramming into the floor
	if movement_vector.y > (Globals.screen_size_y - Constants.ocean_floor_height - fish_radius - 5):
		adjusted_movement_vector.y = Globals.screen_size_y - Constants.ocean_floor_collider_height - fish_radius - 5
	
	return adjusted_movement_vector



#keep track of predators, friends, food
func _on_DetectionRange_body_entered(body):
	#spawned organisms
	if body.get_parent().is_in_group("food"):
		food[body.get_parent().my_id] = weakref(body.get_parent())
	
	#falling feed
	elif body.is_in_group("food"):
		food[body.my_id] = weakref(body)
	
	elif body.is_in_group("angufish") and body.my_id != my_id:
		neighbours[body.my_id] = weakref(body)
	
	elif body.is_in_group("predator"):
		predators[body.my_id] = weakref(body)

func _on_DetectionRange_body_exited(body):
	if body.get_parent().is_in_group("food"):
		food.erase(body.get_parent().my_id)
	
	elif body.is_in_group("food"):
		food.erase(body.my_id)
	
	elif body.is_in_group("angufish"):
		neighbours.erase(body.my_id)
	
	elif body.is_in_group("predator"):
		predators.erase(body.my_id)


#automatically eat when something is in the mouth
func _on_Mouth_body_entered(body):
	if body.get_parent().is_in_group("food"):
		food_in_mouth[body.get_parent().my_id] = weakref(body.get_parent())
	
	if body.is_in_group("food"):
		food_in_mouth[body.my_id] = weakref(body)
	

func _on_Mouth_body_exited(body):
	if body.get_parent().is_in_group("food"):
		food_in_mouth.erase(body.get_parent().my_id)
	
	if body.is_in_group("food"):
		food_in_mouth.erase(body.my_id)
	

#controls eating speed of the fish
func _on_ChewingTimer_timeout():
	chewing = false

func eat_food_in_mouth():
	for k in food_in_mouth:
		if (food_in_mouth[k].get_ref() != null):
			food_in_mouth[k].get_ref().consume(fish_size + 2)
			energy += food_in_mouth[k].get_ref().nutrition_value
			satiation += food_in_mouth[k].get_ref().nutrition_value
		
	


#for keeping track of cover areas to hide/rest
func _on_DetectionRange_area_entered(area):
	if area.get_parent().is_in_group("cover"):
		cover_areas[area.get_parent().my_id] = area.get_parent()
	

func _on_DetectionRange_area_exited(area):
	if area.get_parent().is_in_group("cover"):
		cover_areas.erase(area.get_parent().my_id)
	


#caught by predator
func set_caught():
	caught = true
	disabled = true
	$StruggleTimer.start()

#escaped from predator's grasp
func unset_caught():
	caught = false
	disabled = false
	$StruggleTimer.stop()

#try to escape after caught
func struggle():
	if energy > 0:
		#struggling takes effort
		var consumed_energy = floor(energy / 3)
		energy -= consumed_energy
		
		#roll this number or higher to escape
		var min_escape_val = 85 - (10 * fish_size)
		var escape_roll = consumed_energy + (randi() % 99)
		if escape_roll >= min_escape_val:
			unset_caught()
	

func _on_StruggleTimer_timeout():
	struggle()


func set_hidden(pc_z_val):
	hiding_depth += 1
	if hiding_depth >= 1:
		hidden = true
		set_z_index(pc_z_val + Constants.Z_INDEX_ANGULAR_HIDDEN - fish_size)
	

func unset_hidden():
	hiding_depth -= 1
	if hiding_depth <= 0:
		hidden = false
		set_z_index(Constants.Z_INDEX_ANGULAR - fish_size)
	


func show_hide_status(show_status):
	$EIPivot/ResourceNotifier.visible = false
	$EIPivot.visible = show_status
	$EIPivot/EnergyIndicator.visible = show_status

func show_hide_info(show_info):
	$EIPivot/EnergyIndicator.visible = false
	$EIPivot.visible = show_info
	$EIPivot/ResourceNotifier.visible = show_info


#called by WEFishSpawn.gd world event
func check_fertility():
	if fish_size >= 0 and Globals.remaining_spawnable_fishies > 0:
		#var energy_cost = 50 / (fish_size + 1)
		var energy_cost = 40 - (fish_size * 5)
		if (energy - energy_cost >= 40):
			spawn_egg(energy_cost)

func spawn_egg(energy_amount):
	energy -= energy_amount
	satiation -= energy_amount
	
	var entity_manager = get_tree().get_root().get_node("Main/EntityManager")
	entity_manager.create_entity(Constants.ENTITY_TYPE_ID_EGG, self.position)

func grow():
	if fish_size < 4:
		#try to prevent getting stuck on the ground
		self.position += Vector2(0,-fish_radius)
		
		energy -= (max_energy - 50)
		satiation = energy
		
		fish_size += 1
		var scaling_amount = 1 + (fish_size * 0.25)
		scale_body_parts(scaling_amount)
		#bigger fish are drawn behind smaller fish
		set_z_index(Constants.Z_INDEX_ANGULAR - fish_size)
	

func scale_body_parts(size):
	var size_vector = Vector2(size, size)
	
	$Sprite.scale = size_vector
	$SqueezeCollider.scale = size_vector
	$DetectionRange.scale = size_vector
	$Mouth.scale = size_vector
	
	#y-position for scale of 1 is 13
	$EIPivot/EnergyIndicator.rect_position.y = size * 13 
	
	fish_radius = $SqueezeCollider.shape.radius * (1 + (0.25 * fish_size))



func die():
	var new_death_anim = death_anim_r.instance()
	
	#flip sprite if facing left
	if self.position.x - target_pos.x > 0:
		new_death_anim.get_node("Sprite").flip_h = true
	
	new_death_anim.position = self.get_global_position()
	new_death_anim.get_node("Sprite").scale = (1 + fish_size * 0.25) * Vector2(1,1) 
	get_tree().get_root().get_node("Main").add_child(new_death_anim)
	
	get_tree().get_root().get_node("Main/EntityManager").remove_entity(my_id)

#called by the predator who eats you
func get_eaten():
	Globals.num_deaths_predation += 1
	get_tree().get_root().get_node("Main/EntityManager").remove_entity(my_id)


func _on_RestlessnessTimer_timeout():
	feeling_restless = true



