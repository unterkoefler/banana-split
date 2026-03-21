import bananagrams.{type Tile}
import gleam/dynamic/decode
import gleam/http.{Get, Post, Options}
import gleam/json
import gleam/set
import gleam/float
import gleam/list
import gluid
import gleam/result
import wisp.{type Request, type Response}
import web
import passphrase
import sqlight

pub type CreateRoomInput {
  CreateRoomInput(
    host_nickname: String,
  )
}

pub type AddPlayerInput {
  AddPlayerInput(
    nickname: String
  )
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

fn save_room(connection: sqlight.Connection, room: Room) -> Result(Nil, sqlight.Error) {
  let room_result = persist_room_record(connection, room)
  case room_result {
    Ok(Nil) -> {
      persist_player_record(connection, id: room.host.id, nickname: room.host.nickname, room_code: room.room_code)
    }
    Error(e) -> {
      Error(e)
    }
  }
}

fn persist_room_record(connection: sqlight.Connection, room: Room) -> Result(Nil, sqlight.Error) {
  let sql = "
  insert into rooms (room_code, state, host_id) values
  (?, ?, ?);
  "

  sqlight.query(
    sql, 
    on: connection, 
    with: [sqlight.text(room.room_code), sqlight.text("Setup"), sqlight.text(room.host.id)], 
    expecting: decode.dynamic,
  ) |> result.map(fn(_) { Nil })
}

fn persist_player_record(connection: sqlight.Connection, id id: String, nickname nickname: String, room_code room_code: String) -> Result(Nil, sqlight.Error) {
  let sql = "
  insert into players (id, nickname, room_code) values
  (?, ?, ?);
  "

  sqlight.query(
    sql,
    on: connection,
    with: [sqlight.text(id), sqlight.text(nickname), sqlight.text(room_code)],
    expecting: decode.dynamic,
  ) |> result.map(fn(_) { Nil })
}

fn fetch_room(connection: sqlight.Connection, room_code: String) -> Result(Room, sqlight.Error) {
  use room_record <- result.try(fetch_room_record(connection, room_code))
  use host <- result.try(fetch_player_by_id(connection, room_record.host_id))
  use other_players <- result.try(fetch_other_players(connection, room_code:, host_id: host.id))

  Ok(
    Room(
      room_code: room_record.room_code,
      state: room_record.state,
      host:,
      other_players:
    )
  )
}

type RoomRecord {
  RoomRecord(room_code: String, state: RoomState, host_id: String)
}

fn fetch_room_record(connection: sqlight.Connection, room_code: String) -> Result(RoomRecord, sqlight.Error) {
  let room_decoder = {
    use room_code <- decode.field(0, decode.string)
    use state_string <- decode.field(1, decode.string)
    use host_id <- decode.field(2, decode.string)
    let state = case state_string {
      "Setup" -> Ok(Setup)
      "Playing" -> Ok(Playing)
      "GameOver" -> Ok(GameOver)
      _ -> Error(Nil)
    }
    case state {
      Ok(state_) -> {
        decode.success(RoomRecord(room_code:, state: state_, host_id:))
      }
      Error(Nil) -> {
        decode.failure(RoomRecord(room_code: "", state: Setup, host_id: ""), expected: "GameState")
      }
    }
  }
    
  let sql = "
  select room_code, state, host_id
  from rooms
  where room_code = ?
  "

  sqlight.query(
    sql,
    on: connection,
    with: [sqlight.text(room_code)],
    expecting: room_decoder,
  ) |> result.map(fn(results) {
    case results {
      [] -> Error(sqlight.SqlightError(code: sqlight.Notfound, message: "Room not found", offset: -1))
      [result] -> Ok(result)
      _ -> Error(sqlight.SqlightError(code: sqlight.Corrupt, message: "Multiple rooms found", offset: -1))
    }
  }) |> result.flatten
}


fn fetch_player_by_id(connection: sqlight.Connection, id: String) -> Result(Player, sqlight.Error) {
  let player_decoder = {
    use id <- decode.field(0, decode.string)
    use nickname <- decode.field(1, decode.string)
    decode.success(Player(id:, nickname:))
  }
    
  let sql = "
  select id, nickname
  from players
  where id = ?
  "

  sqlight.query(
    sql,
    on: connection,
    with: [sqlight.text(id)],
    expecting: player_decoder,
  ) |> result.map(fn(results) {
    case results {
      [] -> Error(sqlight.SqlightError(code: sqlight.Notfound, message: "Player not found", offset: -1))
      [result] -> Ok(result)
      _ -> Error(sqlight.SqlightError(code: sqlight.Corrupt, message: "Multiple players found", offset: -1))
    }
  }) |> result.flatten
}

fn fetch_other_players(connection: sqlight.Connection, room_code room_code: String, host_id host_id: String) -> Result(List(Player), sqlight.Error) {
  let player_decoder = {
    use id <- decode.field(0, decode.string)
    use nickname <- decode.field(1, decode.string)
    decode.success(Player(id:, nickname:))
  }
    
  let sql = "
  select id, nickname
  from players
  where room_code = ?
  and id != ?
  "

  sqlight.query(
    sql,
    on: connection,
    with: [sqlight.text(room_code), sqlight.text(host_id)],
    expecting: player_decoder,
  ) 
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

    let player = Player(id: gluid.guidv4(), nickname: input.host_nickname)
    let new_room = 
      Room(
        room_code: passphrase.new(3),
        host: player,
        other_players: [],
        state: Setup,
      )

    let assert Ok(Nil) = save_room(conn, new_room)
    let object =
        json.object([
            #("room-code", json.string(new_room.room_code)),
            #("host", json.object([#("id", json.string(player.id)), #("nickname", json.string(player.nickname))])),
            #("other-players", json.array([], json.object))
        ])
    Ok(json.to_string(object))
  }

  case result {
    Ok(json) -> wisp.json_response(json, 201)

    Error(_) -> wisp.unprocessable_content()
  }
}

fn handle_start_game(req: Request, room_code: String) -> Response {
  use conn <- sqlight.with_connection("database.db")

  let assert Ok(room) = fetch_room(conn, room_code)

  // TODO: verify room state

  let #(bunch, hands) = bananagrams.new()
    |> bananagrams.split(
      1 + { list.length(room.other_players) },
      float.random() *. 1000.0 |> float.round
    )

  let assert [hand, ..] = hands

  // TODO: update room state
  // TODO: persist bunch
  // TODO: send websocket events

  let object = 
    json.object([
      #("hand", json.object([
        #("tiles", json.array(hand.pile |> set.to_list, fn(tile) {
          json.object([
            #("id", json.int(bananagrams.tile_to_id(tile))),
            #("letter", json.string(bananagrams.tile_to_letter(tile))),
          ])
        }))
      ])),
      #("bunch-size", json.int(bananagrams.bunch_size(bunch)))
    ])

  wisp.json_response(json.to_string(object), 201)
}


fn handle_add_player(req: Request, room_id: String) -> Response {
  use json <- wisp.require_json(req)
  use conn <- sqlight.with_connection("database.db")

  let result = {
    use input <- result.try(decode.run(json, add_player_input_decoder()))

    let assert Ok(room_record) = fetch_room_record(conn, room_id)
    
    // TODO: verify room is in setup state

    let player = Player(id: gluid.guidv4(), nickname: input.nickname)
    let assert Ok(Nil) = persist_player_record(conn, id: player.id, nickname: player.nickname, room_code: room_record.room_code)

    let assert Ok(room) = fetch_room(conn, room_record.room_code)

    let room = 
      json.object([
        #("room-code", json.string(room.room_code)),
        #("host", json.object([#("id", json.string(room.host.id)), #("nickname", json.string(room.host.nickname))])),
        #("other-players", json.array(room.other_players, fn(player) {
          json.object([
            #("id", json.string(player.id)),
            #("nickname", json.string(player.nickname)),
          ])
        })),
      ])

    let object = 
      json.object([
        #("room", room),
        #("current-player-id", json.string(player.id))
      ])

    Ok(json.to_string(object))
  }

  case result {
    Ok(json) -> wisp.json_response(json, 201)
    Error(_) -> wisp.unprocessable_content()
  }
}
