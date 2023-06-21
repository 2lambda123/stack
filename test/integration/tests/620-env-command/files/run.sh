#!/usr/bin/env bash

set -euxo pipefail

stack build --resolver lts-21.0 async
eval `stack config env --resolver lts-21.0`
ghc Main.hs
