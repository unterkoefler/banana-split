import bananagrams.{type Tile}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/float
import gleam/int
import gleam/http.{Options, Post, Get}
import gleam/json
import gleam/list
import gleam/result
import gleam/option
import gleam/string
import gleam/set
import gluid
import passphrase
import sqlight
import web
import wisp.{type Request, type Response}
import wisp/websocket
import db/rooms
import db/players
import gleam/erlang/process.{new_selector}
import glyn/registry.{type Registry}

pub type Context {
  Context(registry: Registry(Message, Nil))
}

pub type CreateRoomInput {
  CreateRoomInput(host_nickname: String)
}

pub type AddPlayerInput {
  AddPlayerInput(nickname: String)
}

pub type Player {
  Player(id: String, nickname: String)
}

fn player_decoder() -> decode.Decoder(Player) {
  use _ <- decode.field(0, expect_atom("player"))
  use id <- decode.field(1, decode.string)
  use nickname <- decode.field(2, decode.string)
  decode.success(Player(id, nickname))
}

fn tile_decoder() -> decode.Decoder(Tile) {
  use _ <- decode.field(0, expect_atom("tile"))
  use id <- decode.field(1, decode.int)
  use letter <- decode.field(2, decode.string)
  decode.success(bananagrams.Tile(id, letter))
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

pub type Message {
  /// a new player joined your room
  JoinedRoom(player: Player)
  /// you have been dealt a new hand
  HandDealt(new_tiles: List(Tile), bunch_size: Int)
  /// your opponent peeled and you got a new tile
  Peeled(peeler: Player, new_tile: Tile, bunch_size: Int)
  /// your opponent dumped
  Dumped(dumper: Player, bunch_size: Int)
  /// something went wrong, probably
  Close
}

pub fn message_decoder() -> decode.Decoder(Message) {
  decode.one_of(
    {
      use _ <- decode.field(0, expect_atom("close"))
      decode.success(Close)
    },
    or: [
      {
        use _ <- decode.field(0, expect_atom("joined_room"))
        use player <- decode.field(1, player_decoder())
        decode.success(JoinedRoom(player))
      },
      {
        use _ <- decode.field(0, expect_atom("hand_dealt"))
        use new_tiles <- decode.field(1, decode.list(of: tile_decoder()))
        use bunch_size <- decode.field(2, decode.int)
        decode.success(HandDealt(new_tiles, bunch_size))
      },
      {
        use _ <- decode.field(0, expect_atom("peeled"))
        use peeler <- decode.field(1, player_decoder())
        use new_tile <- decode.field(2, tile_decoder())
        use bunch_size <- decode.field(3, decode.int)
        decode.success(Peeled(peeler, new_tile, bunch_size))
      },
      {
        use _ <- decode.field(0, expect_atom("dumped"))
        use dumper <- decode.field(1, player_decoder())
        use bunch_size <- decode.field(2, decode.int)
        decode.success(Dumped(dumper, bunch_size))
      }
    ]
  )
  |> decode.map_errors(fn(errors) { 
    echo errors
    errors
  })
}

fn message_to_json(msg: Message) -> json.Json {
  case msg {
    Close -> {
      json.object([
        #("message", json.string("close")),
      ])
    }
    JoinedRoom(player) -> {
      json.object([
        #("message", json.string("joined_room")),
        #("player", player_to_json(player)),
      ])
    }
    HandDealt(new_tiles, bunch_size) -> {
      json.object([
        #("message", json.string("hand_dealt")),
        #("new_tiles", json.array(new_tiles, tile_to_json)),
        #("bunch_size", json.int(bunch_size)),
      ])
    }
    Peeled(peeler, new_tile, bunch_size) -> {
      json.object([
        #("message", json.string("peeled")),
        #("peeler", player_to_json(peeler)),
        #("new_tile", tile_to_json(new_tile)),
        #("bunch_size", json.int(bunch_size)),
      ])
    }
    Dumped(dumper, bunch_size) -> {
      json.object([
        #("message", json.string("peeled")),
        #("dumper", player_to_json(dumper)),
        #("bunch_size", json.int(bunch_size)),
      ])
    }
  }
}

fn player_to_json(player: Player) -> json.Json {
  json.object([
    #("id", json.string(player.id)),
    #("nickname", json.string(player.nickname)),
  ])
}

fn tile_to_json(tile: Tile) -> json.Json {
  json.object([
    #("id", json.int(tile.id)),
    #("letter", json.string(tile.letter))
  ])
}

fn expect_atom(expected: String) -> decode.Decoder(atom.Atom) {
  use value <- decode.then(atom.decoder())
  case atom.to_string(value) == expected {
    True -> decode.success(value)
    False -> decode.failure(value, "Expected atom: " <> expected)
  }
}
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
    Post, ["rooms", id, "players"] -> handle_add_player(req, id, ctx)
    Post, ["rooms", id, "games"] -> handle_start_game(req, ctx, id)
    Post, ["rooms", id, "grid"] -> handle_peel(req, id)
    Get, ["websocket"] -> handle_websocket(req, ctx)
    // "post/save a new, solved grid"
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

    let player = players.Player(id: gluid.guidv4(), nickname: input.host_nickname)
    let new_room =
      rooms.Room(
        room_code: passphrase.new(3),
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
    |> list.each(fn(pair: #(players.Player, bananagrams.Hand)) { 
      let #(player, player_hand) = pair
      registry.send(
        ctx.registry,
        player.id,
        HandDealt(
          new_tiles: player_hand.pile |> set.to_list,
          bunch_size: bunch_size
        )
      )
    })


  let assert Ok(game_id) = rooms.persist_game(conn, room_code, bunch)
  let assert Ok(_) = rooms.update_with_new_game(conn, room_code, game_id)
  // TODO: send websocket events

  let object =
    json.object([
      #(
        "hand",
        json.object([
          #(
            "tiles",
            json.array(hand.pile |> set.to_list, fn(tile) {
              json.object([
                #("id", json.int(bananagrams.tile_to_id(tile))),
                #("letter", json.string(bananagrams.tile_to_letter(tile))),
              ])
            }),
          ),
        ]),
      ),
      #("bunch-size", json.int(bunch_size)),
    ])

  wisp.json_response(json.to_string(object), 201)
}

fn handle_peel(_req: Request, room_code: String) -> Response {
  use conn <- sqlight.with_connection("database.db")

  let assert Ok(bunch) = rooms.fetch_bunch(conn, room_code)
  let assert Ok(player_count) = players.count(conn, room_code)

  // TODO: pick a random seed
  let #(drawn_tiles, new_bunch) = bananagrams.draw(bunch, player_count, 23)
  let assert Ok(_) = rooms.update_bunch(conn, room_code, new_bunch)

  // TODO: handle what happens when the bunch runs dry
  let assert Ok(curr_player_tile) = drawn_tiles |> set.to_list |> list.first

  let object =
    json.object([
      #(
        "hand",
        json.object([
          #(
            "tiles",
            json.array([curr_player_tile], fn(tile) {
              json.object([
                #("id", json.int(bananagrams.tile_to_id(tile))),
                #("letter", json.string(bananagrams.tile_to_letter(tile))),
              ])
            }),
          ),
        ]),
      ),
      #("bunch-size", json.int(bananagrams.bunch_size(new_bunch))),
    ])

  wisp.json_response(json.to_string(object), 200)
}

fn handle_add_player(req: Request, room_code: String, ctx: Context) -> Response {
  use json <- wisp.require_json(req)
  use conn <- sqlight.with_connection("database.db")

  let result = {
    use input <- result.try(decode.run(json, add_player_input_decoder()))

    // TODO: verify room is in setup state

    let player = players.Player(id: gluid.guidv4(), nickname: input.nickname)
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
      JoinedRoom(Player(player.id, player.nickname)),
      except: [player.id]
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
  let assert Ok(player_id) = wisp.get_query(request)
    |> list.key_find("player-id")
  wisp.websocket(
    request,
    on_init: fn(_connection) { 
      let selector_resp = registry.register(
        ctx.registry,
        player_id,
        Nil
      )
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
          let count = state + 1
          let response = "Echo #" <> int.to_string(count) <> ": " <> text
          case websocket.send_text(connection, response) {
            Ok(_) -> websocket.Continue(count)
            Error(_) -> websocket.StopWithError("Failed to send message")
          }
        }
        websocket.Binary(binary) -> {
          websocket.Continue(state)
        }
        websocket.Closed -> websocket.Stop
        websocket.Shutdown -> websocket.Stop
        websocket.Custom(msg) -> {
          case websocket.send_text(connection, json.to_string(message_to_json(msg))) {
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
  registry: Registry(Message, Nil),
  room: rooms.Room,
  message: Message,
  except except: List(String)
) {
  let recipients = [room.host, ..room.other_players]
    |> list.map(fn(player) { player.id })
    |> list.filter(fn(id) { !list.contains(except, id) })


  list.each(recipients, fn(recipient) {
    registry.send(
      registry,
      recipient,
      message
    )
  })
}
