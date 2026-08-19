import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/order
import gleam/set
import shared.{type Tile}
import vec/vec2
import vec/vec_json

// The tiles in a players hand.
// Within a hand, tiles can be placed in the grid or returned to the pile
pub opaque type Hand {
  Hand(
    pile: set.Set(Tile),
    // the same tiles in the pile, but sorted so that new tiles
    // are added to the end and that the whole pile can be shuffled
    ordered_pile: List(Tile),
    grid: dict.Dict(vec2.Vec2(Int), Tile),
  )
}

pub fn new_from_grid_and_pile(
  grid: dict.Dict(vec2.Vec2(Int), Tile),
  pile: List(Tile),
) -> Hand {
  Hand(pile: pile |> set.from_list, ordered_pile: pile, grid: grid)
}

pub fn hand_decoder() -> decode.Decoder(Hand) {
  use ordered_pile <- decode.field(
    "ordered_pile",
    decode.list(of: shared.tile_decoder_json()),
  )
  use grid_keys <- decode.field(
    "grid_keys",
    decode.list(vec_json.vec2_decoder(decode.int)),
  )
  use grid_values <- decode.field(
    "grid_values",
    decode.list(shared.tile_decoder_json()),
  )
  let grid = list.zip(grid_keys, grid_values) |> dict.from_list
  decode.success(Hand(
    pile: ordered_pile |> set.from_list,
    ordered_pile: ordered_pile,
    grid: grid,
  ))
}

pub fn hand_to_json(hand: Hand) -> json.Json {
  json.object([
    #("ordered_pile", json.array(hand.ordered_pile, shared.tile_to_json)),
    #(
      "grid_keys",
      json.array(hand.grid |> dict.keys, fn(pos) {
        vec_json.vec2_to_json(pos, json.int)
      }),
    ),
    #("grid_values", json.array(hand.grid |> dict.values, shared.tile_to_json)),
  ])
}

pub fn grid(hand: Hand) -> dict.Dict(vec2.Vec2(Int), Tile) {
  hand.grid
}

pub fn ordered_pile(hand: Hand) -> List(Tile) {
  hand.ordered_pile
}

pub fn is_pile_empty(hand: Hand) -> Bool {
  hand.pile |> set.is_empty()
}

pub fn shuffle_hand(hand: Hand) -> Hand {
  Hand(
    pile: hand.pile,
    ordered_pile: hand.ordered_pile |> list.shuffle(),
    grid: hand.grid,
  )
}

pub fn new_hand() -> Hand {
  Hand(pile: set.new(), ordered_pile: [], grid: dict.new())
}

pub fn add_tiles(hand: Hand, new_tiles: List(Tile)) -> Hand {
  let new_tile_set = new_tiles |> set.from_list()
  let all_tiles =
    set.union(hand.pile, dict.values(hand.grid) |> set.from_list())
  let actually_new_tiles = set.difference(new_tile_set, all_tiles)
  let new_pile = hand.pile |> set.union(actually_new_tiles)
  Hand(
    pile: new_pile,
    ordered_pile: hand.ordered_pile
      |> list.append(actually_new_tiles |> set.to_list()),
    grid: hand.grid,
  )
}

pub fn toss(hand: Hand, new_tiles: List(Tile), lost_tile: Tile) {
  let new_pile = hand.pile |> set.delete(lost_tile)
  Hand(
    pile: new_pile,
    ordered_pile: hand.ordered_pile
      |> list.filter(fn(t) { set.contains(new_pile, t) }),
    grid: hand.grid,
  )
  |> add_tiles(new_tiles)
}

pub type CursorDirection {
  CursorLeft
  CursorRight
  CursorDown
  CursorUp
}

pub type WordDirection {
  Right
  Down
}

pub fn place_letter(hand: Hand, letter: String, posn: vec2.Vec2(Int)) -> Hand {
  let matching_tile =
    set.filter(hand.pile, fn(tile) { tile.letter == letter })
    |> set.to_list
    |> list.first
  let existing_tile = hand.grid |> dict.get(posn)
  case matching_tile, existing_tile {
    Ok(tile), Ok(tile_to_remove) -> {
      let new_pile = hand.pile |> set.delete(tile) |> set.insert(tile_to_remove)
      Hand(
        pile: new_pile,
        ordered_pile: hand.ordered_pile
          |> list.filter(fn(t) { new_pile |> set.contains(t) })
          |> list.append([tile_to_remove]),
        grid: dict.insert(hand.grid, posn, tile),
      )
    }
    Ok(tile), Error(_) -> {
      let new_pile = hand.pile |> set.delete(tile)
      Hand(
        pile: new_pile,
        ordered_pile: hand.ordered_pile
          |> list.filter(fn(t) { new_pile |> set.contains(t) }),
        grid: dict.insert(hand.grid, posn, tile),
      )
    }
    Error(_), _ -> hand
  }
}

pub fn remove_letter(from hand: Hand, at posn: vec2.Vec2(Int)) -> Hand {
  let existing_tile = hand.grid |> dict.get(posn)
  case existing_tile {
    Ok(tile) -> {
      Hand(
        pile: hand.pile |> set.insert(tile),
        ordered_pile: hand.ordered_pile |> list.append([tile]),
        grid: hand.grid |> dict.delete(posn),
      )
    }
    Error(_) -> {
      hand
    }
  }
}

pub fn bulk_move(
  hand: Hand,
  posn: vec2.Vec2(Int),
  direction: CursorDirection,
  max_x: Int,
  max_y: Int,
) -> Hand {
  let grid = hand.grid
  case direction {
    CursorUp -> {
      let tiles_to_move =
        grid
        |> dict.filter(fn(tile_posn, _tile) {
          tile_posn.x == posn.x && tile_posn.y <= posn.y
        })
      let last_tile_y =
        tiles_to_move
        |> dict.keys()
        |> list.map(fn(p) { p.y })
        |> list.max(order.reverse(int.compare))
      case last_tile_y == Ok(0) {
        True -> hand
        False -> {
          let moved_tiles =
            tiles_to_move
            |> dict.fold(dict.new(), fn(acc, key, value) {
              dict.insert(acc, vec2.Vec2(key.x, key.y - 1), value)
            })
          let new_grid =
            grid
            |> dict.drop(tiles_to_move |> dict.keys())
            |> dict.merge(moved_tiles)
          Hand(..hand, grid: new_grid)
        }
      }
    }
    CursorDown -> {
      let tiles_to_move =
        grid
        |> dict.filter(fn(tile_posn, _tile) {
          tile_posn.x == posn.x && tile_posn.y >= posn.y
        })
      let last_tile_y =
        tiles_to_move
        |> dict.keys()
        |> list.map(fn(p) { p.y })
        |> list.max(int.compare)
      case last_tile_y == Ok(max_y) {
        True -> hand
        False -> {
          let moved_tiles =
            tiles_to_move
            |> dict.fold(dict.new(), fn(acc, key, value) {
              dict.insert(acc, vec2.Vec2(key.x, key.y + 1), value)
            })
          let new_grid =
            grid
            |> dict.drop(tiles_to_move |> dict.keys())
            |> dict.merge(moved_tiles)
          Hand(..hand, grid: new_grid)
        }
      }
    }
    CursorRight -> {
      let tiles_to_move =
        grid
        |> dict.filter(fn(tile_posn, _tile) {
          tile_posn.y == posn.y && tile_posn.x >= posn.x
        })
      let last_tile_x =
        tiles_to_move
        |> dict.keys()
        |> list.map(fn(p) { p.x })
        |> list.max(int.compare)
      case last_tile_x == Ok(max_x) {
        True -> hand
        False -> {
          let moved_tiles =
            tiles_to_move
            |> dict.fold(dict.new(), fn(acc, key, value) {
              dict.insert(acc, vec2.Vec2(key.x + 1, key.y), value)
            })
          let new_grid =
            grid
            |> dict.drop(tiles_to_move |> dict.keys())
            |> dict.merge(moved_tiles)
          Hand(..hand, grid: new_grid)
        }
      }
    }
    CursorLeft -> {
      let tiles_to_move =
        grid
        |> dict.filter(fn(tile_posn, _tile) {
          tile_posn.y == posn.y && tile_posn.x <= posn.x
        })
      let last_tile_x =
        tiles_to_move
        |> dict.keys()
        |> list.map(fn(p) { p.x })
        |> list.max(order.reverse(int.compare))
      case last_tile_x == Ok(0) {
        True -> hand
        False -> {
          let moved_tiles =
            tiles_to_move
            |> dict.fold(dict.new(), fn(acc, key, value) {
              dict.insert(acc, vec2.Vec2(key.x - 1, key.y), value)
            })
          let new_grid =
            grid
            |> dict.drop(tiles_to_move |> dict.keys())
            |> dict.merge(moved_tiles)
          Hand(..hand, grid: new_grid)
        }
      }
    }
  }
}
