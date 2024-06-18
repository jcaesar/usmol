{
  outputs = {
    self,
    nixpkgs,
  }: let
    inherit (pkgs.lib) mkForce remove getExe;
    pkgs = import nixpkgs {system = "x86_64-linux";};
    linux = let
      ob = pkgs.linux.override {
        kernelArch = "um";
        ignoreConfigErrors = true;
        autoModules = false; # There's some [N/m/?] question in defconfig that the perl script can't answer
        # defconfig = "allmodconfig"; # Alternatively to autoModules = false, you could do this, but there is 1 unknown identifier…
      };
      oa = ob.overrideAttrs (old: {
        buildFlags = remove "bzImage" old.buildFlags ++ ["linux"];
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

  inputs.nixpkgs.url = "github:jcaesar/fork2pr-nixpkgs/84b9867048928648c80b1f438e61ce0bc5d9ba7d"; # branch pr-10
}
