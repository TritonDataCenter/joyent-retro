# Introduction

NOTE: this is still experimental, not really intended for wide use but has been
working well for creating builds for some time.

This repo is used to build a standalone SmartOS image for running in KVM or
Bhyve on SmartOS. Originally, it was used for running ancient images (e.g.,
20130506T233003Z, 20141030T081701Z, or some other ancient build) which we use
for building bits intended to be run on a wide range of platforms. This
decouples the build agent platform image from the underlying compute node
image to give us a stable build target.

## Screenshot

```txt
   _____ _____ _____ _____ _____ _____ _____    _____ _____ _____ _____ _____
  |   __|     |  _  | __  |_   _|     |   __|  | __  |   __|_   _| __  |     |
  |__   | | | |     |    -| | | |  |  |__   |  |    -|   __| | | |    -|  |  |
  |_____|_|_|_|__|__|__|__| |_| |_____|_____|  |__|__|_____| |_| |__|__|_____|

                                         SmartOS Live Image v0.147+
                                          build: 20130506T233003Z

                                 .       .
                                / `.   .' \
                        .---.  <    > <    >  .---.
                        |    \  \ - ~ ~ - /  /    |
                         ~-..-~             ~-..-~
                     \~~~\.'                    `./~~~/
           .-~~^-.    \__/                        \__/
         .'  O    \     /               /       \  \
        (_____,    `._.'               |         }  \/~~~/
         `----.          /       }     |        /    \__/
               `-.      |       /      |       /      `. ,~~|
                   ~-.__|      /_ - ~ ^|      /- _      `..-'   f: f:
                        |     /        |     /     ~-.     `-. _||_||_
                        |_____|        |_____|         ~ - . _ _ _ _ _>


oldskool ttya login:
```

## How it works

Basically what the build script in this repo does is to take a platform image
from a build of SmartOS and turn it into an HVM-bootable zvol. Along the way,
it makes a few changes to make the resulting image work better as a virtual
machine, including:

* fixing mdata tools on old platforms
* fixing ntp tools / scripts on old platforms
* updating to latest CA certificates
* removing the default password
* disabling drivers that don't work in HVM (like kvm/bhyve)
* automatically creating a zpool on first boot
* disabling other services that don't make sense
* creating a vswitch and nat/ipf rules for an "internal" 172.16.9.0/24 network
* loading authorized keys from `root_authorized_keys` metadata like other HVM
  images
* creating an image manifest for importing into an imgapi

So, the resulting image can be created using the regular process for creating
an HVM VM (triton cli, cloudapi, vmapi), and the small root image (1G currently)
contains the modified platform and the custom bits.

The "root" disk image will act like a USB Key to the system and contains all the
bits and other components required to boot. On first boot, the scripts
will create a zpool on the second disk that HVM VMs get as their data disk. The
custom bits will be unpacked and the manifests for the custom services will be
loaded. The metadata will be read, so the `authorized_keys` for root will have
those keys specified for the Triton user who owns the VM.

At that point, the owner can SSH into this system and create a VM. The template
/opt/custom/etc/zone.json.tmpl is provided to help with creating a VM that will
work with the default networking setup.

## Performing a Build

### Prerequisites

* the zone you build in must have a delegated dataset
* the zone you build in must have pcfs and ufs in `fs_allowed`
* the build must run with root permissions

### Building

Download the platform image you want to use into a directory data/ under the top
of this repo with the name `platform-<BUILDSTAMP>.tgz`. E.g.:

```shell
mkdir -p data
curl -o data/platform-20141030T081701Z.tgz https://us-east.manta.joyent.com/Joyent_Dev/public/builds/platform/release-20141030-20141030T081701Z/platform/platform-release-20141030-20141030T081701Z.tgz
```

Then run `./build.sh <BUILDSTAMP>`, so continuing the example:

```shell
./build.sh 20141030T081701Z
```

The build will take a while, but when this process is complete, it should result
in files being created in the output/ directory that look like:

```shell
# ls -l output/
total 160747
-rw-r--r-- 1 root root       808 Apr 22 22:18 smartos-retro-20141030T081701Z-1.0.9.manifest
-rw-r--r-- 1 root root 164408689 Apr 22 22:17 smartos-retro-20141030T081701Z-1.0.9.zvol.gz
#
```

These files can be pushed to an imgapi (using for example the [SDC imgapi cli
tools](https://github.com/TritonDataCenter/sdc-imgapi-cli). Or pulled into a
local machine using something like:

```shell
imgadm install -f smartos-retro-20141030T081701Z-1.0.9.zvol.gz -m smartos-retro-20141030T081701Z-1.0.9.manifest
```

or:

```shell
sdc-imgadm import -f smartos-retro-20141030T081701Z-1.0.9.zvol.gz -m smartos-retro-20141030T081701Z-1.0.9.manifest
```

depending whether one wants to provision using `vmadm` or some component that
goes through the Triton stack.

## Supported Platforms

This tool has been tested with platforms as old as 20130506T233003Z and
20141030T081701Z.

## Development Notes

Whenever you make a change to this repo, you should update the version in
package.json before building. That file is *not* used by npm, but is used to
determine the version for the build.

When testing, you can run:

```shell
TRACE=1 ./build.sh <BUILDSTAMP>
```

to enable xtrace logging from the build script.

## Future Work

* Setup additional interfaces as part of the smartos-setup script. Ideally, all
  interfaces preset in `sdc:nics` should be plumbed. If there are fabric
  networks. Maybe allow SSH from only those?
* Script for building a simple zone using the /opt/custom/etc/zone.json.tmpl so
   that networking works.
* Smaller (256M?) USB template image so we can import even faster.
* Ability to customize network (e.g., nat) setup if desired?
* When something goes horribly wrong in the init process, we should generate a
   root password which allows the person debugging to get in and figure it out.
