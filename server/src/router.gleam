import bunch
import db/players
import db/rooms
import gleam/dynamic/decode
import gleam/float
import gleam/http.{Get, Options, Post}
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gluid
import glyn/registry.{type Registry}
import lustre/attribute
import lustre/element
import lustre/element/html
import passphrase
import repeatedly
import shared.{type Player, Player} as api
import sqlight
import web
import wisp.{type Request, type Response}
import wisp/websocket

pub type Context {
  Context(registry: Registry(api.Message, Nil), static_directory: String)
}

pub type CreateRoomInput {
  CreateRoomInput(host_nickname: String)
}

pub type AddPlayerInput {
  AddPlayerInput(nickname: String)
}

pub type Room {
  Room(
    room_code: String,
    host: Player,
    other_players: List(Player),
    state: RoomState,
  )
}

pub type RoomState {
  Setup
  Playing
  GameOver
}

pub const message_decoder = api.message_decoder_dynamic

fn create_room_input_decoder() -> decode.Decoder(CreateRoomInput) {
  use host_nickname <- decode.field("host-nickname", decode.string)
  decode.success(CreateRoomInput(host_nickname:))
}

fn add_player_input_decoder() -> decode.Decoder(AddPlayerInput) {
  use nickname <- decode.field("nickname", decode.string)
  decode.success(AddPlayerInput(nickname:))
}

pub fn handle_request(
  req: Request,
  ctx: Context,
  allow_all_origins allow_all_origins: Bool,
) -> Response {
  use req <- web.middleware(req, ctx.static_directory, allow_all_origins:)

  case req.method, wisp.path_segments(req) {
    Post, ["rooms"] -> handle_create_room(req)
    Get, ["rooms", "new"] -> serve_index()
    Get, ["rooms", "join"] -> serve_index()
    Get, ["rooms", id] -> handle_get_room(req, id)
    Get, ["rooms", room_code, "hands", player_id] ->
      handle_get_hand(req, ctx, room_code, player_id)
    Post, ["rooms", id, "players"] -> handle_add_player(req, id, ctx)
    Post, ["rooms", id, "games"] -> handle_start_game(req, ctx, id)
    Get, ["websocket"] -> handle_websocket(req, ctx)
    Get, _ -> serve_index()
    Options, _ -> wisp.no_content()
    _, _ -> wisp.not_found()
  }
}

fn serve_index() -> Response {
  let html =
    html.html([], [
      html.head([], [
        html.meta([attribute.charset("utf-8")]),
        html.meta([
          attribute.content("width=device-width, initial-scale=1"),
          attribute.name("viewport"),
        ]),
        html.title([], "Banana Split"),
        html.script(
          [
            attribute.type_("module"),
            attribute.src("/static/banana_split_client_prod.js"),
          ],
          "",
        ),
        html.link([
          attribute.href("/static/index.css"),
          attribute.rel("stylesheet"),
        ]),
      ]),
      html.body([], [html.div([attribute.id("ui")], [])]),
    ])

  html
  |> element.to_document_string
  |> wisp.html_response(200)
}

fn handle_create_room(req: Request) -> Response {
  use json <- wisp.require_json(req)
  use conn <- sqlight.with_connection("database.db")

  let result = {
    use input <- result.try(decode.run(json, create_room_input_decoder()))

    let room_code = passphrase.new(3)
    let player =
      players.Player(
        id: gluid.guidv4(),
        nickname: input.host_nickname,
        room_code:,
        status: players.Alive,
        connectivity: players.Connected,
        approved_victory_for: option.None,
        hand: bunch.new_hand(),
      )
    let new_room =
      rooms.Room(
        room_code:,
        host: player,
        other_players: [],
        state: rooms.Setup,
      )

    let assert Ok(Nil) = rooms.persist(conn, new_room)
    let object =
      json.object([
        #("room-code", json.string(new_room.room_code)),
        #(
          "host",
          json.object([
            #("id", json.string(player.id)),
            #("nickname", json.string(player.nickname)),
          ]),
        ),
        #("other-players", json.array([], json.object)),
      ])
    Ok(json.to_string(object))
  }

  case result {
    Ok(json) -> wisp.json_response(json, 201)

    Error(_) -> wisp.unprocessable_content()
  }
}

fn handle_start_game(_req: Request, ctx: Context, room_code: String) -> Response {
  use conn <- sqlight.with_connection("database.db")

  let assert Ok(room) = rooms.fetch(conn, room_code)

  let #(bunch, hands) =
    bunch.new()
    |> bunch.start(
      1 + { list.length(room.other_players) },
      float.random() *. 1000.0 |> float.round,
    )

  let bunch_size = bunch.bunch_size(bunch)
  let assert [hand, ..other_hands] = hands
  list.zip(room.other_players, other_hands)
  |> list.each(fn(pair: #(players.Player, set.Set(api.Tile))) {
    let #(player, player_hand) = pair
    // TODO: fix N + 1
    let assert Ok(_) =
      players.set_hand(conn, player, bunch.Hand(tiles: player_hand))
    registry.send(
      ctx.registry,
      player.id,
      api.HandDealt(
        new_tiles: player_hand |> set.to_list,
        bunch_size: bunch_size,
      ),
    )
  })

  let assert Ok(_) = players.set_hand(conn, room.host, bunch.Hand(tiles: hand))
  let assert Ok(game_id) = rooms.persist_game(conn, room_code, bunch)
  let assert Ok(_) = rooms.update_with_new_game(conn, room_code, game_id)

  let object =
    json.object([
      #(
        "hand",
        json.object([
          #(
            "tiles",
            json.array(hand |> set.to_list, fn(tile: api.Tile) {
              json.object([
                #("id", json.int(tile.id)),
                #("letter", json.string(tile.letter)),
              ])
            }),
          ),
        ]),
      ),
      #("bunch-size", json.int(bunch_size)),
    ])

  wisp.json_response(json.to_string(object), 201)
}

fn handle_scoop(
  registry: Registry(api.Message, Nil),
  scooper_id: String,
  client_bunch_size: Int,
) {
  use conn <- sqlight.with_connection("database.db")

  let assert Ok(scooper) = players.fetch_by_id(conn, scooper_id)
  let assert Ok(room) = rooms.fetch(conn, scooper.room_code)
  let assert Ok(bunch) = rooms.fetch_bunch(conn, room.room_code)

  case client_bunch_size == bunch.bunch_size(bunch) {
    False -> {
      // client is out of date. ignore their scoop
      Nil
    }
    True -> {
      let player_count = 1 + list.length(room.other_players)
      let seed = float.random() *. 100_000.0 |> float.round
      let #(new_tiles, new_bunch) = bunch.draw(bunch, player_count, seed)
      let assert Ok(_) = rooms.update_bunch(conn, room.room_code, new_bunch)
      let new_bunch_size = bunch.bunch_size(new_bunch)

      // TODO: handle game over conditions (new_tiles < player_count)
      list.zip([room.host, ..room.other_players], new_tiles |> set.to_list)
      |> list.each(fn(pair) {
        let #(player, tile) = pair
        // TODO: fix N+1
        let assert Ok(_) = players.add_tile(conn, player, tile)
        // TODO: avoid dumb player -> player conversion
        let scooper_ = Player(id: scooper.id, nickname: scooper.nickname)
        let new_tile = api.Tile(id: tile.id, letter: tile.letter)
        let message =
          api.Scooped(scooper: scooper_, new_tile:, bunch_size: new_bunch_size)
        registry.send(registry, player.id, message)
      })
    }
  }
}

fn handle_toss(ctx: Context, tosser_id: String, tile: api.Tile) {
  use conn <- sqlight.with_connection("database.db")

  let assert Ok(tosser) = players.fetch_by_id(conn, tosser_id)
  let assert Ok(room) = rooms.fetch(conn, tosser.room_code)
  let assert Ok(bunch) = rooms.fetch_bunch(conn, room.room_code)

  let #(new_tiles, new_bunch) = bunch.toss(bunch, tile)
  let assert Ok(_) = rooms.update_bunch(conn, room.room_code, new_bunch)
  let new_bunch_size = bunch.bunch_size(new_bunch)
  let assert Ok(_) = players.toss(conn, tosser, tile, new_tiles)

  let assert Ok(_) =
    registry.send(
      ctx.registry,
      tosser.id,
      api.Tossed(new_tiles, tile, new_bunch_size),
    )
  let broadcast_msg =
    api.OpponentTossed(
      tosser: api.Player(tosser.id, tosser.nickname),
      bunch_size: new_bunch_size,
    )
  broadcast_to_room(ctx.registry, room, broadcast_msg, except: [tosser.id])
}

fn handle_victory_claim(ctx: Context, claimant_id: String, grid: api.Grid) {
  use conn <- sqlight.with_connection("database.db")

  let assert Ok(claimant) = players.fetch_by_id(conn, claimant_id)
  let assert Ok(room) = rooms.fetch(conn, claimant.room_code)
  case room.other_players {
    [] -> {
      let assert Ok(_) =
        registry.send(
          ctx.registry,
          claimant.id,
          api.GameOver(Player(id: claimant.id, nickname: claimant.nickname)),
        )
      Nil
    }
    _ -> {
      let assert Ok(_) =
        registry.send(ctx.registry, claimant.id, api.ClaimedVictory)
      let broadcast_msg =
        api.OpponentClaimedVictory(
          claimant: Player(id: claimant.id, nickname: claimant.nickname),
          grid: grid,
        )
      broadcast_to_room(ctx.registry, room, broadcast_msg, except: [claimant.id])
    }
  }
}

fn handle_victory_rejection(ctx: Context, rejector_id: String, claimant: Player) {
  use conn <- sqlight.with_connection("database.db")

  let assert Ok(claimant_loaded) = players.fetch_by_id(conn, claimant.id)
  let assert Ok(rejector) = players.fetch_by_id(conn, rejector_id)
  let assert Ok(_) = players.mark_as_dead(conn, claimant.id)
  let assert Ok(room) = rooms.fetch(conn, claimant_loaded.room_code)
  let all_players = [room.host, ..room.other_players]
  let assert Ok(_) = players.clear_all_approvals(conn, room.room_code)
  let #(alive_players, dead_players) =
    list.partition(all_players, fn(p) { p.status == players.Alive })
  let resume_msg =
    api.PrepareToResume(
      claimant:,
      rejector: Player(id: rejector.id, nickname: rejector.nickname),
    )
  let die_msg =
    api.DieOrStayDead(
      claimant:,
      rejector: Player(id: rejector.id, nickname: rejector.nickname),
    )
  case list.is_empty(alive_players) {
    True -> {
      // everyone is back in it!
      let assert Ok(_) = players.revive_all(conn, room.room_code)
      broadcast_to_room(ctx.registry, room, resume_msg, except: [])
    }
    False -> {
      broadcast_to_room(
        ctx.registry,
        room,
        resume_msg,
        except: list.map(dead_players, fn(p) { p.id }),
      )
      broadcast_to_room(
        ctx.registry,
        room,
        die_msg,
        except: list.map(alive_players, fn(p) { p.id }),
      )
    }
  }
}

fn handle_remove_player(ctx: Context, remover_id: String, removee_id: String) {
  use conn <- sqlight.with_connection("database.db")

  let assert Ok(removee) = players.fetch_by_id(conn, removee_id)
  let assert Ok(room) = rooms.fetch(conn, removee.room_code)
  // TODO: handle permission error better
  assert room.host.id == remover_id

  let assert Ok(_) = players.delete(conn, removee.id)

  let msg = api.LeftRoom(api.Player(id: removee.id, nickname: removee.nickname))
  broadcast_to_room(ctx.registry, room, msg, except: [])
  // TODO: clean up websocket stuff
}

fn handle_rematch(ctx: Context, room_code: String) {
  use conn <- sqlight.with_connection("database.db")
  let assert Ok(room) = rooms.fetch(conn, room_code)

  broadcast_to_room(ctx.registry, room, api.Rematch, except: [])
}

fn handle_save_final_hand(
  player: players.Player,
  grid: api.Grid,
  pile: List(api.Tile),
) {
  use conn <- sqlight.with_connection("database.db")

  let grid_text = api.grid_to_json(grid) |> json.to_string()
  let pile_text = json.array(pile, api.tile_to_json) |> json.to_string()
  let assert Ok(_) =
    players.save_grid_and_pile(conn, player, grid_text, pile_text)
}

fn handle_victory_approval(ctx: Context, approver_id: String, claimant: Player) {
  use conn <- sqlight.with_connection("database.db")

  let assert Ok(approver) = players.fetch_by_id(conn, approver_id)
  let assert Ok(_) =
    players.mark_approval(conn, approver_id:, claimant_id: claimant.id)
  let assert Ok(room) = rooms.fetch(conn, approver.room_code)
  let all_players = [room.host, ..room.other_players]
  case all_approve(all_players, claimant) {
    False -> Nil
    True -> {
      let msg = api.GameOver(winner: claimant)
      broadcast_to_room(ctx.registry, room, msg, except: [])
    }
  }
}

fn all_approve(players: List(players.Player), claimant: Player) {
  players
  |> list.all(fn(player) {
    player.approved_victory_for == option.Some(claimant.id)
    || player.id == claimant.id
  })
}

fn handle_get_room(req: Request, room_code: String) -> Response {
  use conn <- sqlight.with_connection("database.db")

  let result = {
    let assert Ok(room) = rooms.fetch(conn, room_code)
    let room =
      json.object([
        #("room-code", json.string(room.room_code)),
        #(
          "host",
          json.object([
            #("id", json.string(room.host.id)),
            #("nickname", json.string(room.host.nickname)),
          ]),
        ),
        #(
          "other-players",
          json.array(room.other_players, fn(player) {
            json.object([
              #("id", json.string(player.id)),
              #("nickname", json.string(player.nickname)),
            ])
          }),
        ),
      ])

    let object =
      json.object([
        #("room", room),
      ])

    Ok(json.to_string(object))
  }

  case result {
    Ok(json) -> wisp.json_response(json, 201)
    Error(_) -> wisp.unprocessable_content()
  }
}

fn handle_get_hand(
  req: Request,
  ctx: Context,
  room_code: String,
  player_id: String,
) -> Response {
  use conn <- sqlight.with_connection("database.db")

  // TODO: could check that the game is over...
  let result = {
    let assert Ok(#(grid, pile)) = players.get_grid_and_pile(conn, player_id)
    let object =
      json.object([
        #("grid", api.grid_to_json(grid)),
        #("pile", json.array(pile, api.tile_to_json)),
      ])

    Ok(json.to_string(object))
  }

  case result {
    Ok(json) -> wisp.json_response(json, 201)
    Error(_) -> wisp.unprocessable_content()
  }
}

fn handle_add_player(req: Request, room_code: String, ctx: Context) -> Response {
  use json <- wisp.require_json(req)
  use conn <- sqlight.with_connection("database.db")

  case decode.run(json, add_player_input_decoder()) {
    Error(_) -> {
      wisp.unprocessable_content()
    }
    Ok(input) -> {
      let assert Ok(room) = rooms.fetch(conn, room_code)
      case room.state {
        rooms.Playing | rooms.GameOver -> {
          wisp.bad_request("Invalid room state")
        }
        rooms.Setup -> {
          case list.length(room.other_players) < 7 {
            False -> {
              // TODO: handle race condition
              wisp.bad_request("The room is full")
            }
            True -> {
              let player =
                players.Player(
                  id: gluid.guidv4(),
                  nickname: input.nickname,
                  room_code: room_code,
                  status: players.Alive,
                  connectivity: players.Connected,
                  approved_victory_for: option.None,
                  hand: bunch.new_hand(),
                )
              let assert Ok(Nil) =
                players.persist(
                  conn,
                  id: player.id,
                  nickname: player.nickname,
                  room_code: room_code,
                )

              let assert Ok(room) = rooms.fetch(conn, room_code)

              broadcast_to_room(
                ctx.registry,
                room,
                api.JoinedRoom(Player(player.id, player.nickname)),
                except: [player.id],
              )

              let room =
                json.object([
                  #("room-code", json.string(room.room_code)),
                  #(
                    "host",
                    json.object([
                      #("id", json.string(room.host.id)),
                      #("nickname", json.string(room.host.nickname)),
                    ]),
                  ),
                  #(
                    "other-players",
                    json.array(room.other_players, fn(player) {
                      json.object([
                        #("id", json.string(player.id)),
                        #("nickname", json.string(player.nickname)),
                      ])
                    }),
                  ),
                ])

              let object =
                json.object([
                  #("room", room),
                  #("current-player-id", json.string(player.id)),
                ])

              wisp.json_response(json.to_string(object), 201)
            }
          }
        }
      }
    }
  }
}

type WebsocketState {
  WebsocketState(
    counter: Int,
    repeater: repeatedly.Repeater(Nil),
    unponged_ping_count: Int,
  )
}

fn handle_websocket(request: Request, ctx: Context) -> Response {
  use conn <- sqlight.with_connection("database.db")

  let assert Ok(player_id) =
    wisp.get_query(request)
    |> list.key_find("player-id")

  let assert Ok(player) = players.fetch_by_id(conn, player_id)
  let assert Ok(room) = rooms.fetch(conn, player.room_code)
  let bunch = rooms.fetch_bunch(conn, player.room_code)
  let bunch_size = case bunch {
    Ok(bunch_) -> bunch.bunch_size(bunch_)
    Error(_) -> 0
  }

  wisp.websocket(
    request,
    on_init: fn(connection) {
      let assert Ok(selector) = registry.register(ctx.registry, player_id, Nil)
      let repeater =
        repeatedly.call(1000, Nil, fn(_state, _count) {
          let result = registry.send(ctx.registry, player_id, api.Ping)
          case result {
            Ok(_) -> Nil
            Error(e) -> {
              // TODO: mark player as disconnected
              wisp.log_error("ping failed")
            }
          }
        })
      case set.is_empty(player.hand.tiles) {
        True -> Nil
        False -> {
          let msg =
            api.Reconnected(
              all_tiles: set.to_list(player.hand.tiles),
              bunch_size: bunch_size,
            )
          websocket.send_text(
            connection,
            json.to_string(api.message_to_json(msg)),
          )
          Nil
        }
      }
      broadcast_to_room(
        ctx.registry,
        room,
        api.PlayerReconnected(Player(player.id, player.nickname)),
        except: [player.id],
      )
      let state = WebsocketState(0, repeater, 0)
      #(state, option.Some(selector))
    },
    on_message: fn(state, message, connection) {
      case message {
        websocket.Text(text) -> {
          case json.parse(text, api.client_message_decoder_json()) {
            Ok(api.Pong) -> {
              let new_state =
                WebsocketState(
                  ..state,
                  counter: state.counter + 1,
                  unponged_ping_count: state.unponged_ping_count - 1,
                )
              websocket.Continue(new_state)
            }
            Ok(api.Scoop(bunch_size)) -> {
              handle_scoop(ctx.registry, player_id, bunch_size)
              websocket.Continue(
                WebsocketState(..state, counter: state.counter + 1),
              )
            }
            Ok(api.Toss(tile)) -> {
              handle_toss(ctx, player_id, tile)
              websocket.Continue(
                WebsocketState(..state, counter: state.counter + 1),
              )
            }
            Ok(api.ClaimVictory(grid)) -> {
              handle_victory_claim(ctx, player_id, grid)
              websocket.Continue(
                WebsocketState(..state, counter: state.counter + 1),
              )
            }
            Ok(api.Reject(claimant)) -> {
              handle_victory_rejection(ctx, player_id, claimant)
              websocket.Continue(
                WebsocketState(..state, counter: state.counter + 1),
              )
            }
            Ok(api.Approve(claimant)) -> {
              handle_victory_approval(ctx, player_id, claimant)
              websocket.Continue(
                WebsocketState(..state, counter: state.counter + 1),
              )
            }
            Ok(api.RemovePlayer(player_id_to_remove)) -> {
              handle_remove_player(ctx, player_id, player_id_to_remove)
              websocket.Continue(
                WebsocketState(..state, counter: state.counter + 1),
              )
            }
            Ok(api.SaveHand(grid, pile)) -> {
              handle_save_final_hand(player, grid, pile)
              websocket.Continue(
                WebsocketState(..state, counter: state.counter + 1),
              )
            }
            Ok(api.InitiateRematch) -> {
              handle_rematch(ctx, player.room_code)
              websocket.Continue(
                WebsocketState(..state, counter: state.counter + 1),
              )
            }
            Error(e) -> {
              echo e
              websocket.Continue(state)
            }
          }
        }
        websocket.Binary(_) -> {
          websocket.Continue(state)
        }
        websocket.Closed -> websocket.Stop
        websocket.Shutdown -> websocket.Stop
        websocket.Custom(msg) -> {
          case state.unponged_ping_count > 5 {
            True -> {
              wisp.log_warning(
                "unpinged pong count exceeds 5. Closing connection.",
              )
              websocket.Stop
            }
            False -> {
              let next_state = case msg {
                api.Ping ->
                  WebsocketState(
                    ..state,
                    unponged_ping_count: state.unponged_ping_count + 1,
                  )
                _ -> state
              }
              send_custom_websocket_msg(connection, msg, next_state)
            }
          }
        }
      }
    },
    on_close: fn(state) {
      repeatedly.stop(state.repeater)
      use conn <- sqlight.with_connection("database.db")
      let assert Ok(_) = players.mark_as_disconnected(conn, player_id)
      let assert Ok(room) = rooms.fetch(conn, player.room_code)
      broadcast_to_room(
        ctx.registry,
        room,
        api.PlayerDisconnected(Player(id: player.id, nickname: player.nickname)),
        except: [player_id],
      )
      wisp.log_info(
        "Connection closed after: "
        <> int.to_string(state.counter)
        <> " messages",
      )
    },
  )
}

fn send_custom_websocket_msg(
  connection: websocket.Connection,
  msg: api.Message,
  next_state: WebsocketState,
) -> websocket.Next(WebsocketState) {
  case
    websocket.send_text(connection, json.to_string(api.message_to_json(msg)))
  {
    Ok(_) -> websocket.Continue(next_state)
    Error(_) -> websocket.StopWithError("Failed to send message")
  }
}

fn broadcast_to_room(
  registry: Registry(api.Message, Nil),
  room: rooms.Room,
  message: api.Message,
  except except: List(String),
) {
  let recipients =
    [room.host, ..room.other_players]
    |> list.map(fn(player) { player.id })
    |> list.filter(fn(id) { !list.contains(except, id) })

  list.each(recipients, fn(recipient) {
    registry.send(registry, recipient, message)
  })
}
