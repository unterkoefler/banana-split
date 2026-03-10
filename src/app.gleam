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
  )
}

type Msg {
  SplitButtonClicked
  PeelButtonClicked
  KeyPressed(key: String)
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    SplitButtonClicked -> {
      let #(bunch, hands) =
        bananagrams.split(
          model.bunch,
          1,
          // TODO: multiplayer
          seed: 13.4 |> float.round,
          // TODO: get time to use for seed
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
          seed: 13,
          // TODO: use time for random seed
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
          #(Model(..model, cursor_direction: new_direction), effect.none())
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
        cursor: vec2.Vec2(int.clamp(model.cursor.x - 1, 0, 15), model.cursor.y),
      ),
      effect.none(),
    )
    CursorRight -> #(
      Model(
        ..model,
        cursor: vec2.Vec2(int.clamp(model.cursor.x + 1, 0, 15), model.cursor.y),
      ),
      effect.none(),
    )
    CursorDown -> #(
      Model(
        ..model,
        cursor: vec2.Vec2(model.cursor.x, int.clamp(model.cursor.y + 1, 0, 15)),
      ),
      effect.none(),
    )
    CursorUp -> #(
      Model(
        ..model,
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
            html.button(
              [
                event.on_click(PeelButtonClicked),
                attribute.id("peel-button"),
              ],
              [element.text("PEEL!")],
            ),
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
      |> batch(4)
      |> list.map(pile_row)
    }
  }
  html.div(
    [
      attribute.id("pile"),
    ],
    tiles,
  )
}

fn pile_row(tiles: List(Tile)) -> Element(Msg) {
  html.div([attribute.class("pile-row")], {
    tiles
    |> list.map(fn(tile) {
      html.div(
        [
          attribute.class("tile"),
        ],
        [element.text(bananagrams.tile_to_letter(tile))],
      )
    })
  })
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
  html.div([attribute.id("grid")], rows)
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
