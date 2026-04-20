# Coldbrew game control — append this to the expresso user's ~/.bashrc on
# the bike (bike-sync.sh does that automatically). Adjust BUILD to match
# whatever version the bike actually runs (ls /usr/local/expresso/).
BUILD=20180514001
alias game-stop='sudo killall Inca Launcher 2>/dev/null; echo stopped'
alias game-start="export DISPLAY=:0 EXPRESSO=/usr/local/expresso EXPRESSO_MASTER_VERSION=\$BUILD; cd /usr/local/expresso && nohup ./\$BUILD/bin/Launcher > /tmp/launcher.log 2>&1 &"
alias game-restart="sudo killall Inca Launcher 2>/dev/null; sleep 2; export DISPLAY=:0 EXPRESSO=/usr/local/expresso EXPRESSO_MASTER_VERSION=\$BUILD; cd /usr/local/expresso && nohup ./\$BUILD/bin/Launcher > /tmp/launcher.log 2>&1 & echo restarting"
alias game-status='ps aux | grep -E "Inca|Launcher|Dispenser" | grep -v grep'
alias bike-sleep='bash ~/bike-sleep.sh'
alias bike-wake='bash ~/bike-wake.sh'
