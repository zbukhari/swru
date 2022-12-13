#!/bin/bash

# Script goals:
#
# 0. Log it all to "/var/log/swru-updater.log"
# 1. Check for updates *to* this script. update_self
# 2. Get new hashes file or use existing in /var/tmp. update_swru_hashes
# 3. Check if there are any apt updates and perform them. update_apt
# 4. Check if there are any swru updates and perform them. update_swru
# 5. If we get here we do a release upgrade. update_release

# Thoughts / ideas and things:
#
# * We can make this take arguments to do a specific action above

set -e

# Always good to "cleanse" the path :-D - We could have our own little
# space such as /opt/l4s or switchroot or something. Then have it do
# it's own checks and balances kinda like retropie.
PATH=/bin:/sbin:/usr/bin:/usr/sbin

### Variables ###
# Files
logfile="/var/log/swru-updater.log"
swru_hashes_file="/var/tmp/latest_swru_hashes.txt"

# URL's
swru_baseurl="https://download.switchroot.org/ubuntu"
swru_hashes_url="${swru_baseurl}/hashes.txt"
my_stable="https://raw.githubusercontent.com/zbukhari/swru/main/swru-updater.bash"

# Helpful / quality of life vars
swru_version="$(< /etc/switchroot_version.conf)"
swru_major_version="$(echo $swru_version | cut -f1 -d.)"
swru_minor_version="$(echo $swru_version | cut -f2 -d.)"
swru_patch_version="$(echo $swru_version | cut -f3 -d.)"

# Limits and things
update_apt_limit=5	# The number of times to try to update all apt packages

### Functions ###
logger_cleanup () {
	exec 1>&3 3>&-	# Restore stdout and close fd 3
	exec 2>&4 4>&-	# Restore stderr and close fd 4
}

update_self () {
	tmpfile=$(mktemp /tmp/swru-updater.bash.XXXXXX)

	wget -qO "$tmpfile" "$my_stable"

	remote_md5=$(md5sum "$tmpfile" | awk '{print $1}')
	my_md5=$(md5sum $0 | awk '{print $1}')

	if [ "x$my_md5" != "x$remote_md5" ]; then
		echo There is a newer version of swru-updater available.
	
		# In order to get this squared away in one shot we need to pass one
		# command so we chain.
		cat "$tmpfile" > "$0" && \
			rm "$tmpfile" && \
			echo "swru-updater has been updated. Please re-run this script." && \
			exit 0
	else
		echo swru-updater is already the latest.
	fi

	rm "$tmpfile"
}

update_swru_hashes () {
	echo Updating Switchroot Ubuntu hashes

	tmpfile=$(mktemp "/tmp/swru_hashes.txt-XXXXXX")
	tmpfile2=$(mktemp "/tmp/swru_hashes.txt-XXXXXX")

	wget -qO "$tmpfile" "$swru_hashes_url"

	if [ $? -eq 0 ]; then
		echo Got updated hashes, updating file.

		# As the command and current path is in the file, we are
		# going to grab the sum, then grep it again, basename the file
		# and then write out a new sums file.
		for sum in $(egrep '^[0-9a-f]{40}  ' "$tmpfile" | awk '{print $1}')
		do
			filename="$(basename $(fgrep $sum $tmpfile | cut -f3- -d' '))"
			echo "${sum}  ${filename}" >> "$tmpfile2"
		done

		cat "$tmpfile2" > "$swru_hashes_file"
	elif [ -f "$swru_hashes_file" ]; then
		echo Could not get file, using existing file.
	else
		echo Unable to get Switchroot Ubuntu hashes. Exiting.
		exit 2
	fi

	rm "$tmpfile" "$tmpfile2"
}

# Grabbed from init from 7z update files with "slight" modifications.
find_boot_path () {
	boot_dev_found="false";
	MMC_BLK=$(sed -ne 's/.*boot_m=//;T' -e 's/\s.*$//p' /proc/cmdline);
	MMC_PART=$(sed -ne 's/.*boot_p=//;T' -e 's/\s.*$//p' /proc/cmdline);
	if [[ -z ${MMC_PART} ]]; then MMC_PART=1; fi;

	# Check if eMMC exists. If yes there will be a mmcblk1 as SD.
	if [[ -f /dev/mmcblk1 ]]; then
		if [[ -n ${MMC_BLK} ]]; then
			boot_src_e=$(findmnt -runo target "/dev/mmcblk${MMC_BLK}p${MMC_PART}")

			if [ $? -eq 0 ]; then
				boot_dev_found="true"
				boot_path="$(echo -e $boot_src_e)"
			else
				boot_path="$(mktemp -d /mnt.XXXXXX)"
				mount "/dev/mmcblk${MMC_BLK}p${MMC_PART}" "$boot_path"
				if [ $? -eq 0 ]; then boot_dev_found="true"; fi
			fi
		else
			boot_path="$(mktemp -d /mnt.XXXXXX)"
			mount /dev/mmcblk1p1 "$boot_path"
			if [ $? -eq 0 ]; then boot_dev_found="true"; fi
		fi
	else
		boot_src_e=$(findmnt -runo target "/dev/mmcblk0p${MMC_PART}")

		if [ $? -eq 0 ]; then
			boot_dev_found="true"
			boot_path="$(echo -e $boot_src_e)"
		else
			boot_path="$(mktemp -d /mnt.XXXXXX)"
			mount "/dev/mmcblk0p${MMC_PART}" "$boot_path"
			if [ $? -eq 0 ]; then boot_dev_found="true"; fi
		fi
	fi

	# Failsafe boot files mount.
	if [[ ${boot_dev_found} == "false" ]]; then
		boot_path="$(mktemp -d /mnt.XXXXXX)"
		mount /dev/mmcblk0p1 "$boot_path"
		if [ $? -ne 0 ]; then
			mount /dev/mmcblk1p1 "$boot_path"
			if [ $? -eq 0 ]; then boot_dev_found="true"; fi
		else
			boot_dev_found="true";
		fi;
	fi
}

update_apt () {
	echo Updating package cache.
	apt-get update

	i=1
	while true
	do
		upgradeable_pkgs=$(apt list --upgradeable 2>/dev/null | wc -l)
		if [ $upgradeable_pkgs -gt 1 ]; then
			echo Starting update_apt iteration $i

			echo There are packages which can be upgraded. Will upgrade them.
			sleep 5

			apt-get -y \
				-o Dpkg::Options::="--force-confdef" \
				-o Dpkg::Options::="--force-confold" \
				dist-upgrade

			echo Finishing update_apt iteration $i

			if [ -f /var/run/reboot-required ]; then
				shutdown -r +1 "APT update requires reboot. Rebooting in one minute. Run this command after reboot."
				exit 0
			fi

			i=$((i+1))
		else
			echo There are no packages which can be upgraded.
			break
		fi
	done
}

# From what the web docs say, any 3.y.z can be upgraded to the latest by
# just unpacking the latest hoping the trend continues.
#
# Pulling in code from "init" to find "boot" aka the FAT with switchroot.
#
# Self notes: initramfs does the unpacking of modules/updates tar.gz.
# init is the shell script with the magic.
#
# Going to hold off on verify as it would require more TLC but for memory
#
# tar df update.tar.gz -C /
# tar df modules.tar.gz -C /lib
#
# We'll let the normal process and "init" take point.
update_swru () {
	# Since working with a 3.4.2 Preview ...
	if [ "x$swru_version" = "x3.4.2" ]; then
		echo Latest Switchroot version found.
		return
	fi

	swru_update_version=$(fgrep update_only $swru_hashes_file | awk '{print $2}' | cut -f3 -d-)

	if [ "x$swru_version" = "x$swru_update_version" ]; then
		echo Latest Switchroot version found.
		return
	fi

	swru_update_major_version=$(echo $swru_update_version | cut -f1 -d.)
	swru_update_minor_version=$(echo $swru_update_version | cut -f2 -d.)
	swru_update_patch_version=$(echo $swru_update_version | cut -f3 -d.)

	if [ "x$swru_major_version" != "x$swru_update_major_version" ]; then
		cat <<-HEREDOC
			Major version mismatch. Local: $swru_version, Remote: $swru_update_version

			This may require manual intervention. Cowardly exiting. Check the docs.

			https://wiki.switchroot.org/en/Linux/Ubuntu-Install-Guide
		HEREDOC

		exit 1
	fi

	if [ "x$boot_dev_found" = "xtrue" ]; then
		echo Updating to latest version.
		swru_update_file="$(fgrep update_only $swru_hashes_file | awk '{print $2}')"
		wget -qO "/dev/shm/${swru_update_file}" "${baseurl}/${swru_update_file}"
		cd "$boot_path"
		test -d l4t-ubuntu && rm -fr l4t-ubuntu
		test -f bootloader/ini/01-ubuntu.ini && rm -f bootloader/ini/01-ubuntu.ini
		7z x "/dev/shm/${swru_update_file}"
		shutdown -r +1 "Switchroot update files staged. Rebooting in one minute."
		exit 0
	else
		cat <<-HEREDOC
			Unable to determine boot partition. Please update manually by following the
			wiki.

			https://wiki.switchroot.org/en/Linux/Ubuntu-Install-Guide
		HEREDOC
		exit 1
	fi
}

# Basic do-release-upgrader. Personally I've run into issues where 3rd party
# repos need some TLC. It either gets disabled or the "sed" wrecks them. We
# do have switchroot but that's unstable - let's see how it goes/blows.
dru () {
	# Using version numbers for a calmer future.
	release_version=$(lsb_release -s -r)
	echo -e "Enabling release upgrade"
	sed -i 's/Prompt=never/Prompt=lts/g' /etc/update-manager/release-upgrades || true

	# We want to use confold and confdef to prevent prompts.
	tmpfile=$(mktemp /etc/apt/apt.conf.d/zzzXXXXXX)
	cat <<-HEREDOC > "$tmpfile"
		Dpkg::Options { "--force-confdef"; "--force-confold"; }
	HEREDOC
	do-release-upgrade -f DistUpgradeViewNonInteractive
	rm "$tmpfile"

	# Doing a simple check here. We can put in extra checks as we discover
	# work that may need to be done.
	post_upgrade_release_version=$(lsb_release -s -r)

	if [ "x$post_upgrade_release_version" = "x$(echo $release_version + 2 | bc -l)" ]; then
		echo Upgrade has succeeded.
		echo -e "Disabling upgrade prompt"
		sed -i 's/Prompt=lts/Prompt=never/g' /etc/update-manager/release-upgrades

		return 0
	else
		echo Upgrade has failed.
		return 1
	fi
}

# Distro specific post upgrade stuff.
update_2_focal () {
	# Temporarily use testing repo
	wget -qO - https://jetson.repo.azka.li/ubuntu/pubkey | apt-key add -
	add-apt-repository 'deb https://jetson.repo.azka.li/ubuntu focal main'

	# I'm not 100% sure what the intention was here. reinstall requires
	# install but then some of the packages in the second line were/are
	# already installed. I'm just going to right the reinstall install
	# bit and hope for the best. Perhaps a confold confdef would be in
	# good order here.
	apt-get -y --reinstall install appstream libappstream*
	apt-get -y install unity-lens-applications unity-lens-files libblockdev-mdraid2 switch-alsa-ucm2

	# We could just call update_apt but if we find there are updates
	# people can just run this script here again.
	#apt-get -o Dpkg::Options::="--force-overwrite" -y dist-upgrade
	#apt-get -f -y -o Dpkg::Options::="--force-overwrite" install

	# echo -e "Restoring gdm3 config"
	# cp /etc/gdm3/custom.conf.bak /etc/gdm3/custom.conf

	# Restore old Xorg conf
	#cp /etc/X11/xorg.conf.dist-upgrade-* /etc/X11/xorg.conf
	#rm /etc/X11/xorg.conf.dist-upgrade-*

	echo -e "Fixing upower"
	mkdir -p /etc/systemd/system/upower.service.d/
	cat <<-HEREDOC > /etc/systemd/system/upower.service.d/override.conf
		[Service]
		PrivateUsers=no
		RestrictNamespaces=no
	HEREDOC

	systemctl daemon-reload && systemctl restart upower
}

update_release () {
	# I'll run with this, bc is installed here already, better for long term
	codename=$(lsb_release -s -c)

	### Omitting - this file is a conf file, should not be overwritten
	#   if it has modifications which it does.
	# echo -e "Backing up gdm3 config"
	# cp /etc/gdm3/custom.conf /etc/gdm3/custom.conf.bak

	case $release_version in
		bionic)
			dru && update_2_focal
			;;
		*)
			echo We are not ready to perform a release upgrade this yet.
			sleep 10
			return
			;;
	esac

	if [ -f /var/run/reboot-required ]; then
		shutdown -r +1 "Release upgrade requires reboot. Rebooting in one minute."
	fi
}

### Let's get ready to rumble! ###
if [[ $(id -u) != 0 ]]; then
	echo -e "This script needs to be run as root."
	exit 1
fi

# Log everything
exec 3>&1 4>&2		# Store stdout and stderr to fd 3 and 4 respectively.
# Pretty sure we only need EXIT QUIT TERM but I'm here for it.
trap 'logger_cleanup' EXIT HUP INT QUIT TERM

# I would like to use ts from moreutils but perl is basic and there.
if [ -x /usr/bin/ts ]; then
	exec > >(tee >(ts '%FT%T%z' >> "$logfile")) 2>&1
else
	exec > >(tee >(perl -pe 'use POSIX strftime; print strftime "%FT%T%z ", localtime' >> "$logfile")) 2>&1
fi

### Time to roll up ye olde sleeves and put some mustard on it!

# 1. Check for updates *to* this script. update_self
update_self
# 2. Get new hashes file or use existing in /var/tmp. update_swru_hashes
update_swru_hashes
# 3. Check if there are any apt updates and perform them. update_apt
update_apt
# 4. Check if there are any swru updates and perform them. update_swru
update_swru
# 5. If we get here we do a release upgrade. update_release
update_release

### azkali says -
# Oh another last note. We pin nvidia-l4t- packages for a reason (32.3.1 provides the best support) so that should be kept that way 🙂

### azkali's checklist
#
#Z# I'd like to know the following :
#Z# - dock works (and switch the right nvpmodel profile)
#Z# - joycon autopairing works
#Z# - audio works
#Z# - login screen works
#Z# - joycons in general
#Z# - hdmi auto change sound output
#Z# - jack switching audio works
#Z# - mic works
