import gleam/dict
import gleam/int
import gleam/list
import gleam/option
import gleam/pair
import gleam/set
import gleam/string
import prng/random
import vec/vec2

pub opaque type Tile {
  Tile(id: Int, letter: String)
}

pub fn tile_to_id(tile: Tile) {
  string.concat(["tile-", tile.letter, "-", int.to_string(tile.id)])
}

pub fn tile_to_letter(tile: Tile) {
  tile.letter
}

// The tiles in the middle of the table.
// new -> starts a new game
// split -> deal a Hand to each player
// dump -> exchange one tile for 3 new ones
// peel -> add a new tile to each Hand
pub opaque type Bunch {
  Bunch(tiles: set.Set(Tile))
}

// The tiles in a players hand.
// Within a hand, tiles can be placed in the grid or returned to the pile
pub type Hand {
  Hand(pile: set.Set(Tile), grid: dict.Dict(vec2.Vec2(Int), Tile))
}

pub fn new() -> Bunch {
  let all_tiles =
    tiles_for_letter("A", 13)
    |> set.union(tiles_for_letter("B", 3))
    |> set.union(tiles_for_letter("C", 3))
    |> set.union(tiles_for_letter("D", 6))
    |> set.union(tiles_for_letter("E", 18))
    |> set.union(tiles_for_letter("F", 3))
    |> set.union(tiles_for_letter("G", 4))
    |> set.union(tiles_for_letter("H", 3))
    |> set.union(tiles_for_letter("I", 12))
    |> set.union(tiles_for_letter("J", 2))
    |> set.union(tiles_for_letter("K", 2))
    |> set.union(tiles_for_letter("L", 5))
    |> set.union(tiles_for_letter("M", 3))
    |> set.union(tiles_for_letter("N", 8))
    |> set.union(tiles_for_letter("O", 11))
    |> set.union(tiles_for_letter("P", 3))
    |> set.union(tiles_for_letter("Q", 2))
    |> set.union(tiles_for_letter("R", 9))
    |> set.union(tiles_for_letter("S", 6))
    |> set.union(tiles_for_letter("T", 9))
    |> set.union(tiles_for_letter("U", 6))
    |> set.union(tiles_for_letter("V", 3))
    |> set.union(tiles_for_letter("W", 3))
    |> set.union(tiles_for_letter("X", 2))
    |> set.union(tiles_for_letter("Y", 3))
    |> set.union(tiles_for_letter("Z", 2))

  Bunch(tiles: all_tiles)
}

pub fn size(bunch: Bunch) -> Int {
  set.size(bunch.tiles)
}

pub fn split(bunch: Bunch, player_count: Int, seed seed: Int) -> #(Bunch, List(Hand)) {
  let initial_pile_size = case player_count {
    1 | 2 | 3 | 4 -> 21
    5 | 6 -> 15
    _ -> 11
    // TODO: limit to 8 players
  }
  list.repeat(0, times: player_count)
  |> list.map_fold(bunch, fn(bunch_, _) {
    let #(tiles, new_bunch) = draw(bunch_, initial_pile_size, seed)
    #(new_bunch, Hand(pile: tiles, grid: dict.new()))
  })
}

pub fn dump(bunch: Bunch, hand: Hand, tile: Tile) -> #(Bunch, Hand) {
  // TODO: assert that the tile is in the hand
  let #(new_tiles, new_bunch) = draw(bunch, 3, 23)
  let new_hand =
    Hand(
      pile: set.union(set.delete(hand.pile, tile), new_tiles),
      grid: hand.grid,
    )
  let final_bunch = Bunch(tiles: set.insert(new_bunch.tiles, tile))
  #(final_bunch, new_hand)
}

pub fn peel(bunch: Bunch, hands: List(Hand), seed seed: Int) -> #(Bunch, List(Hand)) {
  hands
  |> list.map_fold(bunch, fn(bunch, hand) {
    let #(new_tiles, new_bunch) = draw(bunch, 1, seed)
    let new_hand = Hand(pile: set.union(hand.pile, new_tiles), grid: hand.grid)
    #(new_bunch, new_hand)
  })
}

pub type WordDirection {
  Right
  Down
}

pub fn place_word(
  hand: Hand,
  word: String,
  start: vec2.Vec2(Int),
  direction: WordDirection,
) -> Hand {
  string.to_graphemes(word)
  |> list.fold(#(hand, start), fn(acc, letter) {
    let #(hand_acc, cursor) = acc
    let next_hand = place_letter(hand_acc, letter, cursor)
    let next_cursor = case direction {
      Right -> vec2.Vec2(x: cursor.x + 1, y: cursor.y)
      Down -> vec2.Vec2(x: cursor.x, y: cursor.y + 1)
    }
    #(next_hand, next_cursor)
  })
  |> pair.first
}

pub fn place_letter(hand: Hand, letter: String, posn: vec2.Vec2(Int)) -> Hand {
  let matching_tile =
    set.filter(hand.pile, fn(tile) { tile.letter == letter })
    |> set.to_list
    |> list.first
  let existing_tile = hand.grid |> dict.get(posn)
  case matching_tile, existing_tile {
    Ok(tile), Ok(tile_to_remove) ->
      Hand(
        hand.pile |> set.delete(tile) |> set.insert(tile_to_remove),
        dict.insert(hand.grid, posn, tile),
      )
    Ok(tile), Error(_) ->
      Hand(hand.pile |> set.delete(tile), dict.insert(hand.grid, posn, tile))
    Error(_), _ -> hand
  }
}

pub fn remove_letter(from hand: Hand, at posn: vec2.Vec2(Int)) -> Hand {
  let existing_tile = hand.grid |> dict.get(posn)
  case existing_tile {
    Ok(tile) -> {
      Hand(
        hand.pile |> set.insert(tile),
        hand.grid |> dict.delete(posn)
      )
    }
    Error(_) -> {
      hand
    }
  }
}

fn tiles_for_letter(letter: String, count: Int) -> set.Set(Tile) {
  list.repeat(letter, times: count)
  |> list.index_map(fn(l, i) { Tile(id: i, letter: l) })
  |> set.from_list
}

// TODO: if the bunch is running low, the result might have fewer than n tiles
fn draw(bunch: Bunch, n: Int, seed seed: Int) -> #(set.Set(Tile), Bunch) {
  let gen = random.sample(set.to_list(bunch.tiles), n)
  let #(tile_list, _) = random.step(gen, random.new_seed(seed))
  let tiles = tile_list |> set.from_list
  let new_bunch = Bunch(tiles: set.difference(bunch.tiles, tiles))
  #(tiles, new_bunch)
}

// DEBUGGING

pub fn hand_to_string(maybe_hand: option.Option(Hand)) -> String {
  case maybe_hand {
    option.None -> "no hand"
    option.Some(hand) -> {
      let pile_tiles =
        hand.pile
        |> set.to_list
        |> list.map(fn(tile) { tile.letter })
        |> string.join("-")
      let grid_tiles =
        hand.grid
        |> dict.fold([], fn(acc, pos, tile) { [tile.letter, ..acc] })
        |> string.join(" & ")
      string.concat(["pile: ", pile_tiles, ", ", "grid: ", grid_tiles])
    }
  }
}
