import bridge_msg.{type BridgeMsg}
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html.{button}
import lustre/event
import tiramisu/ui

type Model {
  Model(bridge: ui.Bridge(BridgeMsg), word: String)
}

type Msg {
  FromBridge(BridgeMsg)
  WordTyped(word: String)
  FormSubmitted
  SplitButtonClicked
  PeelButtonClicked
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    WordTyped(new_word) -> #(
      Model(bridge: model.bridge, word: new_word |> string.trim),
      effect.none(),
    )
    FormSubmitted -> #(
      Model(bridge: model.bridge, word: ""),
      ui.send(
        model.bridge,
        bridge_msg.WordSubmitted(string.uppercase(model.word)),
      ),
    )
    SplitButtonClicked -> #(
      model,
      ui.send(model.bridge, bridge_msg.Split(1))
    )
    PeelButtonClicked -> #(
      model,
      ui.send(model.bridge, bridge_msg.Peel)
    )

    // these are outgoing messages only
    FromBridge(bridge_msg.WordSubmitted(_)) -> #(model, effect.none())
    FromBridge(bridge_msg.Split(_)) -> #(model, effect.none())
    FromBridge(bridge_msg.Peel) -> #(model, effect.none())
  }
}

fn init(bridge: ui.Bridge(BridgeMsg)) {
  #(Model(bridge: bridge, word: ""), ui.register_lustre(bridge, FromBridge))
}

fn view(model: Model) -> Element(Msg) {
  html.div([], [
    html.form([event.on_submit(fn(_) { FormSubmitted })], [word_input(model)]),
    html.button(
      [
        event.on_click(SplitButtonClicked),
      ], [
        element.text("SPLIT!")
      ]
    ),
    html.button(
      [
        event.on_click(PeelButtonClicked),
      ], [
        element.text("PEEL!")
      ]
    ),
  ])

}

fn word_input(model: Model) -> Element(Msg) {
  html.label([], [
    element.text("Type a word to place tiles"),
    html.input([
      attribute.autocomplete("off"),
      attribute.autofocus(True),
      attribute.type_("text"),
      attribute.name("word"),
      attribute.value(model.word),
      event.on_input(fn(word) { WordTyped(word) }),
    ]),
  ])
}

pub fn start(bridge: ui.Bridge(BridgeMsg)) {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#ui", bridge)

  Nil
}
