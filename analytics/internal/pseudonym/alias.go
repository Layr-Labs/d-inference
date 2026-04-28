package pseudonym

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
)

type Generator struct {
	secret []byte
}

func NewGenerator(secret string) (*Generator, error) {
	if secret == "" {
		return nil, fmt.Errorf("pseudonym secret is required")
	}
	return &Generator{secret: []byte(secret)}, nil
}

func (g *Generator) Alias(kind, stableID string) string {
	mac := hmac.New(sha256.New, g.secret)
	_, _ = mac.Write([]byte(kind))
	_, _ = mac.Write([]byte{':'})
	_, _ = mac.Write([]byte(stableID))
	sum := mac.Sum(nil)

	adj := adjectives[int(sum[0])%len(adjectives)]
	animal := animals[int(sum[1])%len(animals)]
	number := int(binary.BigEndian.Uint16(sum[2:4]))%900 + 100

	return fmt.Sprintf("%s %s %03d", adj, animal, number)
}

var adjectives = []string{
	"Amber",
	"Arc",
	"Ash",
	"Atlas",
	"Brisk",
	"Bronze",
	"Calm",
	"Cinder",
	"Clear",
	"Cobalt",
	"Delta",
	"Dune",
	"Ember",
	"Fable",
	"Flint",
	"Frost",
	"Golden",
	"Granite",
	"Harbor",
	"Indigo",
	"Iron",
	"Jade",
	"Lunar",
	"Marble",
	"Nova",
	"Onyx",
	"Opal",
	"Polar",
	"Quartz",
	"Rising",
	"Silver",
	"Solar",
	"Stone",
	"Swift",
	"Tidal",
	"Velvet",
}

var animals = []string{
	"Badger",
	"Bear",
	"Cougar",
	"Coyote",
	"Crane",
	"Falcon",
	"Fox",
	"Gull",
	"Hawk",
	"Heron",
	"Ibis",
	"Jaguar",
	"Koala",
	"Lynx",
	"Marten",
	"Moose",
	"Otter",
	"Owl",
	"Panther",
	"Pika",
	"Puma",
	"Quail",
	"Raven",
	"Seal",
	"Shark",
	"Sparrow",
	"Stoat",
	"Swift",
	"Tiger",
	"Viper",
	"Wolf",
	"Wren",
}
