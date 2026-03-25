# nix/oci/default.nix
#
# Multi-architecture OCI container images for Metabase.
#
# Generates per-arch streamable layered images:
#   oci-x86_64  — AMD64 (most common)
#   oci-aarch64 — ARM64 (Graviton, M-series Macs)
#   oci-riscv64 — RISC-V 64-bit (emerging)
#
{
  pkgs,
  lib,
  metabase,
  version ? "0.0.0-nix",
  jre ? pkgs.temurin-jre-bin-21,
}:

let
  supportedArchs = [
    "x86_64"
    "aarch64"
    "riscv64"
  ];

  archMap = {
    x86_64 = "amd64";
    aarch64 = "arm64";
    riscv64 = "riscv64";
  };

  layers = import ./layers.nix { inherit pkgs metabase jre; };

  mkImage =
    arch:
    pkgs.dockerTools.streamLayeredImage {
      name = "metabase";
      tag = "${version}-${arch}";
      architecture = archMap.${arch};
      contents = layers.contents;

      config = {
        Cmd = [ "${metabase}/bin/metabase" ];
        ExposedPorts = {
          "3000/tcp" = { };
        };
        Env = [
          "JAVA_OPTS=-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"
          "MB_JETTY_HOST=0.0.0.0"
          "MB_DB_TYPE=h2"
        ];
        Volumes = {
          "/plugins" = { };
        };
        WorkingDir = "/app";
      };
    };

  images = lib.genAttrs supportedArchs mkImage;
in
# Flat exports: oci-x86_64, oci-aarch64, oci-riscv64
lib.mapAttrs' (arch: img: lib.nameValuePair "oci-${arch}" img) images
