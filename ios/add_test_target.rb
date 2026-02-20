#!/usr/bin/env ruby
# Script to add SecretR00MTests target to the Xcode project

require 'xcodeproj'

project_path = 'CalculatorPR0.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Check if test target already exists
if project.targets.any? { |t| t.name == 'SecretR00MTests' }
  puts "Test target 'SecretR00MTests' already exists"
  exit 0
end

# Find the main target
main_target = project.targets.find { |t| t.name == 'CalculatorPR0' }
unless main_target
  puts "Error: Could not find main target 'CalculatorPR0'"
  exit 1
end

# Create test target
test_target = project.new_target(:unit_test_bundle, 'SecretR00MTests', :ios, '16.0')

# Add dependency on main target
test_target.add_dependency(main_target)

# Configure test target build settings
test_target.build_configurations.each do |config|
  config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
  config.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/CalculatorPR0.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/CalculatorPR0'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.ephemeral.rooms.tests'
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['DEVELOPMENT_TEAM'] = 'L63Z9DK375'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['INFOPLIST_FILE'] = ''
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
end

# Create test group in project
tests_group = project.main_group.find_subpath('SecretR00MTests', true)
tests_group.set_source_tree('<group>')
tests_group.set_path('SecretR00MTests')

# Create Mocks subgroup
mocks_group = tests_group.find_subpath('Mocks', true)
mocks_group.set_source_tree('<group>')
mocks_group.set_path('Mocks')

# Add test files
test_files = [
  'CryptoTests.swift',
  'SecurityVerificationTests.swift',
  'RoomLifecycleTests.swift',
  'NetworkResilienceTests.swift',
  'CryptoStateMachineTests.swift',
  'UIStateInteractionTests.swift',
  'SmokeTests.swift',
  'StateMachineAssertionTests.swift'
]

mock_files = [
  'MockWebSocket.swift',
  'MockRoomSessionDelegate.swift',
  'TestHelpers.swift'
]

# Add test source files
test_files.each do |filename|
  file_path = "SecretR00MTests/#{filename}"
  if File.exist?(file_path)
    file_ref = tests_group.new_reference(filename)
    file_ref.set_source_tree('<group>')
    test_target.source_build_phase.add_file_reference(file_ref)
    puts "Added: #{filename}"
  else
    puts "Warning: File not found: #{file_path}"
  end
end

# Add mock files
mock_files.each do |filename|
  file_path = "SecretR00MTests/Mocks/#{filename}"
  if File.exist?(file_path)
    file_ref = mocks_group.new_reference(filename)
    file_ref.set_source_tree('<group>')
    test_target.source_build_phase.add_file_reference(file_ref)
    puts "Added: Mocks/#{filename}"
  else
    puts "Warning: File not found: #{file_path}"
  end
end

# Save project
project.save

puts "\nTest target 'SecretR00MTests' added successfully!"
puts "You may need to:"
puts "1. Open Xcode and update the scheme to include the test target"
puts "2. Clean build folder (Cmd+Shift+K)"
puts "3. Run tests (Cmd+U)"
