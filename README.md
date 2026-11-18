# Runner images for My Compute Cloud

The virtual machine images that [My Compute Cloud](https://mycompute.cloud) jobs run in, and
the means to build your own. An image is a macOS VM for [Tart](https://tart.run), stored in a
container registry. Its contents are declared with [nix-darwin](https://github.com/nix-darwin/nix-darwin)
in this repository, so you can read exactly what a job gets, and change it.

How images fit into the service is explained at <https://mycompute.cloud/docs/images>.

## Published images

| Image | macOS | Contents |
|---|---|---|
| `ghcr.io/my-compute-cloud/macos-runner:tahoe` | 26 (Tahoe) | The tools below. No Xcode. |

Each build is also pushed with a dated tag, such as `tahoe-20261117`, which never moves. Use
the dated tag when a workflow must not change underneath you, and the plain one to follow
along.

## What is in an image

The command-line tools of GitHub's hosted macOS image, by name, at the versions of the
nixpkgs revision pinned in [flake.lock](flake.lock). The list is [modules/tools.nix](modules/tools.nix):

- **Languages:** Node.js 22, Python 3, Ruby 3.3, Go, Rust, Java 21, Kotlin, .NET 8, Perl, and
  GCC and GNU Fortran under versioned names such as `gcc-15`
- **Package and project tools:** npm, Yarn, pipx, Bundler, CocoaPods, vcpkg, Maven, Gradle, Ant
- **Utilities:** Git, Git LFS, GitHub CLI, jq, yq, wget, aria2, GnuPG, zstd, 7-Zip, GNU tar
  (as `gtar`), OpenSSL, pkgconf, Ninja, Bazelisk
- **Tools:** CMake, AWS CLI, AWS SAM CLI, Session Manager plugin, Azure CLI, Bicep, PowerShell,
  fastlane, SwiftFormat, xcbeautify, xcodes
- **From the base image:** Homebrew, Apple's command-line developer tools, Rosetta
- **Nix**, with flakes enabled, for jobs that bring their own environment

### Differences from GitHub's hosted image

| | GitHub-hosted | These images |
|---|---|---|
| Xcode and simulators | Several versions | None. Apple's licence does not let us redistribute Xcode; see [Xcode](#xcode). |
| Tool versions | GitHub's weekly choices | The pinned nixpkgs revision |
| Version switching | A cache of several Node, Python, Ruby and Go versions | One of each; `actions/setup-node` and its siblings download the version a workflow asks for |
| Browsers, Android SDK | Installed | Not installed |
| User and home | `runner`, `/Users/runner` | `admin`, `/Users/admin` |
| Rust | Installed with rustup | From nixpkgs, without rustup; toolchain actions install rustup themselves |
| System tools | Apple's `cc`, `bash`, `sed`, `tar` and so on are the defaults | The same |

## Build your own image

You need an Apple Silicon Mac with Tart. The build cannot run on GitHub's hosted Macs, which
are virtual machines themselves and cannot start another.

To build this repository's image as it is:

```bash
scripts/build.sh
```

That clones the base VM, boots it, applies the configuration inside it, restarts it and checks
that a job would find its tools. It leaves a stopped VM named `mcc-image-tahoe` that you can
look at with `tart run mcc-image-tahoe`. The first build downloads a 27 GB base image; after
that a build takes about ten minutes.

To add your own tools, make a flake that imports this one's module:

```nix
{
  inputs.images.url = "github:my-compute-cloud/images";

  outputs =
    { images, ... }:
    {
      darwinConfigurations.runner = images.inputs.nix-darwin.lib.darwinSystem {
        modules = [
          images.darwinModules.runner
          (
            { pkgs, ... }:
            {
              environment.systemPackages = [ pkgs.terraform ];
              mcc.runner.environment.MY_SETTING = "value";
            }
          )
        ];
      };
    };
}
```

Then build it and push it to a registry of yours:

```bash
tart login ghcr.io
```

```bash
FLAKE=/path/to/your/flake IMAGE=ghcr.io/your-org/macos-runner /path/to/images/scripts/build.sh --push
```

`scripts/build.sh` lists its other settings at the top. The check it runs at the end expects
this repository's tools; if you remove some, point `SMOKE_TEST` at a check of your own. If the registry is private, run
`tart login` on every host that will pull from it.

### The job environment

My Compute Cloud starts a job through the Tart guest agent, in a shell that reads no profile.
So `~/.zprofile` and `/etc/zshrc` do not apply to jobs. Set a job's environment with these
options instead:

| Option | Meaning |
|---|---|
| `mcc.runner.path` | `PATH`, first entry first. The default puts this configuration's tools ahead of Homebrew's and macOS's. |
| `mcc.runner.environment` | Other environment variables |

The tools are in the read-only Nix store. So that installing with them still works, the
default `python3` and `pip3` are a virtual environment in `~/.python`, `npm install -g` and
`gem install` are pointed at the home directory, and the places where those, `pipx`,
`cargo install`, `go install` and `dotnet tool install -g` put programs are first on `PATH`.

To see what a job sees, start the VM and use `tart exec <vm> /bin/bash -c 'command'`. An SSH
or Terminal session reads the shell profile and so differs.

`/etc/mcc-image.json` in every image records the configuration, the revision and the base it
was built from.

### Xcode

Build on a base that has Xcode, and keep the result in a private registry:

```bash
BASE=ghcr.io/cirruslabs/macos-tahoe-xcode:latest IMAGE=ghcr.io/your-org/macos-runner TAGS=tahoe-xcode scripts/build.sh --push
```

### What a base image must have

The configuration is applied on top of a Tart VM that already has an auto-login user (`admin`
by default; `mcc.runner.user`), `sudo` without a password, and the Tart guest agent at
`/opt/homebrew/bin/tart-guest-agent` (`mcc.runner.guestAgent`). Cirrus Labs'
[`macos-*-base` images](https://github.com/cirruslabs/macos-image-templates) have all three.

## Publishing

For maintainers. On a Mac signed in to the registry with `tart login ghcr.io`:

```bash
scripts/build.sh --push
```

The [Build image](.github/workflows/build.yml) workflow does the same on a self-hosted runner
labelled `tart`. Before attaching one: this repository is public, and a pull request from a
fork can change a workflow to run on a self-hosted runner. Put the runner in a runner group
that is limited to this workflow, and keep "Require approval for all external contributors"
on in the repository's Actions settings.

## Licence

[MIT](LICENSE). The images contain software under its own licences, including macOS, whose
licence allows it to run only on Apple hardware.
