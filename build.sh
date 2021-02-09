#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2017, Joyent, Inc.
#

#
# Usage: build.sh [<platform_version>]
#

if [[ -n ${TRACE} ]]; then
    set -o xtrace
fi

function usage {
    echo "Usage: $(basename $0) <platform_stamp>" >&2
}

if [[ $(uname -s) != 'SunOS' ]]; then
    echo "FATAL: This must only be run on SmartOS" >&2
    exit 2
fi

if [[ -z $(zfs list -H -o name zones/$(zonename)/data) ]]; then
    echo "FATAL: Must have a delegated dataset zones/$(zonename)/data" >&2
    usage
    exit 2
fi

set -o errexit

# Reminder: If these ever change, we'll need to change img/manifest.tmpl too
# for the new image_size.
IMAGE=1gb
ZVOL_SIZE=1g # of course it needs a different format

TOP=`pwd`

# We download a recent set of CA certs since the ones in ancient platforms are
# ancient. See https://curl.haxx.se/docs/caextract.html
CERT_URL="https://curl.se/ca/cacert.pem"

PLATFORM_VERSION=$1
if [[ -z ${PLATFORM_VERSION} ]]; then
    echo "FATAL: Must specify platform version" >&2
    exit 2
fi
PLATFORM="platform-${PLATFORM_VERSION}.tgz"
VERSION=$(json version <${TOP}/package.json)

if [[ -z ${VERSION} ]]; then
    echo "FATAL: Failed to get version from ${TOP}/package.json" >&2
    exit 2
fi

if [[ ! -f data/${PLATFORM} ]]; then
    echo "Missing ${PLATFORM}" >&2
    echo "Maybe try /Joyent_Dev/public/old_platform_builds or wherever..." >&2
    echo "Then put it in ${TOP}/data named '${PLATFORM}' and try again" >&2
    exit 2
fi

# get ready
echo "=> Cleaning up from previous run..."
mkdir -p usbmnt platmnt stage
rm -f stage/${IMAGE}.img
umount ${TOP}/platmnt || /bin/true
umount ${TOP}/usbmnt || /bin/true
lofiadm -d ${TOP}/stage/${IMAGE}.img || /bin/true

# Need a recent CA cert
echo "=> Checking CA certs..."
ca_cert_age=$(date +%s)
if [[ -f data/ca-bundle.crt ]]; then
    ca_cert_age=$((${ca_cert_age} \
        - $(/usr/bin/stat --format %Y data/ca-bundle.crt)))
fi
if [[ ${ca_cert_age} -gt 86400 ]]; then
    # CA certs so curl https:// can work
    echo "=> Grabbing latest CA certs... (current is ${ca_cert_age}s old)"
    mkdir -p custom/etc/ssl/certs
    curl -o data/ca-bundle.crt.new ${CERT_URL}
    if [[ $? -eq 0 && -s data/ca-bundle.crt.new ]]; then
        mv data/ca-bundle.crt.new data/ca-bundle.crt
    fi
    if [[ ! -f data/ca-bundle.crt ]]; then
        echo "** Failed to get CA bundle"
        exit 1
    fi
    ca_bundle_size=$(/usr/bin/stat --format %s data/ca-bundle.crt)
    if [[ ${ca_bundle_size} -lt 200000 ]]; then
        echo "** Failed to get CA bundle (too small)"
        exit 1
    fi
fi
cp ./data/ca-bundle.crt custom/etc/ssl/ca-bundle.crt

EXCLUDES=
# New mdata-get (that works in the GZ) was added with TOOLS-292 in Oct 2013.
# To be safe, we'll just copy in the hacked version to any build before 2014.
# The hacked version works even on newer platforms.
echo "=> Building /opt/custom tarball..."
[[ ${PLATFORM_VERSION} > "20140101T000000Z" ]] \
    && EXCLUDES="${EXCLUDES} --exclude=custom/bin/mdata-*"
# Backported ntpd/ntpq for old platforms
[[ ${PLATFORM_VERSION} > "20151103T000000Z" ]] \
    && EXCLUDES="${EXCLUDES} --exclude=custom/bin/ntp*"
gtar ${EXCLUDES} -zcvf stage/custom.tgz custom

# unpack and mount image
echo "=> Unpacking/Mounting USB template image..."
(cd stage && gtar -zxvf ../usb/${IMAGE}.img.tgz)
LOOPBACK=$(lofiadm -a stage/${IMAGE}.img)
mount -F pcfs -o foldcase ${LOOPBACK}:c ${TOP}/usbmnt

# copy in data files
echo "=> Copying /opt/custom tarball..."
cp stage/custom.tgz ${TOP}/usbmnt

# build a grub config
# Rescue mode password is 'root'
echo "=> Creating grub menu.lst..."
(cat > ${TOP}/usbmnt/boot/grub/menu.lst)<< EOF
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2017, Joyent, Inc.
#

default 0
timeout 10
min_mem64 1024
serial --speed=115200 --unit=1,0,2,3 --word=8 --parity=no --stop=1
terminal composite

title Live 64-bit
kernel /os/${PLATFORM_VERSION}/platform/i86pc/kernel/amd64/unix -B console=ttya,ttya-mode="115200,8,n,1,-",smartos=true,disable-ehci=true,disable-uhci=true,disable-kvm=true
module /os/${PLATFORM_VERSION}/platform/i86pc/amd64/boot_archive
module /os/${PLATFORM_VERSION}/platform/i86pc/amd64/boot_archive.hash

title Live 64-bit Rescue (no importing zpool)
kernel /os/${PLATFORM_VERSION}/platform/i86pc/kernel/amd64/unix -B console=ttya,ttya-mode="115200,8,n,1,-",smartos=true,root_shadow='\$5\$2HOHRnK3\$NvLlm.1KQBbB0WjoP7xcIwGnllhzp2HnT.mDO7DpxYA',noimport=true,disable-ehci=true,disable-uhci=true,disable-kvm=true
module /os/${PLATFORM_VERSION}/platform/i86pc/amd64/boot_archive
module /os/${PLATFORM_VERSION}/platform/i86pc/amd64/boot_archive.hash

title Live 64-bit +kmdb
kernel /os/${PLATFORM_VERSION}/platform/i86pc/kernel/amd64/unix -kd -B console=ttya,ttya-mode="115200,8,n,1,-",smartos=true,disable-ehci=true,disable-uhci=true,disable-kvm=true
module /os/${PLATFORM_VERSION}/platform/i86pc/amd64/boot_archive
module /os/${PLATFORM_VERSION}/platform/i86pc/amd64/boot_archive.hash
EOF

echo "=> Copying in platform..."
set +o errexit
(cd usbmnt \
    && gtar --no-same-owner \
        --exclude=root.password \
        --exclude=boot_archive.gitstatus \
        -zxvf ../data/platform-${PLATFORM_VERSION}.tgz \
    && mkdir -p os/${PLATFORM_VERSION} \
    && mv platform-*$(echo ${PLATFORM_VERSION} | tr [:upper:] [:lower:]) \
        os/${PLATFORM_VERSION}/platform)
set -o errexit

### make changes in the platform's boot_archive!
echo "=> Mounting platform..."
mount -F ufs \
    ${TOP}/usbmnt/os/${PLATFORM_VERSION}/platform/i86pc/amd64/boot_archive \
    ${TOP}/platmnt

# We set the password field in shadow to NP which means the user can not login
# using a password, but can still login via SSH keys.
echo "=> Removing password..."
gsed -i -e "s|^root:[^\:]*:|root:NP:|" ${TOP}/platmnt/etc/shadow

echo "=> Applying overlay..."
rsync -va overlay/ ${TOP}/platmnt/
# Fix version in issue
gsed -i -e "s|{{PLATFORM_VERSION}}|${PLATFORM_VERSION}|g" \
    ${TOP}/platmnt/etc/issue

echo "=> Unmounting platform..."
umount ${TOP}/platmnt

echo "=> Rebuilding boot_archive.hash..."
digest -a sha1 ${TOP}/usbmnt/os/${PLATFORM_VERSION}/platform/i86pc/amd64/boot_archive \
    > ${TOP}/usbmnt/os/${PLATFORM_VERSION}/platform/i86pc/amd64/boot_archive.hash

echo "=> Umounting USB image..."
umount ${TOP}/usbmnt
lofiadm -d ${LOOPBACK}
sync; sync # superstition

# We guaranteed earlier we have a delegated dataset, so we can use zfs commands
# here and actually create the image.
DATE=$(date +%Y-%m-%dT%H:%M:%S.000Z)
FILENAME_BASE="joyent-retro-${PLATFORM_VERSION}-${VERSION}"
UUID=$(uuid -v4)

DATASET="zones/$(zonename)/data/${UUID}"

echo "=> Creating zvol (${UUID})..."
zfs create -V ${ZVOL_SIZE} ${DATASET}

echo "=> Writing USB image to zvol..."
dd if=${TOP}/stage/${IMAGE}.img of=/dev/zvol/rdsk/${DATASET} bs=1M
sync; sync # superstition

echo "=> Exporting zvol image..."
zfs snapshot ${DATASET}@final
zfs send ${DATASET}@final > ${TOP}/stage/${FILENAME_BASE}.zvol
zfs destroy ${DATASET}@final
zfs destroy ${DATASET}

echo "=> Compressing zvol image..."
gzip -9 ${TOP}/stage/${FILENAME_BASE}.zvol
SIZE=$(/usr/bin/stat --format %s ${TOP}/stage/${FILENAME_BASE}.zvol.gz)
SHA1=$(/usr/bin/sum -x sha1 ${TOP}/stage/${FILENAME_BASE}.zvol.gz \
    | cut -d' ' -f1)

echo "=> Building manifest..."
cat img/manifest.tmpl | gsed \
    -e "s|{{DATE}}|${DATE}|g" \
    -e "s|{{PLATFORM}}|${PLATFORM_VERSION}|g" \
    -e "s|{{SIZE}}|${SIZE}|g" \
    -e "s|{{SHA1}}|${SHA1}|g" \
    -e "s|{{UUID}}|${UUID}|g" \
    -e "s|{{VERSION}}|${VERSION}|g" \
    > ${TOP}/stage/${FILENAME_BASE}.manifest

mkdir -p ${TOP}/output
mv ${TOP}/stage/${FILENAME_BASE}.* ${TOP}/output
echo "=> DONE!"
echo "=> OUTPUT:"
ls -l output/${FILENAME_BASE}.*

exit 0
