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

if [[ $(id -u) != 0 ]]; then
	echo -e "This script needs to be run as root."
	exit 1
fi

### Functions ###

# Works.
update_self () {
	tmpfile=$(mktemp /tmp/swru-updater.bash.XXXXXX)

	wget -qO "$tmpfile" "$my_stable"

	remote_md5=$(md5sum "$tmpfile" | awk '{print $1}')
	my_md5=$(md5sum $0 | awk '{print $1}')

	if [ "x$my_md5" != "x$remote_md5" ]; then
		echo Need to update this script. Please run $0 again afterwards.
	
		# In order to get this squared away in one shot we need to pass one
		# command so we chain.
		cat "$tmpfile" > "$0" && rm "$tmpfile" && exit 0
	else
		echo Script is already the latest.
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
			echo "${sum}  ${basename}" >> "$tmpfile2"
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
		echo update_apt iteration $i

		upgradeable_pkgs=$(apt list --upgradeable 2>/dev/null | wc -l)
		if [ $upgradeable_pkgs -gt 1 ]; then
			echo There are packages which can be upgraded. Will upgrade them.

			apt-get -y \
				-o Dpkg::Options::="--force-confdef" \
				-o Dpkg::Options::="--force-confold" \
				dist-upgrade

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
		echo Latest found.
		return
	fi
	update_version=$(fgrep update_only $swru_hashes_file | awk '{print $2}' | cut -f3 -d-)

	update_major_version=$(echo $update_version | cut -f1 -d.)
	update_minor_version=$(echo $update_version | cut -f2 -d.)
	update_patch_version=$(echo $update_version | cut -f3 -d.)

	# First easily see if we're at the same major version
	if [ "x$swru_major_version" = "x$update_version" ]; then
		echo Major versions match. Checking whole version.
		if [ "x$update_version" != "x$swru_version" ]; then
			if [ "x$boot_dev_found" = "xtrue" ]; then
				echo Updating to latest version.
				update_file="$(fgrep update_only $swru_hashes_file | awk '{print $2}')"
				wget -qO "/dev/shm/${update_file}" "${baseurl}/${update_file}"
				cd "$boot_path"
				test -d l4t-ubuntu && rm -fr l4t-ubuntu
				test -f bootloader/ini/01-ubuntu.ini && rm -f bootloader/ini/01-ubuntu.ini
				7z x "/dev/shm/${latest_update_file}"
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
		else
			echo You are at the latest Switchroot version.
			return
		fi
	# We do not have the same major SWRU version
	else
		# I am going to leave this here, technically we're at the same kernel version
		# the updates mostly work with kernel stuff and so we update the swru version
		# so it is not a big deal but there may come a time where we find a later
		# kernel version is present and matters. This is for that moment - hopefully
		# we'll have updated documentation :-D
		cat <<-HEREDOC
			Major version mismatch. Local: $swru_version, Remote: $update_version

			This may be expected from one major Ubuntu release to the next and or may
			require manual updating.

			If in doubt check the Wiki for more information and or feel free to hit
			CTRL + C at this point. You can always run this script again later.

			https://wiki.switchroot.org/en/Linux/Ubuntu-Install-Guide

			You will have 10 seconds to hit CTRL + C.
		HEREDOC

		i=10
		while [ $i -gt 0 ];
		do
			# Maybe I can do a joycon trap also - hmmm
			echo -n "${i} - Hit CTRL + C if you want to stop script execution."
			sleep 1
			i=$((i-1))
		done
	fi

	### We could also just update this as a switch case for major, minor, and patch and point to
	#   URL's all over the place for sustainability / sensibility but I digress.
	# case "$swru_major_version" in
	# 	# For long term care - we'd want to manually update this for 4.
	# 	3)
	# 		latest_update_file="$(basename $(cat $swru_hashes_file | fgrep update_only | awk '{print $2}'))"
	# 		# Considering the names used in the past, safe bet.
	# 		latest_update_version="$(echo $latest_update_file | cut -f3 -d-)"

	# 		# Just in case someone's living in the past... we just return.
	# 		latest_update_major_version=$(echo $latest_update_version | cut -f1 -d.)
	# 		latest_update_minor_version=$(echo $latest_update_version | cut -f2 -d.)
	# 		latest_update_patch_version=$(echo $latest_update_version | cut -f3 -d.)

	# 		if [ "x$latest_update_major_version" != "x$swru_major_version" ]; then
	# 			echo The major Switchroot Ubuntu version does not match.
	# 			return
	# 		fi

	# 		# We could go hard in maj.min.patch but for now ... simple string compare.
	# 		if [ "x$swru_version" = "x$latest_update_version" ]; then
	# 			echo "Latest version (i.e. ${swru_version}) installed. Yay you!"
	# 		else
	# 			echo Updating to latest version.
	# 			wget -qO "/dev/shm/${latest_update_file}" "${baseurl}/${latest_update_file}"
	# 			if [ "x$boot_dev_found" = "xtrue" ]; then
	# 				cd "$boot_path"
	# 				test -d l4t-ubuntu && rm -fr l4t-ubuntu
	# 				test -f bootloader/ini/01-ubuntu.ini && rm -f bootloader/ini/01-ubuntu.ini
	# 				7z x "/dev/shm/${latest_update_file}"
	# 				shutdown -r +1 Update files staged. Rebooting in one minute.
	# 				exit 0
	# 			else

	# 				cat <<-HEREDOC
	# 					You will want to update your Switchroot Ubuntu installation as prescribed
	# 					by the documents here before proceeding:

	# 					https://wiki.switchroot.org/en/Linux/Ubuntu-Install-Guide#updates-for-previous-30-installs

	# 					Exiting now.
	# 				HEREDOC
	# 				exit 1
	# 			fi
	# 		fi

	# 		update_url="$latest_3_update"
	# 		filename=$(basename "$latest_3_update")
	# 		7z x "$latest_3_update"
	# 		;;
	# 	*)
	# 		echo Unsupported update version as of now. Exiting. >&2
	# 		exit 2
	# 		;;
	# esac
}

# Log everything
exec > >(tee -a >(sed "s/^/$(date --iso-8601=ns) /g" >> "$logfile")) 2>&1

# Time to roll up ye olde sleeves and put some mustard on it!
update_self
update_swru_hashes
update_apt
update_swru

update_release
# 1. Check for updates *to* this script. update_self
# 2. Get new hashes file or use existing in /var/tmp. update_swru_hashes
# 3. Check if there are any apt updates and perform them. update_apt
# 4. Check if there are any swru updates and perform them. update_swru
# 5. If we get here we do a release upgrade. update_release

# Lets do the release update
echo I am in chump testing mode right now
exit 0

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

# If there's any possible updates, do them. do-release-upgrade requires it
# anyway and CTCaer also wanted me to have my stuff in place. I may want
# to have a bit of a cron "state" in place to make it even more automated.
# For now I'm just going to do it and then someone can just run it again.

# May want to add a check in case there's ever an LTS that isn't easy to
# upgrade.
release=$(lsb_release -s -r)

# From docs in downlaods we only need to install the latest. jkjjj
# the future so going to see if we're at the right version for this, we
# can have includes or something for x.y.z to a.b.c or whatever.
case "$(< /etc/switchroot_version.conf)" in
	3.[0123].0)
		#Z# Find out if people can boot with FAT and a bootloader.
		# This we can automate to be complex or not. Holding off.
		echo Need to upgrade this to 3.4.0.
		swru_upgrader 3
		;;
	3.4.0)
		# As the update to preview 342 doesn't update the conf I
		# may temporarily just use the checksum of the extracted
		# files.
		swru_upgrader 3.4.2
		echo Good to upgrade.
		;;
	*)
		echo You are running a magical version.
		exit 1
		;;
esac

echo -e "Backing up gdm3 config"
cp /etc/gdm3/custom.conf /etc/gdm3/custom.conf.bak

#Z# Just mentioning this but we can also own the endpoint that is checked. I
#Z# do local mirrors via aptly at my job so more or less manage
#Z# /etc/update-manager/meta-release and the URI endpoints to point to our
#Z# own "metadata" files. This way no touchy until we're ready to support the
#Z# "future". But I digress - not sure how long we're going to keep this
#Z# train going but I'd like to think forever.
echo -e "Enabling release upgrade"
sed -i 's/Prompt=never/Prompt=lts/g' /etc/update-manager/release-upgrades || true

echo -e "Performing upgrade"
# I got by with one but I did do a dist-upgrade. Will bear this in mind.
while true
do
	apt_upgrader
done

# do-release-upgrade
# No touchy ... hopefully!
do-release-upgrade -f DistUpgradeViewNonInteractive

# Temporarily use testing repo
wget -qO - https://jetson.repo.azka.li/ubuntu/pubkey | apt-key add -
add-apt-repository 'deb https://jetson.repo.azka.li/ubuntu focal main'

apt-get -y reinstall appstream libappstream*
apt-get -y install unity-lens-applications unity-lens-files libblockdev-mdraid2 switch-alsa-ucm2

#apt-get -o Dpkg::Options::="--force-overwrite" -y dist-upgrade
#apt-get -f -y -o Dpkg::Options::="--force-overwrite" install

echo -e "Restoring gdm3 config"
cp /etc/gdm3/custom.conf.bak /etc/gdm3/custom.conf

# Restore old Xorg conf
#cp /etc/X11/xorg.conf.dist-upgrade-* /etc/X11/xorg.conf
#rm /etc/X11/xorg.conf.dist-upgrade-*

echo -e "Fixing upower"
mkdir -p /etc/systemd/system/upower.service.d/
cat <<HEREDOC > /etc/systemd/system/upower.service.d/override.conf
[Service]
PrivateUsers=no
RestrictNamespaces=no
HEREDOC
systemctl daemon-reload && systemctl restart upower

echo -e "Disabling upgrade prompt"
sed -i 's/Prompt=lts/Prompt=never/g' /etc/update-manager/release-upgrades

echo -e "\nDone upgrading !"