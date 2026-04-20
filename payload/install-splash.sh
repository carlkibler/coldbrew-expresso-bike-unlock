#!/bin/bash
# Install Coldbrew splash screen on the Expresso bike
set -e

DEST="/usr/local/expresso/coldbrew"
SCRIPT="/usr/local/expresso/coldbrew-splash.py"
BASHRC="/home/expresso/.bashrc"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing Coldbrew splash..."

# Install pygame if missing
if ! python3 -c "import pygame" 2>/dev/null; then
    echo "Installing pygame..."
    sudo apt-get install -y python3-pygame 2>/dev/null || \
        sudo pip install pygame 2>/dev/null || \
        echo "Warning: pygame install failed — splash will be skipped gracefully"
fi

# Copy images
sudo mkdir -p "$DEST"
sudo cp "$SCRIPT_DIR/coldbrew/"*.jpg "$DEST/"
sudo chmod 644 "$DEST/"*.jpg

# Copy splash script
sudo cp "$SCRIPT_DIR/coldbrew-splash.py" "$SCRIPT"
sudo chmod 755 "$SCRIPT"

# Patch game-start alias in .bashrc if not already done
if grep -q "coldbrew-splash" "$BASHRC"; then
    echo "Splash already wired into game-start, skipping."
else
    # Find the game-start alias and prepend the splash call
    sed -i "s|alias game-start='|alias game-start='python3 $SCRIPT \&\& |g" "$BASHRC"
    echo "Patched game-start in $BASHRC"
fi

echo "Done. Restart shell or run: source ~/.bashrc"
echo "Test with: python3 $SCRIPT"
