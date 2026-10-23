# This is a guest kernel for Apple's `container` runtime.
#
# Upstream: https://github.com/apple/containerization/tree/main/kernel
#
# This configuration enables two things the default kernel does not:
#
# - CONFIG_VIRTUALIZATION/CONFIG_KVM — gives the guest a /dev/kvm on a
#   nested-virt-capable host (M3+), so the builder can run Nix builds with
#   `requiredSystemFeatures = [ "kvm" ]`. Without nested virt (or
#   `--virtualization`) KVM never initialises, so it is a safe default
#   everywhere.
# - CONFIG_EROFS_FS — lets the linux-builder image
#   (packages/linux-builder-image) use `system.etc.overlay.enable`, which
#   mounts /etc from an erofs metadata image and drops the perl dependency,
#   saving space.
#
{ path }:
let
  # Not pkgsCross: a native aarch64-linux eval offloads to the host's
  # linux-builder, avoiding a darwin→linux cross toolchain.
  linuxPkgs = import path { system = "aarch64-linux"; };

  version = "6.18.5";

  src = linuxPkgs.fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${version}.tar.xz";
    hash = "sha256-GJ0fQJzvjQ0jQhDgRZUXLfOS+MspfhS0R+2Vcg4v2UA=";
  };

  configfile = linuxPkgs.stdenv.mkDerivation {
    pname = "apple-container-kernel-config";
    inherit version src;

    nativeBuildInputs = with linuxPkgs; [
      bison
      flex
    ];

    buildPhase = ''
      runHook preBuild
      cp ${./config-arm64} .config
      bash scripts/config --file .config --enable EROFS_FS
      make ARCH=arm64 olddefconfig
      # Fail loudly if the options we depend on did not survive olddefconfig.
      grep -qx 'CONFIG_VIRTUALIZATION=y' .config
      grep -qx 'CONFIG_KVM=y' .config
      grep -qx 'CONFIG_EROFS_FS=y' .config
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cp .config $out
      runHook postInstall
    '';

    meta.platforms = [ "aarch64-linux" ];
  };

  image = linuxPkgs.linuxKernel.manualConfig {
    pname = "apple-container-kernel";
    inherit version src configfile;
  };
in
# `container system kernel set` only ingests a tar; the raw Image stays
# exposed for `container run --kernel` and debugging.
linuxPkgs.runCommand "apple-container-kernel-${version}"
  {
    passthru = {
      inherit image configfile;
      # Asserts CONFIG_KVM/CONFIG_EROFS_FS survive olddefconfig, without
      # building the kernel.
      tests.config = configfile;
    };
    meta = {
      description = "KVM-capable guest kernel for Apple's container runtime";
      inherit (image.meta) license;
    };
  }
  ''
    mkdir -p $out
    cp ${image}/Image $out/vmlinux-arm64
    cp ${configfile} $out/config
    tar -C $out -cf $out/kernel.tar \
      --owner=0 --group=0 --numeric-owner --mtime=@1 \
      ./vmlinux-arm64
  ''
