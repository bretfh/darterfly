#!/bin/sh
set -e
cd /tmp
hdiutil info | awk '/image-path.*\/finch\.img$/{f=1; next} f && /^\/dev\/disk[0-9]+[ \t]/{print $1; f=0}' | while read d; do hdiutil detach -force $d >/dev/null; done
rm -f finch.img finch.img.gz
dd if=/dev/zero of=finch.img bs=1m count=24 2>/dev/null
d=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage finch.img | head -1 | cut -f1 | tr -d ' ')
diskutil partitionDisk $d GPT MS-DOS FINCHESP 6m APFS finch R >/dev/null
diskutil mount finch >/dev/null 2>&1 || true
m=/Volumes/finch
echo "$FINCH_PASSWORD" | sudo -S sh -c "diskutil enableOwnership $m && chown $(id -u):$(id -g) $m" >/dev/null 2>&1
printf 'hello from tahoe\n' > $m/hello.txt
mkdir -p $m/System/Library
printf 'finch\n' > $m/System/Library/name
ln -s hello.txt $m/link
mkdir $m/many
for i in $(seq 1 300); do echo "file $i" > $m/many/f$i; done
awk 'BEGIN{for(i=0;i<20000;i++) printf "line %05d of a file that spans several blocks\n", i}' > $m/big.txt
printf 'accent\n' > "$m/café.txt"
diskutil unmount $m >/dev/null
diskutil mount readOnly finch >/dev/null
(cd $m && find . -path ./.fseventsd -prune -o -print | LC_ALL=C sort | while IFS= read -r f; do
  if [ -f "$f" ] && [ ! -L "$f" ]; then sum=$(md5 -q "$f"); else sum=-; fi
  stat -f "%N|%HT|%Lp|%z|%i|%l|%u|%g|%Y|$sum" "$f"
done) > /tmp/finch-files.txt
diskutil unmount $m >/dev/null
ioreg -p IOService -w0 -r -l -c IOBlockStorageDriver |
  awk -v disk="${d#/dev/}" 'BEGIN{key="\"BSD Name\" = \"" disk "\""} /^\+-o IOBlockStorageDriver/{if(found)exit; blk=""} {blk=blk $0 "\n"} index($0,key){found=1} END{if(found) printf "%s", blk}'
hdiutil detach $d >/dev/null
gzip -9 -c finch.img > finch.img.gz
