default:
  @just --list

alias r := run
run:
  gleam run -m lustre/dev start

test:
  gleam test
