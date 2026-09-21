#!/usr/bin/env ruby
# Adds the AudioDriver target to Runner.xcodeproj, embeds it in the app
# bundle, and adds the three new Runner Swift files to the Runner target.
# Idempotent, same pattern as add_camera_extension.rb.
#
# Unlike CameraExtension, AudioDriver is NOT a system-extension target: a
# legacy AudioServerPlugIn HAL driver is a plain loadable bundle
# (wrapper.cfbundle, BNDL) that coreaudiod loads from
# /Library/Audio/Plug-Ins/HAL — no OSSystemExtensionRequest. The .driver
# bundle is embedded into Runner.app/Contents/Resources only so
# AudioDriverInstaller.swift has a copy to hand to the privileged install
# script; that embedded copy is never itself loaded by coreaudiod.
#
# Run with Homebrew ruby (system ruby 2.6 cannot load xcodeproj):
#   /opt/homebrew/opt/ruby/bin/ruby macos/add_audio_driver.rb

require 'xcodeproj'

PROJECT   = File.join(__dir__, 'Runner.xcodeproj')
EXT_NAME  = 'AudioDriver'
BUNDLE_ID = 'com.abdulsaheel.beamcam.AudioDriver'
TEAM      = '2U62X3RF3R'
DEPLOY    = '13.0'

project = Xcodeproj::Project.open(PROJECT)
app = project.targets.find { |t| t.name == 'Runner' } or abort 'Runner target not found'

# --- clean out any previous run -------------------------------------------
project.targets.select { |t| t.name == EXT_NAME }.each do |t|
  puts "removing existing target #{t.name}"
  t.remove_from_project
end
# remove_from_project does not clean up other targets' PBXTargetDependency
# entries that pointed at it — leaves a dangling `dep.target == nil` that
# crashes add_dependency's own lookup on the next run. Prune those first.
app.dependencies.select { |d| d.target.nil? }.each(&:remove_from_project)
app.build_phases.select { |p|
  p.respond_to?(:name) && p.name == 'Embed Audio Driver'
}.each(&:remove_from_project)
project.main_group.children.select { |g| g.respond_to?(:name) && g.name == EXT_NAME }
       .each(&:remove_from_project)

# --- create the target (plain loadable bundle, not a system extension) ---
ext = project.new_target(:bundle, EXT_NAME, :osx, DEPLOY, nil, :objc)
ext.product_reference.explicit_file_type = 'wrapper.cfbundle'
ext.product_reference.path = "#{EXT_NAME}.driver"

# xcodeproj's :bundle template default-links Cocoa.framework, which this
# driver (a headless plugin loaded by coreaudiod's out-of-process driver
# host, not an app) has no use for. Drop it rather than carry dead weight.
ext.frameworks_build_phase.files.each { |f| f.remove_from_project }

group = project.main_group.new_group(EXT_NAME, EXT_NAME)
%w[BeamCamAudioPlugIn.c BeamCamAudioRing.h].each do |f|
  ext.add_file_references([group.new_reference(f)])
end
group.new_reference('Info.plist')

%w[CoreAudio.framework CoreFoundation.framework].each do |fw|
  ref = project.frameworks_group.new_reference("System/Library/Frameworks/#{fw}")
  ref.source_tree = 'SDKROOT'
  ext.frameworks_build_phase.add_file_reference(ref)
end

ext.build_configurations.each do |config|
  config.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER'      => BUNDLE_ID,
    'PRODUCT_NAME'                   => EXT_NAME,
    'WRAPPER_EXTENSION'              => 'driver',
    'GENERATE_INFOPLIST_FILE'        => 'NO',
    'INFOPLIST_FILE'                 => "#{EXT_NAME}/Info.plist",
    # Manual, not Automatic: Xcode's automatic signing refuses to pair with an
    # explicitly-specified Developer ID identity.
    'CODE_SIGN_STYLE'                => 'Manual',
    # Developer ID + hardened runtime, unlike CameraExtension's Apple
    # Development pair: this isn't a System Extension activation, and
    # BlackHole 2ch (a working reference driver) is signed the same way.
    'CODE_SIGN_IDENTITY'             => 'Developer ID Application',
    'DEVELOPMENT_TEAM'               => TEAM,
    'MACOSX_DEPLOYMENT_TARGET'       => DEPLOY,
    'SKIP_INSTALL'                   => 'YES',
    'ENABLE_HARDENED_RUNTIME'        => 'YES',
    'LD_RUNPATH_SEARCH_PATHS'        => ['$(inherited)', '@loader_path/../Frameworks'],
    'PROVISIONING_PROFILE_SPECIFIER' => '',
    # WITHOUT $(inherited): the project xcconfig chain sets OTHER_LDFLAGS at
    # the project level to link every Flutter plugin framework (WebRTC,
    # app_links, ...) — right for Runner, wrong here. This driver loads
    # out-of-process into coreaudiod's driver host, which has no access to
    # Runner's Frameworks folder, so inheriting that chain is a dlopen
    # failure ("Library not loaded: @rpath/WebRTC.framework/WebRTC").
    'OTHER_LDFLAGS'                  => ['-framework', 'CoreAudio', '-framework', 'CoreFoundation']
  )
end

# --- embed into the app's Resources (see file-top note: not loaded from
# there — this is just so the app has a copy to hand to the installer) ----
app.add_dependency(ext)

embed = app.new_copy_files_build_phase('Embed Audio Driver')
embed.symbol_dst_subfolder_spec = :resources
build_file = embed.add_file_reference(ext.product_reference)
build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

# --- add the new Runner Swift files if they are not already in the target -
runner_group = project.main_group.children.find { |g| g.respond_to?(:path) && g.path == 'Runner' } ||
               project.main_group
existing = app.source_build_phase.files.map { |f| f.file_ref&.path }
%w[AudioRingBuffer.swift WebRTCAudioBridge.swift AudioDriverInstaller.swift].each do |f|
  next if existing.include?(f)
  ref = runner_group.new_reference(f)
  app.add_file_references([ref])
  puts "added Runner/#{f} to the Runner target"
end

project.save
puts "added #{EXT_NAME} (#{BUNDLE_ID}), embedded it in Runner/Resources, and wired the new Runner sources"
