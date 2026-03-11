require 'json'

module TakeoffTool
  module FlattenPass

    # Attribute dictionary for stamped ancestry metadata
    FLATTEN_DICT = 'FF_Flatten'.freeze

    # IFC organizational containers — ALWAYS flatten
    IFC_ORG_TAGS = %w[IfcProject IfcSite IfcBuilding IfcBuildingStorey].freeze

    # IFC assembly types — NEVER flatten (multi-part objects that should stay together)
    IFC_ASSEMBLY_TAGS = %w[
      IfcWindow IfcDoor IfcCurtainWall IfcStair IfcStairFlight
      IfcRailing IfcFurnishingElement IfcSanitaryTerminal
      IfcLightFixture IfcElectricalAppliance
    ].freeze

    # ─────────────────────────────────────────────────────────
    # Entry point. Flattens nesting in a single undo operation.
    # Returns stats hash: { exploded:, kept:, stamped: }
    # ─────────────────────────────────────────────────────────
    def self.run(model, &progress)
      return { exploded: 0, kept: 0, stamped: 0 } unless model

      stats = { exploded: 0, kept: 0, stamped: 0 }

      model.start_operation('FF Flatten Import', true)
      begin
        flatten_context(model.active_entities, model, stats, 0, &progress)

        # Purge orphaned definitions left behind by explode.
        # Without this, the scanner sees ghost instances inside empty
        # definitions AND the new instances — doubling counts.
        before_count = model.definitions.length
        model.definitions.purge_unused
        after_count = model.definitions.length
        purged = before_count - after_count
        puts "[FF Flatten] Purged #{purged} unused definitions" if purged > 0

        model.commit_operation
      rescue => e
        model.abort_operation
        puts "[FF Flatten] ERROR: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        progress.call("Flatten error: #{e.message}") if progress
      end

      stats
    end

    # ─────────────────────────────────────────────────────────
    # Should the model be flattened? Quick check before running.
    # ─────────────────────────────────────────────────────────
    def self.needs_flatten?(model)
      return false unless model

      # Already flattened?
      return false if model.get_attribute('FF_Flatten', 'flattened')

      # Always flatten — the pass is fast when there's nothing to do,
      # and even a few containers cause selection/visibility issues
      model.definitions.any? do |d|
        next if d.image?
        faces = d.entities.grep(Sketchup::Face)
        children = d.entities.count { |e|
          e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
        }
        faces.empty? && children > 0
      end
    end

    private

    # ─────────────────────────────────────────────────────────
    # Flatten one entities context (model root or definition).
    # Uses while-loop: each explode mutates the collection,
    # so we re-snapshot after each explode.
    # ─────────────────────────────────────────────────────────
    def self.flatten_context(entities, model, stats, depth, &progress)
      return if depth > 20  # safety cap

      max_iters = entities.length * 2 + 200
      iter = 0
      changed = true

      while changed && iter < max_iters
        changed = false
        iter += 1

        targets = entities.to_a.select { |e|
          e.valid? && (e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group))
        }

        targets.each do |inst|
          next unless inst.valid?

          verdict = classify(inst)

          case verdict
          when :flatten
            meta = harvest_metadata(inst)

            if progress && depth < 3
              label = meta[:display_name] || meta[:definition_name] || '?'
              progress.call("Flatten: #{label}")
            end

            new_entities = inst.explode
            stats[:exploded] += 1

            if new_entities
              children = new_entities.select { |e|
                e.valid? && (e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group))
              }
              children.each do |child|
                stamp_metadata(child, meta)
                stats[:stamped] += 1
              end
            end

            changed = true
            break  # restart snapshot — entities collection mutated
          when :keep
            stats[:kept] += 1
          end
        end
      end

      if iter >= max_iters
        puts "[FF Flatten] WARNING: hit iteration cap (#{max_iters}) at depth #{depth}"
      end
    end

    # ─────────────────────────────────────────────────────────
    # Classify an entity: :flatten or :keep
    # ─────────────────────────────────────────────────────────
    def self.classify(inst)
      defn = inst.respond_to?(:definition) ? inst.definition : nil
      return :keep unless defn

      tag = inst.layer ? inst.layer.name : 'Untagged'
      ents = defn.entities

      faces = ents.grep(Sketchup::Face)
      children = ents.select { |e|
        e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
      }

      has_geometry = faces.length > 0
      has_children = children.length > 0

      # Rule 1: IFC organizational containers — always flatten
      return :flatten if IFC_ORG_TAGS.include?(tag)

      # Rule 2: IFC assembly types — always keep
      return :keep if IFC_ASSEMBLY_TAGS.include?(tag)

      # Rule 3: Has actual geometry (faces) — keep
      # This is a real object with its own shape
      return :keep if has_geometry

      # Rule 4: Empty definition — flatten (nothing to lose)
      return :flatten if ents.length == 0

      # Rule 5: Single-child wrapper (1 component, no faces)
      # These are IFC GUID wrappers that just wrap one child
      return :flatten if children.length == 1 && !has_geometry

      # Rule 6: Pure container (only components/groups, no faces)
      # No standalone edges either (exclude construction geometry)
      if has_children && !has_geometry
        standalone_edges = ents.grep(Sketchup::Edge).count { |e| e.faces.length == 0 }
        return :flatten if standalone_edges == 0
      end

      # Default: keep
      :keep
    end

    # ─────────────────────────────────────────────────────────
    # Harvest metadata from a container before exploding it.
    # ─────────────────────────────────────────────────────────
    def self.harvest_metadata(inst)
      defn = inst.respond_to?(:definition) ? inst.definition : nil
      tag = inst.layer ? inst.layer.name : 'Untagged'
      iname = inst.name.to_s.strip
      dname = defn ? defn.name.to_s.strip : ''

      mat = inst.material ? inst.material.display_name : nil

      # IFC type from definition
      ifc_type = nil
      if defn && defn.attribute_dictionaries
        a = defn.attribute_dictionaries['AppliedSchemaTypes']
        if a
          ifc_type = a['IFC 4'] || a['IFC 2x3'] || a['IFC 4x3'] || a['IFC2x3']
        end
      end

      # Collect IFC property sets and other meaningful attribute dictionaries
      ifc_props = {}
      if defn && defn.attribute_dictionaries
        defn.attribute_dictionaries.each do |dict|
          next if %w[dynamic_attributes SU_DefinitionSet AppliedSchemaTypes].include?(dict.name)
          attrs = {}
          dict.each_pair { |k, v| attrs[k] = v rescue nil }
          ifc_props[dict.name] = attrs unless attrs.empty?
        end
      end

      {
        instance_name: iname.empty? ? nil : iname,
        definition_name: dname.empty? ? nil : dname,
        display_name: iname.empty? ? dname : iname,
        tag: tag,
        material: mat,
        ifc_type: ifc_type,
        ifc_props: ifc_props
      }
    end

    # ─────────────────────────────────────────────────────────
    # Stamp parent metadata onto a child entity.
    # Uses FF_Flatten dictionary so child's own attrs are untouched.
    # ─────────────────────────────────────────────────────────
    def self.stamp_metadata(child, meta)
      model = Sketchup.active_model

      # Inherit tag if child is on Layer0/Untagged and parent had a meaningful tag
      child_tag = child.layer ? child.layer.name : 'Untagged'
      if (child_tag == 'Layer0' || child_tag == 'Untagged') && meta[:tag] != 'Untagged' && meta[:tag] != 'Layer0'
        layer = model.layers[meta[:tag]]
        child.layer = layer if layer
      end

      # Inherit material if child has none
      if !child.material && meta[:material]
        mat = model.materials[meta[:material]]
        child.material = mat if mat
      end

      # Preserve model_source for multiverse
      ms = child.get_attribute('FormAndField', 'model_source') rescue nil
      if !ms
        # Check if the parent had a model_source we should propagate
        # (stamped from an earlier flatten level)
        parent_ms = child.get_attribute(FLATTEN_DICT, 'model_source') rescue nil
        child.set_attribute('FormAndField', 'model_source', parent_ms) if parent_ms
      end

      # Stamp ancestry — only if meaningful (skip IFC org names)
      skip_names = /^(Default Building|Default Site|Default Project|IfcProject|IfcSite|IfcBuilding)/i
      display = meta[:display_name]

      if display && display !~ skip_names && display !~ /^[A-Za-z0-9_]{20,}$/
        # Not an IFC GUID and not an org name — worth preserving
        # Chain: if child already has a parent_name, prepend
        existing = child.get_attribute(FLATTEN_DICT, 'parent_name')
        if existing && existing != display
          child.set_attribute(FLATTEN_DICT, 'parent_name', "#{display} > #{existing}")
        else
          child.set_attribute(FLATTEN_DICT, 'parent_name', display)
        end
      end

      # Stamp inherited name if child has no name of its own
      child_name = child.respond_to?(:name) ? child.name.to_s.strip : ''
      child_defn_name = child.respond_to?(:definition) ? child.definition.name.to_s.strip : ''
      is_generic = child_name.empty? && child_defn_name =~ /^Component\d*$/i

      if is_generic && meta[:instance_name] && meta[:instance_name] !~ skip_names
        child.set_attribute(FLATTEN_DICT, 'inherited_name', meta[:instance_name])
      end

      # Stamp parent tag and IFC type
      child.set_attribute(FLATTEN_DICT, 'parent_tag', meta[:tag]) if meta[:tag] && meta[:tag] != 'Untagged'
      child.set_attribute(FLATTEN_DICT, 'parent_ifc_type', meta[:ifc_type]) if meta[:ifc_type]

      # Store IFC property sets as JSON (size-capped)
      if meta[:ifc_props] && !meta[:ifc_props].empty?
        begin
          json = JSON.generate(meta[:ifc_props])
          child.set_attribute(FLATTEN_DICT, 'ifc_props_json', json) if json.length < 4000
        rescue; end
      end
    end

  end
end
