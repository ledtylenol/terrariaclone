package main

import "core:math"
import rl "vendor:raylib"

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
local_to_chunk :: proc(pos: IVec2) -> IVec2 {
	using game_state.camera
	return pos / (32 * i64(zoom))
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
