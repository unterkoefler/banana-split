import bananagrams as bg
import gleam/list
import gleam/set

pub fn new_bunch_test() {
  assert bg.size(bg.new()) == 144
}
