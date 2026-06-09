import app.{AppConfig, KeyPressed, init, update, view}
import gleam/option
import lustre
import plinth/browser/document
import plinth/browser/event as plinth_event

pub fn main() -> Nil {
  let config = AppConfig(api_host: option.Some("http://localhost:8000/"))
  let app =
    lustre.application(
      fn(flags) { init(config, flags) },
      fn(model, msg) { update(config, model, msg) },
      view,
    )
  let assert Ok(runtime) = lustre.start(app, "#ui", Nil)

  // TODO: better handle shift + meta keys
  document.add_event_listener("keyup", fn(event) {
    let key = plinth_event.key(event)
    let msg = lustre.dispatch(KeyPressed(key))
    lustre.send(to: runtime, message: msg)
  })

  Nil
}
