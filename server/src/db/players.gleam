import db/helpers.{expect_one_record}
import gleam/dynamic/decode
import gleam/option
import gleam/result
import sqlight

pub type Player {
  Player(
    id: String,
    nickname: String,
    room_code: String,
    status: PlayerStatus,
    approved_victory_for: option.Option(String),
  )
}

pub type PlayerStatus {
  Alive
  Dead
}

fn player_status_decoder() -> decode.Decoder(PlayerStatus) {
  use status <- decode.then(decode.string)
  case status {
    "alive" -> decode.success(Alive)
    "dead" -> decode.success(Dead)
    _ -> decode.failure(Dead, "PlayerStatus")
  }
}

fn player_status_to_value(player_status: PlayerStatus) -> sqlight.Value {
  case player_status {
    Alive -> sqlight.text("alive")
    Dead -> sqlight.text("dead")
  }
}

pub fn persist(
  connection: sqlight.Connection,
  id id: String,
  nickname nickname: String,
  room_code room_code: String,
) -> Result(Nil, sqlight.Error) {
  let sql =
    "
  insert into players (id, nickname, room_code, status, approved_victory_for) values
  (?, ?, ?, ?, ?);
  "

  sqlight.query(
    sql,
    on: connection,
    with: [
      sqlight.text(id),
      sqlight.text(nickname),
      sqlight.text(room_code),
      player_status_to_value(Alive),
      sqlight.null(),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
}

fn player_decoder() -> decode.Decoder(Player) {
  use id <- decode.field(0, decode.string)
  use nickname <- decode.field(1, decode.string)
  use room_code <- decode.field(2, decode.string)
  use status <- decode.field(3, player_status_decoder())
  use approved_victory_for <- decode.field(4, decode.optional(decode.string))
  decode.success(Player(
    id:,
    nickname:,
    room_code:,
    status:,
    approved_victory_for:,
  ))
}

pub fn fetch_by_id(
  connection: sqlight.Connection,
  id: String,
) -> Result(Player, sqlight.Error) {
  let sql =
    "
  select id, nickname, room_code, status, approved_victory_for
  from players
  where id = ?
  "

  sqlight.query(
    sql,
    on: connection,
    with: [sqlight.text(id)],
    expecting: player_decoder(),
  )
  |> expect_one_record("player")
}

pub fn fetch_others_by_room(
  connection: sqlight.Connection,
  room_code room_code: String,
  host_id host_id: String,
) -> Result(List(Player), sqlight.Error) {
  let sql =
    "
  select id, nickname, room_code, status, approved_victory_for
  from players
  where room_code = ?
  and id != ?
  "

  sqlight.query(
    sql,
    on: connection,
    with: [sqlight.text(room_code), sqlight.text(host_id)],
    expecting: player_decoder(),
  )
}

pub fn mark_as_dead(
  connection: sqlight.Connection,
  player_id: String,
) -> Result(Nil, sqlight.Error) {
  let sql =
    "
  update players
  set status=?
  where id = ?
  "

  sqlight.query(
    sql,
    on: connection,
    with: [
      player_status_to_value(Dead),
      sqlight.text(player_id),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
}

pub fn mark_approval(
  connection: sqlight.Connection,
  approver_id player_id: String,
  claimant_id claimant_id: String,
) -> Result(Nil, sqlight.Error) {
  let sql =
    "
  update players
  set approved_victory_for=?
  where id = ?
  "

  sqlight.query(
    sql,
    on: connection,
    with: [
      sqlight.text(claimant_id),
      sqlight.text(player_id),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
}

pub fn clear_all_approvals(
  connection: sqlight.Connection,
  room_code: String,
) -> Result(Nil, sqlight.Error) {
  let sql =
    "
  update players
  set approved_victory_for=?
  where room_code = ?
  "

  sqlight.query(
    sql,
    on: connection,
    with: [
      sqlight.null(),
      sqlight.text(room_code),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
}

pub fn revive_all(
  connection: sqlight.Connection,
  room_code: String,
) -> Result(Nil, sqlight.Error) {
  let sql =
    "
  update players
  set status=?
  where room_code = ?
  "

  sqlight.query(
    sql,
    on: connection,
    with: [
      player_status_to_value(Alive),
      sqlight.text(room_code),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
}
