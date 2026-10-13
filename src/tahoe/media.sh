#!/bin/sh
set -e
cd /tmp
rm -f finch.img finch.img.gz
dd if=/dev/zero of=finch.img bs=1m count=24 2>/dev/null
d=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage finch.img | head -1 | cut -f1 | tr -d ' ')
diskutil partitionDisk $d GPT MS-DOS FINCHESP 6m APFS finch R >/dev/null
diskutil mount finch >/dev/null 2>&1 || true
m=/Volumes/finch
printf 'hello from tahoe\n' > $m/hello.txt
mkdir -p $m/System/Library
printf 'finch\n' > $m/System/Library/name
ln -s hello.txt $m/link
diskutil unmount $m >/dev/null
ioreg -p IOService -w0 -r -l -c IOBlockStorageDriver |
  awk -v disk="${d#/dev/}" 'BEGIN{key="\"BSD Name\" = \"" disk "\""} /^\+-o IOBlockStorageDriver/{if(found)exit; blk=""} {blk=blk $0 "\n"} index($0,key){found=1} END{if(found) printf "%s", blk}'
hdiutil detach $d >/dev/null
gzip -9 -c finch.img > finch.img.gz
