#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
	echo "Usage: $0 STOCK_LOG ROCKNIX_LOG" >&2
	exit 1
fi

stock_log=$1
rocknix_log=$2

for f in "$stock_log" "$rocknix_log"; do
	if [[ ! -f "$f" ]]; then
		echo "Not a file: $f" >&2
		exit 1
	fi
done

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

extract_devmem() {
	awk '
		/^=== devmem / {
			label=$3
			sub(/^label=/, "", label)
			next
		}
		/^0x[0-9a-fA-F]+ = / {
			addr=$1
			value=$3
			if (label != "" && value ~ /^0x[0-9a-fA-F]+$/) {
				printf "%s %s %s\n", label, addr, value
			}
		}
	' "$1" | sort -k1,1 -k2,2
}

extract_devmem "$stock_log" > "$tmpdir/stock.tsv"
extract_devmem "$rocknix_log" > "$tmpdir/rocknix.tsv"

awk '
	FNR == NR {
		stock[$1 SUBSEP $2] = $3
		keys[$1 SUBSEP $2] = $1 " " $2
		next
	}
	{
		rock[$1 SUBSEP $2] = $3
		keys[$1 SUBSEP $2] = $1 " " $2
	}
	END {
		printf "%-30s %-12s %-12s %-12s %s\n", "block", "addr", "stock", "rocknix", "xor"
		for (k in keys) {
			s = stock[k]
			r = rock[k]
			if (s == "" || r == "" || s == r)
				continue
			sn = strtonum(s)
			rn = strtonum(r)
			split(keys[k], parts, " ")
			printf "%-30s %-12s %-12s %-12s 0x%08x\n", parts[1], parts[2], s, r, xor(sn, rn)
		}
	}
' "$tmpdir/stock.tsv" "$tmpdir/rocknix.tsv" | sort -k1,1 -k2,2

