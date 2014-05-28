#!/bin/sh

echo '--> abf-worker-lxc: restart.sh'

source ~/.bash_profile

if [[ `ps aux | grep god | grep -v gre |  wc -l` == "0" ]] ; then
  cd ~/abf-worker/current
  rm -f ~/abf-worker/shared/pids/*
  rvm ruby-2.1.1@abf-worker exec bundle exec rake abf_worker:clean_up ENV=production
  ENV=production VAGRANT_DEFAULT_PROVIDER=lxc INTERVAL=5 COUNT=1 QUEUE=rpm_worker_default,rpm_worker GROUP=rpm RESQUE_TERM_TIMEOUT=600 TERM_CHILD=1 CURRENT_PATH='/home/rosa/abf-worker/current' BACKGROUND=yes rvm ruby-2.1.1@abf-worker exec bundle exec god -c /home/rosa/abf-worker/current/config/abf-worker.god
else
  echo '--> worker is not dead'
  exit 1
fi
echo '--> worker restarted'
exit 0
