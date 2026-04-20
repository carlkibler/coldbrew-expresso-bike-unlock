#!/bin/sh
#
# Copyright 2009 - Expresso Fitness
# Custom GNOME startup script
#
# environment vars are set in .bash_profile
#

#
# change the nvidia settings
#
/usr/bin/nvidia-settings --assign="DigitalVibrance=500"
# Keep GPU fan quiet at idle; game will load at auto during Inca init
DISPLAY=:0 /usr/bin/nvidia-settings --assign='[gpu:0]/GPUFanControlState=1' --assign='[fan:0]/GPUCurrentFanSpeed=10'

/usr/bin/xgamma -gamma 1.15
echo "NVidia settings complete"

#
# kill any pid files
#
rm -f $EXPRESSO/*.pid
echo "Removed PID files"

#
# remove temp files
#
rm -rf $EXPRESSO/tmp/*
echo "Cleaned expresso tmp directory"

#
# get the version from the configuration
#
CLUTIL=$EXPRESSO/bin/CLUtil
if [ -x $CLUTIL ]
then
	VERSION=`$CLUTIL -p --configuration GetVersion`
else
	#
	# must fall back to the expresso env var
	# 
	VERSION=$EXPRESSO_MASTER_VERSION
fi

#
# if we read the version and it says unknown, we must use the master version
#
if [ "$VERSION" = "unknown" ]
then
	VERSION=$EXPRESSO_MASTER_VERSION
	#
	# now set the configuration to the master version
	#
	$CLUTIL --configuration SetVersion $EXPRESSO_MASTER_VERSION
fi	

#
# sleep 20 seconds for sound init
#
#sleep 20

#
# Fix sound level
#

amixer -c 0 set Front,0 100%
amixer -c 0 set Master,0 100%
amixer -c 0 set PCM,0 100%

#
# run launcher
#
exec $EXPRESSO/$VERSION/bin/Launcher

exit 0
