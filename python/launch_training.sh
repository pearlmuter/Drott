#!/bin/bash
# Run from Drott/python/ directory
PYBIN=/Library/Frameworks/Python.framework/Versions/3.11/bin/python3
LOGFILE=/Users/emil/Desktop/claudcode/Drott/python/temp/training.log

export OMP_NUM_THREADS=8
export MKL_NUM_THREADS=8

> "$LOGFILE"

nohup "$PYBIN" -u train_drott.py \
  --channels 128 --iters 200 --eps 100 --sims 100 \
  --epochs 4 --histwindow 10 --arena 40 --threshold 0.45 --eval 40 --evalsims 25 \
  --temp-threshold 20 --dir-eps 0.25 --dir-alpha 0.3 \
  --export-every 5 --device cpu --resume >> "$LOGFILE" 2>&1 &
TPID=$!
echo $TPID > /Users/emil/Desktop/claudcode/Drott/python/temp/training.pid
echo "Training PID: $TPID" | tee -a "$LOGFILE"

# Keep awake until training exits (works on AC power; -i=idle, -s=system)
nohup caffeinate -si -w $TPID > /dev/null 2>&1 &
echo "caffeinate PID: $!" | tee -a "$LOGFILE"

# Graceful stop at 06:30
STOP_SECS=$("$PYBIN" -c "
import datetime
now = datetime.datetime.now()
t = now.replace(hour=7, minute=0, second=0, microsecond=0)
if t <= now: t += datetime.timedelta(days=1)
print(int((t - now).total_seconds()))
")
nohup sh -c "sleep $STOP_SECS && kill -INT $TPID && echo \"Stopped at \$(date)\" >> '$LOGFILE'" > /dev/null 2>&1 &
echo "Stop scheduled in ${STOP_SECS}s (07:00)" | tee -a "$LOGFILE"
