# building with alternate directory:
# export NIX_REMOTE=/tmp/usmol1
# export NIX_STORE_DIR=/tmp/usmol1/nix/store nom build . -v --keep-going
# nix-prefetch-url file:///nix/store/ws73d521m0im6x7nhb0836i51z2yd9dq-bzip2-1.0.6.2-autoconfiscated.patch --name bzip2-1.0.6.2-autoconfiscated.patch
# nix-prefetch-url https://git.kernel.org/pub/scm/utils/kernel/kmod/kmod.git/snapshot/kmod-31.tar.gz --name source
# nix-prefetch-url file:///nix/store/xjc3kbwkz4w48p9jq81mkd3cxcq7pzxm-fakeroot_1.29.orig.tar.gz --name fakeroot_1.29.orig.tar.gz
# nix-prefetch-url file:///nix/store/j6ij02s4aq6di55xgm22hdybhjb0fmgv-also-wrap-stat-library-call.patch --name also-wrap-stat-library-call.patch
# nix-prefetch-url file:///nix/store/y2h7bqjpc4q9g887w8pbwncjrmr4g9sx-gettext-0.21.1.tar.gz   --name gettext-0.21.1.tar.gz
# nix build .#script -o $NIX_REMOTE/run -v --keep-going --print-build-log
{
  outputs = {
    self,
    nixpkgs,
  }: let
    inherit (pkgs.lib) mkForce getExe getExe' recursiveUpdate;
    coreutil = pkgs.lib.getExe' pkgs.coreutils;
    pkgs = import nixpkgs {
      system = "x86_64-linux";
    };
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

        # doggier
        NAMESPACES y
        NET_NS y
        PID_NS y
        IPC_NS y
        UTS_NS y
        CGROUPS y
        CGROUP_CPUACCT y
        CGROUP_DEVICE y
        CGROUP_FREEZER y
        CGROUP_SCHED y
        MEMCG y
        KEYS y
        VETH m
        BRIDGE m
        POSIX_MQUEUE y
        USER_NS y
        SECCOMP y
        CGROUP_PIDS y
        BLK_CGROUP y
        BLK_DEV_THROTTLING y
        CGROUP_NET_PRIO y
        CFS_BANDWIDTH y
        FAIR_GROUP_SCHED y
        RT_GROUP_SCHED y
        EXT4_FS y
        EXT4_FS_POSIX_ACL y
        EXT4_FS_SECURITY y
        VXLAN y
        CRYPTO y
        CRYPTO_AEAD y
        CRYPTO_GCM y
        CRYPTO_SEQIV y
        CRYPTO_GHASH y
        XFRM y
        XFRM_USER y
        XFRM_ALGO y
        INET_ESP y
        IPVLAN m
        MACVLAN y
        DUMMY y
        OVERLAY_FS y

        NF_TABLES y
        NF_CONNTRACK y
        NF_TABLES_INET y
        NF_TABLES_NETDEV y
        NF_FLOW_TABLE_PROCFS y
        NF_CONNTRACK_EVENTS y
        NF_CONNTRACK_TIMEOUT y
        NF_CONNTRACK_TIMESTAMP y
        INET y
        NETFILTER y
        NET y
        VLAN_8021Q y
        BRIDGE_NETFILTER m
        CGROUP_BPF y

        # bess
        UML_NET y
        UML_NET_VECTOR y
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
    sys = pkgs.nixos ({
      modulesPath,
      pkgs,
      ...
    }: {
      imports = ["${modulesPath}/profiles/minimal.nix"];

      boot.kernelPackages = pkgs.linuxPackagesFor linux;
      # can't use boot.kernel.enable = false; we do want modules, but we don't have a kernel - any file will do
      system.boot.loader.kernelFile = "bin/vmlinux";
      boot.initrd.availableKernelModules = mkForce ["autofs4"]; # autofs is required by systemd, hostfs by this config
      boot.initrd.kernelModules = mkForce ["hostfs"]; # bunch of modules we don't have or need (tpm, efi, …)
      boot.loader.grub.enable = false; # needed for eval
      boot.loader.initScript.enable = false; # unlike the documentation for this option says, not actually required.i
      system.requiredKernelConfig = mkForce []; # systemd requires DMIID, but that requires DMI, and that doesn't exist on ARCH=um
      boot.initrd.systemd.emergencyAccess = true;

      fileSystems."/" = {
        device = "tmp";
        fsType = "tmpfs";
      };
      fileSystems.${builtins.storeDir} = {
        device = "host";
        fsType = "hostfs";
        options = [builtins.storeDir];
      };
      fileSystems."/mnt/host" = {
        device = "host";
        fsType = "hostfs";
      };
      # some hackfixes for messing with the storeDir
      boot.initrd.systemd.services.mkmounttargets = pkgs.lib.mkIf (builtins.storeDir != "/nix/store") {
        # for some reason, initrd-parse-etc.service doesn't do it's thing.
        unitConfig.DefaultDependencies = false;
        wantedBy = ["initrd-fs.target"];
        before = ["initrd-switch-root.service" "initrd-switch-root.service"];
        script = ''
          set -x
          mount
          if ! test -d /sysroot; then
            mkdir -p /sysroot
            mount -ttmpfs - /sysroot
          fi
          if ! test -d /sysroot/tmp/usmol1/nix/store; then
            mkdir -p /sysroot/tmp/usmol1/nix/store /sysroot/mnt/host
            mount -thostfs -o${builtins.storeDir} host /sysroot/${builtins.storeDir}
          fi
        '';
      };
      # Failed at step EXEC spawning …systemd-logind: No such file or directory
      systemd.services.systemd-logind.enable = false; # It's just unnecessary?

      networking.hostName = "lol"; # short for linux on linux. olo
      boot.initrd.systemd.enable = true;
      services.getty.autologinUser = "root";
      services.journald.console = "tty1";

      # startup is slow enough, disable some unused stuff
      networking.firewall.enable = false;
      networking.useDHCP = false;
      services.logrotate.enable = false;
      services.nscd.enable = false;
      services.timesyncd.enable = false;
      system.nssModules = mkForce [];
      systemd.oomd.enable = false;
      nix.enable = false; # doesn't build with alternate store paths
      documentation.enable = false;

      system.stateVersion = "24.11";

      networking.interfaces.vec0.ipv4.addresses = [
        {
          address = "10.0.2.100";
          prefixLength = 24;
        }
      ];
      networking.defaultGateway = "10.0.2.2";
      networking.nameservers = ["10.0.2.3"];

      virtualisation.docker.enable = true;

      systemd.services.compose-run.wantedBy = ["multi-user.target"];
      systemd.services.compose-run.after = ["network.target" "docker.service"];
      systemd.services.compose-run.serviceConfig.ExecStart = let
        imageName = "stuff";
        streamImage = pkgs.dockerTools.streamLayeredImage {
          name = imageName;
          tag = "latest";
          fromImage = null;
          contents = [pkgs.miniserve pkgs.wget];
        };
        port = 1337;

        # standard-ish compose file
        compose.services = {
          serve = {
            image = imageName;
            command = ["miniserve" "-p${toString port}" "/mnt/data"];
            expose = [port];
            volumes = ["./data1:/mnt/data"];
            healthcheck = {
              test = ["CMD" "wget" "-qO/dev/null" "http://localhost:${toString port}/"];
              interval = "5s";
            };
          };
          get = {
            image = imageName;
            command = ["wget" "http://serve:${toString port}/canary" "-O/mnt/data/canary"];
            volumes = ["./data2:/mnt/data"];
            depends_on.serve.condition = "service_healthy";
          };
        };

        composeFile = pkgs.writeText "docker-compose.yaml" (builtins.toJSON compose);
        docker = getExe pkgs.docker;
      in
        pkgs.writeScript "run-compose" ''
          #!${getExe pkgs.bash}
          set -xeuo pipefail
          ${streamImage} | ${docker} image load
          cd "$(mktemp -d)"
          mkdir data1 data2
          echo $RANDOM >data1/canary
          cp ${composeFile} docker-compose.yaml
          ${docker} compose up --abort-on-container-exit --pull=never
          cat data1/canary
          cat data2/canary
        '';
      systemd.services.compose-run.serviceConfig.ExecStopPost = pkgs.writeScript "post-compose" ''
        #!${getExe pkgs.bash}
        set -eux
        if test $SERVICE_RESULT == success; then
          systemctl poweroff
        else
          # kernel panic to communicate the exit code. feels like sacrilege…
          sync
          echo c >/proc/sysrq-trigger
        fi
      '';
    });
    bin = pkgs.writeScriptBin "umlvm" ''
      #!${pkgs.runtimeShell} -eux
      ttycfg="$(${coreutil "stty"} -g < /dev/tty)"
      SOCKD="$(${coreutil "mktemp"} --directory)"
      SOCK="$SOCKD/slirp4netns-bess.sock"
      trap '${coreutil "stty"} "$ttycfg" </dev/tty' EXIT
      trap '${coreutil "rm"} -rf "$SOCKD"; trap - SIGTERM && kill -- -$$' SIGINT SIGTERM
      ${getExe pkgs.slirp4netns} --target-type bess "$SOCK" &
      ${getExe linux} \
        mem=2G \
        init=${sys.config.system.build.toplevel}/init \
        initrd=${sys.config.system.build.initialRamdisk}/${sys.config.system.boot.loader.initrdFile} \
        "vec0:transport=bess,dst=$SOCK" \
        con=null con0=null,fd:2 con1=fd:0,fd:1 \
        ${toString sys.config.boot.kernelParams}
      { set +x; } 2>/dev/null
      jobs -p | ${getExe' pkgs.findutils "xargs"} -rn10 kill
    '';
    # when trying to debug boot problems / enter rescue, set kernel parameters:
    #    SYSTEMD_SULOGIN_FORCE=1
    #    con0=fd:0,fd:1 con1=null,fd:2
    #    systemd.unit=rescue.target
    # something like this is also possible instead of mounting hostfs:
    #   root=/dev/ubda
    #   ubd0=${pkgs.callPackage "${nixpkgs}/nixos/lib/make-ext4-fs" { storePaths = [ sys.config.system.build.toplevel ]; }}
  in {
    packages.${pkgs.system} = {
      default = bin;
      script = pkgs.runCommand "umlvm-run" {} ''
        ln -s ${bin}/bin/umlvm $out
      '';
      # for inspection
      etc = sys.config.system.build.etc;
      top = sys.config.system.build.toplevel;
      config = cfg;
    };
    apps.${pkgs.system} = {
      # nix run .#image | docker image load
      # docker run --tmpfs /dev/shm:rw,nosuid,nodev,exec,size=2g --rm -ti umlvm:latest
      image = {
        type = "app";
        program = "${pkgs.dockerTools.streamLayeredImage {
          maxLayers = 2;
          name = "umlvm";
          tag = "latest";
          fromImage = null;
          config.Entrypoint = [(getExe bin)];
        }}";
      };
    };
    nixosConfigurations.umlvm = sys;
  };

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable"; # branch pr-10
}
