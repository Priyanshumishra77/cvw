#!/usr/bin/bash

mv runs runArchive/$(date +"%Y_%m_%d_%I_%M_%p")
mv newRuns runs
mkdir newRuns
./wallySynth.py