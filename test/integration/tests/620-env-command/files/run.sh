#!/usr/bin/env bash

set -euxo pipefail

stack build --resolver nightly-2023-06-18 async
eval `stack config env --resolver nightly-2023-06-18`
ghc Main.hs
