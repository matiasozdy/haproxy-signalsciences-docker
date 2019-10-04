Usage:
docker build -t haproxysigsci .
docker run --name hapsig -p 8443:8443 -e ENVIRONMENT=ENV -e SIGSCI_ACCESSKEYID=ID -e SIGSCI_SECRETACCESSKEY=KEY -e SIGSCI_ENABLED=true|false haproxysigsci
