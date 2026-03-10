default:
  @just --list


alias r := run-client
[working-directory: 'client']
run-client:
  gleam run -m lustre/dev start

[working-directory: 'client']
test:
  gleam test
