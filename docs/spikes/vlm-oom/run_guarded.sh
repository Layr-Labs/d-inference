#!/bin/bash
# Guarded single run of the VLM-OOM probe.
#
# Samples the probe's RSS every 50 ms and SIGKILLs it the instant it crosses a
# hard ceiling OR system-available memory drops below a floor — so the probe can
# never jetsam-kill the co-resident provider on this 0-swap box. Reports the
# peak RSS it observed (works whether the probe completes or is killed).
#
# usage: run_guarded.sh <png> <decode|naive|mlxpath> [target=448]
set -u
PROBE=${PROBE:-./oom_probe}
PG=16384                                       # vm_stat page size on this box
CEIL_KB=${CEIL_KB:-$(( 14 * 1024 * 1024 ))}    # harness RSS ceiling: 14 GB
FLOOR_B=${FLOOR_B:-$(( 10 * 1024 * 1024 * 1024 ))}  # system-available floor: 10 GB

png="$1"; mode="$2"; target="${3:-448}"

avail_bytes() {
  vm_stat | awk -v pg=$PG '
    /Pages free/{f=$3} /Pages inactive/{i=$3}
    /Pages speculative/{s=$3} /Pages purgeable/{p=$3}
    END{gsub(/\./,"",f);gsub(/\./,"",i);gsub(/\./,"",s);gsub(/\./,"",p);
        print (f+i+s+p)*pg}'
}

echo "----- $png  mode=$mode target=$target  (ceiling $((CEIL_KB/1024/1024))GB, floor $((FLOOR_B/1024/1024/1024))GB) -----"
av0=$(avail_bytes); echo "   system available before: $((av0/1024/1024/1024)) GB"

"$PROBE" "$png" "$mode" "$target" >/tmp/probe.out 2>&1 &
pid=$!
peak=0; killed=""
while kill -0 "$pid" 2>/dev/null; do
  rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
  if [ -n "$rss" ]; then
    [ "$rss" -gt "$peak" ] && peak=$rss
    if [ "$rss" -gt "$CEIL_KB" ]; then
      echo "   !! harness RSS $((rss/1024/1024)) GB > ceiling — SIGKILL (protecting box)"
      kill -9 "$pid" 2>/dev/null; killed="ceiling"; break
    fi
  fi
  av=$(avail_bytes)
  if [ -n "$av" ] && [ "$av" -lt "$FLOOR_B" ]; then
    echo "   !! system available $((av/1024/1024/1024)) GB < floor — SIGKILL (protecting box)"
    kill -9 "$pid" 2>/dev/null; killed="floor"; break
  fi
  sleep 0.05
done
wait "$pid" 2>/dev/null
sed 's/^/   /' /tmp/probe.out
awk -v p=$peak 'BEGIN{printf "   ==> PEAK harness RSS: %d MB (%.2f GB)\n", p/1024, p/1024/1024}'
echo "   killed=${killed:-no}"
av1=$(avail_bytes); echo "   system available after: $((av1/1024/1024/1024)) GB"
