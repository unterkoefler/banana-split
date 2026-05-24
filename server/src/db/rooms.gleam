import bananagrams.{type Bunch}
import db/helpers.{expect_one_record}
import db/players
import gleam/dynamic/decode
import gleam/result
import sqlight

// TODO: move elsewhere
pub type Room {
  Room(
    room_code: String,
    host: players.Player,
    other_players: List(players.Player),
    state: RoomState,
  )
}

pub type RoomState {
  Setup
  Playing
  GameOver
}

pub fn persist(
  connection: sqlight.Connection,
  room: Room,
) -> Result(Nil, sqlight.Error) {
  let room_result = persist_room_record(connection, room)
  case room_result {
    Ok(Nil) -> {
      players.persist(
        connection,
        id: room.host.id,
        nickname: room.host.nickname,
        room_code: room.room_code,
      )
    }
    Error(e) -> {
      Error(e)
    }
  }
}

fn persist_room_record(
  connection: sqlight.Connection,
  room: Room,
) -> Result(Nil, sqlight.Error) {
  let sql =
    "
  insert into rooms (room_code, state, host_id) values
  (?, ?, ?);
  "

  sqlight.query(
    sql,
    on: connection,
    with: [
      sqlight.text(room.room_code),
      sqlight.text("Setup"),
      sqlight.text(room.host.id),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
}

pub fn fetch(
  connection: sqlight.Connection,
  room_code: String,
) -> Result(Room, sqlight.Error) {
  use room_record <- result.try(fetch_room_record(connection, room_code))
  use host <- result.try(players.fetch_by_id(connection, room_record.host_id))
  use other_players <- result.try(players.fetch_others_by_room(
    connection,
    room_code:,
    host_id: host.id,
  ))

  Ok(Room(
    room_code: room_record.room_code,
    state: room_record.state,
    host:,
    other_players:,
  ))
}

type RoomRecord {
  RoomRecord(room_code: String, state: RoomState, host_id: String)
}

fn fetch_room_record(
  connection: sqlight.Connection,
  room_code: String,
) -> Result(RoomRecord, sqlight.Error) {
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
        decode.failure(
          RoomRecord(room_code: "", state: Setup, host_id: ""),
          expected: "GameState",
        )
      }
    }
  }

  let sql =
    "
  select room_code, state, host_id
  from rooms
  where room_code = ?
  "

  sqlight.query(
    sql,
    on: connection,
    with: [sqlight.text(room_code)],
    expecting: room_decoder,
  )
  |> expect_one_record("room")
}

pub fn update_with_new_game(
  connection: sqlight.Connection,
  room_code: String,
  game_id: Int,
) -> Result(Nil, sqlight.Error) {
  let sql =
    "
  update rooms
  set state=?, active_game_id=?
  where room_code = ?
  "

  sqlight.query(
    sql,
    on: connection,
    // TODO: use enum type instead of string for Playing
    with: [
      sqlight.text("Playing"),
      sqlight.int(game_id),
      sqlight.text(room_code),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
}

// ---- GAMES & BUNCHES ---- //

pub fn persist_game(
  connection: sqlight.Connection,
  room_code: String,
  bunch: bananagrams.Bunch,
) -> Result(Int, sqlight.Error) {
  let sql =
    "
  insert into games (bunch, room_code) values
  (?, ?)
  returning id
  "

  let bunch_str =
    bunch
    |> bananagrams.serialize_bunch
    |> sqlight.text

  sqlight.query(
    sql,
    on: connection,
    with: [bunch_str, sqlight.text(room_code)],
    expecting: decode.field(0, decode.int, fn(a) { decode.success(a) }),
  )
  |> expect_one_record("game")
}

pub fn fetch_bunch(
  connection: sqlight.Connection,
  room_code: String,
) -> Result(Bunch, sqlight.Error) {
  let bunch_decoder = {
    use bunch_str <- decode.field(0, decode.string)
    // TODO: handle possible deserialization errors
    let assert Ok(bunch) = bananagrams.deserialize_bunch(bunch_str)
    decode.success(bunch)
  }

  let sql =
    "
  select bunch
  from games
  join rooms
    on rooms.active_game_id = games.id
  where
    rooms.room_code = ?
  "

  sqlight.query(
    sql,
    on: connection,
    with: [sqlight.text(room_code)],
    expecting: bunch_decoder,
  )
  |> expect_one_record("game")
}

pub fn update_bunch(
  connection: sqlight.Connection,
  room_code: String,
  bunch: Bunch,
) -> Result(Nil, sqlight.Error) {
  let sql =
    "
  update games
  set bunch = ?
  where id = (
    select active_game_id from rooms where room_code = ?
  )
  "

  sqlight.query(
    sql,
    on: connection,
    with: [
      sqlight.text(bananagrams.serialize_bunch(bunch)),
      sqlight.text(room_code),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
}
