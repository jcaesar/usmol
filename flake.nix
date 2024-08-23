{
  outputs = {
    self,
    nixpkgs,
  }: let
    inherit (pkgs.lib) mkForce getExe recursiveUpdate;
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

        NF_TABLES m
        NF_CONNTRACK m
        INET y
        NETFILTER y
        NET y
        VLAN_8021Q y
        BRIDGE_NETFILTER m
        CGROUP_BPF y
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
          fileSystems.${builtins.storeDir} = {
            device = "host";
            fsType = "hostfs";
            options = [builtins.storeDir];
          };
          fileSystems."/mnt/host" = {
            device = "host";
            fsType = "hostfs";
          };

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

          networking.interfaces.eth0.ipv4.addresses = [
            {
              address = "10.0.2.15";
              prefixLength = 24;
            }
          ];
          networking.defaultGateway = "10.0.2.2";
          networking.nameservers = ["10.0.2.3"];

          virtualisation.docker.enable = true;
          virtualisation.docker.extraOptions = "--iptables=False";
          # todo
          nixpkgs.overlays = [
            (final: prev: {
              iptables = final.iptables-legacy;
            })
          ];

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
            # nonstandard part: we need extra_hosts since the internal dns relies on nat, which we don't have, and that needs static ips…
            compose.networks.default = {
              driver = "bridge";
              ipam.config = [
                {
                  subnet = "10.5.0.0/16";
                  "gateway" = "10.5.0.1";
                }
              ];
            };
            compose.services.serve.networks.default.ipv4_address = "10.5.0.5";
            compose.services.get.extra_hosts.serve = "10.5.0.5";

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
          eth0=slirp,,${pkgs.lib.getExe self.packages.${pkgs.system}.slirp} \
          con=null con0=null,fd:2 con1=fd:0,fd:1 \
          ${toString sys.config.boot.kernelParams}
      '';
      # when trying to debug boot problems / enter rescue, set kernel parameters:
      #    SYSTEMD_SULOGIN_FORCE=1
      #    con0=fd:0,fd:1 con1=null,fd:2
      #    systemd.unit=rescue.target
      # something like this is also possible instead of mounting hostfs:
      #   root=/dev/ubda
      #   ubd0=${pkgs.callPackage "${nixpkgs}/nixos/lib/make-ext4-fs" { storePaths = [ sys.config.system.build.toplevel ]; }}

      # getting networking to work without root requires some interesting archeology.
      # This thing's got 17 patches on debian, including two CVEs… and then it still doesn't compile
      slirp = pkgs.stdenv.mkDerivation rec {
        pname = "slirp";
        version = "1.0.17";
        src = let
          arc = pkgs.fetchzip {
            url = "mirror://sourceforge/project/slirp/slirp/1.0.16/slirp-1.0.16.tar.gz";
            hash = "sha256-0ZQCHMYcMZmRYlfdjNvmu6ZfY21Ux/1yJhUE3vnrjVo=";
          };
        in "${arc}/src";
        prePatch = ''
          ln -s . src # debian patches expect a different source structure
        '';
        patches = let
          fp = hash: patch:
            pkgs.fetchDebianPatch {
              inherit pname patch hash;
              version = "1:${version}";
              debianRevision = "11";
            };
        in [
          (
            pkgs.fetchpatch {
              url = "mirror://sourceforge/project/slirp/slirp/1.0.17%20patch/slirp_1_0_17_patch.tar.gz";
              hash = "sha256-LxJKrT1EOrciTpzLjntlsc1clOxBHK/N7nWXgEZbATM=";
            }
          )
          (fp "sha256-AuGLMyxMCYlmllyMrCNro1PpAnnRTDQgRjfIW1RIoso=" "001-update-man-fix-hyphens-as-minus.patch")
          # (fp "sha256-R12h1WfdwurtUlbQbVI6G5HYLFSnobd1oPsngBgXe0A=" "002-fix-arguements.patch") # typofix, doesn't apply
          (fp "sha256-RnmUQLrkn6d9lov+jv0eH0TL0hIeh9XR3xIt3LemCrg=" "003-socklen_t.patch")
          (fp "sha256-10PhVNr8zXR6QgEuVx5B49CoXi7R91p5ivKnnsWt/Kk=" "004-compilation-warnings.patch")
          (fp "sha256-FPJvUsLbAcPWwiLkdIoPmU8sz5xWg0ZTnHvpyzmOEFo=" "005-use-snprintf.patch")
          (fp "sha256-flcmAY88/Fb0W0i5/fU94nOlgJQ1ppEKa7IcGc5lHG8=" "006-changelog-1.0.17.patch")
          (fp "sha256-dzIIktX2VlSSguGmpa2eGW69a+MHSQ51S9q5dX3jj/0=" "007-debian-changes.patch")
          (fp "sha256-uvVAo4nVj2xXQjHKWiMmyedj9yjBqAgTQaelECD4H8s=" "008-slirp-amd64-log-crash.patch")
          # (fp "sha256-PKLB0hrA/VRQKl9LehXOrtWB7jiMiAFZGrX6kPdjR8g=" "009-i-hate-perl.patch") # nix doesn't
          (fp "sha256-vcBX5bxvtpc/cAfiqKHIKTmoF/v02bdOcjDopOCHWHs=" "010-fullbolt-fix.patch")
          (fp "sha256-vk7tBcpLHTg8iCAt1TrOtx3T/Bnnfqwllz6GY52Xt8E=" "011-sizeof_ipv4.patch")
          (fp "sha256-RRDKUYmodh4D0YKezl3SXcij74fTFzdp99Sz4TnielE=" "012_ipq64.patch")
          # (fp "sha256-ntMgLRmwZjbudhdhde+92qd0hs6akZzRF0nyEhwfUhU=" "013_hurd.patch") # it hurds
          (fp "sha256-U1Q/geKLtlXYDUe9pODb9V4WMSHDPVOtoYsGafUBEsU=" "014_CVE-2020-7039.patch")
          (fp "sha256-9uIEVLOflhUNYJqZc/K6Bkk2pE7l87H3SqThbbJUO4Q=" "015_949003_explicit_extern_declaration.patch")
          (fp "sha256-a76e59W73TtmouvoHSfYGeVB23TvrQpD/lsU3VxGrUw=" "016_c11b4078042_fix_64_bit_issue_in_slirp.patch")
          (fp "sha256-fMtF65AqETEPwDXfYr1uk/zUVdijYPuT1S3LKzcvodA=" "017_CVE-2020-8608.patch")
          ./slirp-build.patch
        ];
        env.NIX_CFLAGS_COMPILE = "-DFULL_BOLT"; # should be an option if packaged
        preInstall = ''
          mkdir -p $out/man/man1 $out/bin # Otherwise, the install script will install the executable in $out, naming it "bin"
        '';
        buildInputs = [pkgs.libxcrypt];
        meta.mainProgram = "slirp";
      };
      # for inspection
      etc = sys.config.system.build.etc;
      top = sys.config.system.build.toplevel;
      config = cfg;
    };
  };

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable"; # branch pr-10
}
