# frozen_string_literal: true
# smart_diff.rb — Form and Field Smart Diff Module
# Self-contained spatial comparison engine with raw geometry collision detection.
#
# Entry: SmartDiff.enter  -> classify entities -> paint results
# Exit:  SmartDiff.exit   -> restore materials -> clear state
#
# Replaces the old classify_ab_entities + ColorController.apply_smart_diff flow.

module TakeoffTool
  module SmartDiff

    # ═══ CONSTANTS ═══

    CELL_SIZE        = 24.0   # spatial grid cell size (inches)
    COLLISION_TOL    = 1.0    # surface proximity tolerance (inches)
    SAMPLE_COUNT     = 20     # face points sampled per entity for collision
    MATCH_THRESHOLD  = 0.85   # collision score >= this -> :matched
    CHANGE_THRESHOLD = 0.40   # collision score >= this -> :changed
    BB_MATCH_FLOOR   = 0.30   # BB IoU fallback threshold (when no faces)

    COLORS = {
      matched:   [88,  91,  112],   # Surface2 — muted gray
      changed:   [249, 226, 175],   # Yellow/amber
      new_b:     [137, 180, 250],   # Blue
      removed_a: [243, 139, 168]    # Red/pink
    }.freeze

    DEFAULT_OPACITY = {
      matched:   0.15,
      changed:   0.50,
      new_b:     0.90,
      removed_a: 0.70
    }.freeze

    STATES = [:matched, :changed, :new_b, :removed_a].freeze

    # ═══ MODULE STATE ═══

    @active         = false
    @classification = {}    # eid -> :matched | :changed | :new_b | :removed_a
    @categories     = {}    # eid -> category string
    @counts         = {}    # state -> count
    @backed_up      = {}    # eid -> { mat:, vis:, faces: }
    @opacity        = nil   # state -> float
    @visibility     = nil   # state -> bool
    @geo_cache      = {}    # eid -> [[v0,v1,v2], ...] world-space triangles
    @sd_mats        = {}    # state -> Sketchup::Material

    # ═══ PUBLIC API ═══

    def self.enter(category_filter: nil, force_reclassify: false)
      if @active
        puts "[SmartDiff] Already active — forcing re-entry"
        begin; restore_all; rescue => e; puts "[SmartDiff] restore_all: #{e.message}"; end
        @backed_up = {}
        @active = false
      end
      m = Sketchup.active_model
      return unless m

      # Clean slate
      begin
        ColorController.deactivate if ColorController.highlights_active?
      rescue => e
        puts "[SmartDiff] ColorController.deactivate: #{e.message}"
      end

      @opacity    ||= DEFAULT_OPACITY.dup
      @visibility = Hash[STATES.map { |s| [s, true] }]
      @geo_cache    = {}
      @backed_up    = {}

      puts "[SmartDiff] Entering..."
      t0 = Time.now

      # Always reclassify fresh — cache caused stale state issues
      classify

      backup_and_paint(m, category_filter: category_filter)

      @active = true
      elapsed = ((Time.now - t0) * 1000).round
      puts "[SmartDiff] Ready in #{elapsed}ms — #{@counts}"
    end

    def self.exit
      return unless @active
      m = Sketchup.active_model

      backed_count = @backed_up.length
      face_count = @backed_up.values.sum { |info| info[:faces].length }
      puts "[SmartDiff] Exiting... restoring #{backed_count} entities (#{face_count} faces)"

      m.start_operation('Exit Smart Diff', true) if m

      restore_all

      # Remove SmartDiff materials
      if m
        @sd_mats.each_value do |mat|
          m.materials.remove(mat) if mat && mat.valid?
        end
      end

      m.commit_operation if m

      # Restore layer coloring if in A+B view
      if m && TakeoffTool.active_mv_view == 'ab'
        m.rendering_options['DisplayColorByLayer'] = true
      end

      clear_state
      invalidate_cache
      m.active_view.invalidate if m
      puts "[SmartDiff] Exited"
    end

    def self.active?
      @active
    end

    # ─── Controls ───

    def self.set_opacity(state, value)
      @opacity ||= DEFAULT_OPACITY.dup
      sym = state.to_sym
      @opacity[sym] = value
      mat = @sd_mats[sym]
      mat.alpha = value if mat && mat.valid?
    end

    def self.set_visibility(state, visible)
      @visibility ||= Hash[STATES.map { |s| [s, true] }]
      @visibility[state.to_sym] = visible
    end

    # Fast visibility toggle — only show/hide entities of one state.
    # Avoids full restore_all + repaint cycle that freezes SketchUp.
    def self.toggle_state_fast(state, visible, category_filter: nil)
      sym = state.to_sym
      m = Sketchup.active_model
      return unless m && @active && @classification.any?
      cat_set = category_filter ? category_filter.map(&:to_s) : nil
      m.start_operation('Smart Diff Toggle', true)
      count = 0
      @classification.each do |eid, s|
        next unless s == sym
        e = TakeoffTool.find_entity(eid)
        next unless e && e.valid?
        if cat_set
          ent_cat = (@categories[eid] || '').to_s
          next unless cat_set.include?(ent_cat)
        end
        e.visible = visible
        count += 1
      end
      m.commit_operation
      m.active_view.invalidate
      puts "[SmartDiff] Toggled #{sym} #{visible ? 'visible' : 'hidden'}: #{count} entities"
    end

    def self.repaint(category_filter: nil)
      m = Sketchup.active_model
      return unless m && @active && @classification.any?
      restore_all
      backup_and_paint(m, category_filter: category_filter)
    end

    def self.isolate_state(state, categories: nil)
      target = state.to_sym
      STATES.each { |s| set_visibility(s, s == target) }
      repaint(category_filter: categories)
    end

    def self.show_all(categories: nil)
      STATES.each { |s| set_visibility(s, true) }
      repaint(category_filter: categories)
    end

    # ─── Accessors ───

    def self.classification;     @classification;                                          end
    def self.counts;             @counts;                                                  end
    def self.categories;         @categories;                                              end
    def self.opacity_settings;   @opacity    || DEFAULT_OPACITY.dup;                       end
    def self.visibility_settings; @visibility || Hash[STATES.map { |s| [s, true] }];       end

    # ─── Report ───

    def self.generate_report
      sr  = TakeoffTool.scan_results          || []
      ca  = TakeoffTool.category_assignments  || {}
      reg = TakeoffTool.entity_registry       || {}

      cats = Hash.new do |h, k|
        h[k] = { qty_a: 0.0, qty_b: 0.0, count_a: 0, count_b: 0, unit: 'ea',
                 matched: 0, changed: 0, new_b: 0, removed_a: 0 }
      end

      sr.each do |r|
        eid   = r[:entity_id]
        state = @classification[eid]
        next unless state

        e = reg[eid]
        next unless e && e.valid?
        ms  = e.get_attribute('FormAndField', 'model_source') || 'model_a'
        cat = ca[eid] || r[:parsed][:auto_category] || 'Uncategorized'

        mt  = r[:parsed][:measurement_type] || 'ea'
        qty = primary_quantity(r, mt)

        entry = cats[cat]
        entry[:unit] = mt
        entry[state] += 1

        if ms == 'model_a'
          entry[:qty_a]   += qty
          entry[:count_a] += 1
        else
          entry[:qty_b]   += qty
          entry[:count_b] += 1
        end
      end

      cats.map do |cat, d|
        delta = d[:qty_b] - d[:qty_a]
        pct   = d[:qty_a] > 0 ? (delta / d[:qty_a] * 100).round(1) : (d[:qty_b] > 0 ? 100.0 : 0.0)
        d.merge(category: cat, delta: delta.round(2), pct_change: pct)
      end.sort_by { |r| -r[:pct_change].abs }
    end

    # ═══ CLASSIFICATION PIPELINE ═══

    def self.classify
      a_items, b_items = collect_entities
      puts "[SmartDiff] Collected A=#{a_items.length} B=#{b_items.length}"

      if a_items.empty? || b_items.empty?
        @classification = {}
        @categories     = {}
        @counts         = Hash[STATES.map { |s| [s, 0] }]
        return
      end

      # ── Pass 1: same-category matching ──
      candidates = broad_phase(a_items, b_items, cross_category: false)
      puts "[SmartDiff] Pass 1 (same-cat): #{candidates.length} candidate pairs"

      pair_scores = score_candidates(candidates, a_items)

      b_best = best_matches(pair_scores)
      a_matched = reverse_matches(b_best)

      matched_a_eids = a_matched.keys.to_a
      matched_b_eids = b_best.keys.to_a

      # ── Pass 2: cross-category matching for unmatched entities ──
      unmatched_a = a_items.reject { |i| matched_a_eids.include?(i[:eid]) }
      unmatched_b = b_items.reject { |i| matched_b_eids.include?(i[:eid]) }

      if unmatched_a.any? && unmatched_b.any?
        candidates2 = broad_phase(unmatched_a, unmatched_b, cross_category: true)
        puts "[SmartDiff] Pass 2 (cross-cat): #{candidates2.length} candidate pairs"

        pair_scores2 = score_candidates(candidates2, unmatched_a)

        b_best2 = best_matches(pair_scores2)
        a_matched2 = reverse_matches(b_best2)

        # Merge into main results
        b_best.merge!(b_best2)
        a_matched.merge!(a_matched2)
      else
        puts "[SmartDiff] Pass 2 (cross-cat): skipped (no unmatched pairs)"
      end

      # Assign states
      @classification = {}
      @categories     = {}
      @counts         = Hash[STATES.map { |s| [s, 0] }]

      a_items.each do |item|
        @categories[item[:eid]] = item[:category]
        info = a_matched[item[:eid]]
        state = if info
                  info[:score] >= MATCH_THRESHOLD ? :matched : :changed
                else
                  :removed_a
                end
        @classification[item[:eid]] = state
        @counts[state] += 1
      end

      b_items.each do |item|
        @categories[item[:eid]] = item[:category]
        info = b_best[item[:eid]]
        state = if info
                  info[:score] >= MATCH_THRESHOLD ? :matched : :changed
                else
                  :new_b
                end
        @classification[item[:eid]] = state
        @counts[state] += 1
      end

      # Per-category breakdown
      cat_stats = Hash.new { |h, k| h[k] = Hash[STATES.map { |s| [s, 0] }] }
      @classification.each do |eid, state|
        cat = @categories[eid] || '?'
        cat_stats[cat][state] += 1
      end
      cat_stats.sort_by { |c, _| c }.each do |cat, st|
        puts "[SmartDiff] #{cat}: #{st.map { |s, c| "#{s}=#{c}" }.join(' ')}"
      end
    end

    def self.collect_entities
      sr  = TakeoffTool.scan_results          || []
      ca  = TakeoffTool.category_assignments  || {}
      reg = TakeoffTool.entity_registry       || {}

      a_items = []
      b_items = []

      sr.each do |r|
        e = reg[r[:entity_id]]
        next unless e && e.valid? && e.visible?
        ms = e.get_attribute('FormAndField', 'model_source') || 'model_a'
        wb = TakeoffTool.get_world_bounds(e)
        next unless wb && wb[:volume] && wb[:volume] > 0

        cat       = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
        solid_vol = r[:volume_ft3] || 0.0
        dims      = [r[:bb_width_in] || 0, r[:bb_height_in] || 0, r[:bb_depth_in] || 0].sort

        item = { eid: r[:entity_id], entity: e, bounds: wb,
                 category: cat, solid_vol: solid_vol, dims: dims }

        if ms == 'model_a'
          a_items << item
        else
          b_items << item
        end
      end

      [a_items, b_items]
    end

    def self.broad_phase(a_items, b_items, cross_category: false)
      # Index A entities into spatial grid
      grid = Hash.new { |h, k| h[k] = [] }
      a_items.each do |item|
        cells_for_bounds(item[:bounds]).each { |cell| grid[cell] << item }
      end

      candidates = []  # [b_eid, a_eid, bb_ratio]

      b_items.each do |b_item|
        cells   = cells_for_bounds(b_item[:bounds])
        checked = {}
        best_ratio = 0.0
        best_a_eid = nil

        cells.each do |cell|
          (grid[cell] || []).each do |a_item|
            next if checked[a_item[:eid]]
            checked[a_item[:eid]] = true

            # Category gate — skip in cross-category pass
            unless cross_category
              next unless a_item[:category] == b_item[:category]
            end
            next unless geometry_similar?(a_item, b_item)           # volume/dim gate
            next unless bb_overlap?(a_item[:bounds], b_item[:bounds])

            ratio = bb_overlap_ratio(a_item[:bounds], b_item[:bounds])
            if ratio > best_ratio
              best_ratio = ratio
              best_a_eid = a_item[:eid]
            end
          end
        end

        if best_ratio > 0.05 && best_a_eid
          candidates << [b_item[:eid], best_a_eid, best_ratio]
        end
      end

      candidates
    end

    def self.score_candidates(candidates, a_items)
      t0 = Time.now
      pair_scores = {}
      log_count = 0

      candidates.each do |b_eid, a_eid, bb_ratio|
        score = collision_score(b_eid, a_eid)
        final = score || bb_ratio
        pair_scores[[b_eid, a_eid]] = final

        if log_count < 5
          a_cat = a_items.find { |i| i[:eid] == a_eid }&.dig(:category) || '?'
          puts "[SD Score] cat=#{a_cat} bb=#{bb_ratio.round(3)} col=#{score ? score.round(3) : 'nil'} final=#{final.round(3)}"
          log_count += 1
        end
      end

      elapsed = ((Time.now - t0) * 1000).round
      puts "[SmartDiff] Scored #{pair_scores.length} pairs in #{elapsed}ms"
      pair_scores
    end

    def self.best_matches(pair_scores)
      b_best = {}
      pair_scores.each do |(b_eid, a_eid), score|
        if !b_best[b_eid] || score > b_best[b_eid][:score]
          b_best[b_eid] = { a_eid: a_eid, score: score }
        end
      end
      b_best
    end

    def self.reverse_matches(b_best)
      a_matched = {}
      b_best.each_value do |info|
        existing = a_matched[info[:a_eid]]
        if !existing || info[:score] > existing[:score]
          a_matched[info[:a_eid]] = info
        end
      end
      a_matched
    end

    # ═══ COLLISION ENGINE ═══

    def self.extract_world_triangles(eid)
      cached = @geo_cache[eid]
      return cached if cached

      e = TakeoffTool.find_entity(eid)
      return [] unless e && e.valid?

      xform = TakeoffTool.get_accumulated_transform(e)
      defn  = e.respond_to?(:definition) ? e.definition : e

      triangles = []
      collect_faces(defn.entities, xform, triangles)

      @geo_cache[eid] = triangles
      triangles
    end

    def self.collect_faces(entities, parent_xform, triangles)
      entities.each do |ent|
        if ent.is_a?(Sketchup::Face)
          mesh = ent.mesh(0)
          (1..mesh.count_polygons).each do |i|
            pts = mesh.polygon_points_at(i)
            next unless pts && pts.length >= 3
            triangles << pts.map { |p| (parent_xform * p).to_a }
          end
        elsif ent.is_a?(Sketchup::Group) || ent.is_a?(Sketchup::ComponentInstance)
          child_xform = parent_xform * ent.transformation
          child_defn  = ent.respond_to?(:definition) ? ent.definition : ent
          collect_faces(child_defn.entities, child_xform, triangles)
        end
      end
    end

    def self.sample_face_points(triangles, n)
      return [] if triangles.empty?

      areas = triangles.map { |tri| triangle_area(tri) }
      total = areas.sum
      return [] if total <= 0

      points = []
      n.times do
        # Pick triangle weighted by area
        r = rand * total
        cumul = 0.0
        idx   = 0
        areas.each_with_index do |a, i|
          cumul += a
          if cumul >= r
            idx = i
            break
          end
        end

        # Random barycentric point
        tri = triangles[idx]
        u = rand; v = rand
        if u + v > 1.0
          u = 1.0 - u
          v = 1.0 - v
        end

        v0 = tri[0]; v1 = tri[1]; v2 = tri[2]
        points << [
          v0[0] + u * (v1[0] - v0[0]) + v * (v2[0] - v0[0]),
          v0[1] + u * (v1[1] - v0[1]) + v * (v2[1] - v0[1]),
          v0[2] + u * (v1[2] - v0[2]) + v * (v2[2] - v0[2])
        ]
      end
      points
    end

    def self.triangle_area(tri)
      e1x = tri[1][0] - tri[0][0]; e1y = tri[1][1] - tri[0][1]; e1z = tri[1][2] - tri[0][2]
      e2x = tri[2][0] - tri[0][0]; e2y = tri[2][1] - tri[0][1]; e2z = tri[2][2] - tri[0][2]
      cx = e1y * e2z - e1z * e2y
      cy = e1z * e2x - e1x * e2z
      cz = e1x * e2y - e1y * e2x
      Math.sqrt(cx * cx + cy * cy + cz * cz) * 0.5
    end

    # Distance from point to nearest triangle in the set
    def self.nearest_triangle_distance(pt, triangles)
      min_sq = Float::INFINITY
      triangles.each do |tri|
        dsq = point_to_triangle_dist_sq(pt, tri)
        min_sq = dsq if dsq < min_sq
      end
      Math.sqrt(min_sq)
    end

    # Squared distance from point to closest point on triangle.
    # Uses the region-based algorithm from Real-Time Collision Detection (Ericson).
    def self.point_to_triangle_dist_sq(pt, tri)
      v0 = tri[0]; v1 = tri[1]; v2 = tri[2]

      e0x = v1[0] - v0[0]; e0y = v1[1] - v0[1]; e0z = v1[2] - v0[2]
      e1x = v2[0] - v0[0]; e1y = v2[1] - v0[1]; e1z = v2[2] - v0[2]
      vx  = v0[0] - pt[0]; vy  = v0[1] - pt[1]; vz  = v0[2] - pt[2]

      a = e0x * e0x + e0y * e0y + e0z * e0z
      b = e0x * e1x + e0y * e1y + e0z * e1z
      c = e1x * e1x + e1y * e1y + e1z * e1z
      d = e0x * vx  + e0y * vy  + e0z * vz
      e = e1x * vx  + e1y * vy  + e1z * vz

      det = a * c - b * b
      s   = b * e - c * d
      t   = b * d - a * e

      if s + t <= det
        if s < 0
          if t < 0
            # Region 4
            if d < 0
              t = 0.0; s = (-d >= a ? 1.0 : -d / a)
            else
              s = 0.0; t = (e >= 0 ? 0.0 : (-e >= c ? 1.0 : -e / c))
            end
          else
            # Region 3
            s = 0.0; t = (e >= 0 ? 0.0 : (-e >= c ? 1.0 : -e / c))
          end
        elsif t < 0
          # Region 5
          t = 0.0; s = (d >= 0 ? 0.0 : (-d >= a ? 1.0 : -d / a))
        else
          # Region 0 — inside triangle
          inv = 1.0 / det
          s *= inv
          t *= inv
        end
      else
        if s < 0
          # Region 2
          tmp0 = b + d; tmp1 = c + e
          if tmp1 > tmp0
            numer = tmp1 - tmp0; denom = a - 2 * b + c
            s = (numer >= denom ? 1.0 : numer / denom)
            t = 1.0 - s
          else
            s = 0.0; t = (tmp1 <= 0 ? 1.0 : (e >= 0 ? 0.0 : -e / c))
          end
        elsif t < 0
          # Region 6
          tmp0 = b + e; tmp1 = a + d
          if tmp1 > tmp0
            numer = tmp1 - tmp0; denom = a - 2 * b + c
            t = (numer >= denom ? 1.0 : numer / denom)
            s = 1.0 - t
          else
            t = 0.0; s = (tmp1 <= 0 ? 1.0 : (d >= 0 ? 0.0 : -d / a))
          end
        else
          # Region 1
          numer = (c + e) - (b + d)
          if numer <= 0
            s = 0.0; t = 1.0
          else
            denom = a - 2 * b + c
            s = (numer >= denom ? 1.0 : numer / denom)
            t = 1.0 - s
          end
        end
      end

      # Closest point on triangle
      cpx = v0[0] + s * e0x + t * e1x
      cpy = v0[1] + s * e0y + t * e1y
      cpz = v0[2] + s * e0z + t * e1z

      dx = pt[0] - cpx; dy = pt[1] - cpy; dz = pt[2] - cpz
      dx * dx + dy * dy + dz * dz
    end

    # Bidirectional collision score between two entities (0.0–1.0).
    # Samples points on each entity's faces and checks proximity to the other.
    # Returns nil if either entity has no extractable faces (caller uses BB fallback).
    def self.collision_score(eid_a, eid_b)
      tris_a = extract_world_triangles(eid_a)
      tris_b = extract_world_triangles(eid_b)

      return nil if tris_a.empty? || tris_b.empty?

      tol = COLLISION_TOL

      pts_b  = sample_face_points(tris_b, SAMPLE_COUNT)
      hits_ba = pts_b.count { |p| nearest_triangle_distance(p, tris_a) < tol }

      pts_a  = sample_face_points(tris_a, SAMPLE_COUNT)
      hits_ab = pts_a.count { |p| nearest_triangle_distance(p, tris_b) < tol }

      score_ba = pts_b.empty? ? 0.0 : hits_ba.to_f / pts_b.length
      score_ab = pts_a.empty? ? 0.0 : hits_ab.to_f / pts_a.length

      [score_ba, score_ab].min  # conservative: both directions must agree
    end

    # ═══ VISUALIZATION ═══

    def self.backup_and_paint(model, category_filter: nil)
      cat_set = category_filter ? category_filter.map(&:to_s) : nil

      model.rendering_options['DisplayColorByLayer'] = false
      model.start_operation('Smart Diff Paint', true)

      # Create/update materials
      @sd_mats = {}
      COLORS.each do |state, rgb|
        alpha = (@opacity || DEFAULT_OPACITY)[state]
        key   = "FF_SD_#{state}"
        mat   = model.materials[key] || model.materials.add(key)
        mat.color = Sketchup::Color.new(*rgb)
        mat.alpha = alpha
        @sd_mats[state] = mat
      end

      applied = 0
      hidden  = 0

      @classification.each do |eid, state|
        e = TakeoffTool.find_entity(eid)
        next unless e && e.valid?

        # Category filter — hide entities not in selected categories
        if cat_set
          ent_cat = (@categories[eid] || '').to_s
          unless cat_set.include?(ent_cat)
            backup_entity(eid, e)
            e.visible = false
            hidden += 1
            next
          end
        end

        # State visibility toggle
        vis = @visibility || {}
        unless vis.fetch(state, true)
          backup_entity(eid, e)
          e.visible = false
          hidden += 1
          next
        end

        mat = @sd_mats[state]
        next unless mat
        backup_entity(eid, e)
        e.material = mat
        paint_faces(eid, e, mat)
        applied += 1
      end

      model.commit_operation
      model.active_view.invalidate
      puts "[SmartDiff] Painted #{applied}, hidden #{hidden}"
    end

    def self.backup_entity(eid, entity)
      return if @backed_up.key?(eid)
      face_mats = []
      defn = entity.respond_to?(:definition) ? entity.definition : nil
      if defn && defn.count_used_instances <= 1
        defn.entities.grep(Sketchup::Face).each do |f|
          face_mats << [f, f.material, f.back_material]
        end
      end
      @backed_up[eid] = { mat: entity.material, vis: entity.visible?, faces: face_mats }
    end

    def self.paint_faces(eid, entity, mat)
      defn = entity.respond_to?(:definition) ? entity.definition : nil
      return unless defn && defn.count_used_instances <= 1
      defn.entities.grep(Sketchup::Face).each do |f|
        f.material = mat
        f.back_material = mat
      end
    end

    def self.restore_entity(eid)
      info = @backed_up.delete(eid)
      return unless info
      e = TakeoffTool.find_entity(eid)
      unless e && e.valid?
        puts "[SmartDiff] WARN: entity #{eid} invalid on restore"
        return
      end
      e.material = info[:mat]
      e.visible  = info[:vis]
      restored_faces = 0
      invalid_faces = 0
      info[:faces].each do |f, front, back|
        unless f.valid?
          invalid_faces += 1
          next
        end
        f.material      = front
        f.back_material = back
        restored_faces += 1
      end
      if invalid_faces > 0
        puts "[SmartDiff] WARN: eid=#{eid} #{invalid_faces} invalid faces (#{restored_faces} restored)"
      end
    end

    def self.restore_all
      @backed_up.keys.each { |eid| restore_entity(eid) }
      @backed_up.clear
    end

    # ═══ UTILITIES ═══

    def self.cells_for_bounds(wb)
      cs = CELL_SIZE
      x0 = (wb[:min][0] / cs).floor; x1 = (wb[:max][0] / cs).floor
      y0 = (wb[:min][1] / cs).floor; y1 = (wb[:max][1] / cs).floor
      z0 = (wb[:min][2] / cs).floor; z1 = (wb[:max][2] / cs).floor
      cells = []
      (x0..x1).each do |x|
        (y0..y1).each do |y|
          (z0..z1).each do |z|
            cells << "#{x}_#{y}_#{z}"
          end
        end
      end
      cells
    end

    def self.bb_overlap?(a, b)
      a[:min][0] < b[:max][0] && a[:max][0] > b[:min][0] &&
      a[:min][1] < b[:max][1] && a[:max][1] > b[:min][1] &&
      a[:min][2] < b[:max][2] && a[:max][2] > b[:min][2]
    end

    def self.bb_overlap_ratio(a, b)
      xi = [0, [a[:max][0], b[:max][0]].min - [a[:min][0], b[:min][0]].max].max
      yi = [0, [a[:max][1], b[:max][1]].min - [a[:min][1], b[:min][1]].max].max
      zi = [0, [a[:max][2], b[:max][2]].min - [a[:min][2], b[:min][2]].max].max
      inter = xi * yi * zi
      union = a[:volume] + b[:volume] - inter
      union > 0 ? inter / union : 0.0
    end

    def self.geometry_similar?(a, b)
      av = a[:solid_vol]; bv = b[:solid_vol]
      if av > 0 && bv > 0
        ratio = av > bv ? av / bv : bv / av
        return false if ratio > 3.0
      end
      ad = a[:dims]; bd = b[:dims]
      if ad && bd && ad.length == 3 && bd.length == 3
        3.times do |i|
          next if ad[i] < 1.0 && bd[i] < 1.0
          larger  = [ad[i], bd[i]].max
          smaller = [ad[i], bd[i]].min
          return false if smaller > 0 && larger / smaller > 2.0
        end
      end
      true
    end

    def self.primary_quantity(r, mt)
      case mt
      when 'lf'                    then r[:linear_ft]  || 0.0
      when 'sf', 'sf_cy', 'sf_sheets' then r[:area_sf] || 0.0
      when 'cy'                    then (r[:volume_ft3] || 0.0) / 27.0
      when 'volume'                then r[:volume_ft3]  || 0.0
      when 'bf'                    then r[:volume_bf]   || 0.0
      else 1.0
      end
    end

    # ═══ CLASSIFICATION CACHE ═══

    def self.save_classification_cache(model)
      return if @classification.empty?
      require 'json'

      # Build cache fingerprint from scan result count + entity count
      sr = TakeoffTool.scan_results || []
      fingerprint = "#{sr.length}_#{model.definitions.count { |d| !d.image? && d.instances.length > 0 }}"

      cache = {
        'fingerprint' => fingerprint,
        'timestamp' => Time.now.to_i,
        'classification' => {},
        'categories' => {},
        'counts' => {}
      }
      @classification.each { |eid, state| cache['classification'][eid.to_s] = state.to_s }
      @categories.each { |eid, cat| cache['categories'][eid.to_s] = cat }
      @counts.each { |state, n| cache['counts'][state.to_s] = n }

      model.set_attribute('FormAndField', 'smart_diff_cache', JSON.generate(cache))
      puts "[SmartDiff] Classification cached (#{@classification.length} entities, fingerprint=#{fingerprint})"
    end

    def self.load_cached_classification(model)
      json = model.get_attribute('FormAndField', 'smart_diff_cache')
      return false unless json && !json.empty?

      require 'json'
      cache = JSON.parse(json) rescue nil
      return false unless cache

      # Validate fingerprint — model must not have changed
      sr = TakeoffTool.scan_results || []
      fingerprint = "#{sr.length}_#{model.definitions.count { |d| !d.image? && d.instances.length > 0 }}"
      if cache['fingerprint'] != fingerprint
        puts "[SmartDiff] Cache stale (#{cache['fingerprint']} vs #{fingerprint}) — reclassifying"
        return false
      end

      # Restore classification
      @classification = {}
      @categories = {}
      @counts = Hash[STATES.map { |s| [s, 0] }]

      (cache['classification'] || {}).each do |eid_s, state_s|
        eid = eid_s.to_i
        state = state_s.to_sym
        next unless STATES.include?(state)
        # Verify entity still exists
        e = TakeoffTool.find_entity(eid)
        next unless e && e.valid?
        @classification[eid] = state
        @counts[state] += 1
      end
      (cache['categories'] || {}).each do |eid_s, cat|
        @categories[eid_s.to_i] = cat
      end

      age = Time.now.to_i - (cache['timestamp'] || 0)
      puts "[SmartDiff] Cache loaded: #{@classification.length} entities, age=#{age}s"
      @classification.any?
    end

    def self.invalidate_cache
      m = Sketchup.active_model
      m.set_attribute('FormAndField', 'smart_diff_cache', nil) if m
      puts "[SmartDiff] Cache invalidated"
    end

    def self.clear_state
      @active         = false
      @classification = {}
      @categories     = {}
      @counts         = {}
      @geo_cache      = {}
      @sd_mats        = {}
      @opacity        = nil
      @visibility     = nil
    end

  end
end
