#!/bin/bash

set -ex

pip3 install polygraphy==0.49.26

# Clean up pip cache and temporary files
pip3 cache purge
rm -rf ~/.cache/pip
rm -rf /tmp/*
