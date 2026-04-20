#!/bin/bash
# Stop game, kill GPU fan, sleep screen
sudo killall Inca Launcher Dispenser 2>/dev/null
sleep 2
DISPLAY=:0 nvidia-settings -a '[gpu:0]/GPUFanControlState=1' -a '[fan:0]/GPUCurrentFanSpeed=0' 2>/dev/null
for d in 2 3 4; do echo 0 | sudo tee /sys/class/thermal/cooling_device${d}/cur_state > /dev/null; done
DISPLAY=:0 xset dpms force off
echo 'Bike sleeping. GPU fan off, screen off.'
echo '(CPU fan is BIOS-managed; quiets as chip cools over ~5min)'
