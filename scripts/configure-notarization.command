#!/bin/zsh
# Run this directly in Terminal. notarytool prompts locally and stores in Keychain.
# Do not paste your Apple account password or app-specific password into chat.
set -e
print 'Configure the tactile notarization profile in your login Keychain.'
print 'Enter the account details only into the prompts below.'
print 'Developer team: Q73Q75XA2B'
xcrun notarytool store-credentials tactile
print 'Credential setup completed. You can close this Terminal window.'
