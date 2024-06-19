{
  outputs = {
    self,
    nixpkgs,
  }: let
    inherit (pkgs.lib) mkForce remove getExe recursiveUpdate;
    pkgs = import nixpkgs {system = "x86_64-linux";};
    linux = let
      mk = pkgs.linuxManualConfig {
        # config file for the wrong arch. pukes a bit on build start but ends up working nicely
        inherit (pkgs.linux) version src configfile;
        allowImportFromDerivation = true;
      };
      ob = mk.override {
        stdenv = recursiveUpdate pkgs.stdenv {
          hostPlatform.linuxArch = "um";
          hostPlatform.linux-kernel.target = "linux";
        };
      };
      oa = ob.overrideAttrs (old: {
        # buildFlags = remove "bzImage" old.buildFlags ++ ["linux" "ARCH=um"];
        postPatch = old.postPatch + ''
          substituteInPlace arch/um/Makefile --replace-fail 'SHELL := /bin/bash' 'SHELL := ${pkgs.stdenv.shell}'
        '';
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
          boot.initrd.availableKernelModules = mkForce ["autofs4"]; # required by systemd
          boot.initrd.kernelModules = mkForce []; # bunch of modules we don't have or need (tpm, efi, …)
          boot.loader.grub.enable = false; # needed for eval
          boot.loader.initScript.enable = false; # unlike the documentation for this option says, not actually required.

          fileSystems."/" = {
            device = "-";
            fsType = "tmpfs";
          };
          fileSystems."/nix/store" = {
            device = "-";
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
    packages.${pkgs.system}.default = pkgs.writeScriptBin "umlvm" ''
      set -x
      exec ${getExe linux} \
        mem=2G \
        init=${sys.config.system.build.toplevel}/init \
        initrd=${sys.config.system.build.initialRamdisk}/${sys.config.system.boot.loader.initrdFile} \
        con0=null,fd:2 con1=fd:0,fd:1 \
        ${toString sys.config.boot.kernelParams}
    '';
    # something like this is also possible instead of mounting hostsf:
    #   root=/dev/ubda ubd0=${pkgscallPackage 
    #   ubd0=${pkgs.callPackage "${nixpkgs}/nixos/lib/make-ext4-fs" { storePaths = [ sys.config.system.build.toplevel ]; }}
  };

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable"; # branch pr-10
}
