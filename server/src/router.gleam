import bananagrams
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
import passphrase
import shared.{type Player, Player} as api
import sqlight
import web
import wisp.{type Request, type Response}
import wisp/websocket

pub type Context {
  Context(registry: Registry(api.Message, Nil))
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

pub fn handle_request(req: Request, ctx: Context) -> Response {
  use req <- web.middleware(req)

  case req.method, wisp.path_segments(req) {
    Post, ["rooms"] -> handle_create_room(req)
    Get, ["rooms", id] -> handle_get_room(req, id)
    Post, ["rooms", id, "players"] -> handle_add_player(req, id, ctx)
    Post, ["rooms", id, "games"] -> handle_start_game(req, ctx, id)
    Get, ["websocket"] -> handle_websocket(req, ctx)
    Options, _ -> wisp.no_content()
    // TODO: handle re-joining after disconnect
    _, _ -> wisp.not_found()
  }
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

  // TODO: verify room state

  let #(bunch, hands) =
    bananagrams.new()
    |> bananagrams.split(
      1 + { list.length(room.other_players) },
      float.random() *. 1000.0 |> float.round,
    )

  let bunch_size = bananagrams.bunch_size(bunch)
  let assert [hand, ..other_hands] = hands
  list.zip(room.other_players, other_hands)
  |> list.each(fn(pair: #(players.Player, set.Set(api.Tile))) {
    let #(player, player_hand) = pair
    registry.send(
      ctx.registry,
      player.id,
      api.HandDealt(
        new_tiles: player_hand |> set.to_list,
        bunch_size: bunch_size,
      ),
    )
  })

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

fn handle_peel(
  registry: Registry(api.Message, Nil),
  peeler_id: String,
  client_bunch_size: Int,
) {
  use conn <- sqlight.with_connection("database.db")

  let assert Ok(peeler) = players.fetch_by_id(conn, peeler_id)
  let assert Ok(room) = rooms.fetch(conn, peeler.room_code)
  let assert Ok(bunch) = rooms.fetch_bunch(conn, room.room_code)

  case client_bunch_size == bananagrams.bunch_size(bunch) {
    False -> {
      // client is out of date. ignore their peel
      Nil
    }
    True -> {
      let player_count = 1 + list.length(room.other_players)
      // TODO
      let seed = 23
      let #(new_tiles, new_bunch) = bananagrams.draw(bunch, player_count, seed)
      let assert Ok(_) = rooms.update_bunch(conn, room.room_code, new_bunch)
      let new_bunch_size = bananagrams.bunch_size(new_bunch)

      // TODO: handle game over conditions (new_tiles < player_count)
      list.zip([room.host, ..room.other_players], new_tiles |> set.to_list)
      |> list.each(fn(pair) {
        let #(player, tile) = pair
        // TODO: avoid dumb player -> player conversion
        let peeler_ = Player(id: peeler.id, nickname: peeler.nickname)
        let new_tile = api.Tile(id: tile.id, letter: tile.letter)
        let message =
          api.Peeled(peeler: peeler_, new_tile:, bunch_size: new_bunch_size)
        registry.send(registry, player.id, message)
      })
    }
  }
}

fn handle_dump(ctx: Context, dumper_id: String, tile: api.Tile) {
  use conn <- sqlight.with_connection("database.db")

  let assert Ok(dumper) = players.fetch_by_id(conn, dumper_id)
  let assert Ok(room) = rooms.fetch(conn, dumper.room_code)
  let assert Ok(bunch) = rooms.fetch_bunch(conn, room.room_code)

  let #(new_tiles, new_bunch) = bananagrams.dump(bunch, tile)
  let assert Ok(_) = rooms.update_bunch(conn, room.room_code, new_bunch)
  let new_bunch_size = bananagrams.bunch_size(new_bunch)

  let assert Ok(_) =
    registry.send(
      ctx.registry,
      dumper.id,
      api.Dumped(new_tiles, tile, new_bunch_size),
    )
  let broadcast_msg =
    api.OpponentDumped(
      dumper: api.Player(dumper.id, dumper.nickname),
      bunch_size: new_bunch_size,
    )
  broadcast_to_room(ctx.registry, room, broadcast_msg, except: [dumper.id])
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

fn handle_add_player(req: Request, room_code: String, ctx: Context) -> Response {
  use json <- wisp.require_json(req)
  use conn <- sqlight.with_connection("database.db")

  let result = {
    use input <- result.try(decode.run(json, add_player_input_decoder()))

    // TODO: verify room is in setup state

    let player =
      players.Player(
        id: gluid.guidv4(),
        nickname: input.nickname,
        room_code: room_code,
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

    Ok(json.to_string(object))
  }

  case result {
    Ok(json) -> wisp.json_response(json, 201)
    Error(_) -> wisp.unprocessable_content()
  }
}

fn handle_websocket(request: Request, ctx: Context) -> Response {
  let assert Ok(player_id) =
    wisp.get_query(request)
    |> list.key_find("player-id")
  wisp.websocket(
    request,
    on_init: fn(_connection) {
      let selector_resp = registry.register(ctx.registry, player_id, Nil)
      case selector_resp {
        Ok(selector) -> #(0, option.Some(selector))
        Error(e) -> {
          // TODO: 500 error instead
          echo e
          #(0, option.None)
        }
      }
    },
    on_message: fn(state, message, connection) {
      case message {
        websocket.Text(text) -> {
          case json.parse(text, api.client_message_decoder_json()) {
            Ok(api.Peel(bunch_size)) -> {
              handle_peel(ctx.registry, player_id, bunch_size)
              websocket.Continue(state + 1)
            }
            Ok(api.Dump(tile)) -> {
              handle_dump(ctx, player_id, tile)
              websocket.Continue(state + 1)
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
          case
            websocket.send_text(
              connection,
              json.to_string(api.message_to_json(msg)),
            )
          {
            Ok(_) -> websocket.Continue(state)
            Error(_) -> websocket.StopWithError("Failed to send message")
          }
        }
      }
    },
    on_close: fn(state) {
      wisp.log_info(
        "Connection closed after: " <> int.to_string(state) <> " messages",
      )
    },
  )
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
