package main

import "core:fmt"
import "core:math"
import "core:math/linalg/glsl"
import "core:math/rand"
import "core:strings"
import "core:thread"
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

Chunk :: struct {
	tiles: [32][32]TileData,
}
IVec2 :: [2]i64

Setting :: enum {
	TICKRATE,
}
atlases: [SpriteAtlases]rl.Texture2D
GameState :: struct {
	entities: #soa[dynamic]Entity,
	chunks:   map[IVec2]Chunk,
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
	return {i64(math.floor(pos.x / (8 * zoom))), i64(math.floor(pos.y / (8 * zoom)))}
}
global_to_chunk :: proc(pos: Vec2) -> IVec2 {
	using game_state.camera
	return {i64(math.floor(pos.x / (8 * 32 * zoom))), i64(math.floor(pos.y / (8 * 32 * zoom)))}
}
local_to_global :: proc(pos: IVec2) -> Vec2 {
	using game_state.camera
	return {f32(pos.x) * (8 * zoom), f32(pos.y) * 8 * zoom}
}

chunk_fract :: proc(pos: Vec2) -> IVec2 {
	chunk_global := chunk_to_global(global_to_chunk(pos))
	return global_to_local(pos - chunk_global)
}
chunk_to_global :: proc(pos: IVec2) -> Vec2 {
	using game_state.camera
	return {f32(pos.x) * (8 * 32 * zoom), f32(pos.y) * (8 * 32 * zoom)}
}

global_pos_in_chunk :: proc(c_pos: IVec2, tile_pos: IVec2) -> Vec2 {
	return local_to_global(tile_pos) + chunk_to_global(c_pos)
}

get_global_mouse_position :: proc() -> Vec2 {
	using game_state.camera
	return rl.GetMousePosition() / zoom - offset / zoom + target
}
get_local_mouse_position :: proc() -> IVec2 {
	return global_to_local(get_global_mouse_position())
}
get_chunk_mouse_position :: proc() -> IVec2 {
	return global_to_chunk(get_global_mouse_position())
}
generate_world :: proc(
	seed: int = 0,
	frequency: f32 = 1.0,
	rec: rl.Rectangle,
	heightmap_freq: f32 = 1.0,
) {
	ThreadGen :: struct {
		chunk_pos: IVec2,
		state:     ^fast_noise.FNL_State,
		chunk:     Chunk,
	}
	generate_chunk :: proc(t: thread.Task) {
		datas := cast(^[]ThreadGen)t.data
		local_pos: IVec2 = {auto_cast t.user_index % 32, auto_cast t.user_index / 32}
		x, y := local_pos.x, local_pos.y
		state := datas[t.user_index].state
		chunk := Chunk{}
		for cy in 0 ..< 32 {
			for cx in 0 ..< 32 {
				pos := global_pos_in_chunk(local_pos, IVec2{auto_cast cx, auto_cast cy})
				tile := TileData{}
				tile.type = get_tile_from_step(
					fast_noise.get_noise_2d(state, pos.x / 10.0, pos.y / 10.0),
				)
				chunk.tiles[cy][cx] = tile
			}
		}
		datas[t.user_index].chunk = chunk
		fmt.println("thread done ", local_pos)

	}
	// clear_map(&game_state.tiles)
	state := fast_noise.create_state(seed)
	state.noise_type = .Perlin
	state.frequency = frequency
	state.octaves = 3

	local_pos := global_to_chunk({rec.x, rec.y})
	local_scale := IVec2{auto_cast rec.width, auto_cast rec.height} + IVec2{1, 1}

	pool: thread.Pool
	thread.pool_init(&pool, thread_count = 8, allocator = context.allocator)
	defer thread.pool_destroy(&pool)


	datas := make([]ThreadGen, local_scale.x * local_scale.y)
	defer delete(datas)
	for y in 0 ..< local_scale.y {
		for x in 0 ..< local_scale.x {
			pos := IVec2{x, y}
			datas[x + 32 * y] = ThreadGen{pos, &state, {}}
			thread.pool_add_task(
				&pool,
				allocator = context.allocator,
				procedure = generate_chunk,
				data = &datas,
				user_index = int(x + 32 * y),
			)
		}
	}
	thread.pool_start(&pool)
	for !thread.pool_is_empty(&pool) {
		task := thread.pool_pop_done(&pool) or_continue
		gendata := (cast(^[]ThreadGen)task.data)[task.user_index]
		game_state.chunks[gendata.chunk_pos + local_pos] = gendata.chunk
		fmt.println(thread.pool_num_done(&pool), " tasks left ", gendata.chunk_pos)
	}
	thread.pool_finish(&pool)
	// state = fast_noise.create_state(seed + 5)
	// state.frequency = heightmap_freq
	// for i in -i64(rec.width) ..= i64(rec.width) {
	// 	chunk := game_state.chunks[IVec2{0, i} + local_pos]
	// 	for z in 0 ..< 32 {
	// 		thres := i64(fast_noise.get_noise_2d(&state, f32(i) / 100 + f32(z) / 100, 0) * 30)
	// 		for j in 0 ..= thres {
	// 			chunk.tiles[j][z] = TileData{.AIR, 0}
	// 		}
	// 	}
	// }
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
		rec = {0, 0, 40, 10},
		heightmap_freq = 1.0,
	)
	game_state.settings[.TICKRATE] = 20
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
}


tick_tiles :: proc() {
	using game_state.camera
	pos := global_to_chunk(target)
	dt := rl.GetFrameTime()
	size_f := Vec2{f32(rl.GetRenderWidth()), f32(rl.GetRenderHeight())}
	chunks := global_to_chunk(size_f)

	for y in -chunks.y ..= chunks.y {

		for x in -chunks.x ..= chunks.x {
			tick(IVec2{x, y} + pos)
		}
	}
}

tick :: proc(chunk_pos: IVec2) {
	if chunk, ok := &game_state.chunks[chunk_pos]; ok {
		for &tile_row, y in chunk.tiles {
			for &tile, x in tile_row {
				#partial switch tile.type {
				case .SAND:
					if y == 31 {
						next_chunk := (&game_state.chunks[chunk_pos + {0, 1}]) or_break
						if next_chunk.tiles[0][x].type == .AIR {
							next_chunk.tiles[0][x], tile = tile, next_chunk.tiles[0][x]
						}
						break
					} else if y == 32 {break}
					next_tile := &chunk.tiles[y + 1][x]
					if next_tile.type == .AIR {
						next_tile^, tile = tile, next_tile^
					}
				}
			}
		}
	}
}

get_fract_mouse_pos :: proc() -> Vec2 {
	zoom := game_state.camera.zoom
	mouse_pos := get_global_mouse_position() / (zoom * 8)
	fract_x, fract_y := glsl.fract(mouse_pos.x), glsl.fract(mouse_pos.y)
	if fract_x < 0 {fract_x = abs(-fract_x - 1)}
	if fract_y < 0 {fract_y = abs(-fract_y - 1)}
	return Vec2{fract_x, fract_y}
}


draw :: proc() {
	rl.BeginDrawing()
	rl.BeginMode2D(game_state.camera)
	rl.ClearBackground(rl.BLUE)
	draw_tiles()

	rl.EndMode2D()
	rl.DrawFPS(30, 30)
	mouse_pos := get_fract_mouse_pos()
	if tile, ok := get_mouse_tile(); ok {
		rl.DrawText(
			fmt.caprint(
				tile.type,
				tile.tick,
				'\n',
				mouse_pos,
				'\n',
				get_chunk_mouse_position(),
				'\n',
				chunk_fract(get_global_mouse_position()),
			),
			i32(rl.GetMousePosition().x),
			i32(rl.GetMousePosition().y) + 15,
			20,
			rl.WHITE,
		)
	}
	tickrate := fmt.caprintf("%.0f", game_state.settings[.TICKRATE])
	rect := rl.Rectangle{60, 60, 120, 40}
	rl.GuiSetStyle(.DEFAULT, auto_cast rl.GuiDefaultProperty.TEXT_SIZE, 40)
	rl.GuiSliderBar(rect, "tps", tickrate, &game_state.settings[.TICKRATE], 1, 100)
	rl.EndDrawing()
	free_all(context.temp_allocator)
}

get_mouse_tile :: proc() -> (TileData, bool) {
	data := TileData{}
	local := get_chunk_mouse_position()
	tile := TileData{}
	if chunk, ok := game_state.chunks[local]; ok {
		fract := chunk_fract(get_global_mouse_position())
		tile = chunk.tiles[fract.y][fract.x]
		return tile, true
	}
	return tile, false
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
	pos := global_to_chunk(target)

	size_f := Vec2{f32(rl.GetRenderWidth()), f32(rl.GetRenderHeight())}
	tiles := global_to_chunk(size_f)
	for j in -tiles.y - 1 ..= tiles.y + 1 {
		for i in -tiles.x - 1 ..= tiles.x + 1 {
			key := IVec2{j, i} + pos
			chunk := game_state.chunks[key] or_continue
			for row, y in chunk.tiles {
				for tile, x in row {
					rect := get_tile_rect(tile.type)
					global_pos := global_pos_in_chunk(key, IVec2{auto_cast x, auto_cast y})

					rl.DrawTexturePro(
						atlases[.TERRAIN],
						rect,
						{global_pos.x, global_pos.y, 8 * zoom, 8 * zoom},
						{0, 0},
						0.0,
						rl.WHITE,
					)
				}
			}
		}
	}
	f_pos := local_to_global(global_to_local(get_global_mouse_position()))
	rl.DrawRectangleLinesEx(
		{auto_cast f_pos.x, auto_cast f_pos.y, 8 * zoom, 8 * zoom},
		2,
		rl.RAYWHITE,
	)
	rl.DrawRectangle(auto_cast target.x, auto_cast target.y, 8, 8, rl.WHITE)
	rl.DrawRectangle(0, 0, i32(8 * zoom), i32(8 * zoom), rl.RAYWHITE)
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
