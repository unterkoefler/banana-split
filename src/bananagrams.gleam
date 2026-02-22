import gleam/set
import gleam/list
import gleam/dict
import prng/random

pub opaque type Tile {
  Tile(id: Int, letter: String)
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
  Hand(pile: set.Set(Tile), grid: dict.Dict(Tile, Posn))
}

pub type Posn {
  Posn(x: Int, y: Int)
}

pub fn new() -> Bunch {
  let all_tiles = tiles_for_letter("a", 13)
  |> set.union(tiles_for_letter("b", 3))
  |> set.union(tiles_for_letter("c", 3))
  |> set.union(tiles_for_letter("d", 6))
  |> set.union(tiles_for_letter("e", 18))
  |> set.union(tiles_for_letter("f", 3))
  |> set.union(tiles_for_letter("g", 4))
  |> set.union(tiles_for_letter("h", 3))
  |> set.union(tiles_for_letter("i", 12))
  |> set.union(tiles_for_letter("j", 2))
  |> set.union(tiles_for_letter("k", 2))
  |> set.union(tiles_for_letter("l", 5))
  |> set.union(tiles_for_letter("m", 3))
  |> set.union(tiles_for_letter("n", 8))
  |> set.union(tiles_for_letter("o", 11))
  |> set.union(tiles_for_letter("p", 3))
  |> set.union(tiles_for_letter("q", 2))
  |> set.union(tiles_for_letter("r", 9))
  |> set.union(tiles_for_letter("s", 6))
  |> set.union(tiles_for_letter("t", 9))
  |> set.union(tiles_for_letter("u", 6))
  |> set.union(tiles_for_letter("v", 3))
  |> set.union(tiles_for_letter("w", 3))
  |> set.union(tiles_for_letter("x", 2))
  |> set.union(tiles_for_letter("y", 3))
  |> set.union(tiles_for_letter("z", 2))

  Bunch(tiles: all_tiles)
}

pub fn size(bunch: Bunch) -> Int {
  set.size(bunch.tiles)
}

pub fn split(bunch: Bunch, player_count: Int) -> #(Bunch, List(Hand)) {
  let initial_pile_size = case player_count {
    1 | 2 | 3 | 4 -> 21
    5 | 6 -> 15
    _ -> 11 // TODO: limit to 8 players
  }
  list.repeat(0, times: player_count) |> list.map_fold(
    bunch,
    fn (bunch, _) {
      let #(tiles, new_bunch) = draw(bunch, initial_pile_size)
      #(new_bunch, Hand(pile: tiles, grid: dict.new()))
    }
  )
}

pub fn dump(bunch: Bunch, hand: Hand, tile: Tile) -> #(Bunch, Hand) {
  // TODO: assert that the tile is in the hand
  let #(new_tiles, new_bunch) = draw(bunch, 3)
  let new_hand = Hand(pile: set.union(set.delete(hand.pile, tile), new_tiles), grid: hand.grid)
  let final_bunch = Bunch(
    tiles: set.insert(new_bunch.tiles, tile)
  )
  #(final_bunch, new_hand)
}


pub fn peel(bunch: Bunch, hands: List(Hand)) -> #(Bunch, List(Hand)) {
  hands |> list.map_fold(
    bunch,
    fn (bunch, hand) {
      let #(new_tiles, new_bunch) = draw(bunch, 1)
      let new_hand = Hand(pile: set.union(hand.pile, new_tiles), grid: hand.grid)
      #(new_bunch, new_hand)
    }
  )
}

fn tiles_for_letter(letter: String, count: Int) -> set.Set(Tile) {
  list.repeat(letter, times: count) 
  |> list.index_map(fn(l, i) { Tile(id: i, letter: l) })
  |> set.from_list
}

// TODO: if the bunch is running low, the result might have fewer than n tiles
fn draw(bunch: Bunch, n: Int) -> #(set.Set(Tile), Bunch) {
  let gen = random.sample(set.to_list(bunch.tiles), n)
  let #(tile_list, _) = random.step(gen, random.new_seed(11))
  let tiles = tile_list |> set.from_list
  let new_bunch = Bunch(tiles: set.difference(bunch.tiles, tiles))
  #(tiles, new_bunch)
}
