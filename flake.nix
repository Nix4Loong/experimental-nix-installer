{
  description = "Nix Installer";

  inputs = {
    nixpkgs.url = "github:loongson-community/nixpkgs/loong-master";

    crane.url = "github:ipetkov/crane";

    fenix = {
      url = "github:nix-community/fenix";
      flake = false;
    };

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      crane,
      fenix,
      treefmt-nix,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      supportedSystems = [
        "loongarch64-linux"
      ];

      # TODO: What about supporting cross? Probably best would be to just have a
      # splicing compatible scope instead.

      /**
        Memoised instances of nixpkgs with the public overlay applied.
      */
      nixpkgsFor = lib.genAttrs supportedSystems (
        system:
        import nixpkgs {
          localSystem = {
            inherit system;
          };
          # TODO: Don't use overlays for internal packaging - that's not needed.
          # Overlays is the public facing interface.
          overlays = [ self.overlays.default ];
        }
      );

      forAllSystems = lib.genAttrs supportedSystems;

      # Eval the treefmt modules from ./treefmt.nix
      treefmtEval = forAllSystems (system: treefmt-nix.lib.evalModule nixpkgsFor.${system} ./treefmt.nix);

      # Build the nix binary tarball and recompress with zstd
      # This is similar to nix's packaging/binary-tarball.nix but outputs zstd
      nixTarballZstd =
        { pkgs, system }:
        let
          nixPkg = pkgs.nix;
          cacertPkg = pkgs.cacert;
          installerClosureInfo = pkgs.buildPackages.closureInfo {
            rootPaths = [
              nixPkg
              cacertPkg
            ];
          };
        in
        pkgs.runCommand "nix-tarball-zstd-${nixPkg.version}"
          {
            nativeBuildInputs = [ pkgs.zstd ];
            # Export these so they can be read without IFD
            passthru = {
              inherit nixPkg cacertPkg;
              nixStorePath = nixPkg.outPath;
              cacertStorePath = cacertPkg.outPath;
              nixVersion = nixPkg.version;
            };
          }
          ''
            mkdir -p $out

            dir=nix-${nixPkg.version}-${system}

            # Copy the reginfo (closure registration) to temp dir
            cp ${installerClosureInfo}/registration $TMPDIR/reginfo

            # Create tarball matching nix's binary-tarball.nix structure
            # Use --hard-dereference to convert symlinks to regular files
            # Use --transform to rewrite /nix/store paths to $dir/store
            # Store mtime is 1 second into the epoch.
            tar cf - \
              --sort=name \
              --owner=0 --group=0 --mode=u+rw,uga+r \
              --mtime='@1' \
              --absolute-names \
              --hard-dereference \
              --transform "s,$TMPDIR/reginfo,$dir/.reginfo," \
              --transform "s,$NIX_STORE,$dir/store,S" \
              $TMPDIR/reginfo \
              $(cat ${installerClosureInfo}/store-paths) \
              | zstd -19 -T1 -o $out/nix.tar.zst
          '';

      # Shared crane build setup - returns { package, clippy, cargoArtifacts }
      mkCraneBuilds =
        {
          pkgs,
          stdenv,
          buildPackages,
          extraRustFlags ? "",
        }:
        let
          isStaticLoongArch =
            stdenv.hostPlatform.isStatic && buildPackages.stdenv.hostPlatform.system == "loongarch64-linux";
          craneLib =
            if isStaticLoongArch then
              let
                fenixPkgs = import fenix {
                  system = "loongarch64-linux";
                  pkgs = buildPackages;
                };
              in
              (crane.mkLib buildPackages).overrideToolchain (
                with fenixPkgs;
                combine [
                  stable.clippy
                  stable.rustc
                  stable.cargo
                  stable.rustfmt
                  stable.rust-src
                  targets.loongarch64-unknown-linux-musl.stable.rust-std
                ]
              )
            else
              crane.mkLib pkgs;
          tarballPkg = nixTarballZstd {
            pkgs = buildPackages;
            system = buildPackages.stdenv.hostPlatform.system;
          };
          sharedAttrs = {
            src = pkgs.lib.fileset.toSource {
              root = ./.;
              fileset = pkgs.lib.fileset.unions [
                ./Cargo.toml
                ./Cargo.lock
                ./build.rs
                ./src
                ./crates
                ./tests
                ./nix-installer.sh
                ./rustfmt.toml
                ./rust-toolchain.toml
              ];
            };

            # Required to link build scripts.
            depsBuildBuild = [ buildPackages.stdenv.cc ];

            env =
              if isStaticLoongArch then
                {
                  CARGO_BUILD_TARGET = "loongarch64-unknown-linux-musl";
                  RUSTFLAGS = "-C target-feature=+crt-static -C link-self-contained=yes -C default-linker-libraries=yes";
                }
              else
                {
                  # For whatever reason, these don't seem to get set
                  # automatically when using crane.
                  #
                  # Possibly related: <https://github.com/NixOS/nixpkgs/pull/369424>
                  "CC_${stdenv.hostPlatform.rust.cargoEnvVarTarget}" = "${stdenv.cc.targetPrefix}cc";
                  "CXX_${stdenv.hostPlatform.rust.cargoEnvVarTarget}" = "${stdenv.cc.targetPrefix}c++";
                  "CARGO_TARGET_${stdenv.hostPlatform.rust.cargoEnvVarTarget}_LINKER" = "${stdenv.cc.targetPrefix}cc";
                  CARGO_BUILD_TARGET = stdenv.hostPlatform.rust.rustcTarget;
                };
          };
          cargoArtifacts = craneLib.buildDepsOnly sharedAttrs;

          # macOS-only helper embedded into the installer to keep /nix mounted
          # on AWS EC2. Built separately so build.rs can embed it.
          nixMountd = craneLib.buildPackage (
            sharedAttrs
            // {
              inherit cargoArtifacts;
              pname = "nix-mountd";
              cargoExtraArgs = "-p nix-mountd";
              doCheck = false;
              env = sharedAttrs.env // {
                # Like the installer, nix-mountd must run before Nix exists (and
                # when /nix is unmounted), so it cannot link /nix/store dylibs.
                NIX_LDFLAGS = pkgs.lib.optionalString stdenv.hostPlatform.isDarwin "-dead_strip_dylibs";
              };
              # Enforce the above at build time.
              nativeBuildInputs = pkgs.lib.optional stdenv.hostPlatform.isDarwin pkgs.darwin.cctools;
              postInstall = pkgs.lib.optionalString stdenv.hostPlatform.isDarwin ''
                # otool's first line is the binary's own path; skip it.
                if otool -L "$out/bin/nix-mountd" | tail -n +2 | grep -F /nix/store; then
                  echo "error: nix-mountd links a /nix/store dylib (see above)" >&2
                  exit 1
                fi
              '';
            }
          );

          # Bare binary: no Nix closure yet.  Appended below via `pack`.
          bare = craneLib.buildPackage (
            sharedAttrs
            // {
              inherit cargoArtifacts;
              cargoExtraArgs = "-p nix-installer";
              # Tests run as a separate derivation (see `test` below) so the
              # binary and test suite can build in parallel and we avoid
              # paying the LTO link cost twice inside one derivation.
              doCheck = false;
              env =
                sharedAttrs.env
                // pkgs.lib.optionalAttrs (!isStaticLoongArch) {
                  RUSTFLAGS = "${if extraRustFlags != "" then " ${extraRustFlags}" else ""}";
                  # The nixpkgs 25.11 darwin stdenv adds libiconv to NIX_LDFLAGS,
                  # causing the linker to pull it in as a dynamic dependency even
                  # though no iconv symbols are used. The nix-installer binary must
                  # run on macOS *before* Nix is installed, so it cannot reference
                  # /nix/store paths at runtime. Tell the linker to drop unused libs.
                  NIX_LDFLAGS = pkgs.lib.optionalString stdenv.hostPlatform.isDarwin "-dead_strip_dylibs";
                }
                // pkgs.lib.optionalAttrs stdenv.hostPlatform.isDarwin {
                  NIX_MOUNTD_BINARY_PATH = "${nixMountd}/bin/nix-mountd";
                };
              postInstall = ''
                cp nix-installer.sh $out/bin/nix-installer.sh
              '';
            }
          );
        in
        {
          inherit cargoArtifacts tarballPkg bare;

          package =
            pkgs.runCommand "nix-installer-${tarballPkg.passthru.nixVersion}"
              {
                nativeBuildInputs = [
                  pkgs.buildPackages.python3
                ]
                ++ pkgs.lib.optionals stdenv.hostPlatform.isDarwin [
                  pkgs.buildPackages.darwin.sigtool
                  pkgs.buildPackages.darwin.cctools
                ];
                __structuredAttrs = true;
                unsafeDiscardReferences.out = true;
                passthru = { inherit bare; };
              }
              ''
                mkdir -p $out/bin
                python3 ${./scripts/pack} \
                  --input ${bare}/bin/nix-installer \
                  --tarball ${tarballPkg}/nix.tar.zst \
                  --nix-store-path ${tarballPkg.passthru.nixStorePath} \
                  --cacert-store-path ${tarballPkg.passthru.cacertStorePath} \
                  --nix-version ${tarballPkg.passthru.nixVersion} \
                  --output $out/bin/nix-installer
                install -m755 ${bare}/bin/nix-installer.sh $out/bin/nix-installer.sh
              '';

          test = craneLib.cargoTest (
            sharedAttrs
            // {
              inherit cargoArtifacts;
              # Override the release profile's fat LTO: tests only need to
              # pass, not ship, and LTO adds ~55s of link time per build.
              CARGO_PROFILE_RELEASE_LTO = "off";
            }
          );

          clippy = craneLib.cargoClippy (
            sharedAttrs
            // {
              inherit cargoArtifacts;
              cargoClippyExtraArgs = "--all-targets -- -D warnings";
            }
          );
        };

      installerPackage =
        {
          pkgs,
          stdenv,
          buildPackages,
          extraRustFlags ? "",
        }:
        (mkCraneBuilds {
          inherit
            pkgs
            stdenv
            buildPackages
            extraRustFlags
            ;
        }).package;
    in
    {
      # for `nix fmt`
      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      overlays.default = final: prev: {
        nix-installer = installerPackage {
          pkgs = final;
          stdenv = final.stdenv;
          buildPackages = final.buildPackages;
        };

        nix-installer-static = final.pkgsStatic.callPackage installerPackage {
          extraRustFlags = "-C target-feature=+crt-static -C link-self-contained=yes -C default-linker-libraries=yes";
        };
      };

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
          tarballPkg = nixTarballZstd { inherit pkgs system; };
        in
        {
          default = pkgs.mkShell {
            name = "nix-install";

            RUST_SRC_PATH = "${pkgs.rustPlatform.rustcSrc}/library";

            # For `cargo build && scripts/pack ...` during development.
            NIX_INSTALLER_DEV_TARBALL = "${tarballPkg}/nix.tar.zst";
            NIX_INSTALLER_DEV_NIX_PATH = tarballPkg.passthru.nixStorePath;
            NIX_INSTALLER_DEV_CACERT_PATH = tarballPkg.passthru.cacertStorePath;
            NIX_INSTALLER_DEV_NIX_VERSION = tarballPkg.passthru.nixVersion;

            buildInputs =
              with pkgs;
              [
                rustc
                cargo
                clippy
                rust-analyzer
                cacert

                # treefmt (for `nix fmt` and manual formatting)
                treefmtEval.${system}.config.build.wrapper

                # Testing
                act
              ]
              ++ lib.optionals (pkgs.stdenv.isDarwin) (
                with pkgs;
                [
                  libiconv
                ]
              )
              ++ lib.optionals (pkgs.stdenv.isLinux) (
                with pkgs;
                [
                  checkpolicy
                  semodule-utils
                  # users are expected to have a system docker, too
                ]
              );
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};

          craneBuilds = mkCraneBuilds {
            inherit pkgs;
            stdenv = pkgs.stdenv;
            buildPackages = pkgs.buildPackages;
          };

          # Extract version from Cargo.toml
          cargoToml = builtins.fromTOML (builtins.readFile ./Cargo.toml);
          installerVersion = cargoToml.package.version;
          nixVersion = pkgs.nix.version;
          # Extract major.minor from both versions
          versionParts = ver: builtins.match "([0-9]+)\\.([0-9]+).*" ver;
          installerMajorMinor = versionParts installerVersion;
          nixMajorMinor = versionParts nixVersion;

          vmTestChecks = lib.optionalAttrs (system == "x86_64-linux") (
            let
              vmTests = import ./nix/tests/vm-test { inherit nixpkgsFor lib; };
            in
            lib.concatMapAttrs (
              distroName: distroTests:
              if distroName != "all" then
                lib.mapAttrs' (
                  testName: test: lib.nameValuePair "vm-test-${distroName}-${testName}" test
                ) distroTests.x86_64-linux
              else
                { }
            ) vmTests
          );
          containerTestChecks = lib.optionalAttrs (system == "x86_64-linux") (
            let
              containerTests = import ./nix/tests/container-test { inherit nixpkgsFor lib; };
            in
            lib.concatMapAttrs (
              distroName: distroTests:
              if distroName != "all" then
                lib.mapAttrs' (
                  runtime: test: lib.nameValuePair "container-test-${distroName}-${runtime}" test
                ) distroTests.x86_64-linux
              else
                { }
            ) containerTests
          );
        in
        {
          # treefmt handles: rustfmt, nixfmt, shfmt, shellcheck, typos, taplo, yamlfmt, actionlint, editorconfig
          formatting = treefmtEval.${system}.config.build.check self;

          check-version-consistency =
            assert
              installerMajorMinor == nixMajorMinor
              || throw "Version mismatch: installer version ${installerVersion} (${builtins.elemAt installerMajorMinor 0}.${builtins.elemAt installerMajorMinor 1}) does not match Nix version ${nixVersion} (${builtins.elemAt nixMajorMinor 0}.${builtins.elemAt nixMajorMinor 1}). The installer's major.minor must match the Nix version.";
            pkgs.runCommand "check-version-consistency" { } ''
              echo "Version consistency check passed: installer ${installerVersion} matches Nix ${nixVersion}"
              touch $out
            '';

          inherit (craneBuilds) clippy test;
        }
        // vmTestChecks
        // containerTestChecks
      );

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          inherit (pkgs) nix-installer;
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          inherit (pkgs) nix-installer-static;
          default = pkgs.nix-installer-static;
        }
        // lib.optionalAttrs (system == "aarch64-linux") {
          inherit (pkgs) nix-installer-static;
          default = pkgs.nix-installer-static;
        }
        // lib.optionalAttrs (system == "loongarch64-linux") {
          inherit (pkgs) nix-installer-static;
          default = pkgs.nix-installer-static;
        }
        // lib.optionalAttrs (pkgs.stdenv.isDarwin) {
          default = pkgs.nix-installer;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          test-action = {
            type = "app";
            program = toString (
              pkgs.writeShellScript "test-action" ''
                set -e
                echo "Testing GitHub Action with act..."
                ${pkgs.act}/bin/act -W .github/workflows/act-test.yml -j test-release --pull=false
              ''
            );
          };
        }
      );

      hydraJobs =
        let
          version = (builtins.fromTOML (builtins.readFile ./Cargo.toml)).package.version;
          installerName = "nix-installer-loongarch64-linux";
          installerScriptName = "nix-installer.sh";
        in
        rec {
          build = forAllSystems (
            system:
            let
              pkgs = nixpkgsFor.${system};
              dist = self.packages.${system}.default;
            in
            pkgs.runCommand "build" { } ''
              mkdir -p $out/nix-support $out/bin

              cp ${dist}/bin/nix-installer $out/bin/${installerName}
              cp ${dist}/bin/nix-installer.sh $out/bin/${installerScriptName}
              sed -i '1s|^#!.*|#!/bin/sh|' $out/bin/${installerScriptName}
              sed -i 's/\$assemble_installer_templated_version/v${version}/g' $out/bin/${installerScriptName}
              echo "v${version}" > $out/version

              echo "file binary-dist $out/bin/${installerName}" >> $out/nix-support/hydra-build-products
              echo "file binary-dist $out/bin/${installerScriptName}" >> $out/nix-support/hydra-build-products
            ''
          );

          runCommandHook.publish =
            let
              pkgs = nixpkgsFor.loongarch64-linux;
              app = pkgs.writeShellApplication {
                name = "publish-hook";
                runtimeInputs = with pkgs; [
                  jq
                  curl
                ];
                text = ''
                  set -euo pipefail

                  VERSION_PATH="${build.loongarch64-linux}/version"
                  NIX_INSTALLER_PATH="${build.loongarch64-linux}/bin/${installerName}"
                  NIX_INSTALLER_SH_PATH="${build.loongarch64-linux}/bin/${installerScriptName}"
                  if [ "$VERSION_PATH" = "null" ] || [ ! -f "$VERSION_PATH" ]; then
                    echo "Error: version file not found"
                    exit 1
                  fi
                  if [ "$NIX_INSTALLER_PATH" = "null" ] || [ ! -f "$NIX_INSTALLER_PATH" ]; then
                    echo "Error: nix-installer not found"
                    exit 1
                  fi
                  if [ "$NIX_INSTALLER_SH_PATH" = "null" ] || [ ! -f "$NIX_INSTALLER_SH_PATH" ]; then
                    echo "Error: nix-installer.sh not found"
                    exit 1
                  fi

                  VERSION=$(cat "$VERSION_PATH")
                  echo "Version: $VERSION"
                  echo "Found nix-installer at: $NIX_INSTALLER_PATH"
                  echo "Found nix-installer.sh at: $NIX_INSTALLER_SH_PATH"

                  PUBLISH_JSON=$(jq -n \
                    --arg nix_installer "$NIX_INSTALLER_PATH" \
                    --arg nix_installer_sh "$NIX_INSTALLER_SH_PATH" \
                    --arg version "$VERSION" \
                    '[
                      {
                        "from": $nix_installer,
                        "to": ("nix-installer/" + $version + "/"),
                        "overwrite": true
                      },
                      {
                        "from": $nix_installer_sh,
                        "to": ("nix-installer/" + $version + "/"),
                        "overwrite": true
                      },
                      {
                        "from": $nix_installer,
                        "to": "nix-installer/latest/",
                        "overwrite": true
                      },
                      {
                        "from": $nix_installer_sh,
                        "to": "nix-installer/latest/",
                        "overwrite": true
                      }
                    ]')

                  echo "Publishing JSON:"
                  echo "$PUBLISH_JSON" | jq .

                  if curl -fSs -X POST \
                    -H "Content-Type: application/json" \
                    -d "$PUBLISH_JSON" \
                    "http://127.0.0.1:8888/publish"; then
                    echo "Successfully published version $VERSION"
                  else
                    echo "Error: Failed to publish version $VERSION"
                    exit 1
                  fi
                '';
              };
            in
            pkgs.writeScript "publish.sh" ''
              #!${pkgs.runtimeShell}
              exec ${app}/bin/publish-hook "$@"
            '';
        };
    };
}
