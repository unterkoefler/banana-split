import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/regexp
import gleam/result
import gleam/string
import gleam/uri.{type Uri}
import hand.{type Hand, type WordDirection, Down, Right}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import lustre_websocket as ws
import modem
import plinth/browser/clipboard
import plinth/javascript/global
import plinth/javascript/storage
import rsvp
import shared.{type Player, type Tile, Player} as api
import vec/vec2

pub type SetupMode {
  HostSetup(loading: Bool)
  PlayerSetup(loading: Bool)
  UnspecifiedSetup
}

pub type Route {
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

fn model_to_route(model: Model) -> Result(Route, Nil) {
  case model.game_state {
    Loading -> Error(Nil)
    Setup(UnspecifiedSetup) -> Ok(IndexRoute)
    Setup(HostSetup(_)) -> Ok(NewRoomRoute)
    Setup(PlayerSetup(_)) -> Ok(JoinRoomRoute(room_code: model.room_code_input))
    WaitingRoom(_player_id, room) ->
      Ok(WaitingRoomRoute(room_code: room.room_code))
    Playing(play_state) -> Ok(GameRoute(room_code: play_state.room.room_code))
    UnderReview(play_state) ->
      Ok(GameRoute(room_code: play_state.room.room_code))
    Reviewing(play_state, _, _, _) ->
      Ok(GameRoute(room_code: play_state.room.room_code))
    Dead(play_state, _) -> Ok(GameRoute(room_code: play_state.room.room_code))
    ReadyToResume(play_state, _, _) ->
      Ok(GameRoute(room_code: play_state.room.room_code))
    GameOver(_) -> Ok(GameRoute(room_code: ""))
    BadState(_, _) -> Error(Nil)
  }
}

pub type AppConfig {
  AppConfig(api_host: option.Option(String))
}

pub type PlayState {
  PlayState(hand: Hand, bunch_size: Int, player_id: String, room: Room)
}

pub type GameState {
  Loading
  Setup(mode: SetupMode)
  WaitingRoom(player_id: String, room: Room)
  Playing(play_state: PlayState)
  UnderReview(play_state: PlayState)
  Reviewing(
    play_state: PlayState,
    claimant: Player,
    claimant_grid: api.Grid,
    submitted: Bool,
  )
  Dead(play_state: PlayState, reason: String)
  ReadyToResume(play_state: PlayState, claimant: Player, rejector: Player)
  GameOver(winner: Player)
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
        use play_state <- decode.field("play_state", play_state_decoder())
        decode.success(Playing(play_state:))
      },
      {
        use _ <- decode.then(expect_tag("reviewing"))
        use play_state <- decode.field("play_state", play_state_decoder())
        use claimant <- decode.field("claimant", api.player_decoder_json())
        use claimant_grid <- decode.field(
          "claimant_grid",
          api.grid_decoder_json(),
        )
        use submitted <- decode.field("submitted", decode.bool)
        decode.success(Reviewing(
          play_state:,
          claimant:,
          claimant_grid:,
          submitted:,
        ))
      },
      {
        use _ <- decode.then(expect_tag("under_review"))
        use play_state <- decode.field("play_state", play_state_decoder())
        decode.success(UnderReview(play_state:))
      },
      {
        use _ <- decode.then(expect_tag("dead"))
        use play_state <- decode.field("play_state", play_state_decoder())
        use reason <- decode.field("reason", decode.string)
        decode.success(Dead(play_state:, reason:))
      },
      {
        use _ <- decode.then(expect_tag("ready_to_resume"))
        use play_state <- decode.field("play_state", play_state_decoder())
        use claimant <- decode.field("claimant", api.player_decoder_json())
        use rejector <- decode.field("rejector", api.player_decoder_json())
        decode.success(ReadyToResume(play_state:, claimant:, rejector:))
      },
      {
        use _ <- decode.then(expect_tag("game_over"))
        use winner <- decode.field("winner", api.player_decoder_json())
        decode.success(GameOver(winner))
      },
    ],
  )
}

fn play_state_decoder() -> decode.Decoder(PlayState) {
  use hand <- decode.field("hand", hand.hand_decoder())
  use bunch_size <- decode.field("bunch_size", decode.int)
  use player_id <- decode.field("player_id", decode.string)
  use room <- decode.field("room", decode_room())
  decode.success(PlayState(hand:, bunch_size:, player_id:, room:))
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
    Playing(play_state) -> {
      Ok(
        json.object([
          #("tag", json.string("playing")),
          #("play_state", play_state_to_json(play_state)),
        ]),
      )
    }
    UnderReview(play_state) -> {
      Ok(
        json.object([
          #("tag", json.string("under_review")),
          #("play_state", play_state_to_json(play_state)),
        ]),
      )
    }
    Reviewing(play_state, claimant, claimant_grid, submitted) -> {
      Ok(
        json.object([
          #("tag", json.string("reviewing")),
          #("play_state", play_state_to_json(play_state)),
          #("claimant", api.player_to_json(claimant)),
          #("claimant_grid", api.grid_to_json(claimant_grid)),
          #("submitted", json.bool(submitted)),
        ]),
      )
    }
    Dead(play_state, reason) -> {
      Ok(
        json.object([
          #("tag", json.string("dead")),
          #("play_state", play_state_to_json(play_state)),
          #("reason", json.string(reason)),
        ]),
      )
    }
    ReadyToResume(play_state, claimant, rejector) -> {
      Ok(
        json.object([
          #("tag", json.string("ready_to_resume")),
          #("play_state", play_state_to_json(play_state)),
          #("claimant", api.player_to_json(claimant)),
          #("rejector", api.player_to_json(rejector)),
        ]),
      )
    }
    GameOver(winner) -> {
      Ok(
        json.object([
          #("tag", json.string("game_over")),
          #("winner", api.player_to_json(winner)),
        ]),
      )
    }
    BadState(_, _) -> {
      Error(Nil)
    }
  }
}

fn play_state_to_json(play_state: PlayState) -> json.Json {
  let PlayState(hand, bunch_size, player_id, room) = play_state
  json.object([
    #("hand", hand.hand_to_json(hand)),
    #("bunch_size", json.int(bunch_size)),
    #("player_id", json.string(player_id)),
    #("room", room_to_json(room)),
  ])
}

pub type Model {
  Model(
    game_state: GameState,
    cursor: vec2.Vec2(Int),
    cursor_direction: WordDirection,
    tile_to_toss: Result(Tile, Nil),
    nickname: String,
    room_code_input: String,
    ws: option.Option(ws.WebSocket),
    toasts: List(#(Int, String)),
    toast_id_counter: Int,
    host: Uri,
  )
}

pub type Room {
  Room(room_code: String, host: Player, other_players: List(Player))
}

pub type Msg {
  Begin
  CreateRoom
  ShowJoinRoom
  BackToHome
  EditRoomCodeInput(room_code: String)
  JoinRoom
  EditNickname(nickname: String)
  CreatePlayer
  CopyRoomCode(room_code: String)
  ScoopButtonClicked
  ShufflePile
  BananasButtonClicked(grid: api.Grid)
  KeyPressed(key: String)
  MoveCursor(x: Int, y: Int)
  ChangeDirection
  TossInitiated(tile: Tile)
  Toss(tile: Tile)
  ApiCreatedRoom(Result(Room, rsvp.Error))
  ApiJoinedRoom(Result(#(Room, String), rsvp.Error))
  ApiStartedGame(
    player_id: String,
    room: Room,
    result: Result(#(Hand, Int), rsvp.Error),
  )
  ApiLoadedRoom(player_id: String, result: Result(Room, rsvp.Error))
  WsWrapper(ws.WebSocketEvent)
  OnRouteChange(Route)
  DismissToast(Int)
  AddToast(String)
  Approve(claimant: Player)
  Reject(claimant: Player)
  Resume
}

pub fn update(
  config: AppConfig,
  model: Model,
  msg: Msg,
) -> #(Model, Effect(Msg)) {
  let model = Model(..model, tile_to_toss: Error(Nil))
  case msg {
    Begin -> {
      case model.game_state {
        WaitingRoom(player_id, room) -> {
          #(model, start_game(config, player_id, room))
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
    BackToHome -> {
      #(
        Model(..model, game_state: Setup(mode: UnspecifiedSetup)),
        modem.push("/", option.None, option.None),
      )
    }
    EditRoomCodeInput(room_code) -> {
      #(Model(..model, room_code_input: room_code), effect.none())
    }
    JoinRoom -> {
      #(
        Model(..model, game_state: Setup(PlayerSetup(loading: True))),
        join_room(config, model.room_code_input, model.nickname),
      )
    }
    EditNickname(nickname) -> {
      #(Model(..model, nickname: nickname), effect.none())
    }
    CreatePlayer -> {
      #(
        Model(..model, game_state: Setup(HostSetup(loading: True))),
        create_room(config, model.nickname),
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
          ws.init(websocket_url(config, room.host.id), WsWrapper),
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
    ApiLoadedRoom(player_id, Ok(room)) -> {
      #(
        Model(..model, game_state: WaitingRoom(player_id:, room:)),
        effect.none(),
      )
    }
    ApiLoadedRoom(_, Error(e)) -> {
      echo e
      #(
        Model(..model, game_state: BadState("Failed to load room.", 315)),
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
          ws.init(websocket_url(config, current_player_id), WsWrapper),
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
    ApiStartedGame(player_id, room, Ok(#(hand, bunch_size))) -> {
      let game_state = Playing(PlayState(hand:, bunch_size:, player_id:, room:))
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
    ApiStartedGame(_player_id, _room, Error(e)) -> {
      echo e
      #(
        Model(..model, game_state: BadState("Starting game failed.", 318)),
        effect.none(),
      )
    }
    CopyRoomCode(room_code) -> {
      let query = uri.query_to_string([#("room_code", room_code)])
      let relative =
        uri.Uri(
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
          dispatch(AddToast("Link Copied!"))
        }),
      )
    }
    ScoopButtonClicked -> {
      case model.game_state {
        Playing(PlayState(_hand, bunch_size, _player_id, _room)) -> #(
          model,
          scoop(model, bunch_size),
        )
        _ -> #(model, effect.none())
      }
    }
    ShufflePile -> {
      shuffle_pile(model)
    }
    BananasButtonClicked(grid) -> {
      #(model, bananas(model, grid))
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
      #(Model(..model, cursor_direction: new_direction), effect.none())
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
            WaitingRoom(player_id, room) -> {
              let hand = hand.new_hand() |> hand.add_tiles(new_tiles)
              let game_state =
                Playing(PlayState(hand:, bunch_size:, player_id:, room:))
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
        Ok(api.Scooped(scooper, new_tile, bunch_size)) -> {
          case model.game_state {
            Playing(play_state) -> {
              let new_hand = hand.add_tiles(play_state.hand, [new_tile])
              let game_state =
                Playing(PlayState(..play_state, hand: new_hand, bunch_size:))
              save_game_state(game_state)
              let #(toasted_model, toast_effect) = case
                play_state.player_id == scooper.id
              {
                True -> #(model, effect.none())
                False -> add_toast(model, scooper.nickname <> " scooped!")
              }
              #(Model(..toasted_model, game_state:), toast_effect)
            }
            _ -> {
              #(model, effect.none())
            }
          }
        }
        Ok(api.OpponentTossed(tosser, bunch_size)) -> {
          case model.game_state {
            Playing(play_state) -> {
              let game_state = Playing(PlayState(..play_state, bunch_size:))
              save_game_state(game_state)
              let #(toasted_model, toast_effect) =
                add_toast(model, tosser.nickname <> " tossed!")
              #(Model(..toasted_model, game_state:), toast_effect)
            }
            _ -> #(model, effect.none())
          }
        }
        Ok(api.Tossed(new_tiles, lost_tile, bunch_size)) -> {
          case model.game_state {
            Playing(play_state) -> {
              let new_hand = hand.toss(play_state.hand, new_tiles, lost_tile)
              let game_state =
                Playing(PlayState(..play_state, hand: new_hand, bunch_size:))
              save_game_state(game_state)
              #(Model(..model, game_state:), effect.none())
            }
            _ -> {
              #(model, effect.none())
            }
          }
        }
        Ok(api.ClaimedVictory) -> {
          case model.game_state {
            Playing(play_state) -> {
              let game_state = UnderReview(play_state)
              save_game_state(game_state)
              #(Model(..model, game_state:), effect.none())
            }
            _ -> {
              #(model, effect.none())
            }
          }
        }
        Ok(api.OpponentClaimedVictory(claimant, grid)) -> {
          case model.game_state {
            Playing(play_state) -> {
              let game_state = Reviewing(play_state, claimant, grid, False)
              save_game_state(game_state)
              #(Model(..model, game_state:), effect.none())
            }
            Dead(play_state, _reason) -> {
              let game_state = Reviewing(play_state, claimant, grid, False)
              save_game_state(game_state)
              #(Model(..model, game_state:), effect.none())
            }
            ReadyToResume(play_state, _, _) -> {
              let game_state = Reviewing(play_state, claimant, grid, False)
              save_game_state(game_state)
              #(Model(..model, game_state:), effect.none())
            }
            _ -> {
              #(model, effect.none())
            }
          }
        }
        Ok(api.PrepareToResume(claimant, rejector)) -> {
          case model.game_state {
            Reviewing(play_state, _claimant, _claimant_grid, _) -> {
              let game_state = ReadyToResume(play_state, claimant, rejector)
              save_game_state(game_state)
              #(Model(..model, game_state:), effect.none())
            }
            UnderReview(play_state) -> {
              let game_state = ReadyToResume(play_state, claimant, rejector)
              save_game_state(game_state)
              #(Model(..model, game_state:), effect.none())
            }
            _ -> {
              #(model, effect.none())
            }
          }
        }
        Ok(api.DieOrStayDead(claimant, rejector)) -> {
          case model.game_state {
            UnderReview(play_state) -> {
              let reason = rejector.nickname <> " rejected your board"
              let game_state = Dead(play_state, reason:)
              save_game_state(game_state)
              #(Model(..model, game_state:), effect.none())
            }
            Reviewing(play_state, _, _, _) -> {
              let toast =
                rejector.nickname
                <> " rejected "
                <> claimant.nickname
                <> "'s board."
              let reason = "your board was previously rejected"
              let game_state = Dead(play_state, reason:)
              save_game_state(game_state)
              let #(toasted_model, toast_effect) = add_toast(model, toast)
              #(Model(..toasted_model, game_state:), toast_effect)
            }
            _ -> {
              #(model, effect.none())
            }
          }
        }
        Ok(api.GameOver(winner)) -> {
          let game_state = GameOver(winner)
          save_game_state(game_state)
          #(Model(..model, game_state:), effect.none())
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
    TossInitiated(tile) -> {
      #(Model(..model, tile_to_toss: Ok(tile)), effect.none())
    }
    Toss(tile) -> {
      #(model, toss(model, tile))
    }
    OnRouteChange(route) -> {
      case model_to_route(model) == Ok(route) {
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
              case load_player_id() {
                Ok(player_id) -> {
                  #(
                    Model(..model, game_state: Loading),
                    load_waiting_room(config, player_id, room_code),
                  )
                }
                Error(_) -> {
                  #(
                    Model(
                      ..model,
                      game_state: BadState("Cannot load player-id", 558),
                    ),
                    effect.none(),
                  )
                }
              }
            }
            GameRoute(room_code) -> {
              let game_state = load_saved_game_state()
              case game_state {
                Playing(_play_state) -> {
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
    Approve(claimant) -> {
      case model.game_state {
        Reviewing(play_state, claimant, claimant_grid, _submitted) -> {
          let game_state = Reviewing(play_state, claimant, claimant_grid, True)
          save_game_state(game_state)
          #(Model(..model, game_state:), approve(model, claimant))
        }
        _ -> {
          #(model, effect.none())
        }
      }
    }
    Reject(claimant) -> {
      case model.game_state {
        Reviewing(play_state, claimant, claimant_grid, _submitted) -> {
          let game_state = Reviewing(play_state, claimant, claimant_grid, True)
          #(Model(..model, game_state:), reject(model, claimant))
        }
        _ -> {
          #(model, effect.none())
        }
      }
    }
    Resume -> {
      case model.game_state {
        ReadyToResume(play_state, _claimant, _rejector) -> {
          let game_state = Playing(play_state)
          save_game_state(game_state)
          #(Model(..model, game_state:), effect.none())
        }
        _ -> {
          #(model, effect.none())
        }
      }
    }
  }
}

fn websocket_url(config: AppConfig, player_id: String) -> String {
  case config.api_host {
    option.None -> {
      "/websocket?player-id=" <> player_id
    }
    option.Some(host) -> {
      host <> "websocket?player-id=" <> player_id
    }
  }
}

fn create_room_url(config: AppConfig) -> String {
  case config.api_host {
    option.None -> {
      "/rooms/"
    }
    option.Some(host) -> {
      host <> "rooms/"
    }
  }
}

fn join_room_url(config: AppConfig, room_code: String) -> String {
  case config.api_host {
    option.None -> {
      "/rooms/" <> room_code <> "/players"
    }
    option.Some(host) -> {
      host <> "rooms/" <> room_code <> "/players"
    }
  }
}

fn fetch_room_url(config: AppConfig, room_code: String) -> String {
  case config.api_host {
    option.None -> {
      "/rooms/" <> room_code
    }
    option.Some(host) -> {
      host <> "rooms/" <> room_code
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
      storage.set_item(session_storage, game_state_key, value)
      Ok(Nil)
    }
    Error(Nil) -> Ok(Nil)
  }
}

fn save_player_id(player_id: String) -> Result(Nil, Nil) {
  use session_storage <- result.try(storage.session())
  storage.set_item(session_storage, player_id_key, player_id)

  Ok(Nil)
}

fn add_player_to_room(room: Room, player: Player) -> Room {
  Room(..room, other_players: list.append(room.other_players, [player]))
}

fn create_room(config: AppConfig, host_nickname: String) -> Effect(Msg) {
  let body = json.object([#("host-nickname", json.string(host_nickname))])

  let handler = rsvp.expect_json(decode_room(), ApiCreatedRoom)

  rsvp.post(create_room_url(config), body, handler)
}

fn join_room(
  config: AppConfig,
  room_code: String,
  nickname: String,
) -> Effect(Msg) {
  let body = json.object([#("nickname", json.string(nickname))])

  let handler = rsvp.expect_json(decode_join_response(), ApiJoinedRoom)
  let url = join_room_url(config, room_code)

  rsvp.post(url, body, handler)
}

fn start_game(config: AppConfig, player_id: String, room: Room) -> Effect(Msg) {
  let handler =
    rsvp.expect_json(decode_start_game_response(), fn(result) {
      ApiStartedGame(player_id, room, result)
    })
  let url = case config.api_host {
    option.None -> {
      "/rooms/" <> room.room_code <> "/games"
    }
    option.Some(host) -> {
      host <> "rooms/" <> room.room_code <> "/games"
    }
  }

  rsvp.post(url, json.object([]), handler)
}

fn load_waiting_room(
  config: AppConfig,
  player_id: String,
  room_code: String,
) -> Effect(Msg) {
  let handler =
    rsvp.expect_json(decode_load_room_response(), fn(result) {
      ApiLoadedRoom(player_id, result)
    })
  rsvp.get(fetch_room_url(config, room_code), handler)
}

fn scoop(model: Model, bunch_size: Int) -> Effect(Msg) {
  let assert option.Some(socket) = model.ws
  api.Scoop(bunch_size: bunch_size)
  |> api.client_message_to_json()
  |> json.to_string()
  |> fn(m) { ws.send(socket, m) }
}

fn bananas(model: Model, grid: api.Grid) -> Effect(Msg) {
  let assert option.Some(socket) = model.ws
  api.ClaimVictory(grid:)
  |> api.client_message_to_json()
  |> json.to_string()
  |> fn(m) { ws.send(socket, m) }
}

fn approve(model: Model, claimant: Player) -> Effect(Msg) {
  let assert option.Some(socket) = model.ws
  api.Approve(claimant:)
  |> api.client_message_to_json()
  |> json.to_string()
  |> fn(m) { ws.send(socket, m) }
}

fn reject(model: Model, claimant: Player) -> Effect(Msg) {
  let assert option.Some(socket) = model.ws
  api.Reject(claimant:)
  |> api.client_message_to_json()
  |> json.to_string()
  |> fn(m) { ws.send(socket, m) }
}

fn toss(model: Model, tile: Tile) -> Effect(Msg) {
  let assert option.Some(socket) = model.ws
  api.Toss(tile: tile)
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
  decode.success(hand.new_hand() |> hand.add_tiles(tiles))
}

fn decode_join_response() -> decode.Decoder(#(Room, String)) {
  use room <- decode.field("room", decode_room())
  use current_player_id <- decode.field("current-player-id", decode.string)
  decode.success(#(room, current_player_id))
}

fn decode_load_room_response() -> decode.Decoder(Room) {
  use room <- decode.field("room", decode_room())
  decode.success(room)
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

fn room_to_json(room: Room) -> json.Json {
  json.object([
    #("room-code", json.string(room.room_code)),
    #("host", api.player_to_json(room.host)),
    #("other-players", json.array(room.other_players, api.player_to_json)),
  ])
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
        Playing(play_state) -> {
          let PlayState(hand, _, _, _) = play_state
          let new_hand =
            hand.place_letter(hand, key |> string.uppercase, model.cursor)
          let new_cursor = case model.cursor_direction {
            Right ->
              vec2.Vec2(
                int.min(column_count - 1, model.cursor.x + 1),
                model.cursor.y,
              )
            Down ->
              vec2.Vec2(
                model.cursor.x,
                int.min(row_count - 1, model.cursor.y + 1),
              )
          }
          let game_state = Playing(PlayState(..play_state, hand: new_hand))
          save_game_state(game_state)
          #(Model(..model, cursor: new_cursor, game_state:), effect.none())
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
          #(Model(..model, cursor_direction: new_direction), effect.none())
        }
        "Backspace" -> {
          case model.game_state {
            Playing(play_state) -> {
              let PlayState(hand, _, _, _) = play_state
              let new_cursor = case model.cursor_direction {
                Right ->
                  vec2.Vec2(int.max(0, model.cursor.x - 1), model.cursor.y)
                Down ->
                  vec2.Vec2(model.cursor.x, int.max(0, model.cursor.y - 1))
              }
              let new_hand = hand.remove_letter(from: hand, at: model.cursor)
              let game_state = Playing(PlayState(..play_state, hand: new_hand))
              save_game_state(game_state)
              #(Model(..model, cursor: new_cursor, game_state:), effect.none())
            }
            _ -> {
              // no special backspace handling when not playing
              #(model, effect.none())
            }
          }
        }
        "Enter" -> {
          case ready_to_scoop(model) {
            ReadyToScoop(bunch_size) -> {
              let assert option.Some(socket) = model.ws
              #(
                model,
                api.Scoop(bunch_size: bunch_size)
                  |> api.client_message_to_json()
                  |> json.to_string()
                  |> fn(m) { ws.send(socket, m) },
              )
            }
            ReadyToCherry(grid) -> {
              let assert option.Some(socket) = model.ws
              #(
                model,
                api.ClaimVictory(grid:)
                  |> api.client_message_to_json()
                  |> json.to_string()
                  |> fn(m) { ws.send(socket, m) },
              )
            }
            GridIncomplete -> #(model, effect.none())
          }
        }
        ";" -> {
          shuffle_pile(model)
        }
        _ -> #(model, effect.none())
      }
    }
  }
}

fn shuffle_pile(model: Model) -> #(Model, Effect(Msg)) {
  case model.game_state {
    Playing(play_state) -> {
      let PlayState(hand, _, _, _) = play_state
      let new_hand = hand.shuffle_hand(hand)
      let game_state = Playing(PlayState(..play_state, hand: new_hand))
      save_game_state(game_state)
      #(Model(..model, game_state:), effect.none())
    }
    _ -> #(model, effect.none())
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
        cursor: vec2.Vec2(
          int.clamp(model.cursor.x - 1, 0, column_count - 1),
          model.cursor.y,
        ),
      ),
      effect.none(),
    )
    CursorRight -> #(
      Model(
        ..model,
        cursor: vec2.Vec2(
          int.clamp(model.cursor.x + 1, 0, column_count - 1),
          model.cursor.y,
        ),
      ),
      effect.none(),
    )
    CursorDown -> #(
      Model(
        ..model,
        cursor: vec2.Vec2(
          model.cursor.x,
          int.clamp(model.cursor.y + 1, 0, row_count - 1),
        ),
      ),
      effect.none(),
    )
    CursorUp -> #(
      Model(
        ..model,
        cursor: vec2.Vec2(
          model.cursor.x,
          int.clamp(model.cursor.y - 1, 0, row_count - 1),
        ),
      ),
      effect.none(),
    )
  }
}

fn load_saved_game_state() -> GameState {
  storage.session()
  |> result.try(fn(session_storage) {
    storage.get_item(session_storage, game_state_key)
  })
  |> result.try(fn(game_state) {
    json.parse(game_state, game_state_decoder())
    |> result.replace_error(Nil)
  })
  |> result.unwrap(Setup(mode: UnspecifiedSetup))
}

fn reconnect_to_websocket(config: AppConfig) -> Effect(Msg) {
  load_player_id()
  |> result.map(fn(player_id) {
    ws.init(websocket_url(config, player_id), WsWrapper)
  })
  |> result.unwrap(effect.none())
}

const player_id_key = "banana_split.player_id"

const game_state_key = "banana_split.game_state"

fn load_player_id() -> Result(String, Nil) {
  storage.session()
  |> result.try(fn(session_storage) {
    storage.get_item(session_storage, player_id_key)
  })
}

pub fn init(config: AppConfig, _: Nil) {
  let route =
    modem.initial_uri()
    |> result.map(route_from_uri)
    |> result.unwrap(ErrorRoute)

  let host =
    modem.initial_uri()
    |> result.map(fn(url) { uri.Uri(..url, path: "/") })
    |> result.unwrap(uri.Uri(
      scheme: option.Some("http"),
      userinfo: option.None,
      host: option.Some("localhost"),
      port: option.Some(1234),
      path: "/",
      query: option.None,
      fragment: option.None,
    ))
  case route {
    IndexRoute -> {
      #(
        Model(
          game_state: Setup(UnspecifiedSetup),
          cursor: vec2.Vec2(4, 7),
          cursor_direction: Right,
          tile_to_toss: Error(Nil),
          nickname: "",
          room_code_input: "",
          ws: option.None,
          toasts: [],
          //[#(-1, "terry scooped!"), #(-2, "terry tossed!")],
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
          tile_to_toss: Error(Nil),
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
          tile_to_toss: Error(Nil),
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
      case load_player_id() {
        Ok(player_id) -> {
          #(
            Model(
              game_state: Loading,
              cursor: vec2.Vec2(4, 7),
              cursor_direction: Right,
              tile_to_toss: Error(Nil),
              nickname: "",
              room_code_input: room_code,
              ws: option.None,
              toasts: [],
              toast_id_counter: 0,
              host: host,
            ),
            effect.batch([
              reconnect_to_websocket(config),
              modem.init(on_url_change),
              load_waiting_room(config, player_id, room_code),
            ]),
          )
        }
        Error(_) -> {
          #(
            Model(
              game_state: BadState("Failed to load player-id", 1035),
              cursor: vec2.Vec2(4, 7),
              cursor_direction: Right,
              tile_to_toss: Error(Nil),
              nickname: "",
              room_code_input: room_code,
              ws: option.None,
              toasts: [],
              toast_id_counter: 0,
              host: host,
            ),
            effect.none(),
          )
        }
      }
    }
    GameRoute(room_code) -> {
      #(
        Model(
          game_state: load_saved_game_state(),
          cursor: vec2.Vec2(4, 7),
          cursor_direction: Right,
          tile_to_toss: Error(Nil),
          nickname: "",
          room_code_input: "",
          ws: option.None,
          toasts: [],
          toast_id_counter: 0,
          host: host,
        ),
        effect.batch([reconnect_to_websocket(config), modem.init(on_url_change)]),
      )
    }
    ErrorRoute -> {
      #(
        Model(
          game_state: BadState("Something went very badly wrong.", 881),
          cursor: vec2.Vec2(4, 7),
          cursor_direction: Right,
          tile_to_toss: Error(Nil),
          nickname: "",
          room_code_input: "",
          ws: option.None,
          toasts: [],
          toast_id_counter: 0,
          host: host,
        ),
        effect.batch([reconnect_to_websocket(config), modem.init(on_url_change)]),
      )
    }
  }
}

pub fn view(model: Model) -> Element(Msg) {
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
    Playing(play_state) -> {
      [
        html.div(
          [
            attribute.id("play-content"),
          ],
          grid_and_pile(model, play_state, default_type_hint),
        ),
        toast_messages(model.toasts),
      ]
    }
    UnderReview(play_state) -> {
      let modal = element.text("Your opponents are reviewing your board.")
      play_content_with_modal(
        model,
        modal,
        grid_and_pile(model, play_state, default_type_hint),
      )
    }
    Reviewing(_play_state, claimant, claimant_grid, submitted) -> {
      case submitted {
        True -> {
          let modal = element.text("Waiting on other players to review...")
          let contents = [
            view_grid(
              model,
              claimant_grid,
              "Reviewing " <> claimant.nickname <> "'s board.",
            ),
          ]
          play_content_with_modal(model, modal, contents)
        }
        False -> {
          let buttons = [
            html.button(
              [
                event.on_click(Approve(claimant)),
                attribute.class("review-button"),
              ],
              [element.text("Looks good. I admit defeat")],
            ),
            html.button(
              [
                event.on_click(Reject(claimant)),
                attribute.class("review-button"),
              ],
              [
                element.text(
                  "Ha! They have made a fatal mistake. The game is back on!",
                ),
              ],
            ),
          ]
          [
            html.div(
              [
                attribute.id("play-content"),
              ],
              [
                html.div(
                  [
                    attribute.id("sidebar"),
                  ],
                  [
                    html.p([], [
                      element.text(claimant.nickname <> " thinks they've won!"),
                    ]),
                    html.p([], [element.text("Is their board valid?")]),
                    ..buttons
                  ],
                ),
                view_grid(
                  model,
                  claimant_grid,
                  "Reviewing " <> claimant.nickname <> "'s board.",
                ),
              ],
            ),
            toast_messages(model.toasts),
          ]
        }
      }
    }
    Dead(play_state, reason) -> {
      let modal =
        html.p([], [
          element.text("You lost because " <> reason <> "."),
          element.text(
            " But stick around! If everyone's board is invalid, you have a chance at redemption.",
          ),
        ])
      play_content_with_modal(
        model,
        modal,
        grid_and_pile(model, play_state, default_type_hint),
      )
    }
    ReadyToResume(play_state, claimant, rejector) -> {
      let modal =
        html.div([], [
          html.p([], [
            element.text(
              rejector.nickname
              <> " rejected "
              <> claimant.nickname
              <> " 's board!",
            ),
            element.text(
              " You now have a chance to complete your board and claim victory.",
            ),
            element.text(" Ready?"),
          ]),
          html.button(
            [
              event.on_click(Resume),
            ],
            [element.text("Let's go!")],
          ),
        ])
      play_content_with_modal(
        model,
        modal,
        grid_and_pile(model, play_state, default_type_hint),
      )
    }
    GameOver(winner) -> {
      play_content_with_modal(
        model,
        element.text("Game Over! " <> winner.nickname <> " won!"),
        [],
      )
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

const default_type_hint = "Type a letter to place it. Type space to change directions."

fn joining(model: Model, loading: Bool) -> Element(Msg) {
  case loading {
    False -> join_form(model)
    True -> html.text("Loading...")
  }
}

fn grid_and_pile(
  model: Model,
  play_state: PlayState,
  type_hint: String,
) -> List(Element(Msg)) {
  [
    html.div(
      [
        attribute.id("sidebar"),
      ],
      [
        info(model, play_state.bunch_size),
        pile(model, play_state.hand),
      ],
    ),
    view_grid(model, hand.grid(play_state.hand), type_hint),
  ]
}

fn play_content_with_modal(
  model: Model,
  modal: Element(Msg),
  contents: List(Element(Msg)),
) -> List(Element(Msg)) {
  [
    html.div(
      [
        attribute.id("play-content"),
      ],
      [
        html.div([attribute.class("overlay-backdrop")], []),
        html.div(
          [
            attribute.class("overlay"),
          ],
          [modal],
        ),
        ..contents
      ],
    ),
    toast_messages(model.toasts),
  ]
}

fn join_form(model: Model) -> Element(Msg) {
  html.div([attribute.id("joining")], [
    html.form([attribute.id("join-room"), event.on_submit(fn(_) { JoinRoom })], [
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
      html.div([attribute.id("host-setup-buttons")], [
        html.button([event.on_click(BackToHome), attribute.type_("button")], [
          element.text("Back"),
        ]),
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
  html.div([attribute.id("setup-container")], [
    html.div([attribute.id("setup")], [
      html.h1([], [element.text("Banana Split")]),
      html.p([], [
        html.em([], [element.text("The delicious tile-placing word game!")]),
      ]),
      ..setup_content(model, mode)
    ]),
  ])
  |> list.wrap
}

fn waiting_room_wrapper(
  model: Model,
  room: Room,
  current_player_id: String,
) -> List(Element(Msg)) {
  [
    html.div([attribute.id("setup-container")], [
      html.div([attribute.id("setup")], [
        html.h1([], [element.text("Banana Split")]),
        html.div([], waiting_room(model, room, current_player_id)),
      ]),
      toast_messages(model.toasts),
    ]),
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
      html.div([attribute.id("host-setup-buttons")], [
        html.button([event.on_click(BackToHome), attribute.type_("button")], [
          element.text("Back"),
        ]),
        submit_button,
      ]),
    ],
  )
}

fn waiting_room(
  model: Model,
  room: Room,
  current_player_id: String,
) -> List(Element(Msg)) {
  let next_steps = case
    room.host.id == current_player_id,
    list.length(room.other_players) < 7
  {
    True, True -> [
      html.p([], [element.text("Is everyone here? Let's go!")]),
      html.div([attribute.class("begin-button")], [
        html.button([event.on_click(Begin)], [element.text("Begin!")]),
      ]),
    ]
    True, False -> [
      element.text("The room is full. Let's go!"),
      html.button([event.on_click(Begin)], [element.text("Begin!")]),
    ]
    False, True -> [
      element.text(
        "Hold tight. When everyone is here, the host will start the game.",
      ),
    ]
    False, False -> [
      element.text("The room is full! The host will start the game soon."),
    ]
  }
  let dots = case list.length(room.other_players) < 7 {
    True -> {
      html.p([attribute.id("waiting-room-dots")], [element.text("...")])
    }
    False -> element.none()
  }
  [
    html.p([], [
      element.text(
        "Share this code with your friends. Play with up to 8 people.",
      ),
    ]),
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
    dots,
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
        attribute.attribute("stroke", "white"),
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
        attribute.attribute("stroke", "white"),
        attribute.attribute("fill", "white"),
        attribute.attribute("x", "8"),
        attribute.attribute("y", "3"),
      ]),
    ],
  )
}

type Scoopability {
  GridIncomplete
  ReadyToScoop(bunch_size: Int)
  ReadyToCherry(grid: api.Grid)
}

fn ready_to_scoop(model: Model) -> Scoopability {
  case model.game_state {
    Playing(PlayState(hand, bunch_size, _player_id, room)) -> {
      case hand.is_pile_empty(hand) {
        True -> {
          let player_count = 1 + list.length(room.other_players)
          case bunch_size < player_count {
            True -> ReadyToCherry(hand.grid(hand))
            False -> ReadyToScoop(bunch_size)
          }
        }
        False -> GridIncomplete
      }
    }
    _ -> GridIncomplete
  }
}

fn pile(model: Model, hand: Hand) -> Element(Msg) {
  let tiles = hand.ordered_pile(hand)
  let toss_hint = case model.tile_to_toss {
    Error(_) -> "Click a letter to toss it."
    Ok(_) -> "Click again to confirm"
  }
  let inner = case ready_to_scoop(model) {
    ReadyToScoop(_bunch_size) -> {
      [
        html.button(
          [
            event.on_click(ScoopButtonClicked),
            attribute.id("scoop-button"),
          ],
          [element.text("SCOOP!")],
        ),
      ]
    }
    ReadyToCherry(grid) -> {
      [
        html.button(
          [
            event.on_click(BananasButtonClicked(grid)),
            attribute.id("scoop-button"),
          ],
          [element.text("CHERRY!")],
        ),
      ]
    }
    GridIncomplete -> {
      [
        html.button(
          [
            attribute.id("shuffle-button"),
            event.on_click(ShufflePile),
          ],
          [element.text("Shuffle ;")],
        ),
        html.div(
          [],
          tiles
            |> batch(4)
            |> list.map(fn(l) { pile_row(model, l) }),
        ),
        html.em([], [element.text(toss_hint)]),
      ]
    }
  }
  html.div(
    [
      attribute.id("pile"),
    ],
    inner,
  )
}

fn pile_row(model: Model, tiles: List(Tile)) -> Element(Msg) {
  html.div([attribute.class("pile-row")], {
    tiles
    |> list.map(fn(tile) {
      let is_tossing_tile = Ok(tile) == model.tile_to_toss
      let on_click = case is_tossing_tile {
        True -> Toss(tile: tile)
        False -> TossInitiated(tile: tile)
      }
      html.div(
        [
          attribute.class("tile"),
          attribute.classes([#("tossing-tile", is_tossing_tile)]),
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

const row_count = 20

const column_count = 28

fn view_grid(model: Model, grid: api.Grid, type_hint: String) -> Element(Msg) {
  let rows =
    list.repeat(Nil, row_count)
    |> list.index_map(fn(_, i) { row(model, grid, y: i) })
  html.div([], [
    html.em([attribute.class("type-hint")], [
      element.text(type_hint),
    ]),
    html.div([attribute.id("grid")], [
      html.div([], rows),
    ]),
  ])
}

fn row(model: Model, grid: api.Grid, y y: Int) -> Element(Msg) {
  let cells =
    list.repeat(Nil, column_count)
    |> list.index_map(fn(_, i) { cell(model, grid, x: i, y: y) })
  html.div([attribute.class("row")], cells)
}

fn cell(model: Model, grid: api.Grid, x x: Int, y y: Int) -> Element(Msg) {
  let letter = case dict.get(grid, vec2.Vec2(x, y)) {
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
          attribute.attribute("height", "45"),
        ],
        [
          svg.polyline([
            attribute.attribute("points", "50,0 60,25 50,45"),
            attribute.attribute("fill", "#E0CA3C"),
            attribute.attribute("stroke", "#C2BBF0"),
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
          attribute.attribute("width", "45"),
          attribute.attribute("height", "55"),
        ],
        [
          svg.polyline([
            attribute.attribute("points", "0,49 25,60 45,49"),
            attribute.attribute("fill", "#E0CA3C"),
            attribute.attribute("stroke", "#C2BBF0"),
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
