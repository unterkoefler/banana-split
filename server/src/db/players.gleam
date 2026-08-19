import bunch.{type Hand, Hand}
import db/helpers.{expect_one_record}
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option
import gleam/result
import gleam/set
import shared.{type Grid, type Tile} as api
import sqlight

pub type Player {
  Player(
    id: String,
    nickname: String,
    room_code: String,
    status: PlayerStatus,
    approved_victory_for: option.Option(String),
    hand: Hand,
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
  insert into players (id, nickname, room_code, status, approved_victory_for, hand) values
  (?, ?, ?, ?, ?, ?);
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
      sqlight.text(bunch.serialize_hand(bunch.new_hand())),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
}

fn player_decoder() -> decode.Decoder(Player) {
  let hand_decoder = {
    use hand_str <- decode.then(decode.string)
    let assert Ok(hand) = bunch.deserialize_hand(hand_str)
    decode.success(hand)
  }
  use id <- decode.field(0, decode.string)
  use nickname <- decode.field(1, decode.string)
  use room_code <- decode.field(2, decode.string)
  use status <- decode.field(3, player_status_decoder())
  use approved_victory_for <- decode.field(4, decode.optional(decode.string))
  use hand <- decode.field(5, hand_decoder)
  decode.success(Player(
    id:,
    nickname:,
    room_code:,
    status:,
    approved_victory_for:,
    hand:,
  ))
}

pub fn fetch_by_id(
  connection: sqlight.Connection,
  id: String,
) -> Result(Player, sqlight.Error) {
  let sql =
    "
  select id, nickname, room_code, status, approved_victory_for, hand
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
  select id, nickname, room_code, status, approved_victory_for, hand
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

pub fn set_hand(
  connection: sqlight.Connection,
  player: Player,
  hand: Hand,
) -> Result(Nil, sqlight.Error) {
  let sql =
    "
  update players
  set hand = ?
  where id = ?
    "

  sqlight.query(
    sql,
    on: connection,
    with: [
      sqlight.text(bunch.serialize_hand(hand)),
      sqlight.text(player.id),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
}

pub fn get_grid_and_pile(
  connection: sqlight.Connection,
  player_id: String,
) -> Result(#(Grid, List(Tile)), sqlight.Error) {
  let sql =
    "
  select grid, pile
  from players
  where id = ?
  "

  sqlight.query(
    sql,
    on: connection,
    with: [
      sqlight.text(player_id),
    ],
    expecting: grid_and_pile_decoder(),
  )
  |> expect_one_record("player")
}

fn grid_and_pile_decoder() -> decode.Decoder(#(Grid, List(Tile))) {
  let grid_decoder = {
    use grid_string <- decode.then(decode.string)
    let res = json.parse(grid_string, api.grid_decoder_json())
    case res {
      Ok(grid) -> decode.success(grid)
      Error(_) -> decode.failure(dict.new(), "Grid")
    }
  }
  let pile_decoder = {
    use pile_string <- decode.then(decode.string)
    let res = json.parse(pile_string, decode.list(api.tile_decoder_json()))
    case res {
      Ok(pile) -> decode.success(pile)
      Error(_) -> decode.failure([], "Pile")
    }
  }
  use grid <- decode.field(0, grid_decoder)
  use pile <- decode.field(1, pile_decoder)
  decode.success(#(grid, pile))
}

pub fn save_grid_and_pile(
  connection: sqlight.Connection,
  player: Player,
  grid: String,
  pile: String,
) -> Result(Nil, sqlight.Error) {
  let sql =
    "
  update players
  set grid = ?, pile = ?
  where id = ?
  "

  sqlight.query(
    sql,
    on: connection,
    with: [
      sqlight.text(grid),
      sqlight.text(pile),
      sqlight.text(player.id),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
}

pub fn add_tile(
  connection: sqlight.Connection,
  player: Player,
  tile: Tile,
) -> Result(Nil, sqlight.Error) {
  let tiles = player.hand.tiles
  let new_hand = Hand(tiles: tiles |> set.insert(tile))
  set_hand(connection, player, new_hand)
}

pub fn toss(
  connection: sqlight.Connection,
  player: Player,
  tossed_tile: Tile,
  new_tiles: List(Tile),
) -> Result(Nil, sqlight.Error) {
  let tiles = player.hand.tiles
  let new_tiles =
    set.delete(tiles, tossed_tile) |> set.union(new_tiles |> set.from_list)
  set_hand(connection, player, Hand(tiles: new_tiles))
}

pub fn delete(
  connection: sqlight.Connection,
  player_id: String,
) -> Result(Nil, sqlight.Error) {
  let sql =
    "
  delete from players
  where id = ?
  "

  sqlight.query(
    sql,
    on: connection,
    with: [
      sqlight.text(player_id),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
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
