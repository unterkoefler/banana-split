import sqlight
import gleam/io

pub fn main() {
  io.println("Creating database...")

  use conn <- sqlight.with_connection("database.db")

  let sql = "
  pragma foreign_keys = on;

  create table rooms (
    room_code text primary key,
    state text not null,
    host_id text 
  );

  create table players (
    id text primary key,
    nickname text not null,
    room_code text not null,

    foreign key (room_code) references rooms(room_code) on delete cascade
  );

  create table games (
    id integer primary key autoincrement,
    bunch text not null,
    room_code text not null,
  
    foreign key (room_code) references rooms(room_code) on delete cascade
  );
  "

  let assert Ok(Nil) = sqlight.exec(sql, conn)

  Nil
}
