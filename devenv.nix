# Flutter and the meret-* commands. `direnv allow` loads the shell; `devenv
# info` lists the commands. Outside a loaded shell, run one as
# `direnv exec . meret-test`.
#
# Rust stays with rustup: the native-assets hook runs `rustup run <channel>
# cargo`, and rust-toolchain.toml pins the channel.
{
  pkgs,
  lib,
  options,
  ...
}:

let
  # Each command runs from the checkout that contains the working directory,
  # rather than $DEVENV_ROOT, so a shell or agent that inherited this
  # environment from another worktree still builds its own.
  prelude = name: ''
    set -euo pipefail
    root=$PWD
    until [ -f "$root/devenv.nix" ] && [ -d "$root/crates/meret-ffi" ]; do
      if [ "$root" = / ]; then
        echo "${name}: run inside a Meret checkout" >&2
        exit 1
      fi
      root=$(dirname "$root")
    done
    cd "$root"
  '';

  commands = {
    meret-setup = {
      description = "Resolve app packages with the pinned Flutter SDK";
      run = ''
        cd apps/meret
        exec flutter pub get "$@"
      '';
    };
    meret-bridge = {
      description = "Build the host Rust library used by Flutter integration tests";
      run = ''exec cargo build -p meret-ffi "$@"'';
    };
    meret-test = {
      description = "Run the Flutter app tests";
      run = ''
        meret-bridge
        cd apps/meret
        exec flutter test "$@"
      '';
    };
    meret-install = {
      description = "Build the release macOS app, install it as /Applications/Meret.app and open it";
      run = ''
        cd apps/meret
        flutter build macos --release

        # Flutter can replace App.framework after Xcode seals the outer app during
        # an incremental build. This project uses ad-hoc development signing.
        codesign --force --sign - --preserve-metadata=identifier,entitlements,flags build/macos/Build/Products/Release/meret.app
        codesign --verify --deep --strict build/macos/Build/Products/Release/meret.app

        # Quit any running Meret, including a debug build, so the copy isn't in use.
        osascript -e 'quit app id "io.sowilo.meret"' 2>/dev/null || true
        for _ in $(seq 50); do
          pgrep -qx meret || break
          sleep 0.1
        done
        pkill -x meret || true

        rm -rf /Applications/Meret.app
        ditto build/macos/Build/Products/Release/meret.app /Applications/Meret.app
        codesign --verify --deep --strict /Applications/Meret.app
        open /Applications/Meret.app
        echo "Installed /Applications/Meret.app"
      '';
    };
  };
in
{
  # No Nix compiler, Apple SDK or xcrun shim: the Flutter macOS build and
  # cargo use the installed Xcode and the host's compiler.
  stdenv = pkgs.stdenvNoCC;
  apple.sdk = null;
  # stdenv sets these for Nix builds; they would pin the app's minimum macOS
  # to the SDK's and stamp build outputs with 1980.
  unsetEnvVars = options.unsetEnvVars.default ++ [
    "SOURCE_DATE_EPOCH"
    "MACOSX_DEPLOYMENT_TARGET"
    "ZERO_AR_DATE"
  ];

  packages = [
    # Flutter 3.47 with its bundled Dart SDK; pubspec.yaml's Dart bound
    # follows it.
    pkgs.flutter347
    pkgs.rustup
  ];

  scripts = lib.mapAttrs (name: command: {
    inherit (command) description;
    exec = prelude name + command.run;
  }) commands;
}
