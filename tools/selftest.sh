#!/bin/zsh
# Runs the in-app self-test against a fresh store, a fixture home folder, and
# a stand-in Trash, all in /tmp. Exit code 0 when every check passed.
set -u
rm -rf ~/Library/Saved\ Application\ State/com.peri.steward.savedState
store=/tmp/Steward-self.store
rm -f $store $store-shm $store-wal
rm -rf /tmp/Steward-self-home /tmp/Steward-self-trash /tmp/Steward-self-outside "/tmp/Steward-self Holding"
APP_STORE=$store APP_HOME=/tmp/Steward-self-home APP_TRASH=/tmp/Steward-self-trash \
  ~/Applications/Steward.app/Contents/MacOS/Steward --selftest
