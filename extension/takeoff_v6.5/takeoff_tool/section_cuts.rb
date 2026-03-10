module TakeoffTool
  module SectionCuts
    LAYER_NAME = 'FF_Section_Cuts'.freeze
    ATTR_DICT  = 'FFSectionCut'.freeze
    DEFAULT_OFFSET = 48.0  # 4 feet in inches

    @cuts = []  # cached list of { name:, elevation_z:, label:, sp_eid: }

    class << self
      attr_accessor :cuts
    end

    # ── Discover elevation tags and build section cut presets ──

    def self.collect_elevation_tags
      m = Sketchup.active_model
      return [] unless m

      bmk = TakeoffTool.get_elevation_benchmark
      return [] unless bmk

      bmk_z = bmk['z_inches'].to_f       # benchmark world Z in inches
      bmk_elev = bmk['elevation'].to_f    # benchmark elevation value
      bmk_unit = bmk['unit'].to_s

      # Inches per elevation unit
      unit_factor = case bmk_unit
        when 'feet'   then 12.0
        when 'inches' then 1.0
        when 'meters' then 39.3701
        else 12.0
      end

      tags = []
      m.entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        next unless grp.get_attribute('TakeoffMeasurement', 'type') == 'ELEV'
        elev_val = grp.get_attribute('TakeoffMeasurement', 'elevation')
        next unless elev_val
        label = grp.get_attribute('TakeoffMeasurement', 'custom_label').to_s
        elev_label = grp.get_attribute('TakeoffMeasurement', 'elevation_label').to_s
        display = label.empty? ? elev_label : "#{label} #{elev_label}"

        # Calculate world Z from elevation value relative to benchmark
        delta_elev = elev_val.to_f - bmk_elev
        z_inches = bmk_z + (delta_elev * unit_factor)

        puts "[SC] Tag: '#{display}' elev=#{elev_val} → Z=#{z_inches.round(1)}\" (cut at #{(z_inches + DEFAULT_OFFSET).round(1)}\")"

        tags << {
          elevation: elev_val.to_f,
          z_inches: z_inches,
          label: display,
          custom_label: label
        }
      end
      tags
    end

    # ── Build / refresh presets from elevation tags ──

    def self.build_presets
      m = Sketchup.active_model
      return [] unless m

      bmk = TakeoffTool.get_elevation_benchmark
      return [] unless bmk

      tags = collect_elevation_tags
      return [] if tags.empty?

      # Group by unique Z elevations (within 0.5" tolerance)
      unique = []
      tags.sort_by { |t| t[:z_inches] }.each do |t|
        existing = unique.find { |u| (u[:z_inches] - t[:z_inches]).abs < 0.5 }
        if existing
          # Prefer tag with custom label
          if !t[:custom_label].empty? && existing[:custom_label].to_s.empty?
            existing[:label] = t[:label]
            existing[:custom_label] = t[:custom_label]
          end
        else
          unique << t.dup
        end
      end

      presets = unique.map do |t|
        cut_z = t[:z_inches] + DEFAULT_OFFSET
        cut_label = format_cut_label(t, bmk)
        {
          name: cut_label,
          elevation_z: cut_z,
          source_z: t[:z_inches],
          source_label: t[:label],
          source_elevation: t[:elevation]
        }
      end

      @cuts = presets
      presets
    end

    def self.format_cut_label(tag, bmk)
      offset_ft = (DEFAULT_OFFSET / 12.0).round
      base = tag[:custom_label].to_s.empty? ? tag[:label] : tag[:custom_label]
      "#{base} + #{offset_ft}'"
    end

    # ── Section plane management ──

    def self.get_layer(model)
      model.layers[LAYER_NAME] || model.layers.add(LAYER_NAME)
    end

    def self.find_existing_planes(model)
      planes = {}
      model.entities.grep(Sketchup::SectionPlane).each do |sp|
        next unless sp.valid?
        tag = sp.get_attribute(ATTR_DICT, 'ff_cut')
        planes[tag] = sp if tag
      end
      planes
    end

    def self.create_cut(model, preset)
      layer = get_layer(model)
      cut_z = preset[:elevation_z]

      # Horizontal cut looking down
      plane = [Geom::Point3d.new(0, 0, cut_z), Geom::Vector3d.new(0, 0, -1)]
      sp = model.entities.add_section_plane(plane)
      return nil unless sp
      sp.name = "FF: #{preset[:name]}" rescue nil
      sp.layer = layer
      sp.set_attribute(ATTR_DICT, 'ff_cut', preset[:name])
      sp.set_attribute(ATTR_DICT, 'elevation_z', cut_z)
      sp.set_attribute(ATTR_DICT, 'source_label', preset[:source_label])
      # Deactivate — only activate when user selects
      model.entities.active_section_plane = nil
      puts "Takeoff: Section plane created at Z=#{cut_z.round(1)}\" for '#{preset[:name]}'"
      sp
    end

    # ── Activate / deactivate ──

    def self.activate_cut(name)
      m = Sketchup.active_model
      return unless m

      # Ensure presets are built
      build_presets if @cuts.empty?

      planes = find_existing_planes(m)

      # If the requested plane doesn't exist yet, create it from preset
      unless planes[name]
        preset = @cuts.find { |c| c[:name] == name }
        unless preset
          puts "Takeoff: Section cut preset not found: '#{name}'"
          return
        end
        m.start_operation('Create Section Cut', true)
        sp = create_cut(m, preset)
        m.commit_operation
        return unless sp
        planes[name] = sp
      end

      target = planes[name]
      return unless target && target.valid?

      # Activate the requested section plane
      m.start_operation('Activate Section Cut', true)
      target.activate
      # Hide the plane graphic, show the cut effect
      m.rendering_options['DisplaySectionPlanes'] = false
      m.rendering_options['DisplaySectionCuts'] = true
      m.commit_operation

      puts "Takeoff: Section cut activated: #{name}"
      name
    end

    def self.deactivate_all
      m = Sketchup.active_model
      return unless m

      m.start_operation('Deactivate Section Cuts', true)
      m.entities.active_section_plane = nil
      m.commit_operation
      puts "Takeoff: All section cuts deactivated"
    end

    def self.active_cut_name
      m = Sketchup.active_model
      return nil unless m
      active_sp = m.entities.active_section_plane
      return nil unless active_sp
      find_existing_planes(m).each do |tag, sp|
        return tag if sp.valid? && sp.equal?(active_sp)
      end
      nil
    end

    # ── Add custom cut at arbitrary height ──

    def self.add_custom_cut(label, z_inches)
      m = Sketchup.active_model
      return unless m

      preset = {
        name: label,
        elevation_z: z_inches,
        source_z: z_inches - DEFAULT_OFFSET,
        source_label: label,
        source_elevation: 0
      }

      m.start_operation('Add Custom Section Cut', true)
      create_cut(m, preset)
      m.commit_operation

      @cuts << preset
      preset
    end

    # ── Remove a section plane ──

    def self.remove_cut(name)
      m = Sketchup.active_model
      return unless m

      planes = find_existing_planes(m)
      sp = planes[name]
      return unless sp && sp.valid?

      m.start_operation('Remove Section Cut', true)
      sp.erase!
      m.commit_operation

      @cuts.reject! { |c| c[:name] == name }
      puts "Takeoff: Section cut removed: #{name}"
    end

    # ── Remove all FF section planes (for refresh) ──

    def self.remove_all_planes
      m = Sketchup.active_model
      return unless m
      planes = find_existing_planes(m)
      return if planes.empty?
      m.start_operation('Remove All Section Cuts', true)
      m.entities.active_section_plane = nil
      planes.each { |_, sp| sp.erase! if sp.valid? }
      m.commit_operation
      puts "Takeoff: Removed #{planes.length} section planes"
    end

    # ── Sync: ensure all presets have section planes, remove orphans ──

    def self.sync_planes
      m = Sketchup.active_model
      return unless m

      build_presets if @cuts.empty?
      return if @cuts.empty?

      existing = find_existing_planes(m)
      made = 0

      m.start_operation('Sync Section Cuts', true)

      # Create missing planes
      @cuts.each do |preset|
        next if existing[preset[:name]]
        create_cut(m, preset)
        made += 1
      end

      m.commit_operation

      puts "Takeoff: Section cuts synced — #{@cuts.length} presets, #{made} new planes created"
    end

    # ── Payload for dashboard ──

    def self.build_payload
      m = Sketchup.active_model
      return { presets: [], active: nil } unless m

      build_presets if @cuts.empty?
      existing = find_existing_planes(m)
      active = active_cut_name

      bmk = TakeoffTool.get_elevation_benchmark
      unit = bmk ? bmk['unit'] : 'feet'

      presets = @cuts.map do |c|
        has_plane = !!existing[c[:name]]
        {
          name: c[:name],
          elevationZ: c[:elevation_z],
          sourceLabel: c[:source_label],
          sourceElevation: c[:source_elevation],
          active: (c[:name] == active),
          exists: has_plane,
          unit: unit
        }
      end

      # Include any custom planes not from elevation tags
      existing.each do |tag, sp|
        next if @cuts.any? { |c| c[:name] == tag }
        z = sp.get_attribute(ATTR_DICT, 'elevation_z').to_f
        presets << {
          name: tag,
          elevationZ: z,
          sourceLabel: tag,
          sourceElevation: 0,
          active: sp.active?,
          exists: true,
          unit: unit,
          custom: true
        }
      end

      { presets: presets, active: active }
    end
  end
end
