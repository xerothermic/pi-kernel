#!/bin/bash

usage() {
    echo ""
    echo "Raspberry Pi Kernel Builder Utility"
    echo ""
    echo "Commands:"
    echo " * init             : initializes or resets the linux kernel repository (run this the first time)"
    echo " * add <cmp> <path> : add extra component to given path"
    echo " * patch <file>     : applies given patch file to the kernel source code"
    echo " * default          : resets the configuration to defaults"
    echo " * set <name> <val> : adds or modifies the given name to the given value in the kernel .config file"
    echo " * unset <name>     : unsets the given name in the kernel .config file"
    echo " * config           : allows you to define a specific configuration"
    echo " * build            : builds the kernel based on the configuration in .config "
    echo " * zip              : ZIPs all the required files, root folder is rootfs"
    echo " * copy <folder>    : copies the kernel and modules to the given folder"
    echo ""
    echo "Environment variables:"
    echo " * ARCH             : architecture to build the kernel for: 'arm' or 'arm64' (current: ${ARCH})"
    echo " * CORES            : number of cores used to build the kernel (current: ${CORES})"
    echo ""
    echo "Syntax: $0 [command]"
    echo ""
}

# Number of cores defaults to physical CPU cores
[[ ${CORES} -eq 0 ]] && unset CORES
CORES=${CORES:=$(grep "^processor" /proc/cpuinfo | sort -u | wc -l)}
CORES=${CORES:=1}

# Commit to build
KERNEL_TAG=${KERNEL_TAG:-"rpi-6.12.y"}

# Machine to build for
MACHINE=${MACHINE:-"cm4"}

# Get architecture
ARCH=${ARCH:-"arm64"}
case ${ARCH} in

    "arm")
        export COMPILER=arm-linux-gnueabihf-
        export IMAGE=zImage
        export KERNEL=${KERNEL:-"kernel7l"}
        ;;

    "arm64")
        export COMPILER=aarch64-linux-gnu-
        export IMAGE=Image.gz
        if [[ "$MACHINE" == "rpi5" ]]; then
            export KERNEL=${KERNEL:-"kernel_2712"}
        else
            export KERNEL=${KERNEL:-"kernel8"}
        fi
        ;;

    *)
        echo "Wrong architecture, supported values are 'arm' or 'arm64'"
        exit 1
        ;;

esac

# Check MAKE is installed
make -v &> /dev/null
if [[ $? -ne 0 ]]; then
    echo "ERROR: \"make\" not installed! Please run \"apt install build-essential\""
    exit 1
fi

# Compiler command
MAKE="make -j${CORES} ARCH=${ARCH} CROSS_COMPILE=${COMPILER}"

# Get option
if [ $#  -lt 1 ]; then
    usage
    exit 0
fi
OPTION=$1

# Debug
echo "Running '${OPTION}' option for '${ARCH}' architecture, using ${CORES} cores..."

case ${OPTION} in

    "init" | "reset" )
        if [ ! -d linux ]; then
            echo "Cloning raspberrypi/linux repository, ${KERNEL_TAG} tag" 
            git clone --depth=1 --branch ${KERNEL_TAG} https://github.com/raspberrypi/linux
        else
            echo "Resetting raspberrypi/linux repository, ${KERNEL_TAG} tag" 
            pushd linux >> /dev/null
            git reset --hard
            git clean -f -d -X
            git checkout ${KERNEL_TAG}
            popd >> /dev/null
        fi
        rm -rf modules
        
        # Show version
        cat linux/Makefile | head -n 4 | tail -n +2 

        ;;

    "add") 
        if [ $#  -lt 3 ]; then
            usage
            exit 1
        fi
        COMPONENT=$2
        PATH=$3
        if [ ! -d ${COMPONENT} ]; then
            echo "ERROR: \"${COMPONENT}\" not found"
            exit 1
        fi
        if [ ! -d linux/${PATH} ]; then
            echo "ERROR: \"${PATH}\" not found"
            exit 1
        fi
        /bin/cp -r ${COMPONENT} linux/${PATH}/
        NAME=${COMPONENT##*/}
        echo "obj-y += ${NAME}/" >> linux/${PATH}/Makefile
        echo "source \"${PATH}/${NAME}/Kconfig\"" >> linux/${PATH}/Kconfig

        ;;
    
    "patch" )
        if [ $#  -lt 2 ]; then
            usage
            exit 1
        fi
        PATCH=$2
        if [ ! -f ${PATCH} ]; then
            echo "ERROR: \"${PATCH}\" not found"
            exit 1
        fi
        git apply --directory=linux ${PATCH}

        ;;

    "default" )
        pushd linux >> /dev/null
        if [[ "$MACHINE" == "rpi5" ]]; then
            ${MAKE} bcm2712_defconfig
        else
        ${MAKE} bcm2711_defconfig
        fi
        popd >> /dev/null

        ;;

    "config" )
        pushd linux >> /dev/null
        ${MAKE} menuconfig
        popd >> /dev/null

        ;;

    "set")
        if [ $#  -lt 3 ]; then
            usage
            exit 1
        fi
        NAME=$2
        VALUE=$3
        # This line replaces the existing key with the new value or appends the key=value pair to the end of the file
        sed '/^[# ]*'${NAME}'[= ]/{h;s/.*/'${NAME}'='${VALUE}'/};${x;/^$/{s//'${NAME}'='${VALUE}'/;H};x}' -i linux/.config

        ;;

    "unset")
        if [ $#  -lt 2 ]; then
            usage
            exit 1
        fi
        NAME=$2
        sed 's/[# ]*'${NAME}'[= ].*/# '${NAME}' is not set/' -i linux/.config

        ;;

    "build" )
        rm -rf modules
        mkdir modules
        pushd linux >> /dev/null
        ${MAKE} ${IMAGE} modules dtbs
        env PATH=$PATH ${MAKE} INSTALL_MOD_PATH=../modules modules_install
        popd >> /dev/null

        ;;

    "zip" )
        
        # Check ZIP is installed
        zip --help &> /dev/null
        if [[ $? -ne 0 ]]; then
            echo "ERROR: \"zip\" not installed! Please run \"apt install zip\""
            exit 1
        fi

        RELEASE=$(cat linux/include/config/kernel.release)

        rm -rf rootfs $FILE
        mkdir -p rootfs/boot/firmware/overlays/
        cp -r modules/lib rootfs/
        rm -rf rootfs/lib/modules/*/source
        rm -rf rootfs/lib/modules/*/build
        cp -r linux/arch/${ARCH}/boot/dts/broadcom/*.dtb rootfs/boot/firmware/
        cp -r linux/arch/${ARCH}/boot/dts/overlays/*.dtb* rootfs/boot/firmware/overlays/
        cp -r linux/arch/${ARCH}/boot/dts/overlays/README rootfs/boot/firmware/overlays/
        cp -r linux/arch/${ARCH}/boot/${IMAGE} rootfs/boot/firmware/${KERNEL}.img
        cp -r linux/.config rootfs/boot/config-${RELEASE}
        pushd rootfs >> /dev/null
        rm ../${ARCH}.kernel.zip
        zip -yrq ../${ARCH}.kernel.zip *
        popd >> /dev/null
        rm -rf rootfs

        ;;

    "copy" )

        if [ $#  -lt 2 ]; then
            usage
            exit
        fi

        DESTINATION=$2
        RELEASE=$(cat linux/include/config/kernel.release)

        rsync -rtulv --exclude={'source','build'} modules/lib/modules/* ${DESTINATION}/lib/modules/
        rsync -rtulv linux/arch/${ARCH}/boot/dts/broadcom/*.dtb ${DESTINATION}/boot/firmware/
        rsync -rtulv linux/arch/${ARCH}/boot/dts/overlays/*.dtb* ${DESTINATION}/boot/firmware/overlays/
        rsync -rtulv linux/arch/${ARCH}/boot/dts/overlays/README ${DESTINATION}/boot/firmware/overlays/
        rsync -rtulv linux/arch/${ARCH}/boot/${IMAGE} ${DESTINATION}/boot/firmware/${KERNEL}.img
        rsync -rtulv linux/.config ${DESTINATION}/boot/config-${RELEASE}

        ;;

    *)
        echo "Wrong command (${OPTION}), supported values are 'init', 'add', 'patch', 'default', 'set', 'unset', 'config', 'build', 'zip' or 'copy'"
        
        ;;

esac

exit 0
