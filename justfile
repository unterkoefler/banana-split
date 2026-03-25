default:
  @just --list


alias r := run-client
[working-directory: 'client']
run-client:
  gleam run -m lustre/dev start

alias rs := run-server
[working-directory: 'server']
run-server:
  gleam dev

[working-directory: 'client']
test:
  gleam test

[working-directory: 'server']
db-create:
  rm -f database.db
  gleam run -m db/create
