#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Make the raw payload image that the Chipyard VCU118 "sdboot" bootrom loads, and print the
# dd command to write it. It never writes to a device itself.
#
# sdboot (bringup-chipyard fpga/src/main/resources/vcu118/sdboot/sd.c, head.S) reads
# PAYLOAD_SIZE_B = 30 MiB of raw 512 B sectors from SD sector (LBA) 34
# (BBL_PARTITION_START_SECTOR) to PAYLOAD_DEST = 0x8000_0000 and jumps there with a0 = hartid,
# a1 = dtb (Zephyr ignores both). The image is therefore the flat binary of the ELF with its
# first byte at 0x8000_0000, which zephyr.bin already is for this non-XIP board. The script
# checks the ELF entry and lowest LOAD address.
#
# Usage: scripts/mk_sdboot_image.sh <zephyr.elf | zephyr.bin> [out.bin]
#   OBJCOPY=riscv64-zephyr-elf-objcopy  (default)
set -euo pipefail

IN="${1:?usage: $0 <zephyr.elf|zephyr.bin> [out.bin]}"
OUT="${2:-${IN%.*}.sdboot.bin}"
OBJCOPY="${OBJCOPY:-riscv64-zephyr-elf-objcopy}"
READELF="${READELF:-${OBJCOPY%objcopy}readelf}"
DEST=0x80000000
START_SECTOR=34
MAX=$((30 << 20))

if [ "$(head -c4 "$IN" | od -An -c | tr -d ' ')" = '177ELF' ]; then
  entry=$($READELF -h "$IN" | awk '/Entry point/{print $4}')
  low=$($READELF -lW "$IN" | awk '$1=="LOAD"{print $4}' | sort | head -1)
  [ $((entry)) -eq $((DEST)) ] || { echo "ELF entry $entry != $DEST: sdboot jumps to $DEST" >&2; exit 1; }
  [ $((low)) -eq $((DEST)) ] || { echo "lowest LOAD address $low != $DEST (XIP or relocated build?)" >&2; exit 1; }
  $OBJCOPY -O binary "$IN" "$OUT"
else
  cp "$IN" "$OUT"
  echo "note: input is not an ELF; assuming its first byte belongs at $DEST" >&2
fi

size=$(stat -c %s "$OUT")
[ "$size" -le "$MAX" ] || { echo "image is $size B > sdboot's 30 MiB payload window" >&2; exit 1; }
sectors=$(( (size + 511) / 512 ))
echo "image: $OUT  ($size B, $sectors sectors of 512 B)"
echo "sdboot loads 30 MiB from LBA $START_SECTOR to $DEST, then jumps to $DEST."
echo
echo "Write it (DOUBLE-CHECK the device; this destroys data at LBA $START_SECTOR..):"
echo "  sudo dd if=$OUT of=/dev/sdX bs=512 seek=$START_SECTOR conv=fsync status=progress"
echo "Then insert the card in the VCU118, load the bitstream, open the UART at 115200 8N1."
