import bananagrams.{type Bunch}
import bridge_msg.{type BridgeMsg}
import game_ui
import gleam/float
import gleam/int
import gleam/list
import gleam/option
import gleam/time/duration
import paint as p
import paint/canvas
import tiramisu
import tiramisu/background
import tiramisu/camera
import tiramisu/effect.{type Effect}
import tiramisu/geometry
import tiramisu/input
import tiramisu/light
import tiramisu/material
import tiramisu/scene
import tiramisu/transform
import tiramisu/ui
import vec/vec2
import vec/vec3

pub type Model {
  Model(time: Float, bunch: Bunch, cursor: vec2.Vec2(Int))
}

pub type Msg {
  Tick
  BackgroundSet
  FromBridge(BridgeMsg)
}

pub fn main() -> Nil {
  let bridge = ui.new_bridge()
  game_ui.start(bridge)
  let assert Ok(Nil) =
    tiramisu.application(init:, update:, view:)
    |> tiramisu.start("#game", tiramisu.FullScreen, option.Some(#(bridge, FromBridge)))
  Nil
}

fn init(ctx: tiramisu.Context) -> #(Model, Effect(Msg), option.Option(_)) {
  let bg_effect =
    background.set(
      ctx.scene,
      background.Color(0x1a1a2e),
      BackgroundSet,
      BackgroundSet,
    )
  canvas.define_web_component()

  #(
    Model(time: 0.0, bunch: bananagrams.new(), cursor: vec2.Vec2(7, 7)),
    effect.batch([bg_effect, effect.dispatch(Tick)]),
    option.None,
  )
}

fn update(
  model: Model,
  msg: Msg,
  ctx: tiramisu.Context,
) -> #(Model, Effect(Msg), option.Option(_)) {
  case msg {
    Tick -> {
      let delta_seconds = duration.to_seconds(ctx.delta_time)
      let new_time = model.time +. delta_seconds
      let cursor = update_cursor(model.cursor, ctx)
      #(
        Model(time: new_time, bunch: model.bunch, cursor: cursor),
        effect.dispatch(Tick),
        option.None,
      )
    }
    BackgroundSet -> #(model, effect.none(), option.None)
    FromBridge(bridge_msg.WordSubmitted(word)) ->
      #(model, effect.none(), option.None)
  }
}

fn update_cursor(
  cursor: vec2.Vec2(Int),
  ctx: tiramisu.Context,
) -> vec2.Vec2(Int) {
  case input.is_key_just_pressed(ctx.input, input.ArrowLeft) {
    True -> vec2.Vec2(int.clamp(cursor.x - 1, 0, 15), cursor.y)
    False -> {
      case input.is_key_just_pressed(ctx.input, input.ArrowRight) {
        True -> vec2.Vec2(int.clamp(cursor.x + 1, 0, 15), cursor.y)
        False -> {
          case input.is_key_just_pressed(ctx.input, input.ArrowUp) {
            True -> vec2.Vec2(cursor.x, int.clamp(cursor.y - 1, 0, 15))
            False -> {
              case input.is_key_just_pressed(ctx.input, input.ArrowDown) {
                True -> vec2.Vec2(cursor.x, int.clamp(cursor.y + 1, 0, 15))
                False -> cursor
              }
            }
          }
        }
      }
    }
  }
}

fn grid_picture() -> p.Picture {
  let stroke = fn(s) { p.stroke(s, p.colour_rgb(200, 200, 100), 2.0) }
  let horizons =
    list.repeat(0, times: 17)
    |> list.index_map(fn(_, i) {
      p.rectangle(800.0, 0.0) |> p.translate_y(50.0 *. int.to_float(i))
    })
  let verts =
    list.repeat(0, times: 17)
    |> list.index_map(fn(_, i) {
      p.rectangle(0.0, 800.0) |> p.translate_x(50.0 *. int.to_float(i))
    })
  p.combine(list.append(horizons, verts)) |> stroke
}

fn cursor(pos: vec2.Vec2(Int)) -> scene.Node {
  let assert Ok(geom) = geometry.box(size: vec3.Vec3(48.0, 48.0, 0.1))
  let assert Ok(mat) =
    material.new()
    |> material.with_color(0x00ff00)
    |> material.with_transparent(True)
    |> material.with_opacity(0.8)
    |> material.build()
  // (8, 7) -> (25.0, 25.0, 100.0)
  // y - y1 = m * (x - x1)
  // y - 25 = 50 * (x - 8)
  // y = 50 * (x - 8) + 25
  let x = 50.0 *. int.to_float(pos.x - 8) +. 25.0
  let y = -50.0 *. int.to_float(pos.y - 7) +. 25.0
  scene.mesh(
    id: "cursor",
    geometry: geom,
    material: mat,
    transform: transform.at(position: vec3.Vec3(x, y, 100.0)),
    physics: option.None,
  )
}

fn view(model: Model, ctx: tiramisu.Context) -> scene.Node {
  let cam =
    camera.camera_2d(size: vec2.Vec2(
      float.round(ctx.canvas_size.x),
      float.round(ctx.canvas_size.y),
    ))
  scene.empty(id: "Scene", transform: transform.identity, children: [
    scene.camera(
      id: "camera",
      camera: cam,
      transform: transform.at(position: vec3.Vec3(0.0, 0.0, 150.0)),
      active: True,
      viewport: option.None,
      postprocessing: option.None,
    ),
    scene.light(
      id: "ambient",
      light: {
        let assert Ok(light) = light.ambient(color: 0xffffff, intensity: 1.0)
        light
      },
      transform: transform.identity,
    ),
    scene.canvas(
      id: "grid",
      picture: grid_picture(),
      texture_size: vec2.Vec2(800, 800),
      size: vec2.Vec2(800.0, 800.0),
      transform: transform.at(position: vec3.Vec3(0.0, 0.0, 0.0)),
    ),
    cursor(model.cursor),
  ])
}
