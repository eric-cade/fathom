extends Node2D
# agents

signal said_something(message: String)

# Simple DNS Agent Prototype
var agent_name: String = "Bok"
var memory: Array = []
var responses: Array = ["Title: Why Do So Many Deep-Sea Creatures Glow? A Quick Dive into Bioluminescence

Bioluminescence is one of nature's most fascinating adaptations — the ability of organisms to produce light through chemical reactions. In the deep sea, where sunlight doesn't reach, up to 90% of organisms are believed to use some form of bioluminescence.

But why?

Researchers have discovered that glowing adaptations serve a variety of survival purposes: from luring prey and attracting mates to confusing predators or camouflaging against faint light from above. In some species, such as the anglerfish, the glow is produced by symbiotic bacteria living in specialized light organs.

Interestingly, the chemical mechanism for producing light — usually involving luciferin and the enzyme luciferase — varies across species, suggesting that bioluminescence evolved independently multiple times throughout the tree of life.

While we're just scratching the surface, bioluminescence continues to inspire new scientific research, including applications in medicine, bioengineering, and low-energy lighting solutions.

What’s your favorite example of bioluminescence in nature or tech?", "Build towers", "Trap it underground"]

func _ready() -> void:
	# Start the thinking cycle
	think()

func think() -> void:
	# Wait a random interval between 1 and 3 seconds
	await get_tree().create_timer(randf_range(1.0, 3.0)).timeout

	# Select and store a random idea
	var idea: String = responses[randi() % responses.size()]
	memory.append(idea)

	# Emit the thought through the signal
	emit_signal("said_something", agent_name + ": " + idea)

	# Loop the thinking process
	think()
