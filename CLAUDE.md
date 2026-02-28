# Form and Field - SketchUp Extension

## What This Is
A SketchUp extension for construction quantity takeoffs. Built in Ruby using SketchUp's Ruby API and HtmlDialog for the UI.

## Architecture
- takeoff_tool.rb: Main loader file (entry point)
- main.rb: Core plugin logic and menu registration
- dashboard.rb: HtmlDialog-based dashboard UI
- parser.rb: Parses Revit metadata from imported models
- scanner.rb: Scans model geometry for quantities
- exporter.rb: Export/reporting functionality
- highlighter.rb: Visual highlighting of selected elements
- measure_lf.rb: Manual linear foot measurement tool
- measure_sf.rb: Manual square foot measurement tool
- ui/ folder: HTML, CSS, JS for the dashboard interface
- config/ folder: Configuration files

## Key Concepts
- Extension parses Revit metadata (categories, types, cost codes) from IFC/Revit imports
- Visibility filtering by cost code, category, tag
- Auto-detects quantity type (linear, SF, volume) based on geometry
- Dashboard displays grouped quantities with "Group By" system
- Manual measurement tools for linear and SF takeoffs

## Development
- Target: SketchUp 2026
- UI: HtmlDialog (HTML/CSS/JS)
- Live reload in SketchUp Ruby Console: load 'takeoff_tool/main.rb'
- Package for distribution: zip takeoff_tool.rb + takeoff_tool/ folder, rename to .rbz
