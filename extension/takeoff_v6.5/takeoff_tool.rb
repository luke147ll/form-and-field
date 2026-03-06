require 'sketchup.rb'
require 'extensions.rb'

module TakeoffTool
  PLUGIN_ID = 'takeoff_tool'.freeze
  PLUGIN_NAME = 'Takeoff Tool'.freeze
  PLUGIN_VERSION = '10.4.3'.freeze
  PLUGIN_DIR = File.join(File.dirname(__FILE__), PLUGIN_ID).freeze

  extension = SketchupExtension.new(PLUGIN_NAME, File.join(PLUGIN_DIR, 'main'))
  extension.description = 'Interactive construction takeoff tool for SketchUp. Scans Revit imports and calculates quantities.'
  extension.version = PLUGIN_VERSION
  extension.creator = 'TakeoffTool'
  extension.copyright = '2026'

  Sketchup.register_extension(extension, true)
end
