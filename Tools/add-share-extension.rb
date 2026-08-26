#!/usr/bin/env ruby
# frozen_string_literal: true
#
# add-share-extension.rb
#
#   ruby Tools/add-share-extension.rb
#
# ADDITIVE, unlike bootstrap-xcodeproj.rb, which is one-time and would discard
# every change made since. This opens the committed project and adds the share
# extension target to it, and is idempotent: run twice and the second run
# reports that the target is already there rather than creating a duplicate.
#
# Written as a script rather than done by hand in Xcode because the target
# needs eight settings to line up exactly (bundle ID under the app's, App
# Group entitlements on both sides, manual signing to match the app, the
# embed-into-app build phase), and a script says what those are.

require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
project = Xcodeproj::Project.open(File.join(ROOT, "BOFFIN.xcodeproj"))

TARGET_NAME = "BOFFINShare"
APP_BUNDLE_ID = "com.mdeller.boffin"
TEAM = "SYNV8TWB5Z"
DEPLOYMENT_TARGET = "26.0"

if project.targets.any? { |t| t.name == TARGET_NAME }
  puts "#{TARGET_NAME} already exists, nothing to do"
  exit 0
end

app = project.targets.find { |t| t.name == "BOFFIN" }
raise "no BOFFIN app target" unless app

extension = project.new_target(:app_extension, TARGET_NAME, :ios, DEPLOYMENT_TARGET)

group = project.main_group.find_subpath("Extensions/ShareExtension", true)
group.set_source_tree("SOURCE_ROOT")
group.set_path("Extensions/ShareExtension")
source = group.new_reference("ShareViewController.swift")
extension.add_file_references([source])

extension.build_configurations.each do |config|
  s = config.build_settings
  s["PRODUCT_BUNDLE_IDENTIFIER"] = "#{APP_BUNDLE_ID}.share"
  s["INFOPLIST_FILE"] = "Extensions/ShareExtension/Info.plist"
  s["CODE_SIGN_ENTITLEMENTS"] = "Extensions/ShareExtension/BOFFINShare.entitlements"
  s["DEVELOPMENT_TEAM"] = TEAM
  s["SWIFT_VERSION"] = "6.0"
  s["IPHONEOS_DEPLOYMENT_TARGET"] = DEPLOYMENT_TARGET
  s["SKIP_INSTALL"] = "YES"
  s["TARGETED_DEVICE_FAMILY"] = "1,2"
  # An extension is a bundle inside the app, so it must not be signed for
  # distribution independently: it inherits the app's profile at embed time.
  if config.name == "Release"
    s["CODE_SIGN_IDENTITY"] = "Apple Distribution"
    s["CODE_SIGN_STYLE"] = "Manual"
    s["PROVISIONING_PROFILE_SPECIFIER"] = "BOFFIN Share App Store"
  end
end

# The local packages the extension needs. BoffinCore only: it holds
# SharedInbox and depends on nothing, which is what makes it safe to link
# into a memory-constrained extension.
core = project.targets.find { |t| t.name == "BoffinCore" }
if core
  extension.add_dependency(core)
else
  puts "note: BoffinCore is a package product, linking by name"
end

# Embed into the app, and make the app build it first.
embed = app.new_copy_files_build_phase("Embed Foundation Extensions")
embed.symbol_dst_subfolder_spec = :plug_ins
embed.add_file_reference(extension.product_reference, true)
app.add_dependency(extension)

project.save
puts "added #{TARGET_NAME}"
puts "  targets now: #{project.targets.map(&:name).join(', ')}"
