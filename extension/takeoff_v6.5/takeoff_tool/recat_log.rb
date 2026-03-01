module TakeoffTool
  module RecatLog

    # Log a single category change with full entity metadata.
    # Called from dashboard, context menu, and identify dialog handlers.
    def self.log_change(eid, new_category, new_subcategory = nil)
      row = TakeoffTool.scan_results.find { |r| r[:entity_id] == eid }
      return unless row

      parsed = row[:parsed] || {}
      orig_cat = parsed[:auto_category] || 'Uncategorized'

      # Don't log if category is unchanged
      return if new_category == orig_cat

      entry = {
        'timestamp'            => Time.now.strftime('%Y-%m-%dT%H:%M:%S'),
        'entity_name'          => row[:display_name],
        'entity_definition'    => row[:definition_name],
        'instance_name'        => row[:instance_name],
        'layer_tag'            => row[:tag],
        'material'             => row[:material] || 'none',
        'ifc_type'             => row[:ifc_type],
        'bounding_box'         => "#{row[:bb_width_in]} x #{row[:bb_height_in]} x #{row[:bb_depth_in]}",
        'original_category'    => orig_cat,
        'original_subcategory' => parsed[:auto_subcategory],
        'parse_strategy'       => parsed[:category_source],
        'new_category'         => new_category,
        'new_subcategory'      => new_subcategory,
        'confidence'           => (parsed[:confidence] || :none).to_s
      }

      entries = load_entries
      entries << entry
      save_entries(entries)
    rescue => e
      puts "RecatLog: error logging change: #{e.message}"
    end

    def self.load_entries
      m = Sketchup.active_model
      return [] unless m
      json = m.get_attribute('FF_RecatLog', 'entries')
      return [] unless json
      require 'json'
      JSON.parse(json)
    rescue
      []
    end

    def self.save_entries(entries)
      m = Sketchup.active_model
      return unless m
      require 'json'
      m.set_attribute('FF_RecatLog', 'entries', JSON.generate(entries))
    end

    # Generate export text for bug reporter.
    # Section 1: Parser misses grouped by frequency.
    # Section 2: Parser accuracy (accepted vs recategorized per category).
    def self.export_text
      entries = load_entries
      sr = TakeoffTool.scan_results
      ca = TakeoffTool.category_assignments

      lines = []
      lines << "=" * 45
      lines << "RECATEGORIZATION LOG (Parser Training Data)"
      lines << "=" * 45
      lines << ""
      lines << "Total recategorizations: #{entries.length}"
      lines << ""

      # ── Section 1: Parser Misses ──
      if entries.length > 0
        lines << "PARSER MISSES (sorted by frequency):"
        lines << ""

        # Group identical recategorizations
        grouped = {}
        entries.each do |e|
          key = [e['entity_name'], e['layer_tag'], e['material'],
                 e['original_category'], e['new_category']].join('|')
          grouped[key] ||= { entry: e, count: 0 }
          grouped[key][:count] += 1
        end

        grouped.sort_by { |_, v| -v[:count] }.each do |_, v|
          e = v[:entry]
          orig = e['original_category'] == '_IGNORE' ? 'Excluded' : e['original_category']
          new_cat = e['new_category'] == '_IGNORE' ? 'Excluded' : e['new_category']
          new_sub = e['new_subcategory']
          new_display = new_sub ? "#{new_cat} / #{new_sub}" : new_cat

          lines << "\"#{e['entity_name']}\" (#{e['layer_tag']}, #{e['material']})"
          lines << "  Parser said: #{orig} (#{e['parse_strategy']}, #{e['confidence']})"
          lines << "  User changed to: #{new_display}"
          lines << "  BB: #{e['bounding_box']}"
          lines << "  Occurrences: #{v[:count]}"
          lines << ""
        end
      end

      # ── Section 2: Parser Accuracy ──
      if sr && sr.length > 0
        lines << "-" * 45
        lines << "PARSER ACCURACY (accepted vs recategorized)"
        lines << "-" * 45
        lines << ""

        cat_stats = {}
        sr.each do |r|
          parsed_cat = begin; r[:parsed][:auto_category]; rescue; nil; end
          parsed_cat ||= 'Uncategorized'
          next if parsed_cat == '_IGNORE'

          user_cat = ca[r[:entity_id]]
          cat_stats[parsed_cat] ||= { accepted: 0, changed: 0 }
          if user_cat && user_cat != parsed_cat
            cat_stats[parsed_cat][:changed] += 1
          else
            cat_stats[parsed_cat][:accepted] += 1
          end
        end

        cat_stats.sort_by { |k, _| k }.each do |cat, s|
          total = s[:accepted] + s[:changed]
          pct = total > 0 ? (s[:accepted] * 100.0 / total).round(0) : 100
          line = "#{cat}: #{s[:accepted]}/#{total} accepted (#{pct}%)"
          line += " -- #{s[:changed]} recategorized" if s[:changed] > 0
          lines << line
        end
      end

      lines.join("\n")
    rescue => e
      "RecatLog export error: #{e.message}"
    end

  end
end
