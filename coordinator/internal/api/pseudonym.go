package api

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
)

// pseudonymAdjectives is a curated list of friendly adjectives used to
// generate human-readable pseudonyms (e.g. "swift-otter-42").
//
// Curation rules:
//   - Wholesome / positive only (no "sad", "weak", "broken")
//   - Easy to read, single-word
//   - Reads well combined with any animal in pseudonymAnimals
var pseudonymAdjectives = []string{
	"swift", "bold", "calm", "clever", "bright", "brave", "cosmic", "crystal",
	"daring", "deft", "eager", "earnest", "electric", "elegant", "epic", "fancy",
	"fearless", "fierce", "fiery", "fleet", "fluffy", "fond", "frosty", "fuzzy",
	"gentle", "giddy", "glad", "gleeful", "glowing", "golden", "graceful", "grand",
	"great", "happy", "hardy", "heroic", "humble", "iridescent", "jolly", "joyful",
	"keen", "kind", "lively", "lucid", "lucky", "lunar", "magnetic", "mellow",
	"merry", "mighty", "misty", "mythic", "neat", "noble", "nimble", "novel",
	"opal", "perky", "plucky", "polite", "primal", "prime", "proud", "pure",
	"quick", "quiet", "radiant", "rapid", "rare", "regal", "robust", "rosy",
	"sage", "savvy", "shy", "silent", "silken", "silver", "snappy", "snug",
	"solar", "sonic", "spark", "sparkly", "splendid", "spry", "sublime", "sunny",
	"super", "sweet", "swirling", "tame", "tidy", "trusty", "twinkly", "ultra",
	"upbeat", "valiant", "velvet", "vibrant", "vigilant", "vivid", "warm", "wavy",
	"wild", "winged", "wise", "witty", "zappy", "zealous", "zesty", "agile",
	"airy", "amber", "ancient", "aqua", "arctic", "atomic", "auburn", "autumn",
	"azure", "balmy", "bashful", "beamy", "bonny", "bouncy", "breezy", "bubbly",
	"burning", "buttery", "candid", "carmine", "celestial", "cerulean", "cheerful", "cheery",
	"chestnut", "chipper", "chromatic", "classic", "cobalt", "colossal", "coral", "cordial",
	"cottony", "courtly", "creamy", "crimson", "crispy", "cuddly", "curious", "dapper",
	"dazzling", "delightful", "dewy", "dignified", "downy", "dreamy", "ducky", "dynamic",
	"earthy", "ebony", "ember", "emerald", "enchanted", "energetic", "evening", "ever",
	"festive", "flame", "florid", "flowing", "forest", "fragrant", "free", "fresh",
	"friendly", "frosted", "galactic", "garnet", "gentlemanly", "ginger", "glassy", "glimmer",
	"globular", "glossy", "good", "graceful", "granite", "grassy", "groovy", "gusty",
	"halcyon", "hardworking", "harmonic", "hazel", "hazy", "healthy", "hearty", "helpful",
	"hopeful", "honest", "iceberg", "icy", "imperial", "indigo", "ivory", "jade",
	"jaunty", "jazzy", "jovial", "jubilant", "lakeside", "lavender", "leafy", "lemony",
	"lighthearted", "linen", "loyal", "luminous", "lush", "majestic", "maple", "marble",
	"marvelous", "matte", "meadow", "merry", "merciful", "meteoric", "midnight", "mild",
	"mindful", "minty", "mirthful", "modest", "mossy", "muddy", "natural", "nebula",
	"neon", "nightly", "nutty", "obsidian", "ocean", "olive", "onyx", "orchid",
	"ornate", "patient", "peachy", "pearl", "peaceful", "pebbly", "pewter", "pillowy",
	"pine", "playful", "plenty", "pluckier", "plump", "polished", "ponderous", "poppy",
}

// pseudonymAnimals is a curated list of friendly animal names.
// Skews toward smaller / charismatic species because they read well in
// node names.
var pseudonymAnimals = []string{
	"otter", "fox", "owl", "wolf", "bear", "lynx", "deer", "hawk",
	"falcon", "eagle", "dolphin", "whale", "panda", "tiger", "lion", "puma",
	"jaguar", "leopard", "cheetah", "horse", "zebra", "giraffe", "moose", "elk",
	"badger", "beaver", "bunny", "kit", "kitten", "puppy", "raccoon", "rabbit",
	"squirrel", "chipmunk", "mouse", "hedgehog", "porcupine", "mole", "vole", "ferret",
	"weasel", "stoat", "marten", "mink", "shrew", "armadillo", "anteater", "sloth",
	"opossum", "kangaroo", "wombat", "wallaby", "koala", "platypus", "echidna", "tapir",
	"rhino", "hippo", "buffalo", "bison", "yak", "camel", "alpaca", "llama",
	"goat", "sheep", "lamb", "calf", "foal", "pony", "donkey", "mule",
	"piglet", "boar", "warthog", "tapir", "duck", "goose", "swan", "heron",
	"crane", "stork", "egret", "ibis", "flamingo", "peacock", "pheasant", "quail",
	"sparrow", "finch", "robin", "wren", "swallow", "thrush", "lark", "bluebird",
	"cardinal", "canary", "parrot", "macaw", "cockatoo", "raven", "crow", "magpie",
	"jay", "puffin", "penguin", "albatross", "tern", "gull", "pelican", "kingfisher",
	"woodpecker", "hummingbird", "kookaburra", "kiwi", "ostrich", "emu", "rhea", "cassowary",
	"toucan", "hornbill", "starling", "mockingbird", "nightingale", "warbler", "vireo", "tanager",
	"manatee", "narwhal", "orca", "porpoise", "seal", "sealion", "walrus", "dugong",
	"beluga", "octopus", "squid", "cuttlefish", "nautilus", "starfish", "urchin", "anemone",
	"crab", "lobster", "shrimp", "krill", "jellyfish", "seahorse", "stingray", "manta",
	"shark", "marlin", "swordfish", "tuna", "salmon", "trout", "pike", "perch",
	"carp", "koi", "cod", "halibut", "mackerel", "snapper", "grouper", "barracuda",
	"clownfish", "angelfish", "betta", "guppy", "tetra", "minnow", "anchovy", "sardine",
	"frog", "toad", "newt", "salamander", "axolotl", "gecko", "iguana", "chameleon",
	"komodo", "monitor", "skink", "anole", "tortoise", "turtle", "terrapin", "crocodile",
	"alligator", "caiman", "snake", "python", "viper", "cobra", "mamba", "boa",
	"butterfly", "moth", "dragonfly", "ladybug", "firefly", "beetle", "honeybee", "bumblebee",
	"ant", "cricket", "grasshopper", "mantis", "katydid", "cicada", "weevil", "lacewing",
	"caterpillar", "snail", "slug", "earthworm", "centipede", "millipede", "spider", "scorpion",
	"griffin", "phoenix", "dragon", "unicorn", "pegasus", "kraken", "sphinx", "gryphon",
	"hydra", "basilisk", "wyvern", "drake", "centaur", "satyr", "sprite", "pixie",
	"yeti", "kelpie", "selkie", "kitsune", "tanuki", "qilin", "wisp", "firebird",
	"thunderbird", "rocbird", "hippogriff", "minotaur", "manticore", "chimera", "harpy", "siren",
}

// pseudonym returns a stable, opaque, human-readable short ID for an
// account. Format: "<adjective>-<animal>-<NNNN>". Examples:
//
//	swift-otter-2417
//	bold-fox-0042
//	cosmic-griffin-9821
//
// Properties:
//   - Stable: same account_id always produces the same name.
//   - Opaque: account_id is never recoverable from the name.
//   - Friendly: easier to read and remember than raw hex.
//   - 256 × 256 × 10000 = ~655M unique combinations. With ~10K active
//     accounts the birthday-collision probability is negligible.
func pseudonym(accountID string) string {
	if accountID == "" {
		return "anon"
	}
	sum := sha256.Sum256([]byte(accountID))
	// Use 16 bits per index to reduce modulo bias when list lengths
	// don't divide 256 evenly. With ~256-entry lists the residual
	// bias is well under 0.1% of frequency.
	adjIdx := binary.BigEndian.Uint16(sum[0:2])
	aniIdx := binary.BigEndian.Uint16(sum[2:4])
	nn := binary.BigEndian.Uint32(sum[4:8]) % 10000
	adj := pseudonymAdjectives[int(adjIdx)%len(pseudonymAdjectives)]
	animal := pseudonymAnimals[int(aniIdx)%len(pseudonymAnimals)]
	return fmt.Sprintf("%s-%s-%04d", adj, animal, nn)
}
