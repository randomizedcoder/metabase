{
  description = "Metabase dashboard export tool";

  inputs = {
    nixpkgs.url = "path:/home/das/Downloads/n/nixpkgs";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      devShells.${system}.default = import ./nix/devshell.nix { inherit pkgs; };
    };
}
