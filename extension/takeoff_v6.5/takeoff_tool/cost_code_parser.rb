module TakeoffTool
  module CostCodeParser

    @map = nil
    @compiled_force = nil
    @compiled_codes = nil

    # ═══════════════════════════════════════════════════════════
    # Load cost_code_map.json on first use
    # ═══════════════════════════════════════════════════════════

    def self.load_map
      return @map if @map
      require 'json'
      path = File.join(PLUGIN_DIR, 'config', 'cost_code_map.json')
      unless File.exist?(path)
        puts "CostCodeParser: cost_code_map.json not found at #{path}"
        @map = {}
        return @map
      end
      @map = JSON.parse(File.read(path))
      compile_rules
      @map
    rescue => e
      puts "CostCodeParser: Error loading map: #{e.message}"
      @map = {}
    end

    # Pre-compile regex patterns for performance
    def self.compile_rules
      # Compile force rules
      @compiled_force = (@map['force_rules'] || []).map do |rule|
        {
          regex: Regexp.new(rule['pattern'], Regexp::IGNORECASE),
          category: rule['category'],
          cost_code: rule['cost_code'],
          priority: rule['priority'] || 0,
          description: rule['description']
        }
      end

      # Compile all division codes into a flat lookup list
      @compiled_codes = []
      divisions = @map['divisions'] || {}
      divisions.each do |div_num, div|
        codes = div['codes'] || {}
        codes.each do |code_num, code_def|
          compiled = {
            cost_code: code_num,
            division: div_num,
            division_name: div['name'],
            name: code_def['name'],
            keywords: (code_def['keywords'] || []),
            keyword_regexes: (code_def['keywords'] || []).map { |kw| Regexp.new(Regexp.escape(kw), Regexp::IGNORECASE) },
            ifc_types: (code_def['ifc_types'] || []),
            materials: (code_def['materials'] || []),
            material_regexes: (code_def['materials'] || []).map { |m| Regexp.new(Regexp.escape(m), Regexp::IGNORECASE) },
            name_patterns: (code_def['name_patterns'] || []),
            name_pattern_regexes: (code_def['name_patterns'] || []).map { |np| Regexp.new(Regexp.escape(np), Regexp::IGNORECASE) },
            exclude_patterns: (code_def['exclude_patterns'] || []),
            exclude_regexes: (code_def['exclude_patterns'] || []).map { |ep| Regexp.new(Regexp.escape(ep), Regexp::IGNORECASE) },
            size_rules: code_def['size_rules'],
            subcategories: code_def['subcategories'] || {},
            match_rules: (code_def['match_rules'] || []).map { |mr|
              { regex: Regexp.new(mr['pattern'], Regexp::IGNORECASE), force: mr['force'] }
            }
          }
          @compiled_codes << compiled
        end
      end

      # Compile plumbing codes
      plumbing = @map['plumbing_codes'] || {}
      plumbing.each do |code_num, code_def|
        @compiled_codes << {
          cost_code: code_num,
          division: '003',
          division_name: 'Rough Shell',
          name: code_def['name'],
          keywords: (code_def['keywords'] || []),
          keyword_regexes: (code_def['keywords'] || []).map { |kw| Regexp.new(Regexp.escape(kw), Regexp::IGNORECASE) },
          ifc_types: (code_def['ifc_types'] || []),
          materials: [],
          material_regexes: [],
          name_patterns: (code_def['name_patterns'] || []),
          name_pattern_regexes: (code_def['name_patterns'] || []).map { |np| Regexp.new(Regexp.escape(np), Regexp::IGNORECASE) },
          exclude_patterns: [],
          exclude_regexes: [],
          size_rules: nil,
          subcategories: {},
          match_rules: []
        }
      end

      puts "CostCodeParser: Compiled #{@compiled_force.length} force rules, #{@compiled_codes.length} cost codes"
    end

    # Force reload (for dev)
    def self.reload!
      @map = nil
      @compiled_force = nil
      @compiled_codes = nil
      load_map
    end

    # ═══════════════════════════════════════════════════════════
    # classify — Main entry point
    #
    # Returns a parse result hash (same format as other strategies)
    # or nil if no match found.
    #
    # Parameters:
    #   display  — entity display name
    #   tag      — entity layer/tag
    #   mat      — material display name
    #   ifc_type — IFC type string
    #   dims     — [w, h, d] bounding box in inches (optional)
    # ═══════════════════════════════════════════════════════════

    def self.classify(display, tag, mat, ifc_type, dims = nil)
      load_map unless @map

      return nil if @compiled_codes.nil? || @compiled_codes.empty?

      text = display.to_s
      mat_str = mat.to_s
      ifc_str = ifc_type.to_s

      # ─── Step 1: Force rules (highest priority) ───
      if @compiled_force
        @compiled_force.each do |fr|
          if text =~ fr[:regex]
            return build_result(
              display, mat, fr[:category], nil, fr[:cost_code],
              :high, 'cost_code_force', 100
            )
          end
        end
      end

      # ─── Step 2: Score each cost code ───
      best = nil
      best_score = 0

      @compiled_codes.each do |cc|
        score = 0
        matched_how = []

        # Check exclusions first
        excluded = false
        cc[:exclude_regexes].each do |re|
          if text =~ re
            excluded = true
            break
          end
        end
        next if excluded

        # Check inline match_rules (force matches within a code)
        cc[:match_rules].each do |mr|
          if text =~ mr[:regex] && mr[:force]
            score += 50
            matched_how << 'match_rule'
          end
        end

        # Name pattern match (highest value — specific Revit type names)
        cc[:name_pattern_regexes].each do |re|
          if text =~ re
            score += 30
            matched_how << 'name_pattern'
            break
          end
        end

        # Keyword match — longer (multi-word) keywords score higher
        best_kw_score = 0
        cc[:keyword_regexes].each_with_index do |re, ki|
          if text =~ re
            kw_words = cc[:keywords][ki].to_s.split(/\s+/).length
            kw_score = 10 + (kw_words * 5)  # 1-word: 15, 2-word: 20, 3-word: 25
            best_kw_score = kw_score if kw_score > best_kw_score
          end
        end
        if best_kw_score > 0
          score += best_kw_score
          matched_how << 'keyword'
        end

        # IFC type match
        if !ifc_str.empty? && cc[:ifc_types].include?(ifc_str)
          score += 10
          matched_how << 'ifc_type'
        end

        # Material match
        unless mat_str.empty?
          cc[:material_regexes].each do |re|
            if mat_str =~ re
              score += 10
              matched_how << 'material'
              break
            end
          end
        end

        # Bonus: multiple signal types matched = higher confidence
        unique_signals = matched_how.uniq.length
        score += (unique_signals - 1) * 5 if unique_signals > 1

        next if score == 0

        # ─── Step 3: Apply size rules ───
        if cc[:size_rules] && dims
          size_result = apply_size_rules(cc[:size_rules], dims)
          if size_result
            # Size rule may redirect to a different code
            if size_result[:redirect_code]
              next # Skip this code, the redirected code will pick it up
            end
          end
        end

        if score > best_score
          best_score = score
          # Determine subcategory
          subcat = determine_subcategory(cc, text, ifc_str, dims)

          confidence = if score >= 40
            :high
          elsif score >= 20
            :medium
          elsif score >= 10
            :low
          else
            :none
          end

          best = {
            cc: cc,
            score: score,
            subcategory: subcat,
            confidence: confidence,
            matched_how: matched_how
          }
        end
      end

      return nil unless best

      # ─── Step 4: Check timber vs lumber size rule ───
      cc = best[:cc]
      if cc[:size_rules] == 'timber_6x6_plus' && dims
        sr = (@map['size_rules'] || {})['timber_6x6_plus']
        if sr
          sorted = dims.sort
          cross_w = sorted[0]
          cross_h = sorted[1]
          if cross_w >= sr['min_width'] && cross_h >= sr['min_height']
            # It's timber — keep code 3.030
          else
            # It's standard lumber — redirect to 3.011
            # Only redirect if original code was 3.030
            if cc[:cost_code] == '3.030'
              lumber_cc = @compiled_codes.find { |c| c[:cost_code] == sr['lumber_code'] }
              if lumber_cc
                return build_result(
                  display, mat, lumber_cc[:name], best[:subcategory],
                  lumber_cc[:cost_code], best[:confidence], 'cost_code_map',
                  best[:score]
                )
              end
            end
          end
        end
      end

      build_result(
        display, mat, cc[:name], best[:subcategory], cc[:cost_code],
        best[:confidence], 'cost_code_map', best[:score]
      )
    end

    # ═══════════════════════════════════════════════════════════
    # Helpers
    # ═══════════════════════════════════════════════════════════

    private

    def self.determine_subcategory(cc, text, ifc_str, dims)
      return nil if cc[:subcategories].empty?

      cc[:subcategories].each do |sub_name, sub_def|
        # Check name patterns
        if sub_def['name_patterns']
          sub_def['name_patterns'].each do |pat|
            return sub_name if text =~ Regexp.new(Regexp.escape(pat), Regexp::IGNORECASE)
          end
        end

        # Check IFC types
        if sub_def['ifc_types'] && !ifc_str.empty?
          return sub_name if sub_def['ifc_types'].include?(ifc_str)
        end

        # Check min_size
        if sub_def['min_size'] && dims
          if sub_def['min_size'] =~ /(\d+)x(\d+)/
            min_w = $1.to_f
            min_h = $2.to_f
            sorted = dims.sort
            return sub_name if sorted[0] >= min_w && sorted[1] >= min_h
          end
        end
      end

      nil
    end

    def self.apply_size_rules(rule_name, dims)
      return nil unless @map && @map['size_rules']
      rule = @map['size_rules'][rule_name]
      return nil unless rule

      sorted = dims.sort
      cross_w = sorted[0]
      cross_h = sorted[1]

      if rule_name == 'timber_6x6_plus'
        if cross_w < rule['min_width'] || cross_h < rule['min_height']
          return { redirect_code: rule['lumber_code'] }
        end
      end

      nil
    end

    def self.build_result(display, mat, category, subcategory, cost_code, confidence, source, score)
      mt = Parser.measurement_for(category)
      {
        raw: display.to_s,
        element_type: nil,
        function: nil,
        material: mat,
        thickness: nil,
        size_nominal: nil,
        revit_id: nil,
        auto_category: category,
        auto_subcategory: subcategory,
        measurement_type: mt,
        category_source: source,
        confidence: confidence,
        cost_code: cost_code,
        cost_code_score: score
      }
    end

    # ═══════════════════════════════════════════════════════════
    # Sheathing rules — special handling
    # ═══════════════════════════════════════════════════════════

    def self.classify_sheathing(display, mat)
      load_map unless @map
      rules = @map['sheathing_rules'] || {}
      text = display.to_s

      rules.each do |_key, rule|
        # Check triggers
        (rule['triggers'] || []).each do |trigger|
          if text =~ Regexp.new(Regexp.escape(trigger), Regexp::IGNORECASE)
            return {
              category: rule['name'],
              cost_code: rule['cost_code'],
              context: rule['context']
            }
          end
        end
      end

      nil
    end

    # ═══════════════════════════════════════════════════════════
    # Public: get suggested cost code for a category name
    # Looks up what cost code(s) map to a given category name
    # ═══════════════════════════════════════════════════════════

    def self.suggest_cost_code(category_name)
      load_map unless @map
      return [] unless @compiled_codes

      matches = @compiled_codes.select { |cc| cc[:name] == category_name }
      matches.map { |cc| cc[:cost_code] }
    end

    # Get the full map data (for UI / debug)
    def self.map_data
      load_map unless @map
      @map
    end

    # Get flat list of all codes with names
    def self.all_codes
      load_map unless @map
      return [] unless @compiled_codes
      @compiled_codes.map { |cc| { code: cc[:cost_code], name: cc[:name], division: cc[:division_name] } }
    end
  end
end
