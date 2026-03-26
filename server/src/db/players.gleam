import gleam/dynamic/decode
import gleam/result
import sqlight
import db/helpers.{expect_one_record}


pub type Player {
  Player(id: String, nickname: String)
}

pub fn persist(
  connection: sqlight.Connection,
  id id: String,
  nickname nickname: String,
  room_code room_code: String,
) -> Result(Nil, sqlight.Error) {
  let sql =
    "
  insert into players (id, nickname, room_code) values
  (?, ?, ?);
  "

  sqlight.query(
    sql,
    on: connection,
    with: [sqlight.text(id), sqlight.text(nickname), sqlight.text(room_code)],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
}

pub fn fetch_by_id(
  connection: sqlight.Connection,
  id: String,
) -> Result(Player, sqlight.Error) {
  let player_decoder = {
    use id <- decode.field(0, decode.string)
    use nickname <- decode.field(1, decode.string)
    decode.success(Player(id:, nickname:))
  }

  let sql =
    "
  select id, nickname
  from players
  where id = ?
  "

  sqlight.query(
    sql,
    on: connection,
    with: [sqlight.text(id)],
    expecting: player_decoder,
  )
  |> expect_one_record("player")
}

pub fn count(
  connection: sqlight.Connection,
  room_code: String,
) -> Result(Int, sqlight.Error) {
  // TODO
  Ok(1)
}

pub fn fetch_others_by_room(
  connection: sqlight.Connection,
  room_code room_code: String,
  host_id host_id: String,
) -> Result(List(Player), sqlight.Error) {
  let player_decoder = {
    use id <- decode.field(0, decode.string)
    use nickname <- decode.field(1, decode.string)
    decode.success(Player(id:, nickname:))
  }

  let sql =
    "
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

