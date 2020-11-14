#!/bin/bash

# BSD 3-Clause License
# Author @sonique6784
# Copyright (c) 2020, sonique6784

function showRaSCSILogo(){
logo="""
    .~~.   .~~.\n
  '. \ ' ' / .'\n
   .╔═══════╗.\n
  : ║|¯¯¯¯¯|║ :\n
 ~ (║|_____|║) ~\n
( : ║ .  __ ║ : )\n
 ~ .╚╦═════╦╝. ~\n
  (  ¯¯¯¯¯¯¯  ) RaSCSI Assistant\n
   '~ .~~~. ~'\n
       '~'\n
"""
echo -e $logo
}

VIRTUAL_DRIVER_PATH=/home/pi/images
HFS_FORMAT=/usr/bin/hformat
HFDISK_BIN=/usr/bin/hfdisk
LIDO_DRIVER=~/RASCSI/lido-driver.img


function initialChecks() {
    currentUser=$(whoami)
    if [ "pi" != $currentUser ]; then
        echo "You must use 'pi' user (current: $currentUser)"
        exit 1
    fi

    if [ ! -d ~/RASCSI ]; then
        echo "You must checkout RASCSI repo into /user/pi/RASCSI"
        echo "$ git clone git@github.com:akuker/RASCSI.git"
        exit 2
    fi
}


# install all dependency packages for RaSCSI Service
# compile and install RaSCSI Service
function installRaScsi() {
    sudo apt-get update && sudo apt-get install --yes git libspdlog-dev

	cd ~/RASCSI/src/raspberrypi 
	make all CONNECT_TYPE=FULLSPEC 
	sudo make install CONNECT_TYPE=FULLSPEC

    sudoIsReady=$(sudo grep -c "rascsi" /etc/sudoers)

    if [ $sudoIsReady = "0" ]; then
        sudo bash -c 'echo "
# Allow the web server to restart the rascsi service
www-data ALL=NOPASSWD: /bin/systemctl restart rascsi.service
www-data ALL=NOPASSWD: /bin/systemctl stop rascsi.service
# Allow the web server to reboot the raspberry pi
www-data ALL=NOPASSWD: /sbin/shutdown, /sbin/reboot
" >> /etc/sudoers'
    fi
	
	sudo systemctl restart rsyslog
	sudo systemctl enable rascsi # optional - start rascsi at boot
	sudo systemctl start rascsi
	
}

# install everything required to run an HTTP server (Apache+PHP)
# configure PHP
# install 
function installRaScsiWebInterface() {
	
	sudo apt install apache2 php libapache2-mod-php -y
	
    sudo cp ~/RASCSI/src/php/* /var/www/html


    PHP_CONFIG_FILE=/etc/php/7.3/apache2/php.ini

    #Comment out any current configuration
    sudo sed -i.bak 's/^post_max_size/#post_max_size/g' $PHP_CONFIG_FILE
    sudo sed -i.bak 's/^upload_max_filesize/#upload_max_filesize/g' $PHP_CONFIG_FILE

    sudo bash -c 'PHP_CONFIG_FILE=/etc/php/7.3/apache2/php.ini && echo "
# RaSCSI high upload limits
upload_max_filesize = 1200M
post_max_size = 1200M

" >> $PHP_CONFIG_FILE'

    mkdir -p $VIRTUAL_DRIVER_PATH
    chmod -R 775 $VIRTUAL_DRIVER_PATH
    groups www-data
    sudo usermod -a -G pi www-data
    groups www-data

    sudo /etc/init.d/apache2 restart
}



function updateRaScsi() {
    sudo systemctl stop rascsi

	cd ~/RASCSI
	
	make clean
	make all CONNECT_TYPE=FULLSPEC
	sudo make install CONNECT_TYPE=FULLSPEC
	sudo systemctl start rascsi
}

function updateRaScsiWebInterface() {
    sudo /etc/init.d/apache2 stop
    cd ~/RASCSI
    git fetch --all
	cd ~/RASCSI/src/raspberrypi 
    sudo cp ~/RASCSI/src/php/* /var/www/html

    sudo /etc/init.d/apache2 start
}

function showRaScsiStatus() {
    sudo systemctl status rascsi
}

function createDrive600MB() {
    createDrive 600 "HD600"
}

function createDriveCustom() {
    driveSize=-1
    until [ $driveSize -ge "10" ] && [ $driveSize -le "4000" ]; do
        echo "What drive size would you like (in MB) (10-4000)"
        read driveSize

        echo "How would you like to name that drive?"
        read driveName
    done

    createDrive $driveSize "$driveName"
}

function formatDrive() {
    diskPath="$1"
    volumeName="$2"

    if [ ! -x $HFS_FORMAT ]; then
        # Install hfsutils to have hformat to format HFS
        sudo apt-get install hfsutils
    fi

    if [ ! -x $HFDISK_BIN ]; then
        # Clone, compile and install 'hfdisk', partition tool
        git clone git://www.codesrc.com/git/hfdisk.git
        cd hfdisk
        make
        
        sudo cp hfdisk /usr/bin/hfdisk
    fi

    # Inject hfdisk commands to create Drive with correct partitions
    (echo i; echo ; echo C; echo ; echo 32; echo "Driver_Partition"; echo "Apple_Driver"; echo C; echo ; echo ; echo "${volumeName}"; echo "Apple_HFS"; echo w; echo y; echo p;) | $HFDISK_BIN "$diskPath" 
    partitionOk=$?

    if [ $partitionOk -eq 0 ]; then
        if [ ! -f $LIDO_DRIVER ];then
            echo "Lido driver couldn't be found. Make sure RASCSI is up-to-date with git pull"
            return 1
        fi

        # Burn Lido driver to the disk
        dd if=$LIDO_DRIVER of="$diskPath" seek=64 count=32 bs=512 conv=notrunc

        driverInstalled=$?
        if [ $driverInstalled -eq 0 ]; then
            # Format the partition with HFS file system
            $HFS_FORMAT -l "${volumeName}" "$diskPath" 1
            hfsFormattedOk=$?
            if [ $hfsFormattedOk -eq 0 ]; then
                echo "Disk created with success."
            else
                echo "Unable to format HFS partition."
                return 4
            fi
        else
            echo "Unable to install Lido Driver."
            return 3
        fi
    else
        echo "Unable to create the partition."
        return 2
    fi
}

function createDrive() {
    if [ $# -ne 2 ]; then
        echo "To create a Drive, volume size and volume name must be provided"
        echo "$ createDrive 600 \"RaSCSI Drive\""
        echo "Drive wasn't created."
        return
    fi

    driveSize=$1
    driveName=$2
    mkdir -p $VIRTUAL_DRIVER_PATH
    drivePath="${VIRTUAL_DRIVER_PATH}/${driveSize}MB.hda"
    
    if [ ! -f $drivePath ]; then
        echo "Creating a ${driveSize}MB Drive"
        dd if=/dev/zero of=$drivePath bs=1M count=$driveSize

        echo "Formatting drive with HFS"
        formatDrive "$drivePath" "$driveName"

    else
        echo "Error: drive already exists"
    fi
}

function showMenu() {
    echo ""
    echo "Choose among the following options:"
    echo "INSTALL"
    echo "  0) install RaSCSI Service + web interface + 600MB Drive (recommended)"
    echo "  1) install RaSCSI Service (initial)"
    echo "  2) install RaSCSI Web interface"
    echo "UPDATE"
    echo "  3) update RaSCSI Service + web interface (recommended)"
    echo "  4) update RaSCSI Service"
    echo "  5) update RaSCSI Web interface"
    echo "CREATE EMPTY DRIVE"
    echo "  6) 600MB drive (recommended)"
    echo "  7) custom drive size (up to 4000MB)"


    choice=-1

    until [ $choice -ge "0" ] && [ $choice -le "7" ]; do
        echo "Enter your choice (0-7) or CTRL-C to exit"
        read choice
    done


    case $choice in
        0)
            echo "Installing RaSCSI Service + Web interface"
            installRaScsi
            installRaScsiWebInterface
            createDrive600MB
            showRaScsiStatus
        ;;
        1)
            echo "Installing RaSCSI Service"
            installRaScsi
            showRaScsiStatus
        ;;
        2)
            echo "Installing RaSCSI Web interface"
            installRaScsiWebInterface
        ;;
        3)
            echo "Updating RaSCSI Service + Web interface"
            updateRaScsi
            updateRaScsiWebInterface
            showRaScsiStatus
        ;;
        4)
            echo "Updating RaSCSI Service"
            updateRaScsi
            showRaScsiStatus
        ;;
        5)
            echo "Updating RaSCSI Web interface"
            updateRaScsiWebInterface
        ;;
        6)
            echo "Creating a 600MB drive"
            createDrive600MB
        ;;
        7)
            echo "Creating a custom drive"
            createDriveCustom
        ;;
    esac
}


showRaSCSILogo
initialChecks
showMenu