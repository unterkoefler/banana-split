import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/json

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
  /// something went wrong, probably
  Close
}

pub type ClientMessage {
  Peel(bunch_size: Int)
  Dump(tile: Tile)
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

fn player_decoder_json() -> decode.Decoder(Player) {
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

fn tile_decoder_json() -> decode.Decoder(Tile) {
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
    ],
  )
  |> decode.map_errors(fn(errors) {
    echo errors
    errors
  })
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
    #("letter", json.string(tile.letter)),
  ])
}
