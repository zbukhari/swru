#!/bin/bash

set -e

# Always good to "cleanse" the path :-D - We could have our own little
# space such as /opt/l4s or switchroot or something. Then have it do
# it's own checks and balances kinda like retropie.
PATH=/bin:/sbin:/usr/bin:/usr/sbin

### Variables ###
# Files
logfile="/var/log/swru-updater.log"
swru_hashes="/var/tmp/latest_swru_hashes.txt"

# URL's
baseurl="https://download.switchroot.org/ubuntu"
swru_hashes_url="https://download.switchroot.org/ubuntu/hashes.txt"
# swru_latest_update="https://download.switchroot.org/ubuntu/switchroot-ubuntu-3.4.0-update_only-2021-07-23.7z"
my_stable="https://raw.githubusercontent.com/zbukhari/swru/main/l4s-switchroot-update-script.bash"

# Helpful / quality of life
swru_version="$(< /etc/switchroot_version.conf)"
swru_major_version="$(cat /etc/switchroot_version.conf | cut -f1 -d.)"
swru_minor_version="$(cat /etc/switchroot_version.conf | cut -f2 -d.)"
swru_patch_version="$(cat /etc/switchroot_version.conf | cut -f3 -d.)"

if [[ $(id -u) != 0 ]]; then
	echo -e "This script needs to be run as root."
	exit 1
fi

### Functions ###
self_update_script () {
	# First lets see if we need to update the script.
	temp_file=$(mktemp /tmp/l4s-switchroot-update-script.bash.XXXXXX)
	wget -qO - "$my_stable" > "$temp_file"
	remote_md5=$(md5sum "$temp_file" | awk '{print $1}')
	my_md5=$(md5sum $0 | awk '{print $1}')

	if [ "x$my_md5" != "x$remote_md5" ]; then
		echo Need to update this script. Please run $0 again afterwards.
	
		# In order to get this squared away in one shot we need to pass one
		# command so we chain
		cat "$temp_file" > "$0" && rm "$temp_file" && exit 0
	else
		rm "$temp_file"
	fi
}

update_swru_hashes () {
	echo Updating Switchroot Ubuntu hashes

	tmpfile=$(mktemp "/tmp/swru_hashes.txt-XXXXXX")
	wget -qO "$tmpfile" "$swru_hashes_url"
	if [ $? -eq 0 ]; then
		echo Got updated hashes, updating file.
		# Can probably be removed easily later.
		cat "$tmpfile" | grep -v '^root@switchroot' | sed 's# \./# #g' > "$download_swru_sha1_hashes"
		rm "$tmpfile"
	elif [ -f "$download_swru_sha1_hashes" ]; then
		echo Could not get file, using existing file.
	else
		echo Unable to get Switchroot Ubuntu hashes. Exiting.
		exit 2
	fi
}

# Unceremoniously ripped from init for nefarious purposes - jk - very
# farious purposes. Tron - fight for the user!
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

check_apt_updates () {
	echo Updating package cache.
	apt-get update

	upgradeable_pkgs=$(apt list --upgradeable 2>/dev/null | wc -l)
	if [ $upgradeable_pkgs -gt 1 ]; then
		echo There are packages which can be upgraded. Will upgrade them.
		updates=true
	else
		updates=false
	fi
}

apt_upgrader () {
	apt-get -y \
		-o Dpkg::Options::="--force-confdef" \
		-o Dpkg::Options::="--force-confold" \
		dist-upgrade
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
swru_upgrader () {
	major_version=$(echo "$1" | cut -f1 -d.)
	minor_version=$(echo "$1" | cut -f2 -d.)
	patch_version=$(echo "$1" | cut -f3 -d.)

	if [ "x$boot_dev_found" != "xtrue" ]; then

		exit 1
	fi

	case "$swru_major_version" in
		# For long term care - we'd want to manually update this for 4.
		3)
			latest_update_file="$(basename $(cat $swru_hashes_file | fgrep update_only | awk '{print $2}'))"
			# Considering the names used in the past, safe bet.
			latest_update_version="$(echo $latest_update_file | cut -f3 -d-)"

			# Just in case someone's living in the past... we just return.
			latest_update_major_version=$(echo $latest_update_version | cut -f1 -d.)
			latest_update_minor_version=$(echo $latest_update_version | cut -f2 -d.)
			latest_update_patch_version=$(echo $latest_update_version | cut -f3 -d.)

			if [ "x$latest_update_major_version" != "x$swru_major_version" ]; then
				echo The major Switchroot Ubuntu version does not match.
				return
			fi

			# We could go hard in maj.min.patch but for now ... simple string compare.
			if [ "x$swru_version" = "x$latest_update_version" ]; then
				echo "Latest version (i.e. ${swru_version}) installed. Yay you!"
			else
				echo Updating to latest version.
				wget -qO "/dev/shm/${latest_update_file}" "${baseurl}/${latest_update_file}"
				if [ "x$boot_dev_found" = "xtrue" ]; then
					cd "$boot_path"
					test -d l4t-ubuntu && rm -fr l4t-ubuntu
					test -f bootloader/ini/01-ubuntu.ini && rm -f bootloader/ini/01-ubuntu.ini
					7z x "/dev/shm/${latest_update_file}"
					shutdown -r +1 Update files staged. Rebooting in one minute.
					exit 0
				else
					cat <<-HEREDOC
						You will want to update your Switchroot Ubuntu installation as prescribed
						by the documents here before proceeding:

						https://wiki.switchroot.org/en/Linux/Ubuntu-Install-Guide#updates-for-previous-30-installs

						Exiting now.
					HEREDOC
					exit 1
				fi
			fi

			update_url="$latest_3_update"
			filename=$(basename "$latest_3_update")
			7z x "$latest_3_update" 
			;;
		*)
			echo Unsupported update version as of now. Exiting. >&2
			exit 2
			;;
	esac

	cd /root

	wget -qO "/dev/shm/${filename}" "$update_url"

	7z x "/dev/shm/${filename}"

	if [ $? -eq 0 ]; then
		# Could automate this but ... it's good to keep the user involved as we
		# don't have a way to notify them in case they have a weird setup that
		# we're doing work in the background. Granted they should at that point
		# know how to check but alas LCD yo!
		shutdown -r +1 A reboot is required. Please re-run this script after rebooting.
		exit 0
	else
		echo Extract failed. Please reach out to Switchroot people and provide ${logfile}. >&2
		exit 2
	fi
}

# Might want to preserve stdout/stderr.
# Prepending all output with ISO-8601 accurate to nanseconds for logging.
# I could use ts from moreutils but trying to keep this within the realm
# of basic commands.
#
# User will just see the normal output.
exec > >(tee -a >(sed "s/^/$(date --iso-8601=ns) /g" >> "$logfile")) 2>&1

# Do I need to update me?
self_update_script

# Lets update 

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
if [ ! -f /etc/apt/apt.conf.d/local ]; then
	cat <<-HEREDOC > /etc/apt/apt.conf.d/local
		DPkg::options { "--force-confdef"; "--force-confold"; }
	HEREDOC
fi
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
