# The command-line tools in the images, grouped as in the software lists of GitHub's hosted
# images (https://github.com/actions/runner-images/tree/main/images), which this list follows.
# Versions are whatever the pinned nixpkgs has, not GitHub's. The macOS and Linux images get
# the same tools, apart from the few that only make sense on one.
#
# Left out on purpose:
#   - Xcode and simulators: Apple's licence does not let us redistribute them. Build your own
#     image on a base that has Xcode (see the README).
#   - Browsers, the Android SDK and the hosted tool cache: large, and the setup-* actions
#     download exactly the version a workflow asks for.
#   - GNU replacements for system tools (sed, tar, coreutils): the hosted image keeps Apple's
#     as the defaults, so we do too. GNU tar is there as `gtar`, as on the hosted image.
#
# Nothing here may shadow a tool that the operating system provides. `cc`, `gcc`, `ld`, `bash`
# and the like stay Apple's on macOS and Ubuntu's on Linux; the smoke tests check that.
{ lib, pkgs }:
let
  # GCC under versioned names only (gcc-15, g++-15, gfortran-15, and gfortran, which Apple
  # does not ship), as on the hosted image. The plain package would replace Apple's cc and ld.
  gnuCompilers =
    let
      major = lib.versions.major pkgs.gcc.version;
    in
    pkgs.runCommand "gnu-compilers-${major}" { } ''
      mkdir -p $out/bin
      ln -s ${pkgs.gcc}/bin/gcc $out/bin/gcc-${major}
      ln -s ${pkgs.gcc}/bin/g++ $out/bin/g++-${major}
      ln -s ${pkgs.gfortran}/bin/gfortran $out/bin/gfortran-${major}
      ln -s ${pkgs.gfortran}/bin/gfortran $out/bin/gfortran
    '';

  gtar = pkgs.runCommand "gtar" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.gnutar}/bin/tar $out/bin/gtar
  '';
in
{
  languages = with pkgs; [
    dotnet-sdk_8
    go
    jdk21
    kotlin
    nodejs_22
    perl
    # The runner configurations make a virtual environment of this the default python3 and pip3.
    python3
    ruby_3_3
    # Rust comes from nixpkgs rather than rustup, so that its version is pinned with the rest.
    cargo
    clippy
    rustc
    rustfmt
  ];

  packageManagers = with pkgs; [
    bundler
    pipx
    vcpkg
    yarn
  ];

  projectManagement = with pkgs; [
    ant
    gradle
    maven
  ];

  utilities = with pkgs; [
    _7zz
    aria2
    bazelisk
    gh
    git
    git-lfs
    gnupg
    jq
    ninja
    openssl
    pkgconf
    wget
    yq-go
    zstd
  ];

  tools = with pkgs; [
    awscli2
    aws-sam-cli
    azure-cli
    bicep
    cmake
    powershell
    ssm-session-manager-plugin
  ];
}
// lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
  # For building Apple software, and the GNU tools that Ubuntu has anyway.
  apple = with pkgs; [
    cocoapods
    fastlane
    gnuCompilers
    gtar
    swiftformat
    xcbeautify
    xcodes
  ];
}
