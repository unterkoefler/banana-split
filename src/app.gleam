import bananagrams.{
  type Bunch, type Hand, type Tile, type WordDirection, Down, Right,
}
import bridge_msg.{type BridgeMsg}
import game_ui
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option
import gleam/set
import gleam/time/duration
import paint as p
import paint/canvas
import savoiardi
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
  Model(
    time: Float,
    bunch: Bunch,
    hands: List(Hand),
    cursor: vec2.Vec2(Int),
    cursor_direction: WordDirection,
    font: option.Option(savoiardi.Font),
  )
}

pub type Msg {
  Tick
  BackgroundSet
  FromBridge(BridgeMsg)
  FontLoaded(savoiardi.Font)
  FontLoadFailed
}

pub fn main() -> Nil {
  let bridge = ui.new_bridge()
  game_ui.start(bridge)
  let assert Ok(Nil) =
    tiramisu.application(init:, update:, view:)
    |> tiramisu.start(
      "#game",
      tiramisu.FullScreen,
      option.Some(#(bridge, FromBridge)),
    )
  Nil
}

fn init(ctx: tiramisu.Context) -> #(Model, Effect(Msg), option.Option(_)) {
  let bg_effect =
    background.set(
      ctx.scene,
      background.Color(0xffffff),
      //0x1a1a2e),
      BackgroundSet,
      BackgroundSet,
    )
  canvas.define_web_component()
  let #(bunch, hands) = bananagrams.split(bananagrams.new(), 1)

  #(
    Model(
      time: 0.0,
      bunch: bunch,
      cursor: vec2.Vec2(4, 7),
      cursor_direction: Right,
      font: option.None,
      hands: hands,
    ),
    effect.batch([
      bg_effect,
      effect.dispatch(Tick),
      geometry.load_font(
        from: "/fonts/work-sans.json",
        on_success: FontLoaded,
        on_error: FontLoadFailed,
      ),
    ]),
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
      let #(cursor, cursor_direction) =
        update_cursor(model.cursor, model.cursor_direction, ctx)
      let new_hands = update_hands(model.hands, cursor, ctx)
      #(
        Model(
          time: new_time,
          bunch: model.bunch,
          cursor: cursor,
          cursor_direction: cursor_direction,
          font: model.font,
          hands: new_hands,
        ),
        effect.dispatch(Tick),
        option.None,
      )
    }
    BackgroundSet -> #(model, effect.none(), option.None)
    FromBridge(bridge_msg.WordSubmitted(word)) ->
      case model.hands {
        [] -> #(model, effect.none(), option.None)
        [hand, ..rest] -> {
          let new_hand =
            bananagrams.place_word(
              hand,
              word,
              model.cursor,
              model.cursor_direction,
            )
          let new_hands = [new_hand, ..rest]
          #(
            Model(
              time: model.time,
              bunch: model.bunch,
              cursor: model.cursor,
              font: model.font,
              cursor_direction: model.cursor_direction,
              hands: new_hands,
            ),
            effect.none(),
            option.None,
          )
        }
      }

    FontLoaded(font) -> #(
      Model(
        time: model.time,
        bunch: model.bunch,
        cursor: model.cursor,
        cursor_direction: model.cursor_direction,
        font: option.Some(font),
        hands: model.hands,
      ),
      effect.none(),
      option.None,
    )
    FontLoadFailed -> #(model, effect.none(), option.None)
  }
}

fn update_hands(hands: List(Hand), cursor: vec2.Vec2(Int), ctx: tiramisu.Context) -> List(Hand) {
  case hands {
    [first, ..rest] -> {
      case input.is_key_just_pressed(ctx.input, input.Backspace) {
        True -> [bananagrams.remove_letter(from: first, at: cursor), ..rest]
        False -> hands
      }
    }
    [] -> hands
  }
}

fn update_cursor(
  cursor: vec2.Vec2(Int),
  cursor_direction: WordDirection,
  ctx: tiramisu.Context,
) -> #(vec2.Vec2(Int), WordDirection) {
  case input.is_key_just_pressed(ctx.input, input.ArrowLeft) {
    True -> #(
      vec2.Vec2(int.clamp(cursor.x - 1, 0, 15), cursor.y),
      cursor_direction,
    )
    False -> {
      case input.is_key_just_pressed(ctx.input, input.ArrowRight) {
        True -> #(
          vec2.Vec2(int.clamp(cursor.x + 1, 0, 15), cursor.y),
          cursor_direction,
        )
        False -> {
          case input.is_key_just_pressed(ctx.input, input.ArrowUp) {
            True -> #(
              vec2.Vec2(cursor.x, int.clamp(cursor.y - 1, 0, 15)),
              cursor_direction,
            )
            False -> {
              case input.is_key_just_pressed(ctx.input, input.ArrowDown) {
                True -> #(
                  vec2.Vec2(cursor.x, int.clamp(cursor.y + 1, 0, 15)),
                  cursor_direction,
                )
                False ->
                  case input.is_key_just_pressed(ctx.input, input.Space) {
                    True -> {
                      let new_direction = case cursor_direction {
                        Right -> Down
                        Down -> Right
                      }
                      #(cursor, new_direction)
                    }
                    False -> #(cursor, cursor_direction)
                  }
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

fn grid_to_world(grid_coords: vec2.Vec2(Int), z: Float) -> vec3.Vec3(Float) {
  // (8, 7) -> (25.0, 25.0, 100.0)
  // y - y1 = m * (x - x1)
  // y - 25 = 50 * (x - 8)
  // y = 50 * (x - 8) + 25
  let x = 50.0 *. int.to_float(grid_coords.x - 8) +. 25.0
  let y = -50.0 *. int.to_float(grid_coords.y - 7) +. 25.0
  vec3.Vec3(x, y, z)
}

fn cursor(pos: vec2.Vec2(Int), direction: WordDirection) -> scene.Node {
  let assert Ok(geom) = geometry.box(size: vec3.Vec3(48.0, 48.0, 0.1))
  let assert Ok(mat) =
    material.new()
    |> material.with_color(0x00ff00)
    |> material.with_transparent(True)
    |> material.with_opacity(0.8)
    |> material.build()
  let position = grid_to_world(pos, 100.0)
  let pos2 = case direction {
    Right -> grid_to_world(vec2.Vec2(pos.x + 1, pos.y), 100.0)
    Down -> grid_to_world(vec2.Vec2(pos.x, pos.y + 1), 100.0)
  }
  let pos3 = case direction {
    Right -> grid_to_world(vec2.Vec2(pos.x + 2, pos.y), 100.0)
    Down -> grid_to_world(vec2.Vec2(pos.x, pos.y + 2), 100.0)
  }
  let assert Ok(mat2) =
    material.new()
    |> material.with_color(0x00ff00)
    |> material.with_transparent(True)
    |> material.with_opacity(0.5)
    |> material.build()
  let assert Ok(mat3) =
    material.new()
    |> material.with_color(0x00ff00)
    |> material.with_transparent(True)
    |> material.with_opacity(0.2)
    |> material.build()
  scene.empty(id: "cursor-and-fade", transform: transform.identity, children: [
    scene.mesh(
      id: "cursor",
      geometry: geom,
      material: mat,
      transform: transform.at(position: position),
      physics: option.None,
    ),
    scene.mesh(
      id: "cursor-fade-1",
      geometry: geom,
      material: mat2,
      transform: transform.at(position: pos2),
      physics: option.None,
    ),
    scene.mesh(
      id: "cursor-fade-2",
      geometry: geom,
      material: mat3,
      transform: transform.at(position: pos3),
      physics: option.None,
    ),
  ])
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
    cursor(model.cursor, model.cursor_direction),
    tiles(model),
  ])
}

fn tiles(model: Model) -> scene.Node {
  case model.font {
    option.None ->
      scene.empty(id: "nope", transform: transform.identity, children: [])
    option.Some(loaded_font) -> {
      let grid_tile_nodes =
        model.hands
        |> list.map(fn(hand) {
          // TODO: we really only want to render one hand
          hand.grid
          |> dict.fold([], fn(acc, pos, the_tile) {
            [tile(loaded_font, pos, the_tile), ..acc]
          })
        })
        |> list.flatten
      let pile_tile_nodes =
        model.hands
        |> list.map(fn(hand) {
          hand.pile
          |> set.to_list
          |> list.index_map(fn(the_tile, i) {
            let pos = vec2.Vec2(-8 + { i % 5 }, i / 5)
            tile(loaded_font, pos, the_tile)
          })
        })
        |> list.flatten
      scene.empty(id: "tiles", transform: transform.identity, children: [
        scene.empty(
          id: "grid-tiles",
          transform: transform.identity,
          children: grid_tile_nodes,
        ),
        scene.empty(
          id: "pile-tiles",
          transform: transform.identity,
          children: pile_tile_nodes,
        ),
      ])
    }
  }
}

fn tile(font: savoiardi.Font, pos: vec2.Vec2(Int), the_tile: Tile) -> scene.Node {
  let assert Ok(geom) =
    geometry.text(
      text: bananagrams.tile_to_letter(the_tile),
      font: font,
      depth: 0.2,
      size: 24.0,
      curve_segments: 12,
      bevel_enabled: True,
      bevel_thickness: 0.05,
      bevel_size: 0.02,
      bevel_offset: 0.0,
      bevel_segments: 5,
    )
  let position = grid_to_world(pos, 0.0)
  let assert Ok(mat) =
    material.new()
    |> material.with_color(0x000000)
    |> material.with_transparent(False)
    |> material.build()
  scene.mesh(
    id: bananagrams.tile_to_id(the_tile),
    geometry: geom,
    material: mat,
    transform: transform.at(position: position)
      |> transform.translate(vec3.Vec3(-12.5, -12.5, 0.0)),
    physics: option.None,
  )
}
