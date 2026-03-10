import bananagrams.{
  type Bunch, type Hand, type Tile, type WordDirection, Down, Right,
}
import gleam/dict
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/regexp
import gleam/result
import gleam/set
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import vec/vec2

type GameState {
  Setup
  Playing
  GameOver
}

type Model {
  Model(
    game_state: GameState,
    bunch: Bunch,
    hands: List(Hand),
    current_hand: Result(Hand, Nil),
    cursor: vec2.Vec2(Int),
    cursor_direction: WordDirection,
    tile_to_dump: Result(Tile, Nil),
  )
}

type Msg {
  SplitButtonClicked
  PeelButtonClicked
  KeyPressed(key: String)
  DumpInitiated(tile: Tile)
  Dump(tile: Tile)
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    SplitButtonClicked -> {
      let #(bunch, hands) =
        bananagrams.split(
          model.bunch,
          1,
          // TODO: multiplayer
          seed: float.random() *. 1000.0 |> float.round,
        )
      #(
        Model(
          ..model,
          game_state: Playing,
          bunch: bunch,
          hands: hands,
          current_hand: hands |> list.first,
        ),
        effect.none(),
      )
    }
    PeelButtonClicked -> {
      let #(bunch, hands) =
        bananagrams.peel(
          model.bunch,
          model.hands,
          seed: float.random() *. 1000.0 |> float.round,
        )
      #(
        Model(
          ..model,
          bunch: bunch,
          hands: hands,
          current_hand: hands |> list.first,
        ),
        effect.none(),
      )
    }
    KeyPressed(key) -> {
      io.println(key)
      update_for_keypress(model, key)
    }
    DumpInitiated(tile) -> {
      #(Model(..model, tile_to_dump: Ok(tile)), effect.none())
    }
    Dump(tile) -> {
      case model.current_hand {
        Error(_) -> #(model, effect.none())
        // TODO: make unrepresentable
        Ok(hand) -> {
          let #(new_bunch, new_hand) = bananagrams.dump(model.bunch, hand, tile)
          #(
            Model(
              ..model,
              bunch: new_bunch,
              current_hand: Ok(new_hand),
              hands: [
                new_hand,
                ..{ model.hands |> list.rest |> result.unwrap([]) }
              ],
              tile_to_dump: Error(Nil),
            ),
            effect.none(),
          )
        }
      }
    }
  }
}

type CursorDirection {
  CursorLeft
  CursorRight
  CursorDown
  CursorUp
}

fn update_for_keypress(model: Model, key: String) -> #(Model, Effect(Msg)) {
  let assert Ok(re) = regexp.from_string("^[A-Za-z]$")
  case regexp.check(re, key) {
    True -> {
      case model.current_hand {
        Error(_) -> #(model, effect.none())
        // TODO: make unrepresentable
        Ok(hand) -> {
          let new_hand =
            bananagrams.place_word(
              hand,
              key |> string.uppercase,
              model.cursor,
              model.cursor_direction,
            )
          let new_cursor = case model.cursor_direction {
            Right -> vec2.Vec2(int.min(15, model.cursor.x + 1), model.cursor.y)
            Down -> vec2.Vec2(model.cursor.x, int.min(15, model.cursor.y + 1))
          }
          #(
            Model(
              ..model,
              tile_to_dump: Error(Nil),
              cursor: new_cursor,
              current_hand: Ok(new_hand),
              hands: [
                new_hand,
                ..{ model.hands |> list.rest |> result.unwrap([]) }
              ],
            ),
            effect.none(),
          )
        }
      }
    }
    False -> {
      case key {
        "ArrowLeft" -> update_cursor(model, move: CursorLeft)
        "ArrowRight" -> update_cursor(model, move: CursorRight)
        "ArrowDown" -> update_cursor(model, move: CursorDown)
        "ArrowUp" -> update_cursor(model, move: CursorUp)
        " " -> {
          let new_direction = case model.cursor_direction {
            Right -> Down
            Down -> Right
          }
          #(
            Model(
              ..model,
              tile_to_dump: Error(Nil),
              cursor_direction: new_direction,
            ),
            effect.none(),
          )
        }
        "Backspace" -> {
          case model.current_hand {
            Error(_) -> #(model, effect.none())
            // TODO: make unrepresentable
            Ok(hand) -> {
              let new_cursor = case model.cursor_direction {
                Right ->
                  vec2.Vec2(int.max(0, model.cursor.x - 1), model.cursor.y)
                Down ->
                  vec2.Vec2(model.cursor.x, int.max(0, model.cursor.y - 1))
              }
              let new_hand =
                bananagrams.remove_letter(from: hand, at: model.cursor)
              #(
                Model(
                  ..model,
                  tile_to_dump: Error(Nil),
                  cursor: new_cursor,
                  current_hand: Ok(new_hand),
                  hands: [
                    new_hand,
                    ..{ model.hands |> list.rest |> result.unwrap([]) }
                  ],
                ),
                effect.none(),
              )
            }
          }
        }
        _ -> #(model, effect.none())
      }
    }
  }
}

fn update_cursor(
  model: Model,
  move direction: CursorDirection,
) -> #(Model, Effect(Msg)) {
  case direction {
    CursorLeft -> #(
      Model(
        ..model,
        tile_to_dump: Error(Nil),
        cursor: vec2.Vec2(int.clamp(model.cursor.x - 1, 0, 15), model.cursor.y),
      ),
      effect.none(),
    )
    CursorRight -> #(
      Model(
        ..model,
        tile_to_dump: Error(Nil),
        cursor: vec2.Vec2(int.clamp(model.cursor.x + 1, 0, 15), model.cursor.y),
      ),
      effect.none(),
    )
    CursorDown -> #(
      Model(
        ..model,
        tile_to_dump: Error(Nil),
        cursor: vec2.Vec2(model.cursor.x, int.clamp(model.cursor.y + 1, 0, 15)),
      ),
      effect.none(),
    )
    CursorUp -> #(
      Model(
        ..model,
        tile_to_dump: Error(Nil),
        cursor: vec2.Vec2(model.cursor.x, int.clamp(model.cursor.y - 1, 0, 15)),
      ),
      effect.none(),
    )
  }
}

fn init(_: Nil) {
  #(
    Model(
      game_state: Setup,
      bunch: bananagrams.new(),
      cursor: vec2.Vec2(4, 7),
      cursor_direction: Right,
      hands: [],
      current_hand: Error(Nil),
      tile_to_dump: Error(Nil),
    ),
    effect.none(),
  )
}

fn view(model: Model) -> Element(Msg) {
  html.div(
    [
      event.on_keyup(KeyPressed),
      attribute.tabindex(0),
      attribute.autofocus(True),
    ],
    content(model),
  )
}

fn content(model: Model) -> List(Element(Msg)) {
  case model.game_state {
    Setup -> {
      html.button(
        [
          event.on_click(SplitButtonClicked),
        ],
        [element.text("SPLIT!")],
      )
      |> list.wrap
    }
    Playing -> {
      [
        html.div(
          [
            attribute.id("play-content"),
          ],
          [
            grid(model),
            pile(model),
            info(model),
          ],
        ),
      ]
    }
    GameOver -> {
      element.text("Game Over!") |> list.wrap
    }
  }
}

fn pile(model: Model) -> Element(Msg) {
  let tiles = case model.current_hand {
    Error(_) -> []
    Ok(hand) -> {
      hand.pile
      |> set.to_list
    }
  }
  let dump_hint = case model.tile_to_dump {
    Error(_) -> "Click a letter to dump"
    Ok(_) -> "Click again to confirm"
  }
  case list.is_empty(tiles) {
    True -> {
      html.button(
        [
          event.on_click(PeelButtonClicked),
          attribute.id("peel-button"),
        ],
        [element.text("PEEL!")],
      )
    }
    False -> {
      html.div(
        [
          attribute.id("pile"),
        ],
        [
          html.div([
            ], 
            tiles
              |> batch(4)
              |> list.map(fn(l) { pile_row(model, l) })
          ), 
          html.em([], [element.text(dump_hint)])
        ],
      )
    }
  }
}

fn pile_row(model: Model, tiles: List(Tile)) -> Element(Msg) {
  html.div([attribute.class("pile-row")], {
    tiles
    |> list.map(fn(tile) {
      let is_dumping_tile = Ok(tile) == model.tile_to_dump
      let on_click = case is_dumping_tile {
        True -> Dump(tile: tile)
        False -> DumpInitiated(tile: tile)
      }
      html.div(
        [
          attribute.class("tile"),
          attribute.classes([#("dumping-tile", is_dumping_tile)]),
          event.on_click(on_click),
        ],
        [element.text(bananagrams.tile_to_letter(tile))],
      )
    })
  })
}

fn info(model: Model) {
  html.div(
    [
      attribute.class("info")
    ],
    [
      element.text("Remaining letters: " <> { int.to_string(bananagrams.bunch_size(model.bunch)) })
    ]
  )
}

fn batch(l: List(a), batch_size: Int) -> List(List(a)) {
  let #(final_list, last_list, _) =
    l
    |> list.fold(#([], [], 0), fn(acc, el) {
      let #(lol, curr_list, i) = acc
      case i < batch_size {
        True -> #(lol, [el, ..curr_list], i + 1)
        False -> #([curr_list, ..lol], [el], 1)
      }
    })
  [last_list, ..final_list] |> list.reverse
}

fn grid(model: Model) -> Element(Msg) {
  let rows =
    list.repeat(Nil, 16)
    |> list.index_map(fn(_, i) { row(model, y: i) })
  html.div(
    [attribute.id("grid")], 
    [
      html.div([], rows),
      html.em([attribute.class("type-hint")], [element.text("Type to place a letter")])
    ]
  )
}

fn row(model: Model, y y: Int) -> Element(Msg) {
  let cells =
    list.repeat(Nil, 16)
    |> list.index_map(fn(_, i) { cell(model, x: i, y: y) })
  html.div([attribute.class("row")], cells)
}

fn cell(model: Model, x x: Int, y y: Int) -> Element(Msg) {
  let letter = case model.current_hand {
    Error(_) -> ""
    Ok(hand) -> {
      case dict.get(hand.grid, vec2.Vec2(x, y)) {
        Error(_) -> ""
        Ok(tile) -> bananagrams.tile_to_letter(tile)
      }
    }
  }
  let vec2.Vec2(cursor_x, cursor_y) = model.cursor
  let right_x = x - 1
  let below_y = y - 1
  case cursor_x == x, cursor_y == y, model.cursor_direction {
    True, True, Right -> right_cursor_cell(model, letter, x: x, y: y)
    True, True, Down -> down_cursor_cell(model, letter, x: x, y: y)
    False, True, Right if cursor_x == right_x ->
      right_of_cursor_cell(model, letter, x: x, y: y)
    True, False, Down if cursor_y == below_y ->
      below_cursor_cell(model, letter, x: x, y: y)
    _, _, _ -> {
      html.div(
        [
          attribute.class("cell"),
        ],
        [
          element.text(letter),
        ],
      )
    }
  }
}

fn right_cursor_cell(model: Model, letter: String, x x: Int, y y: Int) {
  html.div(
    [
      attribute.class("cell"),
      attribute.class("cursor"),
      attribute.class("cursor-right"),
    ],
    [
      svg.svg(
        [
          attribute.attribute("width", "58"),
          attribute.attribute("height", "50"),
        ],
        [
          svg.polyline([
            attribute.attribute("points", "53,0 58,25 53,50"),
            attribute.attribute("fill", "gray"),
            attribute.attribute("stroke", "#E0CA3C"),
            attribute.attribute("stroke-width", "2"),
          ]),
        ],
      ),
      element.text(letter),
    ],
  )
}

fn down_cursor_cell(model: Model, letter: String, x x: Int, y y: Int) {
  html.div(
    [
      attribute.class("cell"),
      attribute.class("cursor"),
      attribute.class("cursor-down"),
    ],
    [
      svg.svg(
        [
          attribute.attribute("width", "50"),
          attribute.attribute("height", "60"),
        ],
        [
          svg.polyline([
            attribute.attribute("points", "0,55 25,60 50,55"),
            attribute.attribute("fill", "gray"),
            attribute.attribute("stroke", "#E0CA3C"),
            attribute.attribute("stroke-width", "2"),
          ]),
        ],
      ),
      element.text(letter),
    ],
  )
}

fn right_of_cursor_cell(model: Model, letter: String, x x: Int, y y: Int) {
  html.div([attribute.class("cell"), attribute.class("cursor-right-next")], [
    element.text(letter),
  ])
}

fn below_cursor_cell(model: Model, letter: String, x x: Int, y y: Int) {
  html.div([attribute.class("cell"), attribute.class("cursor-down-next")], [
    element.text(letter),
  ])
}

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#ui", Nil)

  Nil
}
