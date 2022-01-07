extends Node

class LinkedListNode extends Node:
	var next: LinkedListNode
	var prev: LinkedListNode
	
	var value: Object
	
	func _init(new_val):
		next = null
		prev = null
		
		value = new_val
	

class LinkedList extends Node:
	var num_nodes: int
	var front: LinkedListNode
	var back: LinkedListNode
	
	func _init():
		num_nodes = 0
		front = null
		back = null
	
	func add(new_llnode):
		if num_nodes == 0:
			front = new_llnode
			back = new_llnode
		else:
			back.next = new_llnode
			new_llnode.prev = back
			
			back = new_llnode
		
		num_nodes += 1
	
	func remove(target_llnode):
		#special case 1 node in list
		if num_nodes == 1:
			target_llnode.queue_free()
			num_nodes -= 1
			front = null
			back = null
			return
		#special case 2 nodes in list
		if num_nodes == 2:
			if front == target_llnode:
				front.next.prev = null
				front = back
			elif back == target_llnode:
				back.prev.next = null
				back = front
			target_llnode.queue_free()
			num_nodes -= 1
			return
		
		#special case front
		if front == target_llnode:
			front.next.prev = null
			front = front.next
		#special case back
		elif back == target_llnode:
			back.prev.next = null
			back = back.prev
		#normal case
		else:
			target_llnode.prev.next = target_llnode.next
			target_llnode.next.prev = target_llnode.prev
		
		target_llnode.queue_free()
		num_nodes -= 1
	
	func print_list():
		var current_node = front
		var counter = 0
		
		var nodes_string = ""
		while counter < num_nodes:
			nodes_string = nodes_string + str(current_node) + ">>"
			current_node = current_node.next
			counter += 1
		
		print("num_nodes: %s" % num_nodes)
		print(nodes_string)
	
	func clear_list():
		while num_nodes > 0:
			remove(front)
		
	
	


#keeps track of which fish to process next
var fish_to_be_processed:LinkedList
#helps in finding fish (for removal)
var fish_directory:Dictionary

const NUM_NODES_PROCESSED_PER_FRAME = 30
var last_processed_node:LinkedListNode = null

func _ready():
	fish_to_be_processed = LinkedList.new()
	
	var entity_manager = get_tree().get_root().get_node("Main/EntityManager")
	entity_manager.connect("fish_created", self, "_on_fish_created")


func _process(delta):
	if fish_to_be_processed.num_nodes > 0:
		var remaining_nodes_to_process = NUM_NODES_PROCESSED_PER_FRAME
		while remaining_nodes_to_process > 0:
			#set the current node to process
			var current_node
			if last_processed_node == null:
				current_node = fish_to_be_processed.front 
			elif last_processed_node == fish_to_be_processed.back:
				current_node = fish_to_be_processed.front
			else:
				current_node = last_processed_node.next
			
			#run the AI
			var fish = current_node.value
			fish.handle_mode_target_locks()
			fish.determine_mode()
			fish.calculate_target(fish.current_mode)
			
			last_processed_node = current_node
			remaining_nodes_to_process -= 1
			
			#terminate loop if you reach the end of the list
			#on the next frame, you will start at the front
			if current_node == fish_to_be_processed.back:
				break
			
		
		
	


func handle_fish_death(dead_fish):
	#find the fish in the processing list
	var node_to_remove = fish_directory[dead_fish.my_id]
	
	#handle case where it was the last node to be processed
	if node_to_remove == last_processed_node:
		last_processed_node = null
	
	#remove from processing list
	fish_to_be_processed.remove(node_to_remove)
	#remove from directory
	fish_directory.erase(dead_fish.my_id)


func _on_fish_created(new_fish):
	#add to processing list
	var new_fish_node = LinkedListNode.new(new_fish)
	fish_to_be_processed.add(new_fish_node)
	
	#add to directory
	fish_directory[new_fish.my_id] = new_fish_node


