{
  description = "Metabase dashboard export tool";

  inputs = {
    nixpkgs.url = "path:/home/das/Downloads/n/nixpkgs";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      python = pkgs.python314;
      pythonWithPackages = python.withPackages (ps: [
        ps.psycopg2
      ]);
    in {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          pythonWithPackages
        ];

        shellHook = ''
          echo "Metabase Dashboard Export Tool"
          echo "Python: $(python3 --version)"
          echo ""
          echo "Usage:"
          echo "  ./bin/export-dashboards.py --list"
          echo "  ./bin/export-dashboards.py --export-all"
          echo "  ./bin/export-dashboards.py --export 'Dashboard Name'"
        '';
      };
    };
}
