#!/bin/bash

set -e

SOURCES_DIR=/tmp/artifacts/
DISTRIBUTION_ZIP="jboss-eap-6.4.0.zip"
EAP_VERSION="6.4"

unzip -q $SOURCES_DIR/$DISTRIBUTION_ZIP
mv jboss-eap-$EAP_VERSION $JBOSS_HOME

$JBOSS_HOME/bin/jboss-cli.sh --command="patch apply $SOURCES_DIR/jboss-eap-6.4.9-patch.zip"
$JBOSS_HOME/bin/jboss-cli.sh --command="patch apply $SOURCES_DIR/jboss-eap-6.4.15-patch.zip"

# https://issues.jboss.org/browse/CLOUD-1260
# https://issues.jboss.org/browse/CLOUD-1431
function remove_scrapped_jars {
  for file in $(find $JBOSS_HOME -name \*.jar); do
    if ! jar -tf  $file &> /dev/null; then
      echo "Cleaning up '$file' jar..."
      rm -rf $file
    fi
  done

  # https://issues.jboss.org/browse/CLOUD-1430
  find $JBOSS_HOME/bundles/system/layers/base/.overlays -type d -empty -delete
}

function update_permissions {
  chown -R jboss:root $JBOSS_HOME
  chmod 0755 $JBOSS_HOME
  chmod -R g+rwX $JBOSS_HOME
}

function aggregate_patched_modules {
  export JBOSS_PIDFILE=/tmp/jboss.pid
  cp -r $JBOSS_HOME/standalone /tmp/

  $JBOSS_HOME/bin/standalone.sh --admin-only -Djboss.server.base.dir=/tmp/standalone &

  start=$(date +%s)
  end=$((start + 120))
  until $JBOSS_HOME/bin/jboss-cli.sh --command="connect" || [ $(date +%s) -ge "$end" ]; do
    sleep 5
  done

  timeout 30 $JBOSS_HOME/bin/jboss-cli.sh --connect --command="/core-service=patching:ageout-history"
  timeout 30 $JBOSS_HOME/bin/jboss-cli.sh --connect --command="shutdown"

  # give it a moment to settle
  for i in $(seq 1 10); do
      test -e "$JBOSS_PIDFILE" || break
      sleep 1
  done

  # EAP still running? something is not right
  if test -e "$JBOSS_PIDFILE"; then
      echo "EAP instance still running; aborting" >&2
      exit 1
  fi

  rm -rf /tmp/standalone
}

aggregate_patched_modules
remove_scrapped_jars
update_permissions

# Enhance standalone.sh to make remote JAVA debugging possible by specifying
# DEBUG=true environment variable
sed -i 's|DEBUG_MODE=false|DEBUG_MODE="${DEBUG:-false}"|' $JBOSS_HOME/bin/standalone.sh
sed -i 's|DEBUG_PORT="8787"|DEBUG_PORT="${DEBUG_PORT:-8787}"|' $JBOSS_HOME/bin/standalone.sh
#CLOUD-437
sed -i "s|-XX:MaxPermSize=256m||" $JBOSS_HOME/bin/standalone.conf