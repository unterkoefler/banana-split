import tiramisu/ui
import bridge_msg.{type BridgeMsg}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{text, type Element}
import lustre/element/html.{div, button, p}
import lustre/event

type Model {
  Model(bridge: ui.Bridge(BridgeMsg), word: String)
}

type Msg {
  FromBridge(BridgeMsg)
  WordTyped(word: String)
  FormSubmitted
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    WordTyped(new_word) ->
      #(Model(bridge: model.bridge, word: new_word), effect.none())
    FormSubmitted ->
      #(Model(bridge: model.bridge, word: ""), ui.send(model.bridge, bridge_msg.WordSubmitted(model.word)))

    // this is an outgoing message only
    FromBridge(bridge_msg.WordSubmitted(_)) -> 
      #(model, effect.none())
  }
}

fn init(bridge: ui.Bridge(BridgeMsg)) {
  #(Model(bridge: bridge, word: ""), ui.register_lustre(bridge, FromBridge))
}

fn view(model: Model) -> Element(Msg) {
  html.form([event.on_submit(fn(_) { FormSubmitted })], [
    word_input(model)
  ])
}

fn word_input(model: Model) -> Element(Msg) {
  html.label([], [
    element.text("Type a word to place tiles"),
    html.input([
      attribute.autofocus(True),
      attribute.type_("text"),
      attribute.name("word"),
      attribute.value(model.word),
      event.on_input(fn(word) { WordTyped(word) })
    ]),
  ])
}

pub fn start(bridge: ui.Bridge(BridgeMsg)) {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#ui", bridge)

  Nil
}
