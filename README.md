# Docker in Linux in Docker

Make me a docker-linux-docker sandwich. No *sudo*s or *what, make it yourself*s.

## Docker in Docker

I can run docker in docker like this:
```console
$ docker run --privileged docker:dind
```
Or, god forbid¹, like this:
```console
$ docker run -v /var/run/docker.sock:/var/run/docker.sock docker:latest
```
But if I do that, I must give that inner docker and whatever has access to it
the same level of access as the outer docker has, which is quite likely root.

Now, there are only mild security implications for the (`docker.io/_/`)`docker` image itself,
but I was trying to encapsulate an application that relies on docker, and I was at a loss.

Now here's my fun little project. I can now run docker in docker like this:
```console
$ docker run --tmpfs /dev/shm:rw,nosuid,nodev,exec,size=2g -ti liftm/usmol
… (about a minute later) …

<<< Welcome to NixOS 24.11pre-git (x86_64) - tty1 >>>
…
[~]# docker run hello-world
…
Hello from Docker!
```
There is the sandwhich I wanted, docker running on linux running on docker.
It requires no special privileges, and works with rootless docker too. 

## Did I just run a linux VM in docker?

No. This is [User Mode Linux](https://www.kernel.org/doc/html/v5.9/virt/uml/user_mode_linux.html)².
Linux runs on a lot of things, and one of those things is linux.
So neither kvm nor any kind of instruction set emulation are involved.
When you check `ps` with this running, you'll see a `linux` running like any other user space process:
```
$ ps ax | grep linux
 777839 ?        Rs     0:26 linux mem=2G init=/tmp/usmol1/…
```

## This is cool. Would I do this for real?

No. For several reasons.

1. It's not smol.  
   ```console
   $ docker pull liftm/usmol
   latest: Pulling from liftm/usmol
   d76c97f8cf21: Downloading 4.2MB/412.7MB
   ```
   For comparison, `docker:dind` is only `134 MB`.

2. It's not fast.  
   User mode linux implements syscalls by having the outer ("host") linux redirect
   system calls from the inner linux user space to user mode linux through ptrace.
   The running user mode linux even subjectively feels a little sluggish.
   
   On top of that, my impelementation boots an entire (systemd-based) NixOS user space.
   NixOS is by no means a light distro.
   If I seriously wanted this, I should probably build on a lighter distro,
   or on some ptrace solution without linux, like proot.

3. User mode linux has lots of seemingly arbitrary limitations,
   like no `nat` table for `iptables` (making docker networking difficult).

4. You have to go through one more layer of wrapping,
   making handling volumes, command line arguments, and exit codes difficult.

5. I definitely won't be keeping this up-to-date.

## Can I do a few more tricks?

I can run this without the outer docker, just as a normal user on ~any kind of linux.

```bash
cd /tmp
mkdir usmol
cd usmol
regctl image export liftm/usmol ./img.tar # part of regclient
tar xf img.tar
jq -r '.[].Layers[]' manifest.json | xargs -n1 tar xf
mv tmp/usmol1 /tmp
/tmp/usmol1/run
```

I can also have it run a demo docker compose file,
that transfers a file from one container to another:

```bash
docker run --tmpfs /dev/shm:rw,nosuid,nodev,exec,size=2g --rm -ti liftm/usmol quiet usmol-run-compose-demo
```

Lastly, this does run in singularity, too:
```bash
singularity run --no-mount tmp --env TMPDIR=/dev/shm docker://liftm/usmol
```

## Footnotes

¹ This causes terrible headaches around volumes if you want to access files from the docker docker container.

² The acronym is terrible, and it's alternative name, linux-on-linux isn't helping with that either. Hence this repository being named USer MOde Linux.
