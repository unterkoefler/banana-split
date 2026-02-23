import gleam/float
import gleam/option
import gleam/time/duration
import paint as p
import paint/canvas
import tiramisu
import tiramisu/background
import tiramisu/camera
import tiramisu/effect.{type Effect}
import tiramisu/geometry
import tiramisu/light
import tiramisu/material
import tiramisu/scene
import tiramisu/transform
import vec/vec2
import vec/vec3
import bananagrams.{type Bunch}

pub type Model {
  Model(time: Float, bunch: Bunch)
}


pub type Msg {
  Tick
  BackgroundSet
}

pub fn main() -> Nil {
  let assert Ok(Nil) = tiramisu.application(init:, update:, view:)
  |> tiramisu.start("#app", tiramisu.FullScreen, option.None)
  Nil
}

fn init(ctx: tiramisu.Context) -> #(Model, Effect(Msg), option.Option(_)) {
  let bg_effect = background.set(ctx.scene, background.Color(0x1a1a2e), BackgroundSet, BackgroundSet)
  #(Model(time: 0.0, bunch: bananagrams.new()), effect.batch([bg_effect, effect.dispatch(Tick)]), option.None)
  canvas.define_web_component()
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
      #(Model(time: new_time, bunch: model.bunch), effect.dispatch(Tick), option.None)
    }
    BackgroundSet -> #(model, effect.none(), option.None)
  }
}

fn grid_picture() -> p.Picture {
  let stroke = fn(s) { p.stroke(s, p.colour_rgb(200, 200, 100), 2.0) }
  let horizons = list.repeat(0, times: 17) |> list.index_map(fn(_, i) {
    p.rectangle(800.0, 0.0) |> p.translate_y(50.0 *. int.to_float(i))
  })
  let verts = list.repeat(0, times: 17) |> list.index_map(fn(_, i) {
    p.rectangle(0.0, 800.0) |> p.translate_x(50.0 *. int.to_float(i))
  })
  p.combine(list.append(horizons, verts)) |> stroke
}

fn view(model: Model, ctx: tiramisu.Context) -> scene.Node {
  let cam = camera.camera_2d(
    size: vec2.Vec2(float.round(ctx.canvas_size.x), float.round(ctx.canvas_size.y)),
  )
  let assert Ok(sprite_geom) = geometry.plane(size: vec2.Vec2(50.0, 50.0))
  let assert Ok(sprite_mat) = material.basic(
    color: 0xff0066,
    transparent: False,
    opacity: 1.0,
    map: option.None,
    side: material.FrontSide,
    alpha_test: 0.0,
    depth_write: True,
  )

  scene.empty(id: "Scene", transform: transform.identity, children: [
    scene.camera(
      id: "camera",
      camera: cam,
      transform: transform.at(position: vec3.Vec3(0.0, 0.0, 20.0)),
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
  ])
}
