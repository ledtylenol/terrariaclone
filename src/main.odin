package main

import "core:fmt"
import "core:math"
import "core:math/linalg/glsl"
import "core:math/rand"
import "core:strings"
import "core:time"
import "shared:fast_noise"
import rl "vendor:raylib"

width :: 1280
height :: 720

game_width :: 10000
game_height :: 100000

fps :: 256
Vec2 :: rl.Vector2


Sprite :: struct {}
NPCKind :: enum {
	ZOMBIE,
	SLIME,
}

NPC :: struct {
	ent:   Entity,
	kind:  NPCKind,
	enemy: bool,
}
Player :: struct {
	ent: Entity,
}

Entity :: struct {
	pos, scale: Vec2,
	sprite:     Sprite,
	health:     i64,
}

SpriteAtlases :: enum {
	PLAYER,
	TERRAIN,
}
TileType :: enum {
	AIR,
	DIRT,
	STONE,
	SAND,
}

TileData :: struct {
	type: TileType,
	tick: f32,
}
IVec2 :: [2]i64

Setting :: enum {
	TICKRATE,
}
atlases: [SpriteAtlases]rl.Texture2D
GameState :: struct {
	entities: [dynamic]Entity,
	tiles:    map[IVec2]TileData,
	settings: [Setting]f32,
	camera:   rl.Camera2D,
	seed:     int,
}
get_tile_from_step :: proc(step: f32) -> TileType {
	type := TileType.DIRT
	switch step {
	case -1.0 ..< 0.0:
		type = .STONE
	case 0.2 ..< 0.5:
		type = .SAND
	case 0.5 ..< 0.7:
		type = .DIRT
	case:
		type = .AIR
	}

	return type

}

global_to_local :: proc(pos: Vec2) -> IVec2 {
	using game_state.camera
	return {i64(math.floor(pos.x / (16 * zoom))), i64(math.floor(pos.y / (16 * zoom)))}
}
local_to_global :: proc(pos: IVec2) -> Vec2 {
	using game_state.camera
	return {f32(pos.x) * (16 * zoom), f32(pos.y) * 16 * zoom}
}

get_global_mouse_position :: proc() -> Vec2 {
	using game_state.camera
	return rl.GetMousePosition() / zoom - offset / zoom + target
}
get_local_mouse_position :: proc() -> IVec2 {
	return global_to_local(get_global_mouse_position())
}
generate_world :: proc(
	seed: int = 0,
	frequency: f32 = 1.0,
	rec: rl.Rectangle,
	heightmap_freq: f32 = 1.0,
) {
	// clear_map(&game_state.tiles)
	state := fast_noise.create_state(seed)
	state.noise_type = .Perlin
	state.frequency = frequency
	state.octaves = 3

	local_pos := global_to_local({rec.x, rec.y})
	for j in -i64(rec.height) ..= i64(rec.height) {
		for i in -i64(rec.width) ..= i64(rec.width) {

			if (local_pos + IVec2{auto_cast i, auto_cast j}) in game_state.tiles do continue
			pos := IVec2{auto_cast i, auto_cast j}
			step := fast_noise.get_noise_2d(
				&state,
				f32(local_pos.x) + f32(i),
				f32(local_pos.y) + f32(j),
			)
			type := get_tile_from_step(step)
			tile := TileData{type, 0}
			pos += local_pos
			game_state.tiles[pos] = tile
		}
	}
	state = fast_noise.create_state(seed + 5)
	state.frequency = heightmap_freq
	for i in -i64(rec.width) ..= i64(rec.width) {
		thres := i64(fast_noise.get_noise_2d(&state, f32(i) / 100, 0) * 30)
		for j in -i64(rec.height) ..= thres {
			pos := IVec2{auto_cast i, auto_cast j} + local_pos
			game_state.tiles[pos] = TileData{.AIR, 0}
		}
	}
}
init :: proc() {

	size_f := Vec2{f32(rl.GetRenderWidth()), f32(rl.GetRenderHeight())}
	cam := rl.Camera2D {
		zoom   = 1.0,
		target = {0, 0},
		offset = size_f / 2,
	}
	game_state.camera = cam
	rl.SetTargetFPS(fps)
	atlases[.PLAYER] = rl.LoadTexture("assets/player.png")
	atlases[.TERRAIN] = rl.LoadTexture("assets/terrain.png")
	game_state.seed = auto_cast time.time_to_unix(time.now())
	generate_world(
		seed = game_state.seed,
		frequency = 0.1,
		rec = {0, 0, 10000, 100},
		heightmap_freq = 1.0,
	)
	init_ui()
}

init_ui :: proc() {
}

update :: proc() {
	dt := rl.GetFrameTime()
	dir := Vec2{}
	if rl.IsKeyDown(.A) do dir.x -= 1
	if rl.IsKeyDown(.D) do dir.x += 1
	if rl.IsKeyDown(.W) do dir.y -= 1
	if rl.IsKeyDown(.S) do dir.y += 1

	game_state.camera.target += dir * dt * 500
	game_state.camera.zoom += rl.GetMouseWheelMove() * 0.1
	game_state.camera.zoom = clamp(game_state.camera.zoom, 0.3, 3.0)
	tick_tiles()
	check_tiles()
}


tick_tiles :: proc() {
	using game_state.camera
	pos := global_to_local(target)
	dt := rl.GetFrameTime()


	size_f := Vec2{f32(rl.GetRenderWidth()), f32(rl.GetRenderHeight())}
	tiles := global_to_local(size_f)
	for j in -tiles.y ..= tiles.y {
		for i in -tiles.x ..= tiles.x {
			key := IVec2{auto_cast i, auto_cast j} + pos
			tile := (&game_state.tiles[key]) or_continue
			tile.tick += dt
			key_plus_one := key
			key_plus_one.y += 1
			if tile.tick >= 1.0 / game_state.settings[.TICKRATE] {
				tick(key)
			}
		}
	}
}

tick :: proc(key: IVec2) {
	tile := &game_state.tiles[key]
	tile.tick = 0.0
	#partial switch tile.type {
	case .SAND:
		if next_tile, ok := game_state.tiles[key + IVec2{0, 1}]; ok {
			if next_tile.type == .AIR {
				game_state.tiles[key + IVec2{0, 1}], game_state.tiles[key] =
					game_state.tiles[key], game_state.tiles[key + IVec2{0, 1}]
			}
		}
	}
}

get_fract_mouse_pos :: proc() -> Vec2 {
	zoom := game_state.camera.zoom
	mouse_pos := get_global_mouse_position() / (zoom * 16)
	fract_x, fract_y := glsl.fract(mouse_pos.x), glsl.fract(mouse_pos.y)
	if fract_x < 0 {fract_x = abs(-fract_x - 1)}
	if fract_y < 0 {fract_y = abs(-fract_y - 1)}
	return Vec2{fract_x, fract_y}
}

check_tiles :: proc() {
	current_tile := get_local_mouse_position()
	if rl.IsMouseButtonPressed(.LEFT) {
		if tile, ok := &game_state.tiles[current_tile]; ok {
			fmt.println("we have ", tile.type, " ", current_tile)
			tile.type = .AIR
		}
	}
}
draw :: proc() {
	rl.BeginDrawing()
	rl.BeginMode2D(game_state.camera)
	rl.ClearBackground(rl.BLUE)
	draw_tiles()

	rl.EndMode2D()
	rl.DrawFPS(30, 30)
	mouse_pos := get_fract_mouse_pos()
	rl.DrawText(
		fmt.caprint(
			get_mouse_tile().type,
			get_mouse_tile().tick,
			'\n',
			mouse_pos,
			'\n',
			get_global_mouse_position(),
		),
		i32(rl.GetMousePosition().x),
		i32(rl.GetMousePosition().y) + 15,
		20,
		rl.WHITE,
	)
	tickrate := fmt.caprintf("%.0f", game_state.settings[.TICKRATE])
	rect := rl.Rectangle{30, 60, 120, 40}
	rl.GuiSliderBar(rect, "tps", tickrate, &game_state.settings[.TICKRATE], 1, 100)
	rl.EndDrawing()
	free_all(context.temp_allocator)
}

get_mouse_tile :: proc() -> TileData {
	data := TileData{}
	local := get_local_mouse_position()
	if tile, ok := game_state.tiles[local]; ok {
		return tile
	}
	return TileData{}
}
get_tile_rect :: proc(data: TileType) -> rl.Rectangle {
	r: rl.Rectangle
	switch data {
	case .AIR:
		r = {0, 0, 16, 16}
	case .DIRT:
		r = {16, 0, 16, 16}
	case .SAND:
		r = {32, 0, 16, 16}
	case .STONE:
		r = {48, 0, 16, 16}
	}
	return r
}
draw_tiles :: proc() {
	using game_state.camera
	pos := global_to_local(target)


	size_f := Vec2{f32(rl.GetRenderWidth()), f32(rl.GetRenderHeight())}
	tiles := global_to_local(size_f)
	for j in -tiles.y ..= tiles.y {
		for i in -tiles.x ..= tiles.x {
			key := IVec2{auto_cast i, auto_cast j} + pos
			if value, ok := game_state.tiles[key]; ok {
				global_pos := local_to_global(key)
				rect := rl.Rectangle{global_pos.x, global_pos.y, 16 * zoom, 16 * zoom}
				rl.DrawTexturePro(
					atlases[.TERRAIN],
					get_tile_rect(value.type),
					rect,
					{0, 0},
					0,
					rl.WHITE,
				)
			}

		}
	}
	f_pos := local_to_global(global_to_local(get_global_mouse_position()))
	rl.DrawRectangleLinesEx(
		{auto_cast f_pos.x, auto_cast f_pos.y, 16 * zoom, 16 * zoom},
		2,
		rl.RAYWHITE,
	)
	rl.DrawRectangle(auto_cast target.x, auto_cast target.y, 16, 16, rl.WHITE)
	rl.DrawRectangle(0, 0, i32(16 * zoom), i32(16 * zoom), rl.RAYWHITE)
}
game_state: GameState
main :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE})
	rl.InitWindow(auto_cast width, auto_cast height, "Terraria Clone")
	defer rl.CloseWindow()

	init()

	for !rl.WindowShouldClose() {
		update()
		draw()
	}
}
