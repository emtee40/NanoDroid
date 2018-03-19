#!/sbin/sh
##########################################################################################
# 
# NanoDroid Patcher survival script
# by Nanolx
# 
# Inspired by 99-flashafterupdate.sh of osm0sis @ xda-developers
# Forked from 99-magisk.sh of topjohnwu @ xda-developers
# 
##########################################################################################

. /tmp/backuptool.functions

# This path should work in any cases
BASEDIR=/data/adb/nanodroid_patcher
TMPDIR=/dev/tmp/install
export ANDROID_DATA="${TMPDIR}"
PATH="${PATH}:/system/bin:/system/xbin"
PATCH_CORE="${BASEDIR}/core_services.jar.dex"

MAGISK_IMG=/data/adb/magisk.img
MAGISK_PATH=/dev/tmp/magisk_img

# remove our own, temporary dalvik-cache
rm -rf "${TMPDIR}"
mkdir -p ${TMPDIR}

##########################################################################################
# Generic Functions
##########################################################################################

ui_print () {
	echo -n -e "ui_print $1\n" >> /proc/self/fd/$OUTFD
	echo -n -e "ui_print\n" >> /proc/self/fd/$OUTFD
}

is_mounted () {
	if [ ! -z "$2" ]; then
		cat /proc/mounts | grep $1 | grep $2, >/dev/null
	else
		cat /proc/mounts | grep $1 >/dev/null
	fi
	return $?
}

mount_image() {
	if [ ! -d "$2" ]; then
		mount -o rw,remount rootfs /
		mkdir -p "$2" 2>/dev/null
		[ ! -d "$2" ] && return 1
	fi

	if ! is_mounted "$2"; then
		LOOPDEVICE=
		for LOOP in 0 1 2 3 4 5 6 7; do
			if ! is_mounted "$2"; then
				LOOPDEVICE=/dev/block/loop$LOOP
				[ -e $LOOPDEVICE ] || mknod $LOOPDEVICE b 7 $LOOP 2>/dev/null
				losetup $LOOPDEVICE "$1" && mount -t ext4 -o loop $LOOPDEVICE "$2"
				if is_mounted "$2"; then
					break;
				fi
			fi
		done
	fi
}

# taken from Magisk, with minor modifications for NanoDroid
mount_partitions () {
	SLOT=$(getprop ro.boot.slot_suffix)
	if [ -z ${SLOT} ]; then
		SLOT=$(getprop ro.boot.slot)
		[ "${SLOT}" = "_" ] && SLOT=
	fi

	is_mounted /data || mount /data 2>/dev/null

	${BOOTMODE} || mount -o bind /dev/urandom /dev/random

	[ ! -f /system/build.prop ] && mount -o ro /system 2>/dev/null

	if [ ! -f /system/build.prop ]; then
		SYSTEMBLOCK=$(find /dev/block -iname system${SLOT} | head -n 1)
		mount -t ext4 -o ro $SYSTEMBLOCK /system
	fi

	if [ -f /system/init.rc ]; then
		mkdir /system_root 2>/dev/null
		mount --move /system /system_root
		mount -o bind /system_root/system /system
	fi

	[ ! -f /system/build.prop ] && error "failed to mount /system"
}

error () {
	ui_print "${@}"
	magisk_cleanup
	exit 1
}


grep_prop() {
	REGEX="s/^$1=//p"
	shift
	FILES=$@
	if [ -z "$FILES" ]; then
		FILES='/system/build.prop'
	fi
	cat $FILES 2>/dev/null | sed -n "$REGEX" | head -n 1
}

detect_odex () {
	[ -n "$(find '/system/framework/' -name '*.odex')" ] && \
		error " !! odexed ROMs are not supported"
}

detect_arch () {
	ABI=$(grep_prop ro.product.cpu.abi | cut -c-3)
	ABI2=$(grep_prop ro.product.cpu.abi2 | cut -c-3)
	ABILONG=$(grep_prop ro.product.cpu.abi)

	ARCH=arm

	[ "$ABI" = "x86" ] && ARCH=x86
	[ "$ABI2" = "x86" ] && ARCH=x86
	[ "$ABILONG" = "arm64-v8a" ] && ARCH=arm64
	[ "$ABILONG" = "x86_64" ] && ARCH=x86_64

	case ${ARCH} in
		arm | arm64 )
				FILE=${BASEDIR}/file.arm
				ZIPB=${BASEDIR}/zip.arm
		;;
		x86 | x86_64 )
				FILE=${BASEDIR}/file.x86
				ZIPB=${BASEDIR}/zip.x86
		;;
	esac

	case ${ARCH} in
		arm | x86 )
			C_LD="/system/lib:/system/vendor/lib"
		;;

		arm64 | x86_64 )
			C_LD="/system/lib64:/system/vendor/lib64"
		;;
	esac

	ui_print " > device architecture: ${ARCH}"
}

detect_sdk () {
	SDK_VERSION=$(grep_prop ro.build.version.sdk)

	[ "${SDK_VERSION}" -gt 27 ] && \
		error " !! Android versions beyond Oreo are not yet supported"

	[ "${SDK_VERSION}" -lt 16 ] && \
		error " !! Android versions before Jelly Bean are not supported"

	if [ "${SDK_VERSION}" -lt 24 ]; then
		ui_print " > Android 4.1 - 6.0 (SDK ${SDK_VERSION}) detected"
		PATCH_HOOK="${BASEDIR}/hook_4.1-6.0_services.jar.dex"
		PATCH_UI_SERVICES="${BASEDIR}/ui_4.1-6.0_services.jar.dex"
	else
		ui_print " > Android 7.0 - 8.1 (SDK ${SDK_VERSION}) detected"
		PATCH_HOOK="${BASEDIR}/hook_7.0-8.0_services.jar.dex"
		PATCH_UI_SERVICES="${BASEDIR}/ui_7.0-8.0_services.jar.dex"
	fi

	[ "${SDK_VERSION}" -gt 21 ] && DEX_OPTS="--multi-dex-threaded"
}

##########################################################################################
# Patcher Functions
##########################################################################################

patch_services () {
	ui_print " "
	ui_print " > patching signature spoofing support"
	ui_print " "

	for jar in /system/framework/*.jar ; do
		BOOTCLASSES=${BOOTCLASSES}:${jar}
	done

	cp /system/framework/services.jar \
		${BASEDIR}/services.jar || \
		error " !! failed to copy services.jar"

	[ "${SDK_VERSION}" -gt 21 ] && \
		mkdir -p "${BASEDIR}/services.jar-mod"

	PATCHES="${PATCH_HOOK} ${PATCH_CORE}"

	ui_print " >> patching services.jar"
	LD_LIBRARY_PATH=${C_LD} \
		/system/bin/dalvikvm \
		-Xbootclasspath:"${BOOTCLASSES}" \
		-classpath "${BASEDIR}/dexpatcher.dex" \
		lanchon.dexpatcher.Main \
		${DEX_OPTS} --api-level "${SDK_VERSION}" \
		--verbose --output ${BASEDIR}/services.jar-mod \
		${BASEDIR}/services.jar ${PATCHES} || \
			error " !! failed to apply patches"

	LD_LIBRARY_PATH=${C_LD} \
		${ZIPB} -d "${BASEDIR}/services.jar" \
		'classes*.dex' || \
			error " !! zip failed"

	LD_LIBRARY_PATH=${C_LD} \
		${ZIPB} -j "${BASEDIR}/services.jar" \
		"${BASEDIR}/services.jar-mod"/classes*.dex || \
			error " !! zip failed"
}

backup_services_jar () {
	ui_print " << backing up services.jar to: /sdcard/nanodroid_backups"
	mkdir -p /sdcard/nanodroid_backups
	cp /system/framework/services.jar /sdcard/nanodroid_backups || \
		error " !! failed to backup services.jar"
}

install_services () {
	ui_print " "
	for destination in /dev/tmp/magisk_img/NanoDroid /dev/tmp/magisk_img/NanoDroid_microG \
		/sbin/.core/img/NanoDroid /sbin/.core/img/NanoDroid_microG /; do
		if [ -d ${destination} ]; then
			install_path="${destination}"
			break
		fi
	done

	if [ "${install_path}" = "/" ]; then
		mount -orw,remount /system || \
			error " !! failed to mount /system read-write"
		backup_services_jar
	fi

	ui_print " << installing patched files to: ${install_path}"

	mkdir -p "${install_path}/system/framework"
	cp ${BASEDIR}/services.jar "${install_path}/system/framework" \
		|| error " !! failed to install services.jar"

	if [ "${install_path}" = "/" ]; then
		echo /system/framework/services.jar >> /data/adb/.nanodroid-list
	fi

	touch /data/adb/.nanodroid-patcher
}

##########################################################################################
# Magisk Functions
##########################################################################################

grow_magisk_img () {
	request_size_check /tmp/services.jar
	image_size_check ${MAGISK_IMG}
	if [ "$reqSizeM" -gt "$curFreeM" ]; then
		SIZE=$(((reqSizeM + curUsedM) / 32 * 32 + 64))
		resize2fs -f ${MAGISK_IMG} ${SIZE}M
		e2fsck -yf ${MAGISK_IMG}
	fi
}

shrink_magisk_img () {
	image_size_check ${MAGISK_IMG}
	NEWDATASIZE=$((curUsedM / 32 * 32 + 32))
	if [ "$curSizeM" -gt "$NEWDATASIZE" ]; then
		resize2fs -f ${MAGISK_IMG} ${NEWDATASIZE}M
		e2fsck -yf ${MAGISK_IMG}
	fi
}

request_size_check() {
	reqSizeM=`unzip -l "$1" 2>/dev/null | tail -n 1 | awk '{ print $1 }'`
	reqSizeM=$((reqSizeM / 1048576 + 1))
}

image_size_check() {
	e2fsck -yf $1
	curBlocks=`e2fsck -n $1 2>/dev/null | grep $1 | cut -d, -f3 | cut -d\  -f2`;
	curUsedM=`echo "$curBlocks" | cut -d/ -f1`
	curSizeM=`echo "$curBlocks" | cut -d/ -f1`
	curFreeM=$(((curSizeM - curUsedM) * 4 / 1024))
	curUsedM=$((curUsedM * 4 / 1024 + 1))
	curSizeM=$((curSizeM * 4 / 1024))
}

magisk_setup () {
	if [ -f ${MAGISK_IMG} ]; then
		grow_magisk_img || \
			error " !! failed to grow magisk.img"
		mount_image ${MAGISK_IMG} ${MAGISK_PATH} || \
			error " !! failed to mount ${MAGISK_PATH}"
	fi
}

magisk_cleanup () {
	if (is_mounted ${MAGISK_PATH}); then
		umount ${MAGISK_PATH}
		losetup -d $LOOPDEVICE
		rmdir ${MAGISK_PATH}
		shrink_magisk_img || \
			error " !! failed to shrink magisk.img"
	fi
}

main () {
	ui_print " "
	ui_print "*******************************"
	ui_print "   NanoDroid Framework Patcher   "
	ui_print "     addon.d 16.3.99999999     "
	ui_print "       created by @Nanolx      "
	ui_print " Utilizing DexPatcher @lanchon "
	ui_print "*******************************"
	ui_print " "

	mount_partitions

	[ -f /data/adb/.nanodroid-patcher ] && \
		rm -f /data/adb/.nanodroid-patcher

	for bin in zip.arm zip.x86 file.arm file.x86; do 
		chmod 0755 "${BASEDIR}/${bin}" || \
			error " !! failed to prepare environment"
	done

	detect_sdk
	detect_arch
	detect_odex

	[ -f ${MAGISK_IMG} ] && magisk_setup

	patch_services
	install_services

	ui_print " "
	ui_print " >> clean up"

	magisk_cleanup

	ui_print " "
	ui_print " > Done!"
	ui_print " "
	ui_print "Thanks for using NanoDroid"
	ui_print " "

	exit 0
}

##########################################################################################
# Check environment
##########################################################################################

if [[ ! -d /data/adb/nanodroid_patcher ]]; then
	ui_print " "
	ui_print " !! NanoDroid-Patcher environment missing"
	ui_print " !! guessing, you've wiped /data ?"
	ui_print " !! re-flash the NanoDroid-Patcher zip"
	ui_print " "
	exit 0
fi

##########################################################################################
# Stuffz
##########################################################################################

case "$1" in
	backup)
		# Stub
	;;
	restore)
		# Stub
	;;
	pre-backup)
		# Stub
	;;
	post-backup)
		# Stub
	;;
	pre-restore)
		# Stub
	;;
	post-restore)
		# Get the FD for ui_print
		OUTFD=`ps | grep -v grep | grep -oE "update(.*)" | cut -d" " -f3`
		# Run the main function in a parallel subshell 
		main
	;;
esac

