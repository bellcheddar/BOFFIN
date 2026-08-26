#!/usr/bin/env ruby
# frozen_string_literal: true
#
# add-app-extension.rb NAME BUNDLE_SUFFIX DIRECTORY [PACKAGE ...]
#
#   ruby Tools/add-app-extension.rb BOFFINQuickLook quicklook \
#        Extensions/QuickLookExtension BoffinCore
#
# ADDITIVE and idempotent, unlike bootstrap-xcodeproj.rb, which is one-time and
# whose own header says re-running it discards every change made since.
#
# Generalised from add-share-extension.rb after the second extension needed the
# same eight settings to line up. The settings are the point of the script: an
# extension whose bundle ID is not under the app's, or which links a package as
# a target dependency rather than a package PRODUCT dependency, fails at link
# or embed time with an error that names something else.

require "xcodeproj"

name, suffix, directory = ARGV[0], ARGV[1], ARGV[2]
packages = ARGV[3..] || []
abort "usage: add-app-extension.rb NAME SUFFIX DIRECTORY [PACKAGE ...]" unless directory

ROOT = File.expand_path("..", __dir__)
project = Xcodeproj::Project.open(File.join(ROOT, "BOFFIN.xcodeproj"))

APP_BUNDLE_ID = "com.mdeller.boffin"
TEAM = "SYNV8TWB5Z"
DEPLOYMENT_TARGET = "26.0"

if project.targets.any? { |t| t.name == name }
  puts "#{name} already exists, nothing to do"
  exit 0
end

app = project.targets.find { |t| t.name == "BOFFIN" }
raise "no BOFFIN app target" unless app

extension = project.new_target(:app_extension, name, :ios, DEPLOYMENT_TARGET)

group = project.main_group.find_subpath(directory, true)
group.set_source_tree("SOURCE_ROOT")
group.set_path(directory)
Dir[File.join(ROOT, directory, "*.swift")].sort.each do |file|
  extension.add_file_references([group.new_reference(File.basename(file))])
end

entitlements = File.join(directory, "#{name}.entitlements")
extension.build_configurations.each do |config|
  s = config.build_settings
  s["PRODUCT_BUNDLE_IDENTIFIER"] = "#{APP_BUNDLE_ID}.#{suffix}"
  s["INFOPLIST_FILE"] = File.join(directory, "Info.plist")
  s["DEVELOPMENT_TEAM"] = TEAM
  s["SWIFT_VERSION"] = "6.0"
  s["IPHONEOS_DEPLOYMENT_TARGET"] = DEPLOYMENT_TARGET
  s["SKIP_INSTALL"] = "YES"
  s["TARGETED_DEVICE_FAMILY"] = "1,2"
  s["GENERATE_INFOPLIST_FILE"] = "NO"
  s["CODE_SIGN_ENTITLEMENTS"] = entitlements if File.exist?(File.join(ROOT, entitlements))
  if config.name == "Release"
    s["CODE_SIGN_IDENTITY"] = "Apple Distribution"
    s["CODE_SIGN_STYLE"] = "Manual"
  end
end

# Package PRODUCT dependencies, reusing the project's existing local package
# references so every target points at the same package rather than a copy.
packages.each do |package|
  reference = project.root_object.package_references.find do |r|
    r.respond_to?(:relative_path) && r.relative_path.to_s.include?(package)
  end
  raise "no local package reference for #{package}" unless reference
  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.package = reference
  dependency.product_name = package
  extension.package_product_dependencies << dependency
end

# Embed into the app, reusing the existing embed phase if one is there.
embed = app.build_phases.find do |phase|
  phase.respond_to?(:symbol_dst_subfolder_spec) && phase.symbol_dst_subfolder_spec == :plug_ins
end
embed ||= begin
  phase = app.new_copy_files_build_phase("Embed Foundation Extensions")
  phase.symbol_dst_subfolder_spec = :plug_ins
  phase
end
embed.add_file_reference(extension.product_reference, true)
app.add_dependency(extension)

project.save
puts "added #{name} (#{APP_BUNDLE_ID}.#{suffix})"
puts "  targets now: #{project.targets.map(&:name).join(', ')}"
