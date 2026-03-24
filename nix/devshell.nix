{ pkgs }:
let
  pythonEnv = import ./python.nix { inherit pkgs; };
  postgres = import ./postgres.nix { inherit pkgs; };
in
pkgs.mkShell {
  buildInputs = [
    pythonEnv
    postgres.postgresql
  ];

  shellHook = ''
    ${postgres.shellHook}

    echo ""
    echo "Metabase Dashboard Export Tool"
    echo "Python: $(python3 --version)"
    echo "PostgreSQL: $(postgres --version)"
    echo ""
    echo "Usage:"
    echo "  ./bin/export-dashboards.py --list"
    echo "  ./bin/export-dashboards.py --export-all"
    echo "  ./bin/export-dashboards.py --export 'Dashboard Name'"
  '';
}
