default:
  @just --list

alias b := build
[working-directory: 'client']
build:
    gleam run -m lustre/dev build banana_split_client_prod --outdir=../server/priv/static


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
