#!/bin/sh
# $1-5: crontab expr, eg: a/1 a a a a
# $6: script name
[ -z "$6" ] && exit 0
cd /etc/storage/
exp=`echo "$1 $2 $3 $4 $5" |sed 's/a/\*/g'`
cron_file="cron/crontabs/admin"
cron_cmd="$exp /usr/bin/$6 > /dev/null 2>&1"

mkdir -p "cron/crontabs"
[ -f "$cron_file" ] || : > "$cron_file"

tmp_file="${cron_file}.tmp.$$"
awk '!seen[$0]++' "$cron_file" > "$tmp_file" && mv "$tmp_file" "$cron_file"

if ! grep -Fqx "$cron_cmd" "$cron_file"; then
	echo "$cron_cmd" >> "$cron_file" && exit 1
fi
exit 0
