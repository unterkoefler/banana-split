import gleam/dynamic/decode
import gleam/http.{Get, Post}
import gleam/json
import gluid
import gleam/result
import wisp.{type Request, type Response}
import web
import passphrase

pub type CreateRoomInput {
  CreateRoomInput(
    host_nickname: String,
  )
}

pub type Player {
  Player(id: String, nickname: String)
}

pub type Room {
  Room(
    room_code: String,
    host: Player,
    other_players: List(Player),
  )
}
    
pub type Person {
  Person(name: String, is_cool: Bool)
}

fn create_room_input_decoder() -> decode.Decoder(CreateRoomInput) {
  use host_nickname <- decode.field("host-nickname", decode.string)
  decode.success(CreateRoomInput(host_nickname:))
}

fn person_decoder() -> decode.Decoder(Person) {
  use name <- decode.field("name", decode.string)
  use is_cool <- decode.field("is-cool", decode.bool)
  decode.success(Person(name:, is_cool:))
}

pub fn handle_request(req: Request) -> Response {
  use req <- web.middleware(req)

  case req.method, wisp.path_segments(req) {
    Post, ["rooms"] -> handle_create_room(req)
    Post, ["rooms", id, "players"] -> handle_add_player(req, id)
    // TODO: handle re-joining after disconnect
    _, _ -> wisp.not_found()
  }
}

fn handle_create_room(req: Request) -> Response {
  use json <- wisp.require_json(req)

  let result = {
    use input <- result.try(decode.run(json, create_room_input_decoder()))

    let player = Player(id: gluid.guidv4(), nickname: input.host_nickname)
    let new_room = 
      Room(
        room_code: passphrase.new(3),
        host: player,
        other_players: [],
      )
    let object =
        json.object([
            #("room-code", json.string(new_room.room_code)),
            #("host", json.object([#("id", json.string(player.id)), #("nickname", json.string(player.nickname))])),
            #("other_players", json.array([], json.object))
        ])
    Ok(json.to_string(object))
  }

  case result {
    Ok(json) -> wisp.json_response(json, 201)

    Error(_) -> wisp.unprocessable_content()
  }
}

fn handle_add_player(req: Request, room_id: String) -> Response {
  // TODO
  wisp.json_response("TODO", 201)
}

fn handle_save_person_example(req) {
  use json <- wisp.require_json(req)

  let result = {
    use person <- result.try(decode.run(json, person_decoder()))

    let object =
      json.object([
        #("name", json.string(person.name)),
        #("is-cool", json.bool(person.is_cool)),
        #("saved", json.bool(True)),
      ])
    Ok(json.to_string(object))
  }

  case result {
    Ok(json) -> wisp.json_response(json, 201)

    Error(_) -> wisp.unprocessable_content()
  }
}
