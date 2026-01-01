#!/bin/sh
# Helper script to partition eMMC for JDC-1B
# This will create p1 = 26MB for storage, p2 = rest for others

DEV="/dev/mmcblk0"

if [ ! -b "$DEV" ]; then
    echo "Error: $DEV not found!"
    exit 1
fi

echo "Warning: This will ERASE all data on $DEV!"
echo "This will create:"
echo "  p1: 26MB (Storage Backing Store)"
echo "  p2: Remainder (Other use)"
echo ""

# Create partition table
# d - delete (up to 4 partitions)
# n - new
# p - primary
# 1 - partition 1
# [default start]
# +26M - size
# n - new
# p - primary
# 2 - partition 2
# [default start]
# [default end]
# w - write

fdisk $DEV <<EOF
d
1
d
2
d
3
d
4
n
p
1

+26M
n
p
2


w
EOF

echo ""
echo "Partitioning complete."
echo "Running mdev -s to refresh device nodes..."
mdev -s
echo "Done. You can now run mtd_storage.sh save to persist data."
