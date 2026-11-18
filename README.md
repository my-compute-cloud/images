# Runner images for My Compute Cloud

The virtual machine images that [My Compute Cloud](https://mycompute.cloud) jobs run in, and
the means to build your own. An image is a macOS or Linux VM for [Tart](https://tart.run),
stored in a container registry; the Linux one can also be built as a disk for
[Linux hosts](#images-for-linux-hosts). What goes into one is in this repository, so you can read
exactly what a job gets, and change it:

- **macOS:** a [nix-darwin](https://github.com/nix-darwin/nix-darwin) configuration declares
  the system, applied on top of a base macOS VM.
- **Linux:** Ubuntu, so that workflows written for `ubuntu-latest` keep working (`apt-get`,
  libraries where prebuilt programs expect them). Docker, the compilers and the runner's
  libraries are installed with apt by [a script](scripts/provision-linux.sh); only the tools
  and the job environment are a Nix package. It is Ubuntu with Nix-pinned tools, not a system
  built by Nix.

The two share one tool list and one cache setup in the flake.

How images fit into the service is explained at <https://mycompute.cloud/docs/images>.

## Published images

| Image | System | Contents |
|---|---|---|
| `ghcr.io/my-compute-cloud/macos-runner:tahoe` | macOS 26 (Tahoe), arm64 | The tools below. No Xcode. |
| `ghcr.io/my-compute-cloud/ubuntu-runner:24.04` | Ubuntu 24.04, arm64 | The tools below, and Docker for container jobs and services. |

Each build is also pushed with a dated tag, such as `tahoe-20261117`, which never moves. Use
the dated tag when a workflow must not change underneath you, and the plain one to follow
along.

## What is in an image

The command-line tools of GitHub's hosted images, by name, at the versions of the nixpkgs
revision pinned in [flake.lock](flake.lock). Both images get the same list,
[modules/tools.nix](modules/tools.nix), apart from what only makes sense on one:

- **Languages:** Node.js 22, Python 3, Ruby 3.3, Go, Rust, Java 21, Kotlin, .NET 8, Perl
- **Package and project tools:** npm, Yarn, pipx, Bundler, vcpkg, Maven, Gradle, Ant
- **Utilities:** Git, Git LFS, GitHub CLI, jq, yq, wget, aria2, GnuPG, zstd, 7-Zip, OpenSSL,
  pkgconf, Ninja, Bazelisk
- **Tools:** CMake, AWS CLI, AWS SAM CLI, Session Manager plugin, Azure CLI, Bicep, PowerShell
- **Nix**, with flakes enabled, for jobs that bring their own environment
- **macOS only:** CocoaPods, fastlane, SwiftFormat, xcbeautify, xcodes, GNU tar as `gtar`, GCC
  and GNU Fortran under versioned names such as `gcc-15`; and from the base image, Homebrew,
  Apple's command-line developer tools and Rosetta
- **Linux only:** Docker with Buildx and Compose, and Ubuntu's own compilers (`build-essential`)

### Differences from GitHub's hosted images

The Linux image is arm64, because the Macs that run it are; GitHub's `ubuntu-latest` is x86.
Container images a job uses must be available for arm64.

| | GitHub-hosted | These images |
|---|---|---|
| Xcode and simulators | Several versions | Not in the image, because Apple's licence does not let us pass Xcode on. The host adds its own; see [Xcode](#xcode). |
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

For the Linux image, which builds in about five minutes on a 5 GB base:

```bash
OS=linux scripts/build.sh
```

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
| `mcc.runner.jobSetup` | Shell commands run just before the runner starts, for what cannot be a fixed variable. The default points package managers' download caches at the host's cache when the host owner provides one (`MCC_CACHE_DIR`). |

The tools are in the read-only Nix store. So that installing with them still works, the
default `python3` and `pip3` are a virtual environment in `~/.python`, `npm install -g` and
`gem install` are pointed at the home directory, and the places where those, `pipx`,
`cargo install`, `go install` and `dotnet tool install -g` put programs are first on `PATH`.

To see what a job sees, start the VM and use `tart exec <vm> /bin/bash -c 'command'`. An SSH
or Terminal session reads the shell profile and so differs.

`/etc/mcc-image.json` in every image records the configuration, the revision and the base it
was built from.

### Xcode

You do not need your own image for Xcode. Install Xcode on the host and set
`"xcode": "/Applications/Xcode.app"` in the agent's policy: the agent copies it into its local
copy of whichever image a pool uses, once, and every job starts with it. See
[the agent's documentation](https://github.com/my-compute-cloud/mcc/blob/main/docs/agent.md).

To have Xcode in the image itself, build on a base that has it, and keep the result in a
private registry:

```bash
BASE=ghcr.io/cirruslabs/macos-tahoe-xcode:latest IMAGE=ghcr.io/your-org/macos-runner TAGS=tahoe-xcode scripts/build.sh --push
```

### Your own Linux image

The Nix part of the Linux image is one package, which holds the tools and the job
environment. `lib.linuxRunner` makes that package with your additions:

```nix
{
  inputs.images.url = "github:my-compute-cloud/images";

  outputs =
    { images, ... }:
    {
      packages.aarch64-linux.runner =
        let
          pkgs = images.inputs.nixpkgs.legacyPackages.aarch64-linux;
        in
        images.lib.linuxRunner {
          inherit pkgs;
          extraPackages = [ pkgs.terraform ];
          extraJobSetup = "export MY_SETTING=value";
        };
    };
}
```

```bash
OS=linux FLAKE=/path/to/your/flake IMAGE=ghcr.io/your-org/ubuntu-runner /path/to/images/scripts/build.sh --push
```

A Linux job's whole environment, `PATH` included, is set in `/etc/mcc/job-env`, which the
agent reads just before it starts the runner; `extraJobSetup` is appended to it. Packages from
apt are installed by [scripts/provision-linux.sh](scripts/provision-linux.sh).

To have container images such as `mysql:8.4` already in every job's VM, you do not need your
own image: list them in the agent's `preload_images` policy on the host.

### What a base image must have

The configuration is applied on top of a Tart VM that already has an auto-login user (`admin`
by default; `mcc.runner.user`), `sudo` without a password, and the Tart guest agent at
`/opt/homebrew/bin/tart-guest-agent` (`mcc.runner.guestAgent`). Cirrus Labs'
[`macos-*-base` images](https://github.com/cirruslabs/macos-image-templates) have all three.
For Linux: an Ubuntu VM with the guest agent running as a user that has `sudo` without a
password, as in Cirrus Labs' `ubuntu` image.

## Images for Linux hosts

A My Compute Cloud host can also be a Linux machine, which runs Linux jobs in VMs under QEMU
with KVM. It cannot use a Tart image. It takes the same Ubuntu configuration as a qcow2 disk,
kept in a registry as an OCI artifact: the disk in pieces as the layers, and a small config
that names the job's user. One tag can hold an x86_64 and an arm64 disk; a host takes its own.

There are two ways to build the disk, both from
[scripts/provision-linux.sh](scripts/provision-linux.sh):

- **On a Mac,** with the Tart build. The disk of a Tart Linux VM boots under QEMU as it is,
  so the build only has to write it out. This gives arm64:

  ```bash
  OS=linux KVM_OUT=./mcc-image-ubuntu-arm64 scripts/build.sh
  ```

- **On a Linux machine with KVM,** from Ubuntu's cloud image, for that machine's
  architecture. This is the only way to x86_64:

  ```bash
  scripts/build-kvm.sh
  ```

Either leaves a directory with `disk.qcow2` and `config.json`. A host can use that directory
directly, by its full path as the image's source, or you publish it:

```bash
scripts/push-kvm.sh ./mcc-image-ubuntu-arm64 ghcr.io/your-org/ubuntu-runner-kvm:24.04
```

That pushes `24.04-arm64` and points `24.04` at every architecture pushed so far.

A Linux host has no guest agent to run a job through. It makes an SSH key for each VM and
passes the public half in as a systemd credential, which only the host can set. The image's
`mcc-guest-access` service, installed by the provisioning script, makes that the job user's
only authorized key before SSH starts listening and turns password logins off. Under Tart
there is no such credential and the service does not run. The check at the end of
`build-kvm.sh` gets in that way, so an image that passes it will let a host in.

## Publishing

For maintainers. On a Mac signed in to the registry with `tart login ghcr.io`:

```bash
scripts/build.sh --push
```

```bash
OS=linux scripts/build.sh --push
```

The [Build image](.github/workflows/build.yml) workflow does the same on a self-hosted runner
labelled `tart`. Before attaching one: this repository is public, and a pull request from a
fork can change a workflow to run on a self-hosted runner. Put the runner in a runner group
that is limited to this workflow, and keep "Require approval for all external contributors"
on in the repository's Actions settings.

## Licence

[MIT](LICENSE). The images contain software under its own licences, including macOS, whose
licence allows it to run only on Apple hardware.
