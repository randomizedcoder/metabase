{ pkgs }:
let
  python = pkgs.python314;
in
python.withPackages (ps: [
  ps.psycopg2
])
