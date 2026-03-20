MAJOR REFACTOR: Create a unified smart scanner that auto-detects the model source and applies the best parsing strategy per entity. No user selection needed.

Create/modify: scanner.rb (or wherever the main scan loop lives)

The scan loop should try MULTIPLE parsing strategies on each entity and use the highest-confidence result.

PARSING STRATEGIES (in priority order for each entity):

STRATEGY 1: IFC NAME PARSER (highest priority)
- Trigger: entity has a descriptive instance name matching known patterns
- Parses: "18x18 Post", "W18x40", "8" Concrete Wall" etc.
- This is the existing ifc_parser.rb logic
- Confidence: HIGH

STRATEGY 2: IFC TAG PARSER  
- Trigger: entity's layer/tag starts with "Ifc" (IfcBeam, IfcWall, IfcMember, etc.)
- Maps IFC type to category
- Confidence: MEDIUM (IfcBuildingElementProxy = LOW)

STRATEGY 3: MATERIAL + BOUNDING BOX PARSER (for Cadworks and similar)
- Trigger: entity has NO descriptive name (generic "Component2033" style) BUT has a meaningful material name
- Material classification:
  - "Oak", "Cedar", "Douglas Fir", "Pine", "White Oak", "Red Oak", "Walnut", "Cherry", "Maple" → Wood
  - "Framing", "Framing1", "Framing2" etc. → Dimensional lumber
  - "LVL", "Microlam", "PSL", "LSL", "Parallam" → Engineered lumber
  - "Steel", "Iron", "Galvanized" → Steel
  - "Concrete", "Concrete1", "Concrete2" → Concrete
  - "Dark Red", "Red" → Unknown (flag for review)
  
- For WOOD materials, use bounding box to determine size:
  - Sort the 3 bounding box dimensions smallest to largest
  - The two smallest are the cross-section, largest is length
  - Convert actual inches to nominal: 1.5"→2x, 3.5"→4x, 5.5"→6x, 7.5"→8x, 9.5"→10x, 11.5"→12x, 13.5"→14x, 15.5"→16x, 17.5"→18x
  - Also handle non-standard: 1.75"→1-3/4" (LVL), 2.625"→2-5/8", 3.625"→3-5/8"
  - If BOTH cross-section dimensions >= 5.5" (nominal 6x6+) → Category: "Timber"
  - If either < 5.5" AND material is Oak/Cedar/etc. → Still "Timber" (hardwood timber)
  - If either < 5.5" AND material is "Framing" → Category: "Structural Lumber"
  - Subcategory: Can't determine from Cadworks data (no member type in name) → set to "Unknown" or leave blank for user to fill
  
- For ENGINEERED materials (LVL, etc.):
  - Category: "Engineered Lumber"
  - Size from bounding box
  
- For STEEL materials:
  - Category: "Structural Steel"  
  - Size from bounding box
  
- For CONCRETE materials:
  - Category: "Concrete"
  - Size from bounding box
  
- Confidence: MEDIUM

STRATEGY 4: EXISTING PARSER (fallback)
- The current parser.rb logic using definition name, layer keywords, etc.
- This handles Revit imports and generic SU models
- Confidence: varies

STRATEGY 5: GENERIC KEYWORD SCAN (lowest priority)
- Scan entity name, definition name, layer name for ANY category keywords
- Door, Window, Wall, Floor, Roof, Stair, Railing, etc.
- Confidence: LOW

THE SCAN LOOP:
```ruby
def scan_entity(entity)
  results = []
  
  # Try each strategy
  r = try_ifc_name_parse(entity)
  results << r if r
  
  r = try_ifc_tag_parse(entity)
  results << r if r
  
  r = try_material_bbox_parse(entity)
  results << r if r
  
  r = try_existing_parse(entity)
  results << r if r
  
  r = try_keyword_scan(entity)
  results << r if r
  
  # Pick highest confidence result
  best = results.sort_by { |r| confidence_score(r[:confidence]) }.last
  best || { category: "Uncategorized", confidence: :none }
end
```

AUTO-DETECTION SUMMARY (runs once at scan start, logged to console):UX improvement — Live visibility updates on reclassification:

When a category is currently isolated in the dashboard and an entity gets reclassified OUT of that category (via any method — dashboard row dropdown, bulk edit, Identify dialog, or Hyper Parse), that entity should immediately:

1. HIDE in the viewport (since it no longer belongs to the isolated category)
2. REMOVE from the current dashboard view (since the dashboard is showing the isolated category)
3. UPDATE the item count on the category header

This should work for ALL reclassification methods:
- Single item category change via row dropdown
- Bulk edit category change on selected items
- Identify dialog "Apply" button
- Hyper Parse "Commit" action

The logic is: after any category change, check if there's an active isolation. If yes, check if the reclassified entity still belongs to the isolated category. If not, hide it and remove it from the current view.

Conversely, if an item gets reclassified INTO the currently isolated category, it should appear and become visible.

Also update the category counts in the header after any reclassification — both the source category (count decreases) and destination category (count increases).# Form and Field - SketchUp Extension

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
