import bananagrams
import gleam/dynamic/decode
import gleam/float
import gleam/http.{Options, Post}
import gleam/json
import gleam/list
import gleam/result
import gleam/set
import gluid
import passphrase
import sqlight
import web
import wisp.{type Request, type Response}
import db/rooms
import db/players

pub type CreateRoomInput {
  CreateRoomInput(host_nickname: String)
}

pub type AddPlayerInput {
  AddPlayerInput(nickname: String)
}

pub type Player {
  Player(id: String, nickname: String)
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

fn create_room_input_decoder() -> decode.Decoder(CreateRoomInput) {
  use host_nickname <- decode.field("host-nickname", decode.string)
  decode.success(CreateRoomInput(host_nickname:))
}

fn add_player_input_decoder() -> decode.Decoder(AddPlayerInput) {
  use nickname <- decode.field("nickname", decode.string)
  decode.success(AddPlayerInput(nickname:))
}

pub fn handle_request(req: Request) -> Response {
  use req <- web.middleware(req)

  case req.method, wisp.path_segments(req) {
    Post, ["rooms"] -> handle_create_room(req)
    Post, ["rooms", id, "players"] -> handle_add_player(req, id)
    Post, ["rooms", id, "games"] -> handle_start_game(req, id)
    Post, ["rooms", id, "grid"] -> handle_peel(req, id)
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

fn handle_start_game(_req: Request, room_code: String) -> Response {
  use conn <- sqlight.with_connection("database.db")

  let assert Ok(room) = rooms.fetch(conn, room_code)

  // TODO: verify room state

  let #(bunch, hands) =
    bananagrams.new()
    |> bananagrams.split(
      1 + { list.length(room.other_players) },
      float.random() *. 1000.0 |> float.round,
    )

  let assert [hand, ..] = hands

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
      #("bunch-size", json.int(bananagrams.bunch_size(bunch))),
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

fn handle_add_player(req: Request, room_code: String) -> Response {
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
