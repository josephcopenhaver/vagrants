#!/bin/bash

export USERNAME=vagrant

echo Provisioning USERNAME=${USERNAME} ...
set -exo pipefail

cat <<'EOF' | tee /etc/provision_functions
BASHRC_PRESERVED_FUNCTIONS="$(cat <<'BASHRC_PRESERVED_FUNCTIONS'
ensure_in_path() {
    dir="$1"
    mode="${2:-p}"
    if ! [[ $mode =~ ^(p|s)$ ]]; then
        echo "second argument to ensure_in_path can either be 'p' or 's' for prefix or suffix respectively; p is the default"
    fi
    if [[ "$dir" == "~/"* ]] || [[ "$dir" == "~" ]]; then
        dir="${HOME}${dir:1}"
    fi
    if [ -z "$dir" ] || [[ "$PATH" == *":${dir}:"* ]] || [[ "$PATH" == "${dir}:"* ]] || [[ "$PATH" == *":${dir}" ]] || [[ "$PATH" == "$dir" ]]; then
        return
    fi
    sep=""
    if [ -n "$PATH" ]; then
        sep=":"
    fi
    if [[ "$mode" == "p" ]]; then
        export PATH="$dir$sep$PATH"
    else
        export PATH="$PATH$sep$dir"
    fi
}
BASHRC_PRESERVED_FUNCTIONS
)"
eval "$BASHRC_PRESERVED_FUNCTIONS"

is_virtualbox_provider() {
    (
        set -eo pipefail
        dmidecode | grep -i product | grep -q 'VirtualBox'
    )
}

ensure_ver_logged() {
    dst="$HOME/.provisioned_versions/$1"
    cmd="$2"
    ignore_cmd_errors="$3"
    if [ -s "$dst" ]; then
        return
    fi
    if [ -n "$ignore_cmd_errors" ]; then
        # run command in subshell
        ( eval "$cmd 2>&1" || true ) > "$dst"
    else
        eval "$cmd 2>&1" > "$dst"
    fi
}

cached_download_file() {
    url="$1"
    dest="${2:-./}"
    overwrite="$3"
    tfname="$4"
    (
        set -eo pipefail

        if [[ "$dest" == *"/" ]]; then
            fname="$(basename "$url")"
            # remove url fragment if there is one...
            fname="${fname%%#*}"
            # decode url basename
            fname="$(printf '%s' "$fname" | python -c "import sys, urllib; sys.stdout.write(urllib.unquote(sys.stdin.read()))")"
            dest="${dest}${fname}"
        else
            fname="$(basename "$dest")"
        fi
        if [ -z "$tfname" ]; then
            tfname="$fname"
        fi
        if [ -z "$overwrite" ] && [ -f "$dest" ]; then
            echo "File already exists: $dest"
            exit 0
        fi
        echo "Downloading FROM $url TO $dest ..."
        rm -f "/tmp/$tfname"
        curl -fsSL "$url" -o "/tmp/$tfname"
        mv "/tmp/$tfname" "$dest"
    )
}

ensure_line_append() {
    file="$1"
    line="$2"
    grep -qF -- "$line" "$file" || echo "$line" >> "$file"
}

init_bashrc() {
    (
        set -exo pipefail
        if [ ! -d ~/.bashrc.d/ ]; then
            install -d ~/.bashrc.d/ -m 0700
        fi
        if [ ! -f ~/.bashrc.original ]; then
            if [ -f ~/.bashrc ]; then
                cp -a ~/.bashrc ~/.bashrc.original
            else
                touch ~/.bashrc.original
            fi
        fi
        if [ ! -f ~/.bashrc.d/00_main_bashrc ]; then
            cp -a ~/.bashrc ~/.bashrc.d/00_main_bashrc
            chmod 0600 ~/.bashrc.d/00_main_bashrc
        fi
    )
}

build_bashrc() {
    (
        set -eo pipefail
        if [ ! -f ~/.bashrc.local ]; then
            cat <<'BASHRC_EOF' > ~/.bashrc.local
# stores cosmetic enhancements for human use not provided by the OS by default
# this file is generated once and only once, you can regenerate by deleting it and reprovisioning

alias git-sha='git log -1 --format="%H"'
alias predate="bash -c 'while IFS='' read -r line || [[ -n \"\$line\" ]]; do printf '\\''[%s] %s\\n'\\'' \"\`date -u \"+%Y-%m-%d %H:%M:%S\"\`\" \"\$line\"; done'"

# always keep this line last
export PS1='`printf "%02X" $?`:\w `git branch 2> /dev/null | grep -E ^* | sed -E s/^\\\\\*\ \(.+\)$/\(\\\\\1\)\ /`\$ '
BASHRC_EOF
        fi
        printf '%s' "$BASHRC_PRESERVED_FUNCTIONS" > ~/.bashrc.d/01_bashrcd_preserved_functions
        cat <<'BASHRC_EOF' > ~/.bashrc.d/99_local_bashrc
if [ -f ~/.bashrc.local ]; then
    . ~/.bashrc.local
fi
BASHRC_EOF
        filter_clause=''
        if [ -n "$1" ]; then
            filter_clause='! -name '"$1"
        fi
        find ~/.bashrc.d/ -maxdepth 1 -type f $(printf '%s' "$filter_clause") | \
        sort | \
        while read file; do
            printf '# [.bashrc.d] FROM %s\n' "$file"
            cat "$file"
            printf '\n'
        done
    )
}

update_bashrc() {
    (
        set -exo pipefail
        [ ! -f ~/.bashrc ] || mv ~/.bashrc ~/.bashrc.bak
        set +x ; build_bashrc 00_main_bashrc | install /dev/stdin -m 0600 ~/.bashrc.d.main ; set -x
        set +x ; build_bashrc | install /dev/stdin -m 0600 ~/.bashrc ; set -x
    )
}

new_bashrcd() {
    file_out="$HOME/.bashrc.d/$1"
    [ ! -f "$file_out" ] || rm -f "$file_out"
    install "${2:-/dev/stdin}" -m 0600 "$file_out"
    set +x ; . "$file_out" ; set -x
    update_bashrc
}

refresh_env_from_bashrc() {
  find ~/.bashrc.d/ -maxdepth 1 -type f -not -path ~/.bashrc.d/00_main_bashrc | \
    sort | \
    while read file; do
      . "$file"
    done
}
EOF

. /etc/provision_functions

echo initialize ~/.bashrc.d/
(
    sudo -u $USERNAME bash <<EOF
        set -eo pipefail ; . /etc/provision_functions ; set -x
        init_bashrc
        update_bashrc
        mkdir -p ~/.provisioned_versions
EOF

    mkdir -p ~/.provisioned_versions
)

ensure_line_append "/etc/resolv.conf" "nameserver 8.8.8.8"

echo update package lists
( set -exo pipefail ; export DEBIAN_FRONTEND=noninteractive ; apt-get update )




# VirtualBox Tweaks (1/2)
if ( is_virtualbox_provider ); then
(
    echo "running in a VirtualBox VM"
    echo "assuming vagrant VirtualBox provider and vm.box=debian/stretch64 ( debian 9 )"
    echo "Ensuring entire virtual disk can be used..."

    set -exo pipefail; export DEBIAN_FRONTEND=noninteractive

    # resize root disk to maximum capacity
    # if something goes wrong here you can comment out the whole block, destroy, and re-up
    if [ -e /dev/sda1 ] && [ -e /dev/sda2 ] && [ -e /dev/sda5 ]; then
        if ! (command -v partprobe); then
            apt-get install -y parted
            command -v partprobe
        fi
        lsblk
        fdisk_output="$(fdisk -l)"
        printf '%s\n' "$fdisk_output"
        old_swap_disk_uuid="$(\ls -la /dev/disk/by-uuid | grep sda5 | sed -E 's/^.*\s+([^\s]+) -> ..\/..\/sda5\s*$/\1/')"
        # subtracting 4 sectors from the fdisk output because the start sector is 2048
        # which with a block size of 512 consumes 4 sectors
        available_sectors=$(( $(printf '%s' "$fdisk_output" | grep 'Disk /dev/sda:' | sed -E 's/^.*\s+([0-9]+)\s+sectors\s*$/\1/') - 4))
        swap_sectors="$(printf '%s' "$fdisk_output" | grep /dev/sda5 | awk '{print $4}')"
        if [[ $available_sectors -gt $(( 16 * 1024 * 1024 * 1024 / 512 )) ]]; then
            echo 'There is over 16G of disk space, reserving 2G for swap'
            swap_sectors=$(( 2 * 1024 * 1024 * 1024 / 512 ))
        fi
        resized_sectors=$(( $available_sectors - $swap_sectors ))
        swapoff /dev/sda5
        ( set +eo pipefail ; fdisk -u /dev/sda <<EOF
p
d
2
d
1
n
p
1

$resized_sectors
N
a
n
p
2


t
2
82
p
w
EOF
true
)
        lsblk
        df -h
        partprobe
        resize2fs /dev/sda1
        lsblk
        df -h
        mkswap /dev/sda2
        swapon /dev/sda2
        while ! (\ls -la /dev/disk/by-uuid | grep sda2 | sed -E 's/^.*\s+([^\s]+) -> ..\/..\/sda2\s*$/\1/'); do
            sleep 1
        done
        new_swap_disk_uuid="$(\ls -la /dev/disk/by-uuid | grep sda2 | sed -E 's/^.*\s+([^\s]+) -> ..\/..\/sda2\s*$/\1/')"
        sed -i.bak "s/$old_swap_disk_uuid/$new_swap_disk_uuid/" /etc/fstab
        mount -a
    fi
)
fi




echo install basic linux packages
(
    set -exo pipefail ; export DEBIAN_FRONTEND=noninteractive
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        gnupg2 \
        software-properties-common \
        rsync \
        bash \
        make \
        jq \
        openssh-client \
        tar \
        netcat \
        curl \
        net-tools \
        dnsutils \
        vim \
        procps \
        htop \
        netcat \
        git \
        tmux \
        tmate \
        build-essential
)


# VirtualBox Tweaks (2/2)
if ( is_virtualbox_provider ); then
(
    echo "running in a VirtualBox VM"
    echo "assuming vagrant VirtualBox provider and vm.box=debian/stretch64 ( debian 9 )"
    echo "Installing virtualbox guest additions..."

    set -exo pipefail; export DEBIAN_FRONTEND=noninteractive

    apt-get install --no-install-recommends -yq linux-headers-$(uname -r)

    virtualbox_version="${VIRTUALBOX_VERSION:-5.2.22}"

    if [[ "$(modinfo vboxguest | grep -E ^version: | sed -E 's/^.*?([0-9]+\.[0-9]+\.[0-9]+).*?$/\1/;')" == "$virtualbox_version" ]]; then
        echo "Already installed virtualbox guest additions."
        exit 0
    fi

    fname="VBoxGuestAdditions_$virtualbox_version.iso"
    cached_download_file \
        https://download.virtualbox.org/virtualbox/$virtualbox_version/$fname \
        /opt/

    mpoint=/mnt/VBoxGuestAdditions
    mkdir -p $mpoint

    cd /opt
    mount "$fname" -o loop $mpoint
    set +eo pipefail
    (
        set -eo pipefail
        cd $mpoint
        sh VBoxLinuxAdditions.run
    )
    err_code=$1
    set -eo pipefail
    [[ $err_code -eq 0 ]] || (
        umount $mpoint
        exit $err_code
    )
    umount $mpoint
    rmdir $mpoint
)
fi

echo install base python runtime
(
    set -exo pipefail ; export DEBIAN_FRONTEND=noninteractive
    apt-get install -y python-setuptools
    command -v pip || easy_install pip
    pip install -U \
        pip \
        pipenv

    apt-get install -y \
        python-dev \
        zlib1g-dev \
        zlib1g \
        gzip \
        \
        libbz2-dev \
        bzip2 \
        \
        libreadline-dev \
        \
        openssl \
        libssl-dev \
        python-openssl \
        \
        build-essential
)

echo install rcode as an alias for rmate
(
    set -exo pipefail

    if ( command -v rcode ); then
        echo "rcode already installed"
        rcode --version || true
        exit 0
    fi

    rm -rf /tmp/rmate.dl.tmp
    curl -fsSL https://raw.github.com/aurora/rmate/master/rmate | install -m 755 /dev/stdin /tmp/rmate.dl.tmp

    # rmate has a non-zero exit code when calling --help and --version
    # so need to account for that
    #
    # test that the binary downloaded correctly
    ( /tmp/rmate.dl.tmp --version 2>&1 || true ) | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'

    # install the binary
    mv /tmp/rmate.dl.tmp /usr/local/bin/rmate
    ln -s rmate /usr/local/bin/rcode

    ensure_ver_logged rcode 'rcode --version' true
)

echo configure python version manager
(
    sudo -u $USERNAME bash <<'EOF'
        set -eo pipefail ; . /etc/provision_functions ; set -x

        if ( command -v pyenv ); then
            pyenv --version
        fi

        curl -fsSL https://github.com/pyenv/pyenv-installer/raw/master/bin/pyenv-installer | bash

        new_bashrcd 11_python_config <<'BASHRC_EOF'
export PYTHONUNBUFFERED=1
export PIPENV_VENV_IN_PROJECT=1
export PYENV_ROOT=~/.pyenv
export PYENV_HOME=$PYENV_ROOT
ensure_in_path "$PYENV_HOME/bin"
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"
BASHRC_EOF

        ensure_ver_logged pyenv 'pyenv --version'
        pyenv install --skip-existing 3.6.1

EOF
)

echo install golang base runtime requirements
(
    set -exo pipefail ; export DEBIAN_FRONTEND=noninteractive

    apt-get install -y \
        bison
)

echo install go version manager
(
    sudo -u $USERNAME bash <<'EOF'
        set -eo pipefail ; . /etc/provision_functions ; set -x

        if ( command -v gvm ); then
            if [ -s ~/.provisioned_versions/golang ]; then
                echo "GVM already installed"
                echo "If you want to use a different version of golang, see 'gvm help' command"
                gvm version
                gvm get
                gvm version
                exit 0
            fi
        else
            [ -e "$HOME/.gvm" ] || bash < <(curl -fsSL https://raw.githubusercontent.com/moovweb/gvm/master/binscripts/gvm-installer)
        fi

        new_bashrcd 12_golang_config <<'BASHRC_EOF'
. "$HOME/.gvm/scripts/gvm"
BASHRC_EOF

        ensure_ver_logged gvm 'gvm version'

        major_version=1
        latest_release="go$(set -eo pipefail ; gvm listall | grep -E '^\s*go'"$major_version"'\.[0-9]+(\.[0-9]+)?\s*$' | sed -E 's/^\s*go([^\s]+)\s*/\1/' | sort --version-sort | tail -1)"
        printf 'latest_release=%q' "$latest_release"
        gvm install "$latest_release" -B
        gvm use "$latest_release" --default
        ensure_ver_logged golang 'go version'
EOF
)

echo install node version manager
(
    sudo -u $USERNAME bash <<'EOF'
        set -eo pipefail ; . /etc/provision_functions ; set -x

        export NVM_DIR="$HOME/.nvm"
        if [ ! -d "$NVM_DIR" ]; then
            rm -rf "$NVM_DIR.clone_tmp"
            git clone https://github.com/creationix/nvm.git "$NVM_DIR.clone_tmp"
            mv "$NVM_DIR.clone_tmp" "$NVM_DIR"
        fi
        cd "$NVM_DIR"
        git fetch origin
        latest_nvm_release="$(git describe --abbrev=0 --tags --match "v[0-9]*" $(git rev-list --tags --max-count=1))"
        git log -1 --format="%H"
        git checkout -f "$latest_nvm_release"
        git log -1 --format="%H"

        new_bashrcd 13_node_config <<'BASHRC_EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[[ -r $NVM_DIR/bash_completion ]] && . $NVM_DIR/bash_completion
BASHRC_EOF

        # nvm is noisy as hell with set -x enabled
        # disabling it so people can remain sane
        set +x

        ensure_ver_logged nvm 'nvm --version ; ( echo ""; cd "$NVM_DIR" ; git log -1 --format="%H" )'

        if [[ "$(nvm ls --no-colors)" == *"default -> "* ]]; then
            echo "A default node version has already been selected"
            echo "default version = $(nvm ls --no-colors default | sed -E 's/^\s*->\s*//; s/\s*\*$//;')"
            echo "If you want to set a new default node version see 'nvm help' command"
            exit 0
        fi

        latest_release="$(nvm ls-remote --lts | grep Latest | sed -E 's/^\s*(v[0-9.]+)\s+.*$/\1/' | sort --version-sort | tail -1)"
        nvm install "$latest_release"
        nvm alias default "$latest_release"
        ensure_ver_logged node 'node --version'

        npm --version
        npm install -g npm@latest
EOF
)

echo install yarn npm package
(
    sudo -u $USERNAME bash <<'EOF'
        set -eo pipefail ; . /etc/provision_functions ; . ~/.bashrc.d.main ; set -x

        if ( command -v yarn ); then
            yarn --version
        fi
        npm install -g yarn@latest
        ensure_ver_logged yarn 'yarn --version'
EOF
)

echo install ruby
(
    if ! ( command -v gpg ) || ! ( command -v dirmngr ); then
    (
        set -exo pipefail ; export DEBIAN_FRONTEND=noninteractive
        echo "install pre-rvm installation dependencies"
        apt-get install -y gnupg2 dirmngr
    )
    fi
    sudo -u $USERNAME bash <<'EOF'
        set -eo pipefail ; . /etc/provision_functions ; set -x

        if ( command -v rvm ); then
            echo "rvm already installed"
            echo "update rvm only"
            ruby --version
            rvm --version
            rvm get stable
            rvm --version
            exit 0
        fi

        echo "install rvm"

        gpg --no-tty \
            --keyserver hkp://pool.sks-keyservers.net \
            --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 \
            7D2BAF1CF37B13E2069D6956105BD0E739499BDB

        curl -fsSL https://get.rvm.io | bash -s stable --ruby --ignore-dotfiles
        new_bashrcd 14_rvm_config <<'BASHRC_EOF'
export RVM_HOME="$HOME/.rvm"
. $RVM_HOME/scripts/rvm
BASHRC_EOF

        ensure_ver_logged rvm 'rvm --version'
        ensure_ver_logged ruby 'ruby --version'
EOF
)

echo install rust
(
    sudo -u $USERNAME bash <<'EOF'
        set -eo pipefail ; . /etc/provision_functions ; set -x

        export CARGO_HOME="$HOME/.cargo"

        echo install rustup
        (
            set -exo pipefail
            if ( command -v rustup ); then
                echo "Command rustup is already installed"
                echo "update rustup only"
                rustc --version
                rustup --version
                rustup self update
                rustup --version
                exit 0
            fi
            curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path
        )
        new_bashrcd 15_rustup_config <<'BASHRC_EOF'
export CARGO_HOME="$HOME/.cargo"
ensure_in_path "$CARGO_HOME/bin"
eval "$(rustup completions bash)"
BASHRC_EOF

        ensure_ver_logged rustup 'rustup --version'
        ensure_ver_logged rustc 'rustc --version'
EOF
)

echo install yamllint from https://github.com/adrienverge/yamllint
(
    if ( command -v yamllint ); then
        echo "yamllint is already installed"
        yamllint --version
        exit 0
    fi

    set -exo pipefail ; export DEBIAN_FRONTEND=noninteractive

    apt-get install -y \
        libyaml-dev

    version='==1.13.0'
    pip install "yamllint${version}"

    ensure_ver_logged yamllint 'yamllint --version'
)

echo install cfn-lint from https://github.com/awslabs/cfn-python-lint
(
    if ( command -v cfn-lint ); then
        echo "cfn-lint is already installed"
        cfn-lint --version
        exit 0
    fi

    set -exo pipefail ; export DEBIAN_FRONTEND=noninteractive

    apt-get install -y \
        libyaml-dev

    version='==0.11.1'
    pip install "cfn-lint${version}"

    ensure_ver_logged cfn-lint 'cfn-lint --version'
)

echo install jsonlint from nodejs packages
(
    sudo -u $USERNAME bash <<'EOF'
        set -eo pipefail ; . /etc/provision_functions ; . ~/.bashrc.d.main ; set -x

        if ( command -v jsonlint ); then
            echo "jsonlint is already installed"
            jsonlint --version || true
            exit 0
        fi

        version='@1.6.3'
        npm install -g "jsonlint${version}"

        ensure_ver_logged jsonlint 'jsonlint --version' true
EOF
)

echo install crystal version manager
(
    set -eo pipefail

    (
        set -exo pipefail ; export DEBIAN_FRONTEND=noninteractive
        echo "install crystallang compiler requirements"
        apt-get install -y \
            libssl-dev \
            libxml2-dev \
            libyaml-dev \
            libgmp-dev \
            \
            libreadline-dev \
            \
            libpcre3 \
            libpcre3-dev \
            \
            libgc-dev \
            \
            libevent-dev

        sudo apt autoremove
    )

    sudo -u $USERNAME bash <<'EOF'
        set -eo pipefail ; . /etc/provision_functions ; set -x

        if ( command -v crenv ); then
            echo "crenv is already installed"
            echo "update crenv only"
            if ( command -v crystal ); then
                crystal --version
            fi
            crenv --version
            crenv update
            crenv --version
        else
            curl -fsSL https://raw.github.com/pine/crenv/master/install.sh | bash

            new_bashrcd 16_crystallang_config <<'BASHRC_EOF'
export CRENV_HOME="$HOME/.crenv"
ensure_in_path "$CRENV_HOME/bin"
eval "$(crenv init -)"
BASHRC_EOF

            ensure_ver_logged crenv 'crenv --version'
        fi

        if ( command -v crystal ); then
            echo "crystal is already installed"
            crystal --version
            exit 0
        fi

        version="0.25.1"
        if [ -z "$version" ]; then
            version="$(crenv install -l | sort --version-sort | tail -1 | sed -E 's/^\s+//; s/\s+$//;')"
        fi

        crenv install "$version"
        crenv global "$version"

        ensure_ver_logged crystal 'crystal --version'
EOF
)

echo install java version manager
(
    set -eo pipefail

    (
        set -exo pipefail ; export DEBIAN_FRONTEND=noninteractive

        version='8'

        apt-get install -y \
            "openjdk-$version-jre-headless" \
            "openjdk-$version-jdk"
    )

    sudo -u $USERNAME bash <<'EOF'
        set -eo pipefail ; . /etc/provision_functions ; set -x

        export JENV_DIR="$HOME/.jenv"
        if [ ! -d "$JENV_DIR" ]; then
            rm -rf "$JENV_DIR.clone_tmp"
            git clone https://github.com/gcuisinier/jenv.git "$JENV_DIR.clone_tmp"
            mv "$JENV_DIR.clone_tmp" "$JENV_DIR"
        fi
        cd "$JENV_DIR"
        git fetch origin
        latest_jenv_release="$(git describe --abbrev=0 --tags --match "[0-9]*" $(git rev-list --tags --max-count=1))"
        git log -1 --format="%H"
        git checkout -f "$latest_jenv_release"
        git log -1 --format="%H"

        new_bashrcd 17_java_config <<'BASHRC_EOF'
export JENV_DIR="$HOME/.jenv"
ensure_in_path "$JENV_DIR/bin"
eval "$(jenv init -)"
BASHRC_EOF

        # jenv is noisy as hell with set -x enabled
        # disabling it so people can remain sane
        set +x

        jenv rehash

        ensure_ver_logged jenv 'jenv --version ; ( echo ""; cd "$JENV_DIR" ; git log -1 --format="%H" )'
EOF
)

echo install docker
(
    set -exo pipefail ; export DEBIAN_FRONTEND=noninteractive

    [ -f /etc/apt/sources.list.d/docker.list ] || touch /etc/apt/sources.list.d/.docker.list.needs-update

    curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -
    printf 'deb [arch=amd64] https://download.docker.com/linux/debian %s stable' "$(lsb_release -cs)" > /etc/apt/sources.list.d/docker.list

    if [ -f /etc/apt/sources.list.d/.docker.list.needs-update ]; then
        apt-get update
        rm /etc/apt/sources.list.d/.docker.list.needs-update
    fi

    apt-get install -y docker-ce

    usermod -a -G docker $USERNAME

    ensure_ver_logged docker 'docker --version'
)

echo install google chrome
(
    set -exo pipefail ; export DEBIAN_FRONTEND=noninteractive

    chrome_version="71.0.3578.98-1"
    # looks like remote versions rotate out pretty often, just going to install some version of stable...
    # this is done by setting the version to an empty string
    chrome_version=""

    [ -f /etc/apt/sources.list.d/google.list ] || touch /etc/apt/sources.list.d/.google.list.needs-update

    curl -fsSL https://dl-ssl.google.com/linux/linux_signing_key.pub | apt-key add -
    printf "deb https://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google.list

    if [ -f /etc/apt/sources.list.d/.google.list.needs-update ]; then
        apt-get update
        rm /etc/apt/sources.list.d/.google.list.needs-update
    fi

    apt-get install -y google-chrome-stable$( test -z "$chrome_version" || printf "=%s" "$chrome_version")
    ensure_ver_logged google-chrome 'google-chrome --version'
)




# second to last, remove provisioning helper script
rm /etc/provision_functions

# last two lines: set the last provisioned timestamp
[ ! -f /etc/provisioned_at ] || cp -a /etc/provisioned_at /etc/provisioned_at.bak
date +%s > /etc/provisioned_at
