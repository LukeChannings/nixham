# Expects $dir, $limit (bytes) and $keep (archives per log).

for log in "$dir"/*.log; do
  [ -f "$log" ] || continue
  [ "$(wc -c <"$log")" -ge "$limit" ] || continue

  rm -f "$log.$((keep - 1)).bz2"
  i=$((keep - 1))
  while [ "$i" -gt 0 ]; do
    [ -f "$log.$((i - 1)).bz2" ] && mv "$log.$((i - 1)).bz2" "$log.$i.bz2"
    i=$((i - 1))
  done

  # launchd opens a job's stdio once, at spawn, and the job can never reopen
  # it: rotating by rename would leave the daemon writing to the renamed
  # inode forever. Truncating keeps the inode the daemon holds, and its
  # O_APPEND writes resume at offset 0. `cp -p` carries the log's owner and
  # mode onto the archive, which bzip2 then preserves.
  cp -p "$log" "$log.0" || continue
  : >"$log"
  bzip2 -9f "$log.0"
done
