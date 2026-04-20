#!/bin/bash
# use-build.sh
# Flips the installed Inca build by updating CLUtil's persistent config AND
# the ~/.expresso_master_version env file (the gnome-startup-custom.sh fallback).
#
# Deploy to the bike as /usr/local/bin/use-2013 and /usr/local/bin/use-2018,
# either as symlinks to use-build.sh or as `alias use-2018=use-build 20180514001`.
#
# Usage:
#   use-build 20130123001   # explicit version
#   use-2013                # alias, assumes installed as symlink named use-2013
#   use-2018
#
# Does NOT reboot — call `sudo reboot` yourself after.
set -euo pipefail

EXPRESSO=/usr/local/expresso
CLUTIL=$EXPRESSO/bin/CLUtil

# Resolve intent: explicit arg, or derive from invocation name.
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    VERSION="$1"
else
    case "$(basename "$0")" in
        use-2013) VERSION=20130123001 ;;
        use-2018) VERSION=20180514001 ;;
        use-2012) VERSION=20121106001 ;;
        *) echo "Usage: $(basename "$0") <version-dir-name>" >&2; exit 1 ;;
    esac
fi

if [[ ! -d "$EXPRESSO/$VERSION" ]]; then
    echo "FATAL: $EXPRESSO/$VERSION does not exist. Installed builds:" >&2
    ls -1d "$EXPRESSO"/2* 2>/dev/null >&2
    exit 2
fi

echo "Current: $($CLUTIL -p --configuration GetVersion)"
echo "Target:  $VERSION"

$CLUTIL --configuration SetVersion "$VERSION"
echo "EXPRESSO_MASTER_VERSION=$VERSION" > /home/expresso/.expresso_master_version
chown expresso:expresso /home/expresso/.expresso_master_version

echo "Switched to $VERSION. Reboot to load: sudo reboot"
