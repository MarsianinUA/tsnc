// The Go twin of bench/ts/raytracer/parse.ts. The name table stays hand-made, as in the TypeScript,
// rather than a Go map.
package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Camera struct {
	eye, target, up Vec
	height          float64
}

type Light struct {
	position, color Vec
}

type Mover struct {
	sphere   *Sphere
	velocity Vec
}

type Scene struct {
	camera                   Camera
	horizon, zenith, ambient Vec
	lights                   []Light
	materials                []*Material
	planes                   []*Plane
	solids                   []Solid
	movers                   []Mover
}

type Line struct {
	number       int
	command      string
	words        []string
	keys, values []string
}

type NameTable struct {
	slots     []int
	materials []*Material
}

const nameSlots = 64

func fail(line *Line, format string, args ...any) {
	fmt.Fprintf(os.Stderr, "scene, line %d: %s\n", line.number, fmt.Sprintf(format, args...))
	os.Exit(1)
}

func readLine(text string, number int) *Line {
	if hash := strings.Index(text, "#"); hash >= 0 {
		text = text[:hash]
	}
	parts := strings.Fields(text)
	if len(parts) == 0 {
		return nil
	}
	line := &Line{number: number, command: parts[0]}
	for _, part := range parts[1:] {
		if key, value, ok := strings.Cut(part, "="); ok {
			line.keys = append(line.keys, key)
			line.values = append(line.values, value)
		} else {
			line.words = append(line.words, part)
		}
	}
	return line
}

func (line *Line) field(key string) (string, bool) {
	for i, k := range line.keys {
		if k == key {
			return line.values[i], true
		}
	}
	return "", false
}

func (line *Line) required(key string) string {
	value, ok := line.field(key)
	if !ok {
		fail(line, "%s needs %s=", line.command, key)
	}
	return value
}

func (line *Line) word(index int, what string) string {
	if index >= len(line.words) {
		fail(line, "%s needs a %s", line.command, what)
	}
	return line.words[index]
}

func (line *Line) parseNumber(text string) float64 {
	value, err := strconv.ParseFloat(text, 64)
	if err != nil {
		fail(line, "%q is not a number", text)
	}
	return value
}

func (line *Line) parseVec(text string) Vec {
	parts := strings.Split(text, ",")
	if len(parts) != 3 {
		fail(line, "%q is not three numbers", text)
	}
	return vec(line.parseNumber(parts[0]), line.parseNumber(parts[1]), line.parseNumber(parts[2]))
}

func (line *Line) numberOf(key string, fallback float64) float64 {
	if value, ok := line.field(key); ok {
		return line.parseNumber(value)
	}
	return fallback
}

func (line *Line) integerOf(key string, fallback int) int {
	value, ok := line.field(key)
	if !ok {
		return fallback
	}
	n, err := strconv.Atoi(value)
	if err != nil || n < 0 {
		fail(line, "%s must be a whole number", key)
	}
	return n
}

func (line *Line) vecOf(key string, fallback Vec) Vec {
	if value, ok := line.field(key); ok {
		return line.parseVec(value)
	}
	return fallback
}

func (line *Line) requiredVec(key string) Vec {
	return line.parseVec(line.required(key))
}

func hashName(name string) int {
	hash := 0
	for i := 0; i < len(name); i++ {
		hash = (hash*31 + int(name[i])) % 65521
	}
	return hash
}

func (table *NameTable) slotOf(name string) int {
	slot := hashName(name) % nameSlots
	for table.slots[slot] != 0 && table.materials[table.slots[slot]-1].name != name {
		slot = (slot + 1) % nameSlots
	}
	return slot
}

func kindOf(line *Line, text string) Kind {
	switch text {
	case "diffuse":
		return diffuse
	case "mirror":
		return mirror
	case "glass":
		return glass
	}
	fail(line, "unknown material kind %q", text)
	return diffuse
}

func textureOf(line *Line) Texture {
	color := line.vecOf("color", vec(0.8, 0.8, 0.8))
	kind, ok := line.field("texture")
	if !ok {
		kind = "solid"
	}
	switch kind {
	case "solid":
		return solid(color)
	case "checker":
		return checker(color, line.requiredVec("color2"), line.numberOf("scale", 1))
	case "marble":
		return marble(color, line.requiredVec("color2"), line.numberOf("scale", 1))
	case "wood":
		return wood(color, line.requiredVec("color2"), line.numberOf("scale", 1))
	case "strata":
		return strata(color, line.requiredVec("color2"), line.numberOf("from", 0), line.numberOf("to", 1))
	}
	fail(line, "unknown texture %q", kind)
	return nil
}

func (table *NameTable) add(line *Line) {
	name := line.word(0, "name")
	slot := table.slotOf(name)
	if table.slots[slot] != 0 {
		fail(line, "material %s is defined twice", name)
	}
	if (len(table.materials)+1)*2 > nameSlots {
		fail(line, "too many materials")
	}
	material := &Material{
		name:         name,
		kind:         kindOf(line, line.word(1, "kind")),
		texture:      textureOf(line),
		specular:     line.numberOf("specular", 0),
		shininess:    line.integerOf("shininess", 1),
		reflectivity: line.numberOf("reflect", 0),
		ior:          line.numberOf("ior", 1.5),
	}
	if emit, ok := line.field("emit"); ok {
		emission := line.parseVec(emit)
		material.emission = &emission
	}
	table.materials = append(table.materials, material)
	table.slots[slot] = len(table.materials)
}

func (table *NameTable) material(line *Line) *Material {
	name := line.required("material")
	slot := table.slotOf(name)
	if table.slots[slot] == 0 {
		fail(line, "no material %s", name)
	}
	return table.materials[table.slots[slot]-1]
}

func (scene *Scene) addSphere(line *Line, s *Sphere) {
	if move, ok := line.field("move"); ok {
		scene.movers = append(scene.movers, Mover{s, line.parseVec(move)})
	} else {
		scene.solids = append(scene.solids, s)
	}
}

func (scene *Scene) addAll(triangles []*Triangle) {
	for _, t := range triangles {
		scene.solids = append(scene.solids, t)
	}
}

func parseScene(source string) *Scene {
	table := &NameTable{slots: make([]int, nameSlots)}
	scene := &Scene{
		camera:  Camera{vec(0, 0, 1), vec(0, 0, 0), vec(0, 1, 0), 0.5},
		horizon: vec(1, 1, 1),
		zenith:  vec(0.5, 0.7, 1),
	}

	for i, text := range strings.Split(source, "\n") {
		line := readLine(text, i+1)
		if line == nil {
			continue
		}
		switch line.command {
		case "camera":
			scene.camera = Camera{
				eye:    line.requiredVec("eye"),
				target: line.requiredVec("target"),
				up:     line.vecOf("up", vec(0, 1, 0)),
				height: line.numberOf("height", 0.5),
			}
		case "sky":
			scene.horizon = line.requiredVec("horizon")
			scene.zenith = line.requiredVec("zenith")
		case "ambient":
			scene.ambient = line.parseVec(line.word(0, "color"))
		case "light":
			scene.lights = append(scene.lights, Light{line.requiredVec("at"), line.requiredVec("color")})
		case "material":
			table.add(line)
		case "plane":
			scene.planes = append(scene.planes, &Plane{
				normal:   normalize(line.requiredVec("normal")),
				offset:   line.numberOf("offset", 0),
				material: table.material(line),
			})
		case "sphere":
			scene.addSphere(line, &Sphere{line.requiredVec("center"), line.numberOf("radius", 1), table.material(line)})
		case "spheres":
			from := line.requiredVec("from")
			step := line.requiredVec("step")
			count := line.integerOf("count", 1)
			radius := line.numberOf("radius", 1)
			material := table.material(line)
			for k := 0; k < count; k++ {
				scene.addSphere(line, &Sphere{addScaled(from, step, float64(k)), radius, material})
			}
		case "icosphere":
			scene.addAll(icosphere(line.requiredVec("center"), line.numberOf("radius", 1),
				line.integerOf("depth", 2), table.material(line)))
		case "box":
			scene.addAll(box(line.requiredVec("min"), line.requiredVec("max"), table.material(line)))
		case "terrain":
			scene.addAll(terrain(line.requiredVec("origin"), line.numberOf("size", 10),
				line.integerOf("cells", 8), line.numberOf("height", 1), table.material(line)))
		default:
			fail(line, "unknown command %q", line.command)
		}
	}
	scene.materials = table.materials
	return scene
}
