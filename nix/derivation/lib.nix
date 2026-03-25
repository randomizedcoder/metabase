# nix/derivation/lib.nix
#
# Shared helpers for Metabase sub-derivations.
#
{
  pkgs,
  jdk ? pkgs.temurin-bin-21,
}:

let
  clojureBuildInputs = [
    jdk
    pkgs.clojure
    pkgs.git
    pkgs.python3
  ];
in
{
  # Common nativeBuildInputs for Clojure-based derivations
  inherit clojureBuildInputs;

  # Clojure + frontend tooling (used by frontend.nix, static-viz.nix)
  frontendBuildInputs = clojureBuildInputs ++ [
    pkgs.bun
    pkgs.nodejs_22
  ];

  # Shell fragment: install node_modules from pre-fetched FOD
  setupNodeModules =
    { frontendDeps }:
    ''
      export NODE_OPTIONS="--max-old-space-size=4096"
      cp -r ${frontendDeps} node_modules
      chmod -R u+w node_modules
      patchShebangs node_modules
      bun run patch-package
    '';

  # Shell fragment: override Maven repos for shadow-cljs offline builds
  setupMavenRepoOverride = ''
    LOCAL_REPO="file://$HOME/.m2/repository"
    mkdir -p $HOME/.clojure
    echo '{:mvn/repos {"central" {:url "'"$LOCAL_REPO"'"} "clojars" {:url "'"$LOCAL_REPO"'"}}}' > $HOME/.clojure/deps.edn
  '';

  # Shell fragment: set up offline .m2 repo from pre-fetched clojureDeps FOD.
  # Copies the repo, makes it writable, strips remote markers, patches deps.edn
  # files for git deps and Maven repo URLs.
  #
  # Usage in buildPhase:
  #   ${lib.setupClojureDeps { inherit clojureDeps; }}
  setupClojureDeps =
    { clojureDeps }:
    ''
      export HOME=$TMPDIR
      export JAVA_HOME="${jdk}"

      # Copy pre-fetched Maven repository (writable — Clojure tooling writes cache/lock files)
      mkdir -p $HOME/.m2
      cp -r ${clojureDeps}/repository $HOME/.m2/repository
      chmod -R u+w $HOME/.m2/repository
      find $HOME/.m2/repository -name "_remote.repositories" -delete

      # Patch deps.edn: replace git deps with local paths, redirect Maven repos to file://
      bash ${./patch-git-deps.sh} deps.edn ${clojureDeps}/gitlibs
      bash ${./patch-mvn-repos.sh} "file://$HOME/.m2/repository"
    '';

  # Shell fragment: common setup for frontend-based builds (frontend.nix, static-viz.nix).
  # Sets up node_modules, Clojure deps, Maven repo override, and build environment.
  setupFrontendBuild =
    {
      frontendDeps,
      clojureDeps,
      edition ? "oss",
    }:
    ''
      export NODE_OPTIONS="--max-old-space-size=4096"
      cp -r ${frontendDeps} node_modules
      chmod -R u+w node_modules
      patchShebangs node_modules
      bun run patch-package

      export HOME=$TMPDIR
      export JAVA_HOME="${jdk}"

      mkdir -p $HOME/.m2
      cp -r ${clojureDeps}/repository $HOME/.m2/repository
      chmod -R u+w $HOME/.m2/repository
      find $HOME/.m2/repository -name "_remote.repositories" -delete

      bash ${./patch-git-deps.sh} deps.edn ${clojureDeps}/gitlibs
      bash ${./patch-mvn-repos.sh} "file://$HOME/.m2/repository"

      LOCAL_REPO="file://$HOME/.m2/repository"
      mkdir -p $HOME/.clojure
      echo '{:mvn/repos {"central" {:url "'"$LOCAL_REPO"'"} "clojars" {:url "'"$LOCAL_REPO"'"}}}' > $HOME/.clojure/deps.edn

      export WEBPACK_BUNDLE=production
      export MB_EDITION=${edition}
    '';
}
