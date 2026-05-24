import bananagrams.{type Bunch, type Hand, type WordDirection, Down, Right}
import gleam/dict
import gleam/dynamic/decode
import gleam/float
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option
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
import lustre_websocket as ws
import plinth/browser/clipboard
import plinth/browser/document
import plinth/browser/event as plinth_event
import rsvp
import shared.{type Player, type Tile, Player, Tile} as api
import vec/vec2

fn api_host() -> String {
    //"http://localhost:8000/"
    "http://192.168.1.199:8000/"
}

fn api_host_no_scheme() -> String {
  api_host() 
    |> string.remove_prefix("https://")
    |> string.remove_prefix("http://")
    |> string.remove_suffix("/")
}

type SetupMode {
  HostSetup
  PlayerSetup
  UnspecifiedSetup
}

type GameState {
  Setup(mode: SetupMode)
  Playing
  GameOver
}

type RemoteData(a) {
  NotFetched
  Loading
  Loaded(data: a)
  // TODO: add an error message to failed state
  Failed
}

type Model {
  Model(
    game_state: GameState,
    bunch: Bunch,
    bunch_size: Int,
    hands: List(Hand),
    current_hand: Result(Hand, Nil),
    cursor: vec2.Vec2(Int),
    cursor_direction: WordDirection,
    tile_to_dump: Result(Tile, Nil),
    room: RemoteData(Room),
    nickname: String,
    room_code_input: String,
    current_player_id: String,
    ws: option.Option(ws.WebSocket),
  )
}

type Room {
  Room(room_code: String, host: Player, other_players: List(Player))
}

type Msg {
  Split
  CreateRoom
  ShowJoinRoom
  EditRoomCodeInput(room_code: String)
  JoinRoom
  EditNickname(nickname: String)
  CreatePlayer
  CopyRoomCode(room_code: String)
  PeelButtonClicked
  KeyPressed(key: String)
  MoveCursor(x: Int, y: Int)
  DumpInitiated(tile: Tile)
  Dump(tile: Tile)
  ApiCreatedRoom(Result(Room, rsvp.Error))
  ApiJoinedRoom(Result(#(Room, String), rsvp.Error))
  ApiStartedGame(Result(#(Hand, Int), rsvp.Error))
  ApiPeeled(Result(#(Hand, Int), rsvp.Error))
  WsWrapper(ws.WebSocketEvent)
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Split -> {
      case model.room {
        Loaded(room) -> {
          #(model, start_game(room.room_code))
        }
        _ -> {
          let #(bunch, hands) =
            bananagrams.split(
              model.bunch,
              1,
              // TODO: make BE request
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
      }
    }
    CreateRoom -> {
      #(Model(..model, game_state: Setup(mode: HostSetup)), effect.none())
    }
    ShowJoinRoom -> {
      #(Model(..model, game_state: Setup(mode: PlayerSetup)), effect.none())
    }
    EditRoomCodeInput(room_code) -> {
      #(Model(..model, room_code_input: room_code), effect.none())
    }
    JoinRoom -> {
      #(
        Model(..model, room: Loading),
        join_room(model.room_code_input, model.nickname),
      )
    }
    EditNickname(nickname) -> {
      #(Model(..model, nickname: nickname), effect.none())
    }
    CreatePlayer -> {
      #(Model(..model, room: Loading), create_room(model.nickname))
    }
    ApiCreatedRoom(Ok(room)) -> {
      #(
        Model(..model, room: Loaded(room), current_player_id: room.host.id),
        ws.init(
          api_host() <> "websocket?player-id=" <> room.host.id,
          WsWrapper,
        ),
      )
    }
    ApiCreatedRoom(Error(e)) -> {
      echo e
      #(Model(..model, room: Failed), effect.none())
    }
    ApiJoinedRoom(Ok(#(room, current_player_id))) -> {
      #(
        Model(..model, room: Loaded(room), current_player_id:),
        ws.init(
          api_host() <> "websocket?player-id=" <> current_player_id,
          WsWrapper,
        ),
      )
    }
    ApiJoinedRoom(Error(e)) -> {
      echo e
      #(Model(..model, room: Failed), effect.none())
    }
    ApiStartedGame(Ok(#(hand, bunch_size))) -> {
      #(
        Model(..model, game_state: Playing, current_hand: Ok(hand), bunch_size:),
        effect.none(),
      )
    }
    ApiStartedGame(Error(e)) -> {
      echo e
      #(model, effect.none())
    }
    ApiPeeled(Ok(#(hand, bunch_size))) -> {
      let new_hand =
        model.current_hand
        |> result.map(fn(base) {
          bananagrams.merge_hands(base: base, with: hand)
        })
      #(Model(..model, current_hand: new_hand, bunch_size:), effect.none())
    }
    ApiPeeled(Error(e)) -> {
      echo e
      #(model, effect.none())
    }
    CopyRoomCode(room_code) -> {
      #(
        model,
        effect.from(fn(_dispatch) {
          clipboard.write_text(room_code)
          // TODO: dispatch a msg for a toast
          Nil
        }),
      )
    }
    PeelButtonClicked -> {
      case model.room {
        Loaded(room) -> {
          #(model, peel(room.room_code))
        }
        _ -> {
          // single player
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
      }
    }
    KeyPressed(key) -> {
      update_for_keypress(model, key)
    }
    MoveCursor(x: x, y: y) -> {
      #(Model(..model, cursor: vec2.Vec2(x, y)), effect.none())
    }
    WsWrapper(ws.InvalidUrl) -> panic
    WsWrapper(ws.OnOpen(socket)) -> #(
      Model(..model, ws: option.Some(socket)),
      ws.send(socket, "client-init"),
    )
    WsWrapper(ws.OnTextMessage(ws_msg)) -> {
      case json.parse(ws_msg, api.message_decoder_json()) {
        Error(e) -> {
          echo e
          #(model, effect.none())
        }
        Ok(api.JoinedRoom(player)) -> {
          #(
            Model(..model, room: add_player_to_room(player, model.room)),
            effect.none(),
          )
        }
        Ok(api.HandDealt(new_tiles, bunch_size)) -> {
          #(
            Model(
              ..model,
              game_state: Playing,
              current_hand: Ok(bananagrams.Hand(
                pile: new_tiles |> set.from_list(),
                grid: dict.new(),
              )),
              bunch_size:,
            ),
            effect.none(),
          )
        }
        Ok(api.Peeled(peeler, new_tile, bunch_size)) -> todo
        Ok(api.Dumped(dumper, bunch_size)) -> todo
        Ok(api.Close) -> todo
      }
    }
    WsWrapper(ws.OnBinaryMessage(_)) -> #(model, effect.none())
    WsWrapper(ws.OnClose(reason)) -> {
      echo reason
      #(Model(..model, ws: option.None), effect.none())
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

fn add_player_to_room(
  player: Player,
  maybe_room: RemoteData(Room),
) -> RemoteData(Room) {
  case maybe_room {
    Loaded(room) -> {
      Loaded(
        Room(..room, other_players: list.append(room.other_players, [player])),
      )
    }
    _ -> maybe_room
  }
}

fn create_room(host_nickname: String) -> Effect(Msg) {
  let body = json.object([#("host-nickname", json.string(host_nickname))])

  let handler = rsvp.expect_json(decode_room(), ApiCreatedRoom)

  rsvp.post(api_host() <> "rooms", body, handler)
}

fn join_room(room_code: String, nickname: String) -> Effect(Msg) {
  let body = json.object([#("nickname", json.string(nickname))])

  let handler = rsvp.expect_json(decode_join_response(), ApiJoinedRoom)
  let url = api_host() <> "rooms/" <> room_code <> "/players"

  rsvp.post(url, body, handler)
}

fn start_game(room_code: String) -> Effect(Msg) {
  let handler = rsvp.expect_json(decode_start_game_response(), ApiStartedGame)
  let request =
    request.new()
    |> request.set_scheme(http.Http)
    |> request.set_method(http.Post)
    |> request.set_host(api_host_no_scheme())
    |> request.set_path("/rooms/" <> room_code <> "/games")

  rsvp.send(request, handler)
}

fn peel(room_code: String) -> Effect(Msg) {
  let handler = rsvp.expect_json(decode_start_game_response(), ApiPeeled)
  let request =
    request.new()
    |> request.set_scheme(http.Http)
    |> request.set_method(http.Post)
    |> request.set_host(api_host_no_scheme())
    |> request.set_path("/rooms/" <> room_code <> "/grid")

  rsvp.send(request, handler)
}

fn decode_start_game_response() -> decode.Decoder(#(Hand, Int)) {
  use bunch_size <- decode.field("bunch-size", decode.int)
  use hand <- decode.field("hand", decode_hand())
  decode.success(#(hand, bunch_size))
}

fn decode_hand() -> decode.Decoder(Hand) {
  use tiles <- decode.field("tiles", decode.list(bananagrams.decode_tile()))
  decode.success(bananagrams.Hand(
    pile: tiles |> set.from_list,
    grid: dict.new(),
  ))
}

fn decode_join_response() -> decode.Decoder(#(Room, String)) {
  use room <- decode.field("room", decode_room())
  use current_player_id <- decode.field("current-player-id", decode.string)
  decode.success(#(room, current_player_id))
}

fn decode_room() -> decode.Decoder(Room) {
  use room_code <- decode.field("room-code", decode.string)
  use host <- decode.field("host", decode_player())
  use other_players <- decode.field(
    "other-players",
    decode.list(decode_player()),
  )
  decode.success(Room(room_code:, host:, other_players:))
}

fn decode_player() -> decode.Decoder(Player) {
  use id <- decode.field("id", decode.string)
  use nickname <- decode.field("nickname", decode.string)
  decode.success(Player(id:, nickname:))
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
        "Enter" -> {
          case ready_to_peel(model) {
            True -> #(
              model,
              effect.from(fn(dispatch) { dispatch(PeelButtonClicked) }),
            )
            False -> #(model, effect.none())
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
      game_state: Setup(mode: UnspecifiedSetup),
      bunch: bananagrams.new(),
      cursor: vec2.Vec2(4, 7),
      cursor_direction: Right,
      hands: [],
      current_hand: Error(Nil),
      tile_to_dump: Error(Nil),
      room: NotFetched,
      nickname: "",
      room_code_input: "",
      current_player_id: "",
      bunch_size: 0,
      ws: option.None,
    ),
    effect.none(),
  )
}

fn view(model: Model) -> Element(Msg) {
  html.div([], content(model))
}

fn content(model: Model) -> List(Element(Msg)) {
  case model.game_state {
    Setup(mode) -> {
      setup(model, mode)
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

fn joining(model: Model) -> Element(Msg) {
  case model.room {
    NotFetched -> {
      join_form(model)
    }
    Loading -> {
      html.text("Loading...")
    }
    Loaded(room) -> {
      html.div([], waiting_room(model, room))
    }
    Failed -> {
      element.text("That didn't work :(")
    }
  }
}

fn join_form(model: Model) -> Element(Msg) {
  html.div([attribute.id("joining")], [
    html.h1([], [element.text("Banana Split")]),
    html.form([attribute.id("join-room"), event.on_submit(fn(_) { JoinRoom })], [
      html.label([], [
        element.text("Nickname: "),
        html.input([
          attribute.autofocus(True),
          attribute.type_("text"),
          attribute.name("nickname"),
          attribute.value(model.nickname),
          event.on_input(EditNickname),
        ]),
      ]),
      html.label([], [
        element.text("Room code: "),
        html.input([
          attribute.autofocus(True),
          attribute.type_("text"),
          attribute.name("room-code"),
          attribute.value(model.room_code_input),
          event.on_input(EditRoomCodeInput),
        ]),
      ]),
      html.div([], [
        html.button(
          [
            attribute.type_("submit"),
          ],
          [
            element.text("Next"),
          ],
        ),
      ]),
    ]),
  ])
}

fn setup(model: Model, mode: SetupMode) -> List(Element(Msg)) {
  html.div([attribute.id("setup")], [
    html.h1([], [element.text("Banana Split")]),
    ..setup_content(model, mode)
  ])
  |> list.wrap
}

fn setup_content(model: Model, mode: SetupMode) -> List(Element(Msg)) {
  case mode {
    UnspecifiedSetup -> {
      [
        html.button(
          [
            event.on_click(Split),
          ],
          [element.text("Start single-player")],
        ),
        html.button(
          [
            event.on_click(CreateRoom),
          ],
          [element.text("Create multi-player room")],
        ),
        html.button(
          [
            event.on_click(ShowJoinRoom),
          ],
          [element.text("Join existing room")],
        ),
      ]
    }
    HostSetup -> {
      [host_setup(model)]
    }
    PlayerSetup -> {
      [joining(model)]
    }
  }
}

fn host_setup(model: Model) -> Element(Msg) {
  case model.room {
    NotFetched -> {
      html.form(
        [attribute.id("player-setup"), event.on_submit(fn(_) { CreatePlayer })],
        [
          html.p([], [element.text("What should we call you?")]),
          html.label([], [
            element.text("Nickname: "),
            html.input([
              attribute.autofocus(True),
              attribute.type_("text"),
              attribute.name("nickname"),
              attribute.value(model.nickname),
              event.on_input(EditNickname),
            ]),
          ]),
          html.div([], [
            html.button(
              [
                attribute.type_("submit"),
              ],
              [
                element.text("Next"),
              ],
            ),
          ]),
        ],
      )
    }
    Loading -> {
      html.div([attribute.id("player-setup")], [
        html.p([], [element.text("What should we call you?")]),
        html.label([], [
          element.text("Nickname: "),
          html.input([
            attribute.autofocus(True),
            attribute.type_("text"),
            attribute.name("nickname"),
            attribute.value(model.nickname),
          ]),
        ]),
        html.div([], [
          html.button([], [
            element.text("Loading..."),
          ]),
        ]),
      ])
    }
    Loaded(room) -> {
      html.div([], waiting_room(model, room))
    }
    Failed -> {
      element.text("That didn't work :(")
    }
  }
}

fn waiting_room(model: Model, room: Room) -> List(Element(Msg)) {
  [
    html.p([], [element.text("Share this code with your friends:")]),
    html.div(
      [attribute.id("room-code"), event.on_click(CopyRoomCode(room.room_code))],
      [
        element.text(room.room_code),
        copy_to_clipboard_icon(),
      ],
    ),
    html.ol([attribute.id("player-list")], [
      html.li([], [element.text(room.host.nickname <> " (Host)")]),
      ..{
        room.other_players
        |> list.map(fn(player) {
          let txt = case player.id == model.current_player_id {
            True -> player.nickname <> " (You)"
            False -> player.nickname
          }
          html.li([], [element.text(txt)])
        })
      }
    ]),
    html.p([], [element.text("...")]),
    element.text("Is everyone here? Let's go!"),
    html.button([event.on_click(Split)], [element.text("Split!")]),
  ]
}

fn copy_to_clipboard_icon() -> Element(Msg) {
  svg.svg(
    [
      attribute.attribute("width", "50"),
      attribute.attribute("height", "50"),
    ],
    [
      svg.rect([
        attribute.attribute("height", "40"),
        attribute.attribute("width", "40"),
        attribute.attribute("rx", "3"),
        attribute.attribute("ry", "3"),
        attribute.attribute("stroke", "black"),
        attribute.attribute("fill", "none"),
        attribute.attribute("stroke-width", "3"),
        attribute.attribute("x", "3"),
        attribute.attribute("y", "8"),
      ]),
      svg.rect([
        attribute.attribute("height", "40"),
        attribute.attribute("width", "40"),
        attribute.attribute("rx", "3"),
        attribute.attribute("ry", "3"),
        attribute.attribute("stroke", "black"),
        attribute.attribute("fill", "black"),
        attribute.attribute("x", "8"),
        attribute.attribute("y", "3"),
      ]),
    ],
  )
}

fn ready_to_peel(model: Model) -> Bool {
  model.current_hand
  |> result.map(fn(hand) { set.is_empty(hand.pile) })
  |> result.unwrap(False)
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
  case ready_to_peel(model) {
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
          html.div(
            [],
            tiles
              |> batch(4)
              |> list.map(fn(l) { pile_row(model, l) }),
          ),
          html.em([], [element.text(dump_hint)]),
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
  html.div([attribute.class("info")], [
    element.text("Remaining letters: " <> { int.to_string(model.bunch_size) }),
  ])
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
  html.div([attribute.id("grid")], [
    html.div([], rows),
    html.em([attribute.class("type-hint")], [
      element.text(
        "Type a letter to place it. Type space to change directions.",
      ),
    ]),
  ])
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
      html.div([attribute.class("cell"), event.on_click(MoveCursor(x, y))], [
        element.text(letter),
      ])
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
  html.div(
    [
      attribute.class("cell"),
      attribute.class("cursor-right-next"),
      event.on_click(MoveCursor(x, y)),
    ],
    [
      element.text(letter),
    ],
  )
}

fn below_cursor_cell(model: Model, letter: String, x x: Int, y y: Int) {
  html.div(
    [
      attribute.class("cell"),
      attribute.class("cursor-down-next"),
      event.on_click(MoveCursor(x, y)),
    ],
    [
      element.text(letter),
    ],
  )
}

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(runtime) = lustre.start(app, "#ui", Nil)

  // TODO: better handle shift + meta keys
  document.add_event_listener("keyup", fn(event) {
    let key = plinth_event.key(event)
    let msg = lustre.dispatch(KeyPressed(key))
    lustre.send(to: runtime, message: msg)
  })

  Nil
}
