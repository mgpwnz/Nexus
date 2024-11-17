#!/bin/bash
# Default variables
function="install"
NEXUS_HOME=$HOME/.nexus
NEXUS_PATH="$HOME/.nexus/network-api/clients/cli/target/release/prover"
# Options
option_value(){ echo "$1" | sed -e 's%^--[^=]*=%%g; s%^-[^=]*=%%g'; }

while test $# -gt 0; do
    case "$1" in
        -in|--install)
            function="install"
            shift
            ;;
        -up|--update)
            function="update"
            shift
            if [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                version="$1"
                shift
            fi
            ;;
        -un|--uninstall)
            function="uninstall"
            shift
            ;;
        *|--)
            break
            ;;
    esac
done

install() {
    sudo apt update && sudo apt upgrade -y
    sudo apt install curl iptables build-essential git wget lz4 jq make gcc nano automake autoconf tmux htop nvme-cli pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip libleveldb-dev -y
    sudo curl https://sh.rustup.rs -sSf | sh -s -- -y
    source $HOME/.cargo/env
    export PATH="$HOME/.cargo/bin:$PATH"
    rustup update
    #check dir
    if [ ! -d "$NEXUS_HOME/network-api" ]; then
        mkdir -p $NEXUS_HOME
        cd $NEXUS_HOME && git clone https://github.com/nexus-xyz/network-api
        cd $NEXUS_HOME/network-api/clients/cli && cargo build --release
        cd $HOME
        # Create the systemd service file
        sudo tee /etc/systemd/system/nexus.service > /dev/null <<EOF
[Unit]
Description=Nexus Node
After=network-online.target

[Service]
User=$USER
Environment=PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.cargo/bin
ExecStart=$NEXUS_PATH beta.orchestrator.nexus.xyz
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

        sudo systemctl enable nexus.service
        sudo systemctl daemon-reload
        sudo systemctl start nexus.service

    else
        echo "$NEXUS_HOME/network-api exists. Updating."
        (cd $NEXUS_HOME/network-api && git pull)
        sudo systemctl restart nexus.service
    fi
    sudo journalctl -u nexus -f
}

update() {
    sudo apt update && sudo apt upgrade -y

    if [ -d "$NEXUS_HOME" ]; then
        echo "Directory $NEXUS_HOME exists. Checking for updates..."
        (cd $NEXUS_HOME/network-api && git pull)
        sudo systemctl restart nexus.service
        sudo journalctl -u nexus -f
    fi
}

uninstall() {
    if [ ! -d "$NEXUS_HOME" ]; then
        echo "Directory $NEXUS_HOME does not exist. Nothing to uninstall."
        return 0
    fi

    read -r -p "Wipe all DATA? [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            sudo systemctl stop nexus.service  
            sudo systemctl disable nexus.service
            sudo systemctl daemon-reload
            rm -rf "$NEXUS_HOME"
            sudo rm -f /etc/systemd/system/nexus.service

            echo "Nexus successfully uninstalled and data wiped."
            ;;
        *)
            echo "Canceled"
            return 0
            ;;
    esac
}

# Install necessary packages and execute the function
sudo apt install wget jq -y &>/dev/null
cd
$function
