#!/bin/bash
# This script sets up a single-node Kubernetes cluster using kubeadm.
# It supports AMD GPUs (default) and Nvidia GPUs.
# The script includes functions for cleanup, initialization, and cluster creation.
# It also applies necessary configurations such as networking (Flannel)
# and GPU device plugins for Kubernetes.
set -e
set -o pipefail

# URLs for resources
FLANNEL_URL="https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"

# AMD GPU resources
AMDGPU_DP_URL="https://raw.githubusercontent.com/ROCm/k8s-device-plugin/master/k8s-ds-amdgpu-dp.yaml"
AMDGPU_LABELLER_URL="https://raw.githubusercontent.com/ROCm/k8s-device-plugin/master/k8s-ds-amdgpu-labeller.yaml"

# Nvidia GPU resources - using local custom YAML with proper device mounts
NVIDIAGPU_DP_URL="https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.1/deployments/static/nvidia-device-plugin.yml"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Usage function
usage() {
    echo "Usage: $0 {cleanup|init|create} [gpu-type]"
    echo "  gpu-type: amd or nvidia"
    echo ""
    echo "Examples:"
    echo "  $0 init amd         # Initialize system for AMD GPU (default)"
    echo "  $0 init nvidia      # Initialize system for Nvidia GPU (configures CRI-O runtime)"
    echo "  $0 create amd       # Creates cluster with AMD GPU support"
    echo "  $0 create nvidia    # Creates cluster with Nvidia GPU support"
    echo "  $0 cleanup          # Cleanup existing cluster"
    exit 1
}

# Dependency check
check_dependencies() {
    for cmd in kubectl kubeadm; do
        if ! command -v $cmd &>/dev/null; then
            log "Error: $cmd is not installed."
            exit 1
        fi
    done
}

# Cleanup function
cleanup() {
    echo "Running cleanup..."

    sudo kubeadm reset -f
    rm -rf "$HOME/.kube/"
    rm -rf /var/lib/gkm/caches/*

    sudo systemctl daemon-reload
    sudo systemctl restart kubelet
    sudo systemctl restart crio
    sudo ls /etc/cni/net.d
    sudo rm -rf /etc/cni/net.d/*
    sudo rm /etc/systemd/zram-generator.conf
    sudo swapon -av
    sudo free -h
    sudo setenforce 1
    sudo systemctl start firewalld
    echo "Cleanup completed."
}

# Configure Nvidia runtime for CRI-O
configure_nvidia_runtime() {
    log "Configuring Nvidia runtime for CRI-O..."

    # Check if nvidia-ctk is installed
    if ! command -v nvidia-ctk &>/dev/null; then
        log "Error: nvidia-ctk is not installed."
        log "Please install it first: sudo dnf install nvidia-container-toolkit"
        exit 1
    fi

    # Configure CRI-O to use nvidia runtime (uses crun with CDI)
    log "Creating Nvidia runtime configuration for CRI-O..."
    sudo nvidia-ctk runtime configure --runtime=crio --set-as-default --config=/etc/crio/crio.conf.d/99-nvidia.conf

    # Configure crun as a runtime for the nvidia-container-runtime
    if ! cat /etc/nvidia-container-runtime/config.toml | grep runtimes | grep -q crun; then
        log "Adding crun as as runtime for the nvidia-container-runtime..."
        sudo cp -f /etc/nvidia-container-runtime/config.toml /etc/nvidia-container-runtime/config.toml.gkm-save
        sudo sed -e 's/runtimes = [\(.*\)]/runtimes = [\\1 "crun"]/' \
            -i /etc/nvidia-container-runtime/config.toml
    fi

    # Restart CRI-O to apply changes
    log "Restarting CRI-O to apply Nvidia runtime configuration..."
    sudo systemctl restart crio

    # Verify CRI-O is running
    if sudo systemctl is-active --quiet crio; then
        log "CRI-O is running with Nvidia runtime configured"
        sudo systemctl status crio --no-pager | head -10
    else
        log "Error: CRI-O failed to start after Nvidia configuration"
        sudo systemctl status crio --no-pager
        exit 1
    fi

    log "Nvidia runtime configuration completed."
}

# Initialization function
init() {
    local gpu_type="$1" # Default to AMD if not specified

    # Normalize GPU type to lowercase
    gpu_type="${gpu_type,,}"

    if [[ "$gpu_type" != "amd" && "$gpu_type" != "nvidia" ]]; then
        log "Error: Invalid GPU type '$gpu_type'. Use 'amd' or 'nvidia'."
        usage
    fi

    log "Initializing system for $gpu_type GPU support..."
    sudo tee /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

    sudo modprobe overlay
    sudo modprobe br_netfilter

    lsmod | grep br_netfilter
    lsmod | grep overlay

    sudo tee /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    sudo sysctl --system

    for sysvar in net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward; do
        sysctl $sysvar
    done

    # Configure Nvidia runtime if needed
    if [[ "$gpu_type" == "nvidia" ]]; then
        configure_nvidia_runtime
    fi

    log "Initialization completed for $gpu_type GPU support."
}

# Cluster creation function
create() {
    local gpu_type="$1" # Default to AMD if not specified

    # Normalize GPU type to lowercase
    gpu_type="${gpu_type,,}"

    if [[ "$gpu_type" != "amd" && "$gpu_type" != "nvidia" ]]; then
        log "Error: Invalid GPU type '$gpu_type'. Use 'amd' or 'nvidia'."
        usage
    fi

    log "Running Kubernetes init and setup with $gpu_type GPU support..."
    sudo touch /etc/systemd/zram-generator.conf
    sudo setenforce 0
    sudo swapoff -av
    sudo systemctl stop firewalld
    sudo kubeadm init --v 99 --pod-network-cidr=10.244.0.0/16 --cri-socket /var/run/crio/crio.sock
    rm -f "$HOME/.kube/config"
    mkdir -p "$HOME/.kube"
    sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
    sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
    kubectl get nodes
    kubectl describe node
    kubectl apply -f "$FLANNEL_URL"
    kubectl describe node

    # Deploy GPU-specific device plugins
    if [[ "$gpu_type" == "amd" ]]; then
        log "Deploying AMD GPU device plugins..."
        kubectl create -f "$AMDGPU_DP_URL"
        kubectl create -f "$AMDGPU_LABELLER_URL"
    elif [[ "$gpu_type" == "nvidia" ]]; then
        log "Deploying Nvidia GPU device plugin..."
        kubectl create -f "$NVIDIAGPU_DP_URL"
    fi

    log "Cluster creation and configuration completed with $gpu_type GPU support."
}

# Main execution
if [[ "$#" -lt 1 ]] || [[ "$#" -gt 2 ]]; then
    usage
fi

check_dependencies

COMMAND="$1"

case "$COMMAND" in
cleanup)
    cleanup
    ;;
init | create)
    if [ $# -eq 2 ]; then
        $COMMAND "$2"
    else
        log "No gpu type specified"
        usage
    fi
    ;;
*)
    usage
    ;;
esac
