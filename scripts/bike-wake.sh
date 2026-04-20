#!/bin/bash
# Restore GPU fan to auto, wake screen, start game
DISPLAY=:0 nvidia-settings -a '[gpu:0]/GPUFanControlState=0' 2>/dev/null
DISPLAY=:0 xset dpms force on
cd /usr/local/expresso && nohup ./20180514001/bin/Launcher > /tmp/launcher.log 2>&1 &
echo 'Bike waking. GPU fan auto, screen on, game starting.'
