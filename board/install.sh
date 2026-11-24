#!/bin/sh
# heavyboard's first install on a shared web host with CGI (written for NearlyFreeSpeech): upload a folder
# with index.cgi (the FreeBSD build), .htaccess, password and, optionally, control-password, then run here:
#   sh install.sh [PUBLIC_DIR [DATA_DIR [WEB_GROUP]]]
# PUBLIC_DIR (default /home/public/heavy) gets index.cgi and .htaccess; DATA_DIR (default
# /home/protected/heavyboard, which the web cannot read; HEAVYBOARD_DATA must name it when it differs)
# gets the passwords, and the web server's group (default web) may write it.
set -e
PUBLIC=${1:-/home/public/heavy}
DATA=${2:-/home/protected/heavyboard}
GROUP=${3:-web}
mkdir -p "$PUBLIC" "$DATA"
cp index.cgi "$PUBLIC/index.cgi"
cp .htaccess "$PUBLIC/.htaccess"
chmod 755 "$PUBLIC/index.cgi"
for f in password control-password; do
  if [ -f "$f" ]; then cp "$f" "$DATA/$f"; chgrp "$GROUP" "$DATA/$f"; chmod 640 "$DATA/$f"; fi
done
chgrp "$GROUP" "$DATA"
chmod 770 "$DATA"
echo "installed into $PUBLIC"
