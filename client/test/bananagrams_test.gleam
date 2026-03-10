import bananagrams as bg
import gleam/list
import gleam/set

pub fn new_bunch_test() {
  assert bg.size(bg.new()) == 144
}

pub fn split_1_player_test() {
  let #(bunch, hands) = bg.split(bg.new(), 1, seed: 11)
  assert bg.size(bunch) == 123
  assert list.length(hands) == 1
  list.each(hands, fn(hand) {
    assert set.size(hand.pile) == 21
  })
}

pub fn split_2_player_test() {
  let #(bunch, hands) = bg.split(bg.new(), 2, seed: 11)
  assert bg.size(bunch) == 102
  assert list.length(hands) == 2
  list.each(hands, fn(hand) {
    assert set.size(hand.pile) == 21
  })
}

pub fn split_5_player_test() {
  let #(bunch, hands) = bg.split(bg.new(), 5, seed: 11)
  assert bg.size(bunch) == 144 - 5 * 15
  assert list.length(hands) == 5
  list.each(hands, fn(hand) {
    assert set.size(hand.pile) == 15
  })
}

pub fn split_8_player_test() {
  let #(bunch, hands) = bg.split(bg.new(), 8, seed: 11)
  assert bg.size(bunch) == 144 - 8 * 11
  assert list.length(hands) == 8
  list.each(hands, fn(hand) {
    assert set.size(hand.pile) == 11
  })
}

pub fn dump_test() {
  let assert #(bunch, [hand]) = bg.split(bg.new(), 1, seed: 11)
  assert bg.size(bunch) == 123
  assert set.size(hand.pile) == 21
  let assert Ok(tile) = set.to_list(hand.pile) |> list.first
  assert set.contains(hand.pile, tile)
  let #(new_bunch, new_hand) = bg.dump(bunch, hand, tile)
  assert bg.size(new_bunch) == 121
  assert set.size(new_hand.pile) == 23
  assert !set.contains(new_hand.pile, tile)
}

pub fn peel_test() {
  let #(bunch, hands) = bg.split(bg.new(), 2, seed: 11)
  assert bg.size(bunch) == 102
  let #(new_bunch, new_hands) = bg.peel(bunch, hands, seed: 13)
  assert bg.size(new_bunch) == 100
  new_hands
  |> list.each(fn(hand) {
    assert set.size(hand.pile) == 22
  })
}
