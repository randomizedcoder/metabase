# nix/derivation/deps-clojure.nix
#
# Fixed-output derivation (FOD) for Clojure/Maven dependencies.
# Downloads the entire .m2/repository needed for building Metabase.
#
# Cache trigger: Only rebuilds when deps.edn changes.
#
# To update the hash after deps.edn changes:
#   1. Set hash to lib.fakeHash
#   2. Run: nix build .#deps-clojure
#   3. Copy the expected hash from the error message
#   4. Replace lib.fakeHash with the real hash
#
{
  pkgs,
  lib,
  src,
}:

pkgs.stdenv.mkDerivation {
  pname = "metabase-deps-clojure";
  version = "0.1.0";

  inherit src;

  nativeBuildInputs = [
    pkgs.temurin-bin-21
    pkgs.clojure
    pkgs.git
    pkgs.cacert
  ];

  buildPhase = ''
        export HOME=$TMPDIR
        export JAVA_HOME="${pkgs.temurin-bin-21}"
        export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        export GIT_SSL_CAINFO="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"

        # Download all dependencies for main + build + drivers + cljs aliases
        clojure -P
        clojure -P -A:build
        clojure -P -A:drivers
        clojure -P -A:dev
        clojure -P -A:cljs
        clojure -P -A:drivers:build

        # Resolve deps for each individual driver module (they have custom Maven repos)
        # Use -Spath to force full dependency tree resolution including POMs
        for driver_dir in modules/drivers/*/; do
          if [ -f "$driver_dir/deps.edn" ]; then
            echo "Resolving deps for driver: $(basename $driver_dir)"
            (cd "$driver_dir" && clojure -Spath > /dev/null) || true
          fi
        done

        # Simulate the driver build's calc-basis calls to capture ALL transitive deps
        # The build system uses deps/find-edn-maps which resolves from the Clojure
        # install root + each driver's deps.edn, pulling in different transitive deps
        # than plain 'clojure -Spath' does
        clojure -M:build -e '
          (require (quote [clojure.tools.deps.alpha :as deps])
                   (quote [clojure.tools.deps.alpha.util.dir :as deps.dir])
                   (quote [clojure.java.io :as io]))
          (let [root (System/getProperty "user.dir")]
            ;; Resolve core metabase deps the same way build_drivers does
            (println "Resolving metabase-core deps via calc-basis...")
            (let [core-edn (deps/merge-edns ((juxt :root-edn :project-edn)
                                              (deps/find-edn-maps (str root "/deps.edn"))))]
              (binding [deps.dir/*the-dir* (io/file root)]
                (deps/calc-basis core-edn)))
            ;; Resolve each driver deps the same way
            (doseq [d (.listFiles (io/file root "modules/drivers"))
                    :when (.isDirectory d)
                    :let [edn-file (io/file d "deps.edn")]
                    :when (.exists edn-file)]
              (println "Resolving driver via calc-basis:" (.getName d))
              (try
                (let [edn (deps/merge-edns ((juxt :root-edn :project-edn)
                                             (deps/find-edn-maps (str edn-file))))
                      combined (deps/combine-aliases edn #{:oss})]
                  (binding [deps.dir/*the-dir* d]
                    (deps/calc-basis (deps/tool edn combined))))
                (catch Exception e
                  (println "  Warning:" (.getMessage e))))))
          (println "calc-basis resolution complete")
        '

        # Generate missing POM files for artifacts from custom repos (e.g. athena-jdbc from S3)
        # Maven/tools.deps needs POMs even for standalone JARs
        find $HOME/.m2/repository -name "*.jar" | while read jar; do
          dir=$(dirname "$jar")
          base=$(basename "$jar" .jar)
          pom="$dir/$base.pom"
          if [ ! -f "$pom" ]; then
            # Extract groupId/artifactId/version from path
            relpath=$(realpath --relative-to="$HOME/.m2/repository" "$dir")
            version=$(basename "$dir")
            artifact_dir=$(dirname "$relpath")
            artifactId=$(basename "$artifact_dir")
            groupId=$(dirname "$artifact_dir" | tr '/' '.')
            echo "Generating missing POM: $groupId:$artifactId:$version"
            cat > "$pom" <<POMEOF
    <?xml version="1.0" encoding="UTF-8"?>
    <project xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd"
      xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <modelVersion>4.0.0</modelVersion>
      <groupId>$groupId</groupId>
      <artifactId>$artifactId</artifactId>
      <version>$version</version>
    </project>
    POMEOF
          fi
        done
  '';

  installPhase = ''
    # Remove non-deterministic timestamp files
    # Note: resolver-status.properties and maven-metadata-*.xml are kept —
    # tools.deps needs them for offline version range resolution (e.g. [1.2.1],[1.3.0])
    # _remote.repositories is kept here but deleted later in setupClojureDeps
    find $HOME/.m2/repository -type f -name \*.lastUpdated -delete

    mkdir -p $out
    cp -r $HOME/.m2/repository $out/repository
    # Capture git-lib checked-out sources (e.g. build-uber-log4j2-handler, malli)
    # Only copy libs/ (checked-out source at specific SHAs), not _repos/ (bare git
    # repos which contain store path references in pack files/config)
    if [ -d "$HOME/.gitlibs/libs" ]; then
      mkdir -p $out/gitlibs
      cp -r $HOME/.gitlibs/libs $out/gitlibs/libs
    fi
  '';

  # Disable fixup — FODs must not reference store paths (patchShebangs would add them)
  dontFixup = true;

  # Fixed-output derivation settings
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  outputHash = "sha256-cH0XsiSngF+gnEI3oS+H0rHIk06UgAumI+fiuR0uqYs=";

  # Allow proxy env vars through for network access
  impureEnvVars = lib.fetchers.proxyImpureEnvVars;
}
