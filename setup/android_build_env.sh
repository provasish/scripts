#!/usr/bin/env bash

# Copyright (C) 2018 Harsh 'MSF Jarvis' Shandilya
# Copyright (C) 2018 Akhil Narang
# SPDX-License-Identifier: GPL-3.0-only

# Script to setup an AOSP Build environment on Ubuntu and Linux Mint
# Supports Ubuntu 16.04 - 24.04+ (and derivatives) and Debian 10+

LATEST_MAKE_VERSION="4.3"
UBUNTU_16_PACKAGES="libesd0-dev"
UBUNTU_20_PACKAGES="libncurses5 curl python-is-python3"
DEBIAN_10_PACKAGES="libncurses5"
DEBIAN_11_PACKAGES="libncurses5"
PACKAGES=""

# Packages shared by every supported release
COMMON_PACKAGES="adb autoconf automake axel bc bison build-essential \
    ccache clang cmake curl expat fastboot flex g++ \
    g++-multilib gawk gcc gcc-multilib git git-lfs gnupg gperf \
    htop imagemagick lib32z1-dev libc6-dev libcap-dev \
    libexpat1-dev libgmp-dev ^liblz4-.* ^liblzma.* libmpc-dev libmpfr-dev \
    libssl-dev libtool libxml2 libxml2-utils ^lzma.* lzop \
    maven ncftp patch patchelf pkg-config pngcrush \
    pngquant python3-pyelftools re2c schedtool squashfs-tools subversion \
    texinfo unzip w3m xsltproc zip zlib1g-dev lzip \
    libxml-simple-perl libswitch-perl apt-utils rsync"

# Ubuntu <= 23.04 / Debian <= 12: ncurses5, SDL 1.2 and Python 2 are still packaged
LEGACY_PACKAGES="lib32ncurses5-dev libtinfo5 libncurses5-dev ncurses-dev \
    libsdl1.2-dev python2.7 python-all-dev"

# Ubuntu >= 24.04 (and derivatives): ncurses5 and Python 2 were dropped,
# SDL 1.2 is provided by sdl12-compat
MODERN_PACKAGES="lib32ncurses-dev libncurses-dev libsdl1.2-compat-dev \
    python3 python3-dev python-is-python3"

# Read distro information from /etc/os-release (lsb-core no longer exists on Ubuntu 24.04+)
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
fi
DISTRO_ID="${ID:-unknown}"
DISTRO_VERSION="${VERSION_ID:-0}"
DISTRO_NAME="${PRETTY_NAME:-${DISTRO_ID} ${DISTRO_VERSION}}"

# Work out which Ubuntu release this system is based on (Mint, Pop!_OS, Zorin, elementary, ...)
UBUNTU_MAJOR=0
if [[ ${DISTRO_ID} == "ubuntu" || ${DISTRO_ID} == "pop" ]]; then
    UBUNTU_MAJOR="${DISTRO_VERSION%%.*}"
elif [[ -n ${UBUNTU_CODENAME} ]]; then
    case "${UBUNTU_CODENAME}" in
        xenial) UBUNTU_MAJOR=16 ;;
        bionic) UBUNTU_MAJOR=18 ;;
        focal) UBUNTU_MAJOR=20 ;;
        jammy) UBUNTU_MAJOR=22 ;;
        noble) UBUNTU_MAJOR=24 ;;
        *) UBUNTU_MAJOR=99 ;; # Unknown codename: assume a newer release
    esac
fi
DEBIAN_MAJOR=0
if [[ ${DISTRO_ID} == "debian" ]]; then
    DEBIAN_MAJOR="${DISTRO_VERSION%%.*}"
fi

echo "Detected: ${DISTRO_NAME}"

sudo apt install software-properties-common -y
# Most of the packages below live in the universe component
if [[ ${UBUNTU_MAJOR} -ge 16 ]]; then
    sudo add-apt-repository -y universe
fi
sudo apt update

MODERN=false
if [[ ${UBUNTU_MAJOR} -ge 24 || ${DEBIAN_MAJOR} -ge 13 ]]; then
    MODERN=true
    PACKAGES="${MODERN_PACKAGES}"
elif [[ ${UBUNTU_MAJOR} -eq 16 || ${DISTRO_NAME} =~ "Mint 18" ]]; then
    PACKAGES="${LEGACY_PACKAGES} ${UBUNTU_16_PACKAGES}"
elif [[ ${UBUNTU_MAJOR} -ge 20 ]]; then
    PACKAGES="${LEGACY_PACKAGES} ${UBUNTU_20_PACKAGES}"
elif [[ ${DEBIAN_MAJOR} -eq 10 ]]; then
    PACKAGES="${LEGACY_PACKAGES} ${DEBIAN_10_PACKAGES}"
elif [[ ${DEBIAN_MAJOR} -eq 11 ]]; then
    PACKAGES="${LEGACY_PACKAGES} ${DEBIAN_11_PACKAGES}"
else
    PACKAGES="${LEGACY_PACKAGES}"
fi

# Drop packages that have no install candidate, so a single removed package
# doesn't abort the whole install on newer releases
pkg_available() {
    # Real package with an install candidate
    apt-cache policy "$1" 2>/dev/null | grep -q "Candidate: [^(]" && return 0
    # Virtual package that something provides (e.g. ncurses-dev)
    [[ -n "$(apt-cache showpkg "$1" 2>/dev/null | sed -n '/^Reverse Provides:/,$p' | tail -n +2)" ]]
}

INSTALL_LIST=()
MISSING_LIST=()
set -f # don't let the ^regex.* entries glob against files in the current directory
for pkg in ${COMMON_PACKAGES} ${PACKAGES}; do
    if [[ ${pkg} == ^* ]] || pkg_available "${pkg}"; then
        INSTALL_LIST+=("${pkg}")
    else
        MISSING_LIST+=("${pkg}")
    fi
done
set +f
if [[ ${#MISSING_LIST[@]} -gt 0 ]]; then
    echo "Skipping packages not available on ${DISTRO_NAME}: ${MISSING_LIST[*]}"
fi

sudo DEBIAN_FRONTEND=noninteractive \
    apt install "${INSTALL_LIST[@]}" -y

# Older AOSP prebuilts (clang, etc.) still link against libncurses.so.5 / libtinfo.so.5,
# which Ubuntu 24.04+ no longer ships. Pull them from the Ubuntu 22.04 archive.
if [[ ${MODERN} == true && "$(dpkg --print-architecture)" == "amd64" ]]; then
    NCURSES5_BASE="http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses"
    # Pick the newest 22.04 (6.3-2*) build in the pool; fall back to the original release
    NCURSES5_VERSION="$(curl -fsSL "${NCURSES5_BASE}/" 2>/dev/null \
        | grep -oE 'libtinfo5_6\.3-2[^_"]*_amd64\.deb' | sed -E 's/^libtinfo5_(.*)_amd64\.deb$/\1/' \
        | sort -uV | tail -1)"
    NCURSES5_VERSION="${NCURSES5_VERSION:-6.3-2}"
    for pkg in libtinfo5 libncurses5; do
        if ! dpkg -s "${pkg}" > /dev/null 2>&1; then
            echo "Installing ${pkg} from the Ubuntu 22.04 archive"
            tmpdeb="$(mktemp --suffix=.deb)"
            if curl -fsSL -o "${tmpdeb}" "${NCURSES5_BASE}/${pkg}_${NCURSES5_VERSION}_amd64.deb"; then
                sudo apt install -y "${tmpdeb}" || echo "Failed to install ${pkg}, continuing"
            else
                echo "Could not download ${pkg}, continuing without it"
            fi
            rm -f "${tmpdeb}"
        fi
    done
fi

echo -e "Installing GitHub CLI"
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update
sudo apt install -y gh

echo -e "Setting up udev rules for adb!"
sudo curl --create-dirs -L -o /etc/udev/rules.d/51-android.rules -O -L https://raw.githubusercontent.com/M0Rf30/android-udev-rules/master/51-android.rules
sudo chmod 644 /etc/udev/rules.d/51-android.rules
sudo chown root /etc/udev/rules.d/51-android.rules
sudo systemctl restart udev

# Only build make from source when the distro's make is older than LATEST_MAKE_VERSION
# (Ubuntu 24.04+ already ships make 4.3 or newer)
if [[ "$(command -v make)" ]]; then
    makeversion="$(make -v | head -1 | awk '{print $3}')"
    if [[ "$(printf '%s\n%s\n' "${makeversion}" "${LATEST_MAKE_VERSION}" | sort -V | head -1)" != "${LATEST_MAKE_VERSION}" ]]; then
        echo "Installing make ${LATEST_MAKE_VERSION} instead of ${makeversion}"
        bash "$(dirname "$0")"/make.sh "${LATEST_MAKE_VERSION}"
    fi
fi

echo "Installing repo"
sudo curl --create-dirs -L -o /usr/local/bin/repo -O -L https://storage.googleapis.com/git-repo-downloads/repo
sudo chmod a+rx /usr/local/bin/repo
