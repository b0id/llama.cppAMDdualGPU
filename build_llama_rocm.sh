#!/bin/bash

# llama.cpp ROCm Build Script for Dual RX 7900 XTX
# Specifically tailored for EndeavourOS with ROCm 6.3.3 and gfx1100 architecture

# Configuration
LLAMA_CPP_DIR="$HOME/llama.cpp"
BUILD_DIR="${LLAMA_CPP_DIR}/build"
LOG_DIR="${LLAMA_CPP_DIR}/build_logs"
ROCM_PATH="/opt/rocm"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="${LOG_DIR}/build_log_${TIMESTAMP}.txt"

# Color codes for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to log messages
log() {
    echo -e "${BLUE}[$(date +"%T")]${NC} $1" | tee -a "$LOG_FILE"
}

# Function to log errors
error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

# Function to log success
success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

# Function to log warnings
warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Initialize log file
echo "Build Log - $(date)" >"$LOG_FILE"
echo "=================================" >>"$LOG_FILE"

# Check if llama.cpp directory exists
if [ ! -d "$LLAMA_CPP_DIR" ]; then
    error "llama.cpp directory not found at $LLAMA_CPP_DIR"
    log "Cloning the repository from GitHub..."
    git clone https://github.com/ggerganov/llama.cpp.git "$LLAMA_CPP_DIR"
    if [ $? -ne 0 ]; then
        error "Failed to clone llama.cpp repository"
        exit 1
    fi
    success "Repository cloned successfully"
else
    log "Found existing llama.cpp directory at $LLAMA_CPP_DIR"

    # Ask if user wants to update the repository
    read -p "Do you want to update the repository? (y/n): " update_repo
    if [[ $update_repo == "y" || $update_repo == "Y" ]]; then
        log "Updating llama.cpp repository..."
        cd "$LLAMA_CPP_DIR" && git pull
        if [ $? -ne 0 ]; then
            warning "Failed to update repository, continuing with existing code"
        else
            success "Repository updated successfully"
        fi
    fi
fi

# Check if ROCm is installed and accessible
if [ ! -d "$ROCM_PATH" ]; then
    error "ROCm path not found at $ROCM_PATH"
    exit 1
fi

log "ROCm path found at $ROCM_PATH"

# Verify required packages are installed
REQUIRED_PACKAGES=("rocm-hip-sdk" "hipblas" "rocblas" "rocm-cmake" "rocm-llvm")
MISSING_PACKAGES=()

for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! pacman -Q "$pkg" &>/dev/null; then
        MISSING_PACKAGES+=("$pkg")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -ne 0 ]; then
    warning "Some required packages are missing: ${MISSING_PACKAGES[*]}"
    read -p "Do you want to install them now? (y/n): " install_pkgs
    if [[ $install_pkgs == "y" || $install_pkgs == "Y" ]]; then
        log "Installing missing packages..."
        sudo pacman -Syu "${MISSING_PACKAGES[@]}"
        if [ $? -ne 0 ]; then
            error "Failed to install required packages"
            exit 1
        fi
        success "Packages installed successfully"
    else
        warning "Continuing without installing required packages. Build might fail."
    fi
else
    log "All required packages are installed"
fi

# Optional: Check for rocwmma-dev package for potential performance improvements
if ! pacman -Q "rocwmma-dev" &>/dev/null; then
    warning "rocwmma-dev package is not installed. This package can improve flash attention performance."
    read -p "Do you want to install rocwmma-dev? (y/n): " install_rocwmma
    if [[ $install_rocwmma == "y" || $install_rocwmma == "Y" ]]; then
        log "Installing rocwmma-dev..."
        sudo pacman -Syu rocwmma-dev
        if [ $? -ne 0 ]; then
            warning "Failed to install rocwmma-dev, continuing without it"
        else
            success "rocwmma-dev installed successfully"
        fi
    fi
fi

# Remove old build directory if it exists
if [ -d "$BUILD_DIR" ]; then
    log "Removing old build directory..."
    rm -rf "$BUILD_DIR"
    if [ $? -ne 0 ]; then
        error "Failed to remove old build directory"
        exit 1
    fi
fi

# Create fresh build directory
log "Creating fresh build directory..."
mkdir -p "$BUILD_DIR"
if [ $? -ne 0 ]; then
    error "Failed to create build directory"
    exit 1
fi

# Set up environment variables
log "Setting up environment variables for ROCm build..."
export HIP_PATH=$(hipconfig -R)
export HIPCXX=$(hipconfig -l)/clang

# Log the environment variables
log "HIP_PATH set to: $HIP_PATH"
log "HIPCXX set to: $HIPCXX"

# Check if HIP device library path needs to be set
DEVICE_LIB=$(find "$HIP_PATH" -name oclc_abi_version_400.bc -exec dirname {} \; 2>/dev/null | head -n 1)
if [ -n "$DEVICE_LIB" ]; then
    log "Found device library at: $DEVICE_LIB"
    log "Setting HIP_DEVICE_LIB_PATH environment variable"
    export HIP_DEVICE_LIB_PATH="$DEVICE_LIB"
else
    warning "Could not find device library path. If build fails with device library errors, you may need to set HIP_DEVICE_LIB_PATH manually."
fi

# Ask if user wants to use rocWMMA for potential performance improvement
USE_ROCWMMA=OFF
if pacman -Q "rocwmma-dev" &>/dev/null; then
    read -p "Do you want to enable rocWMMA for potential flash attention performance improvement? (y/n): " use_rocwmma
    if [[ $use_rocwmma == "y" || $use_rocwmma == "Y" ]]; then
        USE_ROCWMMA=ON
        log "Enabling rocWMMA for flash attention"
    fi
fi

# Ask if user wants to build server (API)
BUILD_SERVER=OFF
read -p "Do you want to build the server (API) version as well? (y/n): " build_server
if [[ $build_server == "y" || $build_server == "Y" ]]; then
    BUILD_SERVER=ON
    log "Will build server (API) version"
fi

# Ask if user wants to enable both GPUs
ENABLE_MULTIGPU=OFF
read -p "Do you want to enable multi-GPU support for your dual RX 7900 XTX setup? (y/n): " enable_multigpu
if [[ $enable_multigpu == "y" || $enable_multigpu == "Y" ]]; then
    ENABLE_MULTIGPU=ON
    log "Enabling multi-GPU support"
fi

# Configure CMake
log "Configuring CMake..."
cd "$LLAMA_CPP_DIR" || {
    error "Failed to change to llama.cpp directory"
    exit 1
}

# Build command
CMAKE_ARGS=(
    -S.
    -Bbuild
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DGGML_HIP=ON
    -DAMDGPU_TARGETS=gfx1100
    -DLLAMA_CUBLAS=OFF
)

# Add optional flags based on user choices
if [ "$USE_ROCWMMA" = "ON" ]; then
    CMAKE_ARGS+=(-DGGML_HIP_ROCWMMA_FATTN=ON)
fi

if [ "$BUILD_SERVER" = "ON" ]; then
    CMAKE_ARGS+=(-DLLAMA_BUILD_SERVER=ON)
fi

if [ "$ENABLE_MULTIGPU" = "ON" ]; then
    CMAKE_ARGS+=(-DLLAMA_HIP_FORCE_DISABLE=OFF)
fi

# Execute CMake command
log "Running CMake with the following arguments: ${CMAKE_ARGS[*]}"
cmake "${CMAKE_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    error "CMake configuration failed"
    exit 1
fi

success "CMake configuration completed successfully"

# Build with Ninja
log "Building llama.cpp with Ninja..."
cd "$BUILD_DIR" || {
    error "Failed to change to build directory"
    exit 1
}
ninja -j$(nproc) 2>&1 | tee -a "$LOG_FILE"

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    error "Build failed"
    exit 1
fi

success "Build completed successfully!"

# List the built binaries
log "Built binaries:"
find "$BUILD_DIR/bin" -type f -executable -print | tee -a "$LOG_FILE"

# Test GPU detection
if [ -f "$BUILD_DIR/bin/llama-cli" ]; then
    log "Testing GPU detection..."
    "$BUILD_DIR/bin/llama-cli" --list-devices 2>&1 | tee -a "$LOG_FILE"
fi

log "Build script completed!"
echo -e "${GREEN}=========================${NC}"
echo -e "${GREEN}  Build Log: $LOG_FILE ${NC}"
echo -e "${GREEN}=========================${NC}"

# Show usage examples
cat <<EOF

Example usage for single GPU:
  ./build/bin/llama-cli -m /path/to/model.gguf -n 512 -ngl 99

Example usage for dual GPUs:
  ./build/bin/llama-cli -m /path/to/model.gguf -n 512 -ngl 99 -ts 8192
  
To test GPU offloading:
  ./build/bin/llama-benchmark -m /path/to/model.gguf -ngl 99

If you built the server, start it with:
  ./build/bin/llama-server -m /path/to/model.gguf -ngl 99

EOF
