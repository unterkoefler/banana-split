import bananagrams.{type Hand, type WordDirection, Down, Right}
import gleam/dict
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/regexp
import gleam/result
import gleam/string
import gleam/uri.{type Uri}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import lustre_websocket as ws
import modem
import plinth/browser/clipboard
import plinth/browser/document
import plinth/browser/event as plinth_event
import plinth/javascript/global
import plinth/javascript/storage
import rsvp
import shared.{type Player, type Tile, Player} as api
import vec/vec2

fn api_host() -> String {
  //"http://localhost:8000/"
  //"http://192.168.1.199:8000/"
  "http://192.168.0.166:8000/"
}

fn api_host_no_scheme() -> String {
  api_host()
  |> string.remove_prefix("https://")
  |> string.remove_prefix("http://")
  |> string.remove_suffix("/")
}

type SetupMode {
  HostSetup(loading: Bool)
  PlayerSetup(loading: Bool)
  UnspecifiedSetup
}

type Route {
  IndexRoute
  NewRoomRoute
  JoinRoomRoute(room_code: String)
  WaitingRoomRoute(room_code: String)
  GameRoute(room_code: String)
  ErrorRoute
}

fn on_url_change(uri: Uri) -> Msg {
  OnRouteChange(route_from_uri(uri))
}

fn route_from_uri(uri: Uri) -> Route {
  case uri.path_segments(uri.path) {
    [] -> IndexRoute
    ["rooms", "new"] -> NewRoomRoute
    ["rooms", "join"] -> {
      let room_code =
        uri.query
        |> option.to_result(Nil)
        |> result.try(uri.parse_query)
        |> result.try(fn(query_dict) { list.key_find(query_dict, "room_code") })
        |> result.unwrap("")
      JoinRoomRoute(room_code:)
    }
    ["rooms", room_code, "wait"] -> WaitingRoomRoute(room_code:)
    ["rooms", room_code, "play"] -> GameRoute(room_code:)
    _ -> ErrorRoute
  }
}

fn model_to_route(model: Model) -> Route {
  case model.game_state {
    // TODO: this is weird
    Loading -> ErrorRoute
    Setup(UnspecifiedSetup) -> IndexRoute
    Setup(HostSetup(_)) -> NewRoomRoute
    Setup(PlayerSetup(_)) -> JoinRoomRoute(room_code: model.room_code_input)
    WaitingRoom(_player_id, room) -> WaitingRoomRoute(room_code: room.room_code)
    // TODO
    Playing(_hand, _bunch_size) -> GameRoute(room_code: "")
    // TODO
    GameOver -> ErrorRoute
    BadState(_, _) -> ErrorRoute
  }
}

type GameState {
  Loading
  Setup(mode: SetupMode)
  WaitingRoom(player_id: String, room: Room)
  Playing(hand: Hand, bunch_size: Int)
  GameOver
  BadState(message: String, code: Int)
}

fn setup_mode_decoder() -> decode.Decoder(SetupMode) {
  decode.one_of(
    {
      use _ <- decode.then(expect_tag("host_setup"))
      use loading <- decode.field("loading", decode.bool)
      decode.success(HostSetup(loading:))
    },
    or: [
      {
        use _ <- decode.then(expect_tag("player_setup"))
        use loading <- decode.field("loading", decode.bool)
        decode.success(PlayerSetup(loading:))
      },
      {
        use _ <- decode.then(expect_tag("unspecified_setup"))
        decode.success(UnspecifiedSetup)
      },
    ],
  )
}

fn game_state_decoder() -> decode.Decoder(GameState) {
  decode.one_of(
    {
      use _ <- decode.then(expect_tag("setup"))
      use mode <- decode.field("mode", setup_mode_decoder())
      decode.success(Setup(mode))
    },
    or: [
      {
        use _ <- decode.then(expect_tag("waiting_room"))
        use player_id <- decode.field("player_id", decode.string)
        use room <- decode.field("room", decode_room())
        decode.success(WaitingRoom(player_id:, room:))
      },
      {
        use _ <- decode.then(expect_tag("playing"))
        use hand <- decode.field("hand", bananagrams.hand_decoder())
        use bunch_size <- decode.field("bunch_size", decode.int)
        decode.success(Playing(hand:, bunch_size:))
      },
      {
        use _ <- decode.then(expect_tag("game_over"))
        decode.success(GameOver)
      },
    ],
  )
}

fn expect_tag(expected: String) -> decode.Decoder(String) {
  use value <- decode.field("tag", decode.string)
  case value == expected {
    True -> decode.success(value)
    False -> decode.failure(value, "Expected string: " <> expected)
  }
}

fn game_state_to_json(game_state: GameState) -> Result(json.Json, Nil) {
  // it's only useful to save the game state sometimes
  case game_state {
    Loading -> {
      Error(Nil)
    }
    Setup(mode) -> {
      Error(Nil)
    }
    WaitingRoom(player_id, room) -> {
      Error(Nil)
    }
    Playing(hand, bunch_size) -> {
      Ok(
        json.object([
          #("tag", json.string("playing")),
          #("hand", bananagrams.hand_to_json(hand)),
          #("bunch_size", json.int(bunch_size)),
        ]),
      )
    }
    GameOver -> {
      // TODO
      Error(Nil)
    }
    BadState(_, _) -> {
      Error(Nil)
    }
  }
}

type Model {
  Model(
    game_state: GameState,
    cursor: vec2.Vec2(Int),
    cursor_direction: WordDirection,
    tile_to_dump: Result(Tile, Nil),
    nickname: String,
    room_code_input: String,
    ws: option.Option(ws.WebSocket),
    toasts: List(#(Int, String)),
    toast_id_counter: Int,
    host: Uri,
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
  ChangeDirection
  DumpInitiated(tile: Tile)
  Dump(tile: Tile)
  ApiCreatedRoom(Result(Room, rsvp.Error))
  ApiJoinedRoom(Result(#(Room, String), rsvp.Error))
  ApiStartedGame(room_code: String, result: Result(#(Hand, Int), rsvp.Error))
  WsWrapper(ws.WebSocketEvent)
  OnRouteChange(Route)
  DismissToast(Int)
  AddToast(String)
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Split -> {
      case model.game_state {
        WaitingRoom(_player_id, room) -> {
          #(model, start_game(room.room_code))
        }
        _ -> {
          #(Model(..model), effect.none())
        }
      }
    }
    CreateRoom -> {
      #(
        Model(..model, game_state: Setup(mode: HostSetup(loading: False))),
        modem.push("/rooms/new", option.None, option.None),
      )
    }
    ShowJoinRoom -> {
      #(
        Model(..model, game_state: Setup(mode: PlayerSetup(loading: False))),
        modem.push("/rooms/join", option.None, option.None),
      )
    }
    EditRoomCodeInput(room_code) -> {
      #(Model(..model, room_code_input: room_code), effect.none())
    }
    JoinRoom -> {
      #(
        Model(..model, game_state: Setup(PlayerSetup(loading: True))),
        join_room(model.room_code_input, model.nickname),
      )
    }
    EditNickname(nickname) -> {
      #(Model(..model, nickname: nickname), effect.none())
    }
    CreatePlayer -> {
      #(
        Model(..model, game_state: Setup(HostSetup(loading: True))),
        create_room(model.nickname),
      )
    }
    ApiCreatedRoom(Ok(room)) -> {
      save_player_id(room.host.id)
      #(
        Model(
          ..model,
          game_state: WaitingRoom(player_id: room.host.id, room: room),
        ),
        effect.batch([
          ws.init(
            api_host() <> "websocket?player-id=" <> room.host.id,
            WsWrapper,
          ),
          modem.push(
            "/rooms/" <> room.room_code <> "/wait",
            option.None,
            option.None,
          ),
        ]),
      )
    }
    ApiCreatedRoom(Error(e)) -> {
      echo e
      #(
        Model(..model, game_state: BadState("Failed to create room.", 286)),
        effect.none(),
      )
    }
    ApiJoinedRoom(Ok(#(room, current_player_id))) -> {
      save_player_id(current_player_id)
      #(
        Model(
          ..model,
          game_state: WaitingRoom(player_id: current_player_id, room: room),
        ),
        effect.batch([
          ws.init(
            api_host() <> "websocket?player-id=" <> current_player_id,
            WsWrapper,
          ),
          modem.push(
            "/rooms/" <> room.room_code <> "/wait",
            option.None,
            option.None,
          ),
        ]),
      )
    }
    ApiJoinedRoom(Error(e)) -> {
      echo e
      #(
        Model(..model, game_state: BadState("Failed to join room.", 307)),
        effect.none(),
      )
    }
    ApiStartedGame(room_code, Ok(#(hand, bunch_size))) -> {
      let game_state = Playing(hand:, bunch_size:)
      save_game_state(game_state)
      #(
        Model(..model, game_state:),
        modem.push("/rooms/" <> room_code <> "/play", option.None, option.None),
      )
    }
    ApiStartedGame(_room_code, Error(e)) -> {
      echo e
      #(
        Model(..model, game_state: BadState("Split failed.", 318)),
        effect.none(),
      )
    }
    CopyRoomCode(room_code) -> {
      let query = uri.query_to_string([#("room_code", room_code)])
      let relative = uri.Uri(
        scheme: option.None,
        userinfo: option.None,
        host: option.None,
        port: option.None,
        path: "/rooms/join",
        query: option.Some(query),
        fragment: option.None,
      )
      let assert Ok(url) = uri.merge(model.host, relative) 
      #(
        model,
        effect.from(fn(dispatch) {
          clipboard.write_text(uri.to_string(url))
          dispatch(AddToast("Copied!")) 
        }),
      )
    }
    PeelButtonClicked -> {
      case model.game_state {
        Playing(_hand, bunch_size) -> #(model, peel(model, bunch_size))
        _ -> #(model, effect.none())
      }
    }
    KeyPressed(key) -> {
      update_for_keypress(model, key)
    }
    MoveCursor(x: x, y: y) -> {
      #(Model(..model, cursor: vec2.Vec2(x, y)), effect.none())
    }
    ChangeDirection -> {
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
    WsWrapper(ws.InvalidUrl) -> {
      #(
        Model(
          ..model,
          game_state: BadState("Failed to connect to server.", 357),
        ),
        effect.none(),
      )
    }
    WsWrapper(ws.OnOpen(socket)) -> #(
      Model(..model, ws: option.Some(socket)),
      effect.none(),
    )
    WsWrapper(ws.OnTextMessage(ws_msg)) -> {
      case json.parse(ws_msg, api.message_decoder_json()) {
        Error(e) -> {
          echo e
          #(model, effect.none())
        }
        Ok(api.JoinedRoom(player)) -> {
          case model.game_state {
            WaitingRoom(player_id, room) -> {
              #(
                Model(
                  ..model,
                  game_state: WaitingRoom(
                    player_id: player_id,
                    room: add_player_to_room(room, player),
                  ),
                ),
                effect.none(),
              )
            }
            _ -> #(model, effect.none())
          }
        }
        Ok(api.HandDealt(new_tiles, bunch_size)) -> {
          case model.game_state {
            WaitingRoom(_player_id, room) -> {
              let hand =
                bananagrams.new_hand() |> bananagrams.add_tiles(new_tiles)
              let game_state = Playing(hand:, bunch_size:)
              save_game_state(game_state)
              #(
                Model(..model, game_state:),
                modem.push(
                  "/rooms/" <> room.room_code <> "/play",
                  option.None,
                  option.None,
                ),
              )
            }
            _ -> #(model, effect.none())
          }
        }
        Ok(api.Peeled(peeler, new_tile, bunch_size)) -> {
          case model.game_state {
            Playing(hand, _old_bunch_size) -> {
              let new_hand = bananagrams.add_tiles(hand, [new_tile])
              let game_state = Playing(new_hand, bunch_size:)
              save_game_state(game_state)
              let #(toasted_model, toast_effect) = // TODO: store player id in Playing state
              case model.nickname == peeler.nickname {
                True -> #(model, effect.none())
                False -> add_toast(model, peeler.nickname <> " peeled!")
              }
              #(Model(..toasted_model, game_state:), toast_effect)
            }
            _ -> {
              #(model, effect.none())
            }
          }
        }
        Ok(api.OpponentDumped(dumper, bunch_size)) -> {
          case model.game_state {
            Playing(hand, _old_bunch_size) -> {
              let game_state = Playing(hand:, bunch_size:)
              save_game_state(game_state)
              let #(toasted_model, toast_effect) =
                add_toast(model, dumper.nickname <> " dumped!")
              #(Model(..toasted_model, game_state:), toast_effect)
            }
            _ -> #(model, effect.none())
          }
        }
        Ok(api.Dumped(new_tiles, lost_tile, bunch_size)) -> {
          case model.game_state {
            Playing(hand, _old_bunch_size) -> {
              let new_hand = bananagrams.dump(hand, new_tiles, lost_tile)
              let game_state = Playing(new_hand, bunch_size:)
              save_game_state(game_state)
              #(Model(..model, game_state:), effect.none())
            }
            _ -> {
              #(model, effect.none())
            }
          }
        }
        Ok(api.Close) -> {
          case model.ws {
            option.Some(socket) -> #(model, ws.close(socket))
            option.None -> #(model, effect.none())
          }
        }
      }
    }
    WsWrapper(ws.OnBinaryMessage(_)) -> #(model, effect.none())
    WsWrapper(ws.OnClose(reason)) -> {
      echo reason
      // TODO: reconnect?
      #(Model(..model, ws: option.None), effect.none())
    }
    DumpInitiated(tile) -> {
      #(Model(..model, tile_to_dump: Ok(tile)), effect.none())
    }
    Dump(tile) -> {
      #(model, dump(model, tile))
    }
    OnRouteChange(route) -> {
      case model_to_route(model) == route {
        True -> #(model, effect.none())
        False -> {
          case route {
            IndexRoute -> {
              #(
                Model(..model, game_state: Setup(UnspecifiedSetup)),
                effect.none(),
              )
            }
            NewRoomRoute -> {
              #(
                Model(..model, game_state: Setup(HostSetup(loading: False))),
                effect.none(),
              )
            }
            JoinRoomRoute(room_code) -> {
              #(
                Model(..model, game_state: Setup(PlayerSetup(loading: False))),
                effect.none(),
              )
            }
            WaitingRoomRoute(room_code) -> {
              // TODO: issue GET to load room info
              // TODO: load player_id from storage (or error)
              #(Model(..model, game_state: Loading), effect.none())
            }
            GameRoute(room_code) -> {
              let game_state = load_saved_game_state()
              case game_state {
                Playing(_, _) -> {
                  #(Model(..model, game_state:), effect.none())
                }
                _ -> {
                  #(
                    Model(
                      ..model,
                      game_state: BadState("Failed to load game details.", 490),
                    ),
                    effect.none(),
                  )
                }
              }
            }
            ErrorRoute -> {
              #(
                Model(
                  ..model,
                  game_state: BadState("Something went horribly wrong.", 496),
                ),
                effect.none(),
              )
            }
          }
        }
      }
    }
    DismissToast(id) -> {
      case list.key_pop(model.toasts, id) {
        Ok(#(_, toasts)) -> #(Model(..model, toasts:), effect.none())
        Error(Nil) -> #(model, effect.none())
      }
    }
    AddToast(message) -> {
      add_toast(model, message)
    }
  }
}

fn add_toast(model: Model, message: String) -> #(Model, Effect(Msg)) {
  let current_id = model.toast_id_counter
  let next_id = current_id + 1
  let toasts = [#(current_id, message), ..model.toasts]
  #(
    Model(..model, toast_id_counter: next_id, toasts:),
    dismiss_toast(current_id),
  )
}

fn dismiss_toast(id: Int) -> Effect(Msg) {
  use dispatch <- effect.from
  use <- my_set_timeout(4000)
  dispatch(DismissToast(id))
}

fn my_set_timeout(delay: Int, callback: fn() -> anything) -> Nil {
  global.set_timeout(delay, callback)
  Nil
}

fn save_game_state(game_state: GameState) -> Result(Nil, Nil) {
  use session_storage <- result.try(storage.session())
  case game_state_to_json(game_state) {
    Ok(state) -> {
      let value = json.to_string(state)
      storage.set_item(session_storage, "bananagrams.game_state", value)
      Ok(Nil)
    }
    Error(Nil) -> Ok(Nil)
  }
}

fn save_player_id(player_id: String) -> Result(Nil, Nil) {
  use session_storage <- result.try(storage.session())
  storage.set_item(session_storage, "bananagrams.player_id", player_id)

  Ok(Nil)
}

fn add_player_to_room(room: Room, player: Player) -> Room {
  Room(..room, other_players: list.append(room.other_players, [player]))
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
  let handler =
    rsvp.expect_json(decode_start_game_response(), fn(result) {
      ApiStartedGame(room_code, result)
    })
  let request =
    request.new()
    |> request.set_scheme(http.Http)
    |> request.set_method(http.Post)
    |> request.set_host(api_host_no_scheme())
    |> request.set_path("/rooms/" <> room_code <> "/games")

  rsvp.send(request, handler)
}

fn peel(model: Model, bunch_size: Int) -> Effect(Msg) {
  let assert option.Some(socket) = model.ws
  api.Peel(bunch_size: bunch_size)
  |> api.client_message_to_json()
  |> json.to_string()
  |> fn(m) { ws.send(socket, m) }
}

fn dump(model: Model, tile: Tile) -> Effect(Msg) {
  let assert option.Some(socket) = model.ws
  api.Dump(tile: tile)
  |> api.client_message_to_json()
  |> json.to_string()
  |> fn(m) { ws.send(socket, m) }
}

fn decode_start_game_response() -> decode.Decoder(#(Hand, Int)) {
  use bunch_size <- decode.field("bunch-size", decode.int)
  use hand <- decode.field("hand", decode_hand())
  decode.success(#(hand, bunch_size))
}

fn decode_hand() -> decode.Decoder(Hand) {
  use tiles <- decode.field("tiles", decode.list(api.tile_decoder_json()))
  decode.success(bananagrams.new_hand() |> bananagrams.add_tiles(tiles))
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
      case model.game_state {
        Playing(hand, bunch_size) -> {
          let new_hand =
            bananagrams.place_letter(
              hand,
              key |> string.uppercase,
              model.cursor,
            )
          let new_cursor = case model.cursor_direction {
            Right -> vec2.Vec2(int.min(15, model.cursor.x + 1), model.cursor.y)
            Down -> vec2.Vec2(model.cursor.x, int.min(15, model.cursor.y + 1))
          }
          let game_state = Playing(new_hand, bunch_size:)
          save_game_state(game_state)
          #(
            Model(
              ..model,
              tile_to_dump: Error(Nil),
              cursor: new_cursor,
              game_state:,
            ),
            effect.none(),
          )
        }
        _ -> {
          // no special handling needed for keypresses outside of play
          #(model, effect.none())
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
          case model.game_state {
            Playing(hand, bunch_size) -> {
              let new_cursor = case model.cursor_direction {
                Right ->
                  vec2.Vec2(int.max(0, model.cursor.x - 1), model.cursor.y)
                Down ->
                  vec2.Vec2(model.cursor.x, int.max(0, model.cursor.y - 1))
              }
              let new_hand =
                bananagrams.remove_letter(from: hand, at: model.cursor)
              let game_state = Playing(new_hand, bunch_size:)
              save_game_state(game_state)
              #(
                Model(
                  ..model,
                  tile_to_dump: Error(Nil),
                  cursor: new_cursor,
                  game_state:,
                ),
                effect.none(),
              )
            }
            _ -> {
              // no special backspace handling when not playing
              #(model, effect.none())
            }
          }
        }
        "Enter" -> {
          case ready_to_peel(model) {
            True -> {
              let assert option.Some(socket) = model.ws
              // TODO: remove assert
              let assert Playing(_hand, bunch_size) = model.game_state
              #(
                model,
                api.Peel(bunch_size: bunch_size)
                  |> api.client_message_to_json()
                  |> json.to_string()
                  |> fn(m) { ws.send(socket, m) },
              )
            }
            False -> #(model, effect.none())
          }
        }
        ";" -> {
          case model.game_state {
            Playing(hand, bunch_size) -> {
              let new_hand = bananagrams.shuffle_hand(hand)
              let game_state = Playing(new_hand, bunch_size:)
              save_game_state(game_state)
              #(Model(..model, game_state:), effect.none())
            }
            _ -> #(model, effect.none())
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

fn load_saved_game_state() -> GameState {
  storage.session()
  |> result.try(fn(session_storage) {
    storage.get_item(session_storage, "bananagrams.game_state")
  })
  |> result.try(fn(game_state) {
    json.parse(game_state, game_state_decoder())
    |> result.replace_error(Nil)
  })
  |> result.unwrap(Setup(mode: UnspecifiedSetup))
}

fn reconnect_to_websocket() -> Effect(Msg) {
  storage.session()
  |> result.try(fn(session_storage) {
    storage.get_item(session_storage, "bananagrams.player_id")
  })
  |> result.map(fn(player_id) {
    ws.init(api_host() <> "websocket?player-id=" <> player_id, WsWrapper)
  })
  |> result.unwrap(effect.none())
}

fn init(_: Nil) {
  let route =
    modem.initial_uri()
    |> result.map(route_from_uri)
    |> result.unwrap(ErrorRoute)

  let host =
    modem.initial_uri()
    |> result.map(fn(url) { uri.Uri(..url, path: "/") })
    |> result.unwrap(
      uri.Uri(
        scheme: option.Some("http"),
        userinfo: option.None,
        host: option.Some("localhost"),
        port: option.Some(1234),
        path: "/",
        query: option.None,
        fragment: option.None,
      )
    )
  case route {
    IndexRoute -> {
      #(
        Model(
          game_state: Setup(UnspecifiedSetup),
          cursor: vec2.Vec2(4, 7),
          cursor_direction: Right,
          tile_to_dump: Error(Nil),
          nickname: "",
          room_code_input: "",
          ws: option.None,
          toasts: [],
          //[#(-1, "terry peeled!"), #(-2, "terry dumped!")],
          toast_id_counter: 0,
          host: host,
        ),
        modem.init(on_url_change),
      )
    }
    NewRoomRoute -> {
      #(
        Model(
          game_state: Setup(HostSetup(loading: False)),
          cursor: vec2.Vec2(4, 7),
          cursor_direction: Right,
          tile_to_dump: Error(Nil),
          nickname: "",
          room_code_input: "",
          ws: option.None,
          toasts: [],
          toast_id_counter: 0,
          host: host,
        ),
        modem.init(on_url_change),
      )
    }
    JoinRoomRoute(room_code) -> {
      #(
        Model(
          game_state: Setup(PlayerSetup(loading: False)),
          cursor: vec2.Vec2(4, 7),
          cursor_direction: Right,
          tile_to_dump: Error(Nil),
          nickname: "",
          room_code_input: room_code,
          ws: option.None,
          toasts: [],
          toast_id_counter: 0,
          host: host,
        ),
        modem.init(on_url_change),
      )
    }
    WaitingRoomRoute(room_code) -> {
      #(
        Model(
          game_state: Loading,
          // TODO: make api call
          cursor: vec2.Vec2(4, 7),
          cursor_direction: Right,
          tile_to_dump: Error(Nil),
          nickname: "",
          room_code_input: room_code,
          ws: option.None,
          toasts: [],
          toast_id_counter: 0,
          host: host,
        ),
        effect.batch([reconnect_to_websocket(), modem.init(on_url_change)]),
      )
    }
    GameRoute(room_code) -> {
      #(
        Model(
          game_state: load_saved_game_state(),
          cursor: vec2.Vec2(4, 7),
          cursor_direction: Right,
          tile_to_dump: Error(Nil),
          nickname: "",
          room_code_input: "",
          ws: option.None,
          toasts: [],
          // [#(-1, "terry peeled!"), #(-2, "terry dumped!")],
          toast_id_counter: 0,
          host: host,
        ),
        effect.batch([reconnect_to_websocket(), modem.init(on_url_change)]),
      )
    }
    ErrorRoute -> {
      #(
        Model(
          game_state: BadState("Something went very badly wrong.", 881),
          cursor: vec2.Vec2(4, 7),
          cursor_direction: Right,
          tile_to_dump: Error(Nil),
          nickname: "",
          room_code_input: "",
          ws: option.None,
          toasts: [],
          toast_id_counter: 0,
          host: host,
        ),
        effect.batch([reconnect_to_websocket(), modem.init(on_url_change)]),
      )
    }
  }
}

fn view(model: Model) -> Element(Msg) {
  html.div([], content(model))
}

fn content(model: Model) -> List(Element(Msg)) {
  case model.game_state {
    Setup(mode) -> {
      setup(model, mode)
    }
    WaitingRoom(player_id, room) -> {
      waiting_room_wrapper(model, room, player_id)
    }
    Playing(hand, bunch_size) -> {
      [
        html.div(
          [
            attribute.id("play-content"),
          ],
          [
            grid(model, hand),
            pile(model, hand),
            info(model, bunch_size),
          ],
        ),
        toast_messages(model.toasts),
      ]
    }
    GameOver -> {
      element.text("Game Over!") |> list.wrap
    }
    Loading -> {
      element.text("Loading...") |> list.wrap
    }
    BadState(message, code) -> {
      element.text(message <> "\n Error code: " <> int.to_string(code) <> ".")
      |> list.wrap
    }
  }
}

fn joining(model: Model, loading: Bool) -> Element(Msg) {
  case loading {
    False -> join_form(model)
    True -> html.text("Loading...")
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

fn waiting_room_wrapper(
  model: Model,
  room: Room,
  current_player_id: String,
) -> List(Element(Msg)) {
  [
    html.div([attribute.id("setup")], [
      html.h1([], [element.text("Banana Split")]),
      html.div([], waiting_room(model, room, current_player_id)),
    ]),
    toast_messages(model.toasts),
  ]
}

fn setup_content(model: Model, mode: SetupMode) -> List(Element(Msg)) {
  case mode {
    UnspecifiedSetup -> {
      [
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
    HostSetup(loading) -> {
      [host_setup(model, loading)]
    }
    PlayerSetup(loading) -> {
      [joining(model, loading)]
    }
  }
}

fn host_setup(model: Model, loading: Bool) -> Element(Msg) {
  let submit_button = case loading {
    True -> {
      html.button([], [
        element.text("Loading..."),
      ])
    }
    False -> {
      html.button(
        [
          attribute.type_("submit"),
        ],
        [
          element.text("Next"),
        ],
      )
    }
  }
  let on_input = case loading {
    True -> attribute.none()
    False -> event.on_input(EditNickname)
  }
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
          on_input,
        ]),
      ]),
      html.div([], [submit_button]),
    ],
  )
}

fn waiting_room(
  model: Model,
  room: Room,
  current_player_id: String,
) -> List(Element(Msg)) {
  let next_steps =
    case room.host.id == current_player_id {
      True -> [
        element.text("Is everyone here? Let's go!"),
        html.button([event.on_click(Split)], [element.text("Split!")]),
      ]
      False -> [
        element.text("Hold tight. When everyone is here, the host will start the game.")
      ]
    }
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
          let txt = case player.id == current_player_id {
            True -> player.nickname <> " (You)"
            False -> player.nickname
          }
          html.li([], [element.text(txt)])
        })
      }
    ]),
    html.p([], [element.text("...")]),
    ..next_steps
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
  case model.game_state {
    Playing(hand, _bunch_size) -> bananagrams.is_pile_empty(hand)
    _ -> False
  }
}

fn pile(model: Model, hand: Hand) -> Element(Msg) {
  let tiles = bananagrams.ordered_pile(hand)
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
        [element.text(tile.letter)],
      )
    })
  })
}

fn info(model: Model, bunch_size: Int) {
  html.div([attribute.class("info")], [
    element.text("Remaining letters: " <> { int.to_string(bunch_size) }),
  ])
}

fn toast_messages(toasts: List(#(Int, String))) -> Element(Msg) {
  let items =
    toasts
    |> list.map(fn(toast) {
      let #(_, message) = toast
      html.div([attribute.class("toast")], [element.text(message)])
    })
  html.div([attribute.id("toast-container")], items)
}

fn batch(l: List(a), batch_size: Int) -> List(List(a)) {
  let #(final_list, last_list, _) =
    l
    |> list.fold(#([], [], 0), fn(acc, el) {
      let #(lol, curr_list, i) = acc
      case i < batch_size {
        True -> #(lol, [el, ..curr_list], i + 1)
        False -> #([curr_list |> list.reverse, ..lol], [el], 1)
      }
    })
  [last_list, ..final_list] |> list.reverse
}

fn grid(model: Model, hand: Hand) -> Element(Msg) {
  let rows =
    list.repeat(Nil, 16)
    |> list.index_map(fn(_, i) { row(model, hand, y: i) })
  html.div([attribute.id("grid")], [
    html.div([], rows),
    html.em([attribute.class("type-hint")], [
      element.text(
        "Type a letter to place it. Type space to change directions.",
      ),
    ]),
  ])
}

fn row(model: Model, hand: Hand, y y: Int) -> Element(Msg) {
  let cells =
    list.repeat(Nil, 16)
    |> list.index_map(fn(_, i) { cell(model, hand, x: i, y: y) })
  html.div([attribute.class("row")], cells)
}

fn cell(model: Model, hand: Hand, x x: Int, y y: Int) -> Element(Msg) {
  let letter = case dict.get(bananagrams.grid(hand), vec2.Vec2(x, y)) {
    Error(_) -> ""
    Ok(tile) -> tile.letter
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

fn right_cursor_cell(_model: Model, letter: String, x _x: Int, y _y: Int) {
  html.div(
    [
      attribute.class("cell"),
      attribute.class("cursor"),
      attribute.class("cursor-right"),
      event.on_click(ChangeDirection),
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

fn down_cursor_cell(_model: Model, letter: String, x _x: Int, y _y: Int) {
  html.div(
    [
      attribute.class("cell"),
      attribute.class("cursor"),
      attribute.class("cursor-down"),
      event.on_click(ChangeDirection),
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

fn right_of_cursor_cell(_model: Model, letter: String, x x: Int, y y: Int) {
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

fn below_cursor_cell(_model: Model, letter: String, x x: Int, y y: Int) {
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
