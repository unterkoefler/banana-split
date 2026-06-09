import gleam/int
import gleam/list
import gleam/set
import gleam/string
import prng/random
import shared.{type Tile, Tile}

pub fn bunch_size(bunch: Bunch) {
  set.size(bunch.tiles)
}

// The tiles in the middle of the table.
// new -> starts a new game
// split -> deal tiles to each player
// dump -> exchange one tile for 3 new ones
// peel -> add a new tile to each Hand
pub opaque type Bunch {
  Bunch(tiles: set.Set(Tile))
}

pub fn new() -> Bunch {
  //Bunch(tiles_for_letter("Q", 70))
  //}

  //fn new_v1() -> Bunch {
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

pub fn serialize_bunch(bunch: Bunch) -> String {
  bunch.tiles
  |> set.to_list
  |> list.map(fn(tile) { tile.letter <> int.to_string(tile.id) })
  |> string.join(",")
}

pub fn deserialize_bunch(str: String) -> Result(Bunch, Nil) {
  let tiles =
    str
    |> string.split(on: ",")
    |> list.map(fn(tile) {
      // TODO: remove asserts and return errors
      let assert Ok(#(letter, id_str)) = string.pop_grapheme(tile)
      let assert Ok(id) = int.parse(id_str)
      Tile(letter:, id:)
    })
  Ok(Bunch(tiles: tiles |> set.from_list))
}

pub fn split(
  bunch: Bunch,
  player_count: Int,
  seed seed: Int,
) -> #(Bunch, List(set.Set(Tile))) {
  let initial_pile_size = case player_count {
    1 | 2 | 3 | 4 -> 21
    5 | 6 -> 15
    _ -> 11
    // TODO: limit to 8 players
  }
  list.repeat(0, times: player_count)
  |> list.map_fold(bunch, fn(bunch_, _) {
    let #(tiles, new_bunch) = draw(bunch_, initial_pile_size, seed)
    #(new_bunch, tiles)
  })
}

pub fn dump(bunch: Bunch, tile: Tile) -> #(List(Tile), Bunch) {
  case set.contains(bunch.tiles, tile) {
    True -> #([], bunch)
    False -> {
      // TODO: use a random seed
      let seed = 23
      let #(new_tiles, new_bunch) = draw(bunch, 3, seed)
      let final_bunch = Bunch(tiles: set.insert(new_bunch.tiles, tile))
      #(new_tiles |> set.to_list, final_bunch)
    }
  }
}

fn tiles_for_letter(letter: String, count: Int) -> set.Set(Tile) {
  list.repeat(letter, times: count)
  |> list.index_map(fn(l, i) { Tile(id: i, letter: l) })
  |> set.from_list
}

// TODO: if the bunch is running low, the result might have fewer than n tiles
pub fn draw(bunch: Bunch, n: Int, seed seed: Int) -> #(set.Set(Tile), Bunch) {
  let gen = random.sample(set.to_list(bunch.tiles), n)
  let #(tile_list, _) = random.step(gen, random.new_seed(seed))
  let tiles = tile_list |> set.from_list
  let new_bunch = Bunch(tiles: set.difference(bunch.tiles, tiles))
  #(tiles, new_bunch)
}
