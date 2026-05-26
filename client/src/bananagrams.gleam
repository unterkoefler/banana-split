import gleam/dict
import gleam/list
import gleam/set
import shared.{type Tile}
import vec/vec2

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
  let new_pile = hand.pile |> set.union(new_tiles |> set.from_list())
  Hand(
    pile: new_pile,
    ordered_pile: hand.ordered_pile |> list.append(new_tiles),
    grid: hand.grid,
  )
}

pub fn dump(hand: Hand, new_tiles: List(Tile), lost_tile: Tile) {
  let new_pile = hand.pile |> set.delete(lost_tile)
  Hand(
    pile: new_pile,
    ordered_pile: hand.ordered_pile
      |> list.filter(fn(t) { set.contains(new_pile, t) }),
    grid: hand.grid,
  )
  |> add_tiles(new_tiles)
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
