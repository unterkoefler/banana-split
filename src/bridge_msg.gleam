pub type BridgeMsg {
  // UI -> Game
  WordSubmitted(word: String)
  Split(player_count: Int)
  Peel
}
