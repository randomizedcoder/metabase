# nix/derivation/uberjar.nix
#
# Sub-derivation: final Metabase uberjar assembly.
# Combines all sub-derivation outputs into the final JAR.
#
# Cache trigger: Rebuilds when backend source or any sub-derivation changes.
#
{
  pkgs,
  lib,
  src,
  clojureDeps,
  frontend,
  staticViz,
  translations,
  drivers,
  version ? "0.0.0-nix",
  edition ? "oss",
}:

let
  drvLib = import ./lib.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  pname = "metabase-uberjar";
  inherit version src;
  nativeBuildInputs = drvLib.clojureBuildInputs;
  buildPhase = ''
    runHook preBuild
    ${drvLib.setupClojureDeps { inherit clojureDeps; }}
    export MB_EDITION="${edition}"

    # Assemble sub-derivation outputs (chmod needed: store paths are read-only)
    mkdir -p resources/frontend_client
    cp -r ${frontend}/resources/frontend_client/* resources/frontend_client/
    chmod -R u+w resources/frontend_client/
    cp -r ${staticViz}/resources/frontend_client/* resources/frontend_client/
    cp -r ${translations}/resources/* resources/
    mkdir -p resources/modules
    cp -r ${drivers}/plugins/*.jar resources/modules/

    # Git config for version detection (best-effort — not critical for build)
    export GIT_DISCOVERY_ACROSS_FILESYSTEM=1
    git config --global --add safe.directory "$PWD" 2>/dev/null || true

    clojure -X:build:build/uberjar :edition :${edition}
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/metabase
    cp target/uberjar/metabase.jar $out/share/metabase/
    runHook postInstall
  '';
}
