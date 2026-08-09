#!/usr/bin/env ruby
# Adds the CameraExtension system-extension target to Runner.xcodeproj and
# embeds it in the app bundle. Idempotent: re-running removes and rebuilds the
# target rather than stacking duplicates.
#
# Run with Homebrew ruby (system ruby 2.6 cannot load xcodeproj):
#   /opt/homebrew/opt/ruby/bin/ruby macos/add_camera_extension.rb

require 'xcodeproj'

PROJECT   = File.join(__dir__, 'Runner.xcodeproj')
EXT_NAME  = 'CameraExtension'
EXT_ID    = 'com.abdulsaheel.beamcam.CameraExtension'
TEAM      = '2U62X3RF3R'
DEPLOY    = '13.0' # CMIOExtension needs 12.3+; 13.0 keeps the API surface simple

project = Xcodeproj::Project.open(PROJECT)
app = project.targets.find { |t| t.name == 'Runner' } or abort 'Runner target not found'

# --- clean out any previous run -------------------------------------------
project.targets.select { |t| t.name == EXT_NAME }.each do |t|
  puts "removing existing target #{t.name}"
  t.remove_from_project
end
app.build_phases.select { |p|
  p.respond_to?(:name) && p.name == 'Embed System Extensions'
}.each(&:remove_from_project)
project.main_group.children.select { |g| g.respond_to?(:name) && g.name == EXT_NAME }
       .each(&:remove_from_project)

# --- create the target ----------------------------------------------------
ext = project.new_target(
  :application_extension, EXT_NAME, :osx, DEPLOY, nil, :swift
)
# xcodeproj has no :system_extension symbol; set the UTI directly.
ext.product_type = 'com.apple.product-type.system-extension'
ext.product_reference.explicit_file_type = 'wrapper.system-extension'
ext.product_reference.path = "#{EXT_NAME}.systemextension"

group = project.main_group.new_group(EXT_NAME, EXT_NAME)
%w[main.swift BeamCamProvider.swift].each do |f|
  ext.add_file_references([group.new_reference(f)])
end
group.new_reference('Info.plist')
group.new_reference("#{EXT_NAME}.entitlements")

# CoreMediaIO is what the provider API lives in.
%w[CoreMediaIO.framework CoreMedia.framework CoreVideo.framework Foundation.framework]
  .each do |fw|
    ref = project.frameworks_group.new_reference("System/Library/Frameworks/#{fw}")
    ref.source_tree = 'SDKROOT'
    ext.frameworks_build_phase.add_file_reference(ref)
  end

ext.build_configurations.each do |config|
  config.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER'          => EXT_ID,
    # NOT EXT_NAME. sysextd derives the bundle path from the identifier rather
    # than scanning the directory, so a system extension must be filed as
    # "<bundle id>.systemextension" or activation fails with error code 4
    # ("Extension not found in App bundle"). Apple documents this in the System
    # Extensions Overview; see developer.apple.com/forums/thread/823200.
    'PRODUCT_NAME'                       => '$(PRODUCT_BUNDLE_IDENTIFIER)',
    'PRODUCT_MODULE_NAME'                => EXT_NAME,
    'INFOPLIST_FILE'                     => "#{EXT_NAME}/Info.plist",
    'CODE_SIGN_ENTITLEMENTS'             => "#{EXT_NAME}/#{EXT_NAME}.entitlements",
    'CODE_SIGN_STYLE'                    => 'Automatic',
    'CODE_SIGN_IDENTITY'                 => 'Apple Development',
    'DEVELOPMENT_TEAM'                   => TEAM,
    'MACOSX_DEPLOYMENT_TARGET'           => DEPLOY,
    'SWIFT_VERSION'                      => '5.0',
    'SKIP_INSTALL'                       => 'YES',
    # The Offcuts guide is explicit that hardened runtime breaks local
    # development installs of camera extensions.
    'ENABLE_HARDENED_RUNTIME'            => 'NO',
    'CLANG_ENABLE_MODULES'               => 'YES',
    # Provisions the app group for the extension under automatic signing.
    'REGISTER_APP_GROUPS'                => 'YES',
    'LD_RUNPATH_SEARCH_PATHS'            => ['$(inherited)', '@executable_path/../Frameworks'],
    'INSTALL_PATH'                       => '$(LOCAL_LIBRARY_DIR)/SystemExtensions',
    'PROVISIONING_PROFILE_SPECIFIER'     => ''
  )
end

# --- embed into the app ---------------------------------------------------
app.add_dependency(ext)

embed = app.new_copy_files_build_phase('Embed System Extensions')
embed.symbol_dst_subfolder_spec = :products_directory
embed.dst_path = '$(CONTENTS_FOLDER_PATH)/Library/SystemExtensions'
build_file = embed.add_file_reference(ext.product_reference)
build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

project.save
puts "added #{EXT_NAME} (#{EXT_ID}) and embedded it in Runner"
