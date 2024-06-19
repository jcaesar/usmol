{
  outputs = {
    self,
    nixpkgs,
  }: let
    inherit (pkgs.lib) mkForce getExe recursiveUpdate;
    pkgs = import nixpkgs {system = "x86_64-linux";};
    fixShell = ''
      substituteInPlace arch/um/Makefile --replace-fail 'SHELL := /bin/bash' 'SHELL := ${pkgs.stdenv.shell}'
    '';
    cfg = pkgs.linux.configfile.overrideAttrs (old: {
      postPatch = old.postPatch + fixShell;
      kernelArch = "um"; # here, the attr works. on the kernel itself, it doesn't.
      # defconfig = "allmodconfig";
      # default config sets an impossible value for RC_CORE that breaks autoModules, not possible to override :(
      kernelConfig = ''
        # systemd nixos module says these are necessary
        CRYPTO_USER_API_HASH y
        CRYPTO_HMAC y
        CRYPTO_SHA256 y
        TMPFS_POSIX_ACL y
        TMPFS_XATTR y
        BLK_DEV_INITRD y

        # found out the hard way that at least XZ and SCRIPT are necessary for boot
        EXPERT y
        MODULE_COMPRESS_XZ y
        MODULE_SIG n
        BINFMT_MISC y
        BINFMT_SCRIPT y

        # debug
        IKCONFIG y
        IKCONFIG_PROC y
      '';
    });
    linux = let
      mk = pkgs.linuxManualConfig {
        # config file for the wrong arch. pukes a bit on build start but ends up working nicely
        inherit (pkgs.linux) version src;
        configfile = cfg;
        allowImportFromDerivation = true;
      };
      ob = mk.override {
        stdenv = recursiveUpdate pkgs.stdenv {
          hostPlatform.linuxArch = "um";
          hostPlatform.linux-kernel.target = "linux";
        };
      };
      oa = ob.overrideAttrs (old: {
        postPatch = old.postPatch + fixShell;
        installPhase = ''
          # there doesn't seem to be an install target for um
          install -Dm555 ./vmlinux $out/bin/vmlinux
          ln -s $out/bin/vmlinux $out/bin/linux
          runHook postInstall
        '';
        meta = old.meta // {mainProgram = "vmlinux";};
      });
    in
      oa;
    sys = nixpkgs.lib.nixosSystem {
      inherit (pkgs) system;
      modules = [
        {
          boot.kernelPackages = pkgs.linuxPackagesFor linux;
          # can't use boot.kernel.enable = false; we do want modules, but we don't have a kernel - any file will do
          system.boot.loader.kernelFile = "bin/vmlinux";
          boot.initrd.availableKernelModules = mkForce ["autofs4"]; # autofs is required by systemd, hostfs by this config
          boot.initrd.kernelModules = mkForce ["hostfs"]; # bunch of modules we don't have or need (tpm, efi, …)
          boot.loader.grub.enable = false; # needed for eval
          boot.loader.initScript.enable = false; # unlike the documentation for this option says, not actually required.i
          system.requiredKernelConfig = mkForce []; # systemd requires DMIID, but that requires DMI, and that doesn't exist on ARCH=um

          fileSystems."/" = {
            device = "tmp";
            fsType = "tmpfs";
          };
          fileSystems."/nix/store" = {
            device = "host";
            fsType = "hostfs";
            options = ["/nix/store"];
          };

          networking.hostName = "lol"; # short for linux on linux. olo
          boot.initrd.systemd.enable = true;
          services.getty.autologinUser = "root";

          # startup is slow enough, disable some unused stuff (esp. networking)
          networking.firewall.enable = false;
          services.nscd.enable = false;
          networking.useDHCP = false;
          system.nssModules = mkForce [];
          systemd.oomd.enable = false;

          system.stateVersion = "24.11";
        }
      ];
    };
  in {
    packages.${pkgs.system} = {
      default = pkgs.writeScriptBin "umlvm" ''
        set -x
        exec ${getExe linux} \
          mem=2G \
          init=${sys.config.system.build.toplevel}/init \
          initrd=${sys.config.system.build.initialRamdisk}/${sys.config.system.boot.loader.initrdFile} \
          con=null con0=null,fd:2 con1=fd:0,fd:1 \
          ${toString sys.config.boot.kernelParams}
          # con0=fd:0,fd:1 con1=null,fd:2 \
          # systemd.unit=rescue.target SYSTEMD_SULOGIN_FORCE=1 \
          # con0=null,fd:2 con1=fd:0,fd:1 \
      '';
      # when trying to debug boot problems / enter rescue, set kernel parameters:
      #    SYSTEMD_SULOGIN_FORCE=1
      #    con0=fd:0,fd:1 con1=null,fd:2
      #    systemd.unit=rescue.target
      # something like this is also possible instead of mounting hostfs:
      #   root=/dev/ubda 
      #   ubd0=${pkgs.callPackage "${nixpkgs}/nixos/lib/make-ext4-fs" { storePaths = [ sys.config.system.build.toplevel ]; }}

      # for inspection
      etc = sys.config.system.build.etc;
      top = sys.config.system.build.toplevel;
      config = cfg;
    };
  };

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable"; # branch pr-10
}
