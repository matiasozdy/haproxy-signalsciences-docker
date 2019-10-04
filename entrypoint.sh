#!/bin/bash
DOCKERID=`hostname`
INSTHOST="$SIGSCI_HOSTNAME-$DOCKERID"
SIGSCI_SERVER_HOSTNAME=$INSTHOST
export STACK_ENVIRONMENT
export SIGSCI_ENABLED

## Required
if [[ -z "$ROOT_DOMAIN" ]]; then
    echo "ROOT_DOMAIN must be set"
    exit 1
fi

if [[ -z "$SIGSCI_ENABLED" ]]; then
    echo "SIGSCI_ENABLED must be set"
    exit 1
fi

j2 /tmp/haproxy.cfg.j2 > /usr/local/etc/haproxy/haproxy.cfg

if [[ $SIGSCI_ENABLED == "true" ]]; then
/usr/sbin/sigsci-agent &
sleep 10
fi
haproxy -db -W  -f /usr/local/etc/haproxy/haproxy.cfg
