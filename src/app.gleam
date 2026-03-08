import bananagrams.{type Bunch, type Hand, type WordDirection, Down, Right}
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
        html.button(
          [
            event.on_click(PeelButtonClicked),
            attribute.tabindex(-1),
          ],
          [element.text("PEEL!")],
        ),
        grid(model),
        pile(model),
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
      |> list.map(fn(tile) {
        html.div(
          [
            attribute.class("tile"),
          ],
          [element.text(bananagrams.tile_to_letter(tile))],
        )
      })
    }
  }
  html.div(
    [
      attribute.id("pile"),
    ],
    tiles,
  )
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
  let is_cursor = model.cursor == vec2.Vec2(x, y)
  let is_cursor_right = model.cursor_direction == Right
  let is_cursor_down = model.cursor_direction == Down
  html.div(
    [
      attribute.class("cell"),
    ],
    [
      html.div(
        [
          attribute.class("cell-inner"),
          attribute.classes([
            #("cursor", is_cursor),
            #("cursor-right", is_cursor_right),
            #("cursor-down", is_cursor_down),
          ]),
        ],
        [element.text(letter)],
      ),
    ],
  )
}

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#ui", Nil)

  Nil
}
