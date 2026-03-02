import bridge_msg.{type BridgeMsg}
import gleam/io
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html.{button}
import lustre/event
import tiramisu/ui

type GameState {
  Setup
  // pre-split
  Playing
  GameOver
}

type Model {
  Model(bridge: ui.Bridge(BridgeMsg), game_state: GameState)
}

type Msg {
  FromBridge(BridgeMsg)
  SplitButtonClicked
  PeelButtonClicked
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    SplitButtonClicked -> #(
      Model(..model, game_state: Playing),
      ui.send(model.bridge, bridge_msg.Split(1)),
    )
    PeelButtonClicked -> #(model, ui.send(model.bridge, bridge_msg.Peel))

    // these are outgoing messages only
    FromBridge(bridge_msg.Split(_)) -> #(model, effect.none())
    FromBridge(bridge_msg.Peel) -> #(model, effect.none())
  }
}

fn init(bridge: ui.Bridge(BridgeMsg)) {
  #(
    Model(bridge: bridge, game_state: Setup),
    ui.register_lustre(bridge, FromBridge),
  )
}

fn view(model: Model) -> Element(Msg) {
  case model.game_state {
    Setup -> {
      html.button(
        [
          event.on_click(SplitButtonClicked),
        ],
        [element.text("SPLIT!")],
      )
    }
    Playing -> {
      html.button(
        [
          event.on_click(PeelButtonClicked),
          attribute.tabindex(-1),
        ],
        [element.text("PEEL!")],
      )
    }
    GameOver -> {
      element.text("Game Over!")
    }
  }
}

pub fn start(bridge: ui.Bridge(BridgeMsg)) {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#ui", bridge)

  Nil
}
