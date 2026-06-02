import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/json
import gleam/list
import vec/vec2
import vec/vec_json

pub type Message {
  /// a new player joined your room
  JoinedRoom(player: Player)
  /// you have been dealt a new hand
  HandDealt(new_tiles: List(Tile), bunch_size: Int)
  /// your opponent peeled and you got a new tile
  Peeled(peeler: Player, new_tile: Tile, bunch_size: Int)
  /// your opponent dumped
  OpponentDumped(dumper: Player, bunch_size: Int)
  /// you dumped
  Dumped(new_tiles: List(Tile), lost_tile: Tile, bunch_size: Int)
  /// your claim to victory has been acknowledged
  ClaimedVictory
  /// your opponent thinks they won
  OpponentClaimedVictory(claimant: Player, grid: Grid)
  /// a victory claim has been rejected and you can keep playing
  PrepareToResume(claimant: Player, rejector: Player)
  /// a victory claim has been rejected but you cannot keep playing
  DieOrStayDead(claimant: Player, rejector: Player)
  /// someone won
  GameOver(winner: Player)
  /// something went wrong, probably
  Close
}

pub type Grid =
  dict.Dict(vec2.Vec2(Int), Tile)

pub type ClientMessage {
  Peel(bunch_size: Int)
  Dump(tile: Tile)
  ClaimVictory(grid: Grid)
  Reject(claimant: Player)
  Approve(claimant: Player)
}

pub type Player {
  Player(id: String, nickname: String)
}

pub type Tile {
  Tile(id: Int, letter: String)
}

fn player_decoder_dynamic() -> decode.Decoder(Player) {
  use _ <- decode.field(0, expect_atom("player"))
  use id <- decode.field(1, decode.string)
  use nickname <- decode.field(2, decode.string)
  decode.success(Player(id, nickname))
}

pub fn player_decoder_json() -> decode.Decoder(Player) {
  use id <- decode.field("id", decode.string)
  use nickname <- decode.field("nickname", decode.string)
  decode.success(Player(id, nickname))
}

fn tile_decoder_dynamic() -> decode.Decoder(Tile) {
  use _ <- decode.field(0, expect_atom("tile"))
  use id <- decode.field(1, decode.int)
  use letter <- decode.field(2, decode.string)
  decode.success(Tile(id, letter))
}

pub fn tile_decoder_json() -> decode.Decoder(Tile) {
  use id <- decode.field("id", decode.int)
  use letter <- decode.field("letter", decode.string)
  decode.success(Tile(id, letter))
}

pub fn message_decoder_dynamic() -> decode.Decoder(Message) {
  decode.one_of(
    {
      use _ <- decode.field(0, expect_atom("close"))
      decode.success(Close)
    },
    or: [
      {
        use _ <- decode.field(0, expect_atom("joined_room"))
        use player <- decode.field(1, player_decoder_dynamic())
        decode.success(JoinedRoom(player))
      },
      {
        use _ <- decode.field(0, expect_atom("hand_dealt"))
        use new_tiles <- decode.field(
          1,
          decode.list(of: tile_decoder_dynamic()),
        )
        use bunch_size <- decode.field(2, decode.int)
        decode.success(HandDealt(new_tiles, bunch_size))
      },
      {
        use _ <- decode.field(0, expect_atom("peeled"))
        use peeler <- decode.field(1, player_decoder_dynamic())
        use new_tile <- decode.field(2, tile_decoder_dynamic())
        use bunch_size <- decode.field(3, decode.int)
        decode.success(Peeled(peeler, new_tile, bunch_size))
      },
      {
        use _ <- decode.field(0, expect_atom("opponent_dumped"))
        use dumper <- decode.field(1, player_decoder_dynamic())
        use bunch_size <- decode.field(2, decode.int)
        decode.success(OpponentDumped(dumper, bunch_size))
      },
      {
        use _ <- decode.field(0, expect_atom("dumped"))
        use new_tiles <- decode.field(
          1,
          decode.list(of: tile_decoder_dynamic()),
        )
        use lost_tile <- decode.field(2, tile_decoder_dynamic())
        use bunch_size <- decode.field(3, decode.int)
        decode.success(Dumped(new_tiles, lost_tile, bunch_size))
      },
      {
        use _ <- decode.then(expect_atom("claimed_victory"))
        decode.success(ClaimedVictory)
      },
      {
        use _ <- decode.field(0, expect_atom("opponent_claimed_victory"))
        use claimant <- decode.field(1, player_decoder_dynamic())
        use grid <- decode.field(2, grid_decoder_dynamic())
        decode.success(OpponentClaimedVictory(claimant, grid))
      },
      {
        use _ <- decode.field(0, expect_atom("prepare_to_resume"))
        use claimant <- decode.field(1, player_decoder_dynamic())
        use rejector <- decode.field(2, player_decoder_dynamic())
        decode.success(PrepareToResume(claimant, rejector))
      },
      {
        use _ <- decode.field(0, expect_atom("die_or_stay_dead"))
        use claimant <- decode.field(1, player_decoder_dynamic())
        use rejector <- decode.field(2, player_decoder_dynamic())
        decode.success(DieOrStayDead(claimant, rejector))
      },
      {
        use _ <- decode.field(0, expect_atom("game_over"))
        use winner <- decode.field(1, player_decoder_dynamic())
        decode.success(GameOver(winner))
      },
    ],
  )
  |> decode.map_errors(fn(errors) {
    echo errors
    errors
  })
}

fn grid_decoder_dynamic() -> decode.Decoder(Grid) {
  decode.dict(vec2_decoder_dynamic(), tile_decoder_dynamic())
}

fn vec2_decoder_dynamic() -> decode.Decoder(vec2.Vec2(Int)) {
  use _ <- decode.field(0, expect_atom("vec2"))
  use x <- decode.field(1, decode.int)
  use y <- decode.field(2, decode.int)
  decode.success(vec2.Vec2(x, y))
}

pub fn message_decoder_json() -> decode.Decoder(Message) {
  decode.one_of(
    {
      use _ <- decode.then(expect_string("close"))
      decode.success(Close)
    },
    or: [
      {
        use _ <- decode.then(expect_string("joined_room"))
        use player <- decode.field("player", player_decoder_json())
        decode.success(JoinedRoom(player))
      },
      {
        use _ <- decode.then(expect_string("hand_dealt"))
        use new_tiles <- decode.field(
          "new_tiles",
          decode.list(of: tile_decoder_json()),
        )
        use bunch_size <- decode.field("bunch_size", decode.int)
        decode.success(HandDealt(new_tiles, bunch_size))
      },
      {
        use _ <- decode.then(expect_string("peeled"))
        use peeler <- decode.field("peeler", player_decoder_json())
        use new_tile <- decode.field("new_tile", tile_decoder_json())
        use bunch_size <- decode.field("bunch_size", decode.int)
        decode.success(Peeled(peeler, new_tile, bunch_size))
      },
      {
        use _ <- decode.then(expect_string("opponent_dumped"))
        use dumper <- decode.field("dumper", player_decoder_json())
        use bunch_size <- decode.field("bunch_size", decode.int)
        decode.success(OpponentDumped(dumper, bunch_size))
      },
      {
        use _ <- decode.then(expect_string("dumped"))
        use new_tiles <- decode.field(
          "new_tiles",
          decode.list(of: tile_decoder_json()),
        )
        use lost_tile <- decode.field("lost_tile", tile_decoder_json())
        use bunch_size <- decode.field("bunch_size", decode.int)
        decode.success(Dumped(new_tiles, lost_tile, bunch_size))
      },
      {
        use _ <- decode.then(expect_string("claimed_victory"))
        decode.success(ClaimedVictory)
      },
      {
        use _ <- decode.then(expect_string("opponent_claimed_victory"))
        use claimant <- decode.field("claimant", player_decoder_json())
        use grid <- decode.field("grid", grid_decoder_json())
        decode.success(OpponentClaimedVictory(claimant, grid))
      },
      {
        use _ <- decode.then(expect_string("prepare_to_resume"))
        use claimant <- decode.field("claimant", player_decoder_json())
        use rejector <- decode.field("rejector", player_decoder_json())
        decode.success(PrepareToResume(claimant, rejector))
      },
      {
        use _ <- decode.then(expect_string("die_or_stay_dead"))
        use claimant <- decode.field("claimant", player_decoder_json())
        use rejector <- decode.field("rejector", player_decoder_json())
        decode.success(DieOrStayDead(claimant, rejector))
      },
      {
        use _ <- decode.then(expect_string("game_over"))
        use winner <- decode.field("winner", player_decoder_json())
        decode.success(GameOver(winner))
      },
    ],
  )
  |> decode.map_errors(fn(errors) {
    echo errors
    errors
  })
}

pub fn client_message_decoder_json() -> decode.Decoder(ClientMessage) {
  decode.one_of(
    {
      use _ <- decode.then(expect_string("peel"))
      use bunch_size <- decode.field("bunch_size", decode.int)
      decode.success(Peel(bunch_size: bunch_size))
    },
    or: [
      {
        use _ <- decode.then(expect_string("dump"))
        use tile <- decode.field("tile", tile_decoder_json())
        decode.success(Dump(tile:))
      },
      {
        use _ <- decode.then(expect_string("claim_victory"))
        use grid <- decode.field("grid", grid_decoder_json())
        decode.success(ClaimVictory(grid:))
      },
      {
        use _ <- decode.then(expect_string("reject"))
        use claimant <- decode.field("claimant", player_decoder_json())
        decode.success(Reject(claimant:))
      },
      {
        use _ <- decode.then(expect_string("approve"))
        use claimant <- decode.field("claimant", player_decoder_json())
        decode.success(Approve(claimant:))
      },
    ],
  )
  |> decode.map_errors(fn(errors) {
    echo errors
    errors
  })
}

fn expect_atom(expected: String) -> decode.Decoder(atom.Atom) {
  use value <- decode.then(atom.decoder())
  case atom.to_string(value) == expected {
    True -> decode.success(value)
    False -> decode.failure(value, "Expected atom: " <> expected)
  }
}

fn expect_string(expected: String) -> decode.Decoder(String) {
  use value <- decode.field("message", decode.string)
  case value == expected {
    True -> decode.success(value)
    False -> decode.failure(value, "Expected string: " <> expected)
  }
}

pub fn message_to_json(msg: Message) -> json.Json {
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
    OpponentDumped(dumper, bunch_size) -> {
      json.object([
        #("message", json.string("opponent_dumped")),
        #("dumper", player_to_json(dumper)),
        #("bunch_size", json.int(bunch_size)),
      ])
    }
    Dumped(new_tiles, lost_tile, bunch_size) -> {
      json.object([
        #("message", json.string("dumped")),
        #("new_tiles", json.array(new_tiles, tile_to_json)),
        #("lost_tile", tile_to_json(lost_tile)),
        #("bunch_size", json.int(bunch_size)),
      ])
    }
    ClaimedVictory -> {
      json.object([
        #("message", json.string("claimed_victory")),
      ])
    }
    OpponentClaimedVictory(claimant, grid) -> {
      json.object([
        #("message", json.string("opponent_claimed_victory")),
        #("claimant", player_to_json(claimant)),
        #("grid", grid_to_json(grid)),
      ])
    }
    PrepareToResume(claimant, rejector) -> {
      json.object([
        #("message", json.string("prepare_to_resume")),
        #("claimant", player_to_json(claimant)),
        #("rejector", player_to_json(rejector)),
      ])
    }
    DieOrStayDead(claimant, rejector) -> {
      json.object([
        #("message", json.string("die_or_stay_dead")),
        #("claimant", player_to_json(claimant)),
        #("rejector", player_to_json(rejector)),
      ])
    }
    GameOver(winner) -> {
      json.object([
        #("message", json.string("game_over")),
        #("winner", player_to_json(winner)),
      ])
    }
  }
}

pub fn client_message_to_json(msg: ClientMessage) -> json.Json {
  case msg {
    Peel(bunch_size) -> {
      json.object([
        #("message", json.string("peel")),
        #("bunch_size", json.int(bunch_size)),
      ])
    }
    Dump(tile) -> {
      json.object([
        #("message", json.string("dump")),
        #("tile", tile_to_json(tile)),
      ])
    }
    ClaimVictory(grid) -> {
      json.object([
        #("message", json.string("claim_victory")),
        #("grid", grid_to_json(grid)),
      ])
    }
    Reject(claimant) -> {
      json.object([
        #("message", json.string("reject")),
        #("claimant", player_to_json(claimant)),
      ])
    }
    Approve(claimant) -> {
      json.object([
        #("message", json.string("approve")),
        #("claimant", player_to_json(claimant)),
      ])
    }
  }
}

pub fn player_to_json(player: Player) -> json.Json {
  json.object([
    #("id", json.string(player.id)),
    #("nickname", json.string(player.nickname)),
  ])
}

pub fn tile_to_json(tile: Tile) -> json.Json {
  json.object([
    #("id", json.int(tile.id)),
    #("letter", json.string(tile.letter)),
  ])
}

pub fn grid_to_json(grid: Grid) -> json.Json {
  json.object([
    #(
      "grid_keys",
      json.array(grid |> dict.keys, fn(pos) {
        vec_json.vec2_to_json(pos, json.int)
      }),
    ),
    #("grid_values", json.array(grid |> dict.values, tile_to_json)),
  ])
}

pub fn grid_decoder_json() -> decode.Decoder(Grid) {
  use grid_keys <- decode.field(
    "grid_keys",
    decode.list(vec_json.vec2_decoder(decode.int)),
  )
  use grid_values <- decode.field(
    "grid_values",
    decode.list(tile_decoder_json()),
  )
  let grid = list.zip(grid_keys, grid_values) |> dict.from_list
  decode.success(grid)
}
