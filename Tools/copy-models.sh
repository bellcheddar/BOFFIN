#!/bin/bash
# Copy the Core ML models the app needs into its bundle.
#
# A build phase rather than a folder reference, because a folder reference to
# Models/ would also ship everything else that lives there: the PyTorch
# weights the heads were trained from, the parity reference tensors, and a
# 128 MB fine-tuned backbone kept from an experiment. The bundle would be
# nearly twice the size and would carry training artefacts to users.
#
# This exists because an archive built without it produced a 7.6 MB app with
# NO models in it. That app installs, launches and runs, and every analysis
# reports "Analysis models are not bundled in this build" -- a TestFlight
# build that cannot do the thing the app is for, and nothing about the build
# said so.
#
# `SequenceStore.modelDirectory` looks for a "Models" directory in the bundle
# and falls back, in DEBUG only, to the source tree. That fallback is why this
# was never noticed: every simulator build found the models by another route.
set -euo pipefail

SOURCE="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}/Models"
DEST="${BUILT_PRODUCTS_DIR:-/tmp}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-BOFFIN.app}/Models"

# The models are gitignored, so CI has none. Skipping is correct there: CI
# builds and tests the app, and the tests that need a model already check for
# it and skip themselves. Failing here would turn "no models on this machine"
# into a broken build.
if [ ! -d "$SOURCE" ]; then
    echo "note: no Models directory at $SOURCE, skipping the model copy"
    exit 0
fi

WANTED=(
    "esm2_t12_35M_UR50D.mlpackage"
    "esm2_t12_35M_UR50D.scoring.mlpackage"
    "esm2_t12_35M_UR50D.tokeniser.json"
    "heads/disorder.mlpackage"
    "heads/secondary_structure.mlpackage"
    "heads/topology.mlpackage"
    "heads/family.mlpackage"
    "heads/family_labels.json"
    "heads/config.json"
)

mkdir -p "$DEST/heads"
copied=0
for item in "${WANTED[@]}"; do
    if [ ! -e "$SOURCE/$item" ]; then
        # Named individually rather than globbed, so a model that stops being
        # produced is reported here instead of silently not shipping.
        echo "warning: $item is missing from Models/, the app will degrade without it"
        continue
    fi
    # rsync rather than cp: the models are 138 MB and this runs on every
    # build, so it has to be incremental or it dominates the build time.
    rsync -a --delete "$SOURCE/$item" "$DEST/$(dirname "$item")/"
    copied=$((copied + 1))
done
echo "note: copied $copied of ${#WANTED[@]} model items into the bundle"
