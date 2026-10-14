#!/bin/sh
cd /tmp
d=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage finch-check.img | head -1 | cut -f1 | tr -d ' ')
fsck_apfs -n $d 2>&1
v=$(diskutil list | awk -v d="${d#/dev/}" '/Physical Store/ && $0 ~ d {found=1} found && /APFS Volume/ {print $NF; exit}')
echo "--- volume $v"
mkdir -p /tmp/finch-mnt
if diskutil mount readOnly -mountPoint /tmp/finch-mnt $v >/dev/null 2>&1; then
  (cd /tmp/finch-mnt && find . -path ./.fseventsd -prune -o -print | LC_ALL=C sort | while IFS= read -r f; do
    if [ -f "$f" ] && [ ! -L "$f" ]; then sum=$(md5 -q "$f"); else sum=-; fi
    stat -f "%N|%HT|%Lp|%z|%i|%l|%u|%g|%Y|$sum" "$f"
  done)
  diskutil unmount /tmp/finch-mnt >/dev/null 2>&1
else
  echo "--- mount failed"
fi
hdiutil detach $d -force >/dev/null 2>&1
true
